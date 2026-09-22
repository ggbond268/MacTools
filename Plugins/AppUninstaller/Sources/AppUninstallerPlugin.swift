import Foundation
import AppKit
import SwiftUI
import MacToolsPluginKit

public final class AppUninstallerPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppUninstallerProvider(context: context)
    }
}

@MainActor
private struct AppUninstallerProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        let configuration = UninstallConfiguration.system()
        let scanner = UninstallScanner(configuration: configuration)
        let environment = UninstallSystemEnvironment(configuration: configuration)
        let temporaryDirectory = context.temporaryDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MacTools-AppUninstaller", isDirectory: true)
        let engineRoot = context.resourceBundle.url(
            forResource: "mactools-engine",
            withExtension: "sh",
            subdirectory: "MoleEngine"
        )?.deletingLastPathComponent()
            ?? context.resourceBundle.resourceURL?.appendingPathComponent("MoleEngine", isDirectory: true)
            ?? temporaryDirectory.appendingPathComponent("MissingMoleEngine", isDirectory: true)
        let engine = BundledMoleEngine(rootURL: engineRoot, temporaryDirectory: temporaryDirectory)
        let service = MoleBackedUninstallReviewService(scanner: scanner, environment: environment, engine: engine)
        let history = context.supportDirectory.map { UninstallHistory(directory: $0.appendingPathComponent("UninstallHistory", isDirectory: true)) }
        let executor = history.map {
            UninstallExecutor(scanner: scanner, environment: environment, history: $0, reviewer: service)
        }
        let localization = PluginLocalization(bundle: context.resourceBundle)
        return [AppUninstallerPlugin(controller: .init(service: service, executor: executor, history: history,
                                                       localization: localization), localization: localization)]
    }
}

@MainActor
final class AppUninstallerPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginSettingsPresenting, PluginActionProviding, PluginActionExecutionHostContextConsuming {
    static let pluginID = "app-uninstaller"
    static let reviewActionID = "open-review"
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var actionExecutionHostContext: PluginActionExecutionHostContext?
    private let controller: AppUninstallerController
    private let localization: PluginLocalization
    private var fullDiskAccess = false
    private let permissionProbe: @Sendable () -> Bool
    private let settingsOpener: @MainActor (URL) -> Bool

    init(controller: AppUninstallerController, localization: PluginLocalization,
         permissionProbe: @escaping @Sendable () -> Bool = { AppUninstallerFullDiskAccessProbe.hasAccess() },
         settingsOpener: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.controller = controller; self.localization = localization
        self.permissionProbe = permissionProbe; self.settingsOpener = settingsOpener
        metadata = PluginMetadata(id: Self.pluginID, title: localization.string("metadata.title", defaultValue: "应用卸载"),
            iconName: "app.badge.checkmark", iconTint: .orange, order: 93,
            defaultDescription: localization.string("metadata.description", defaultValue: "检查归属证据，确认后将应用与选定的关联文件移入废纸篓。"))
        primaryPanelDescriptor = .init(controlStyle: .button, menuActionBehavior: .dismissBeforeHandling,
                                     buttonTitleProvider: { localization.string("review.open", defaultValue: "检查") })
        controller.onStateChange = { [weak self] in self?.onStateChange?() }
        controller.openHomebrew = { [weak self] in self?.actionExecutionHostContext?.openProviderSettings(providerID: "homebrew") }
        controller.openXcodeStorage = { [weak self] in self?.actionExecutionHostContext?.openProviderSettings(providerID: "xcode-clean") }
        controller.openFullDiskAccess = { [weak self] in self?.handlePermissionAction(id: "full-disk-access") }
    }

    var primaryPanelState: PluginPanelState {
        .init(subtitle: metadata.defaultDescription, isOn: controller.isScanning || controller.isRemoving, isExpanded: false,
              isEnabled: true, isVisible: true, detail: nil, errorMessage: controller.error)
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var permissionRequirements: [PluginPermissionRequirement] {
        [.init(id: "full-disk-access", kind: .automation,
               title: localization.string("permission.title", defaultValue: "完全磁盘访问"),
               description: localization.string("permission.description", defaultValue: "检查受保护的关联位置；未授权的位置会显示检查不完整。"))]
    }
    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .selfManaged) { [controller, localization] _ in
            AppUninstallerView(controller: controller, localization: localization)
        }
    }
    func activate(context: PluginRuntimeContext) {
        controller.activate()
        let probe = permissionProbe
        Task.detached { [weak self] in
            let granted = probe()
            await self?.updatePermission(granted)
        }
    }
    private func updatePermission(_ granted: Bool) { fullDiskAccess = granted; onStateChange?() }
    func permissionState(for permissionID: String) -> PluginPermissionState {
        .init(isGranted: permissionID == "full-disk-access" && fullDiskAccess,
              footnote: fullDiskAccess ? nil : localization.string("permission.unknown", defaultValue: "尚未确认完全磁盘访问。扫描会显示实际可读范围；授权后请重新打开 MacTools。"))
    }
    func handlePermissionAction(id: String) {
        guard id == "full-disk-access", let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        _ = settingsOpener(url)
    }
    func deactivate(reason: PluginDeactivationReason) { controller.deactivate() }
    func refresh() { controller.refreshRunningState() }
    func handleAction(_ action: PluginPanelAction) {
        guard case .invokeAction("execute") = action else { return }
        requestSettingsPresentation?()
    }
    var actionDefinitions: [ActionDefinition] {
        [.init(key: .init(providerID: Self.pluginID, actionID: Self.reviewActionID), title: metadata.title,
               description: metadata.defaultDescription, keywords: ["app", "uninstall", "review", "应用", "卸载", "检查"],
               systemImage: metadata.iconName, externalInvocationPolicy: .unavailable, capabilities: [.foregroundInteractive])]
    }
    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        valid(reference) ? .available : .unavailable(PluginKitLocalization.actionUnavailable)
    }
    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard valid(invocation.reference) else { return .init { .failed(message: PluginKitLocalization.actionUnavailable) } }
        return .init { [weak self] in
            guard let self, let show = self.requestSettingsPresentation else {
                return .failed(message: PluginKitLocalization.actionUnavailable)
            }
            show()
            return .succeeded()
        }
    }
    private func valid(_ reference: ActionReference) -> Bool {
        reference.key == .init(providerID: Self.pluginID, actionID: Self.reviewActionID)
            && reference.schemaVersion == 1 && reference.parameters.entries.isEmpty
    }
}
