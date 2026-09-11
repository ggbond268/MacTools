import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class EmptyTrashPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        EmptyTrashPluginProvider(context: context)
    }
}

@MainActor
private struct EmptyTrashPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [EmptyTrashPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class EmptyTrashPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginPanelSurfaceLifecycleHandling,
    PluginActionProviding, PluginActionPermissionProviding
{
    private enum PermissionID {
        static let automation = "automation"
    }
    private enum ActionID {
        static let empty = "empty"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let countItems: @Sendable () async throws -> Int
    private let emptyItems: () async throws -> Void
    private let countRefreshDelay: Duration
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EmptyTrashPlugin")
    private var itemCount: Int = 0
    private var isEmptying = false
    private var lastErrorMessage: String?
    private var isPrimaryPanelVisible = false
    private var countRefreshTask: Task<Void, Never>?

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        countItems: @escaping @Sendable () async throws -> Int = EmptyTrashPlugin.fetchTrashItemCount,
        emptyItems: (() async throws -> Void)? = nil,
        countRefreshDelay: Duration = .milliseconds(150)
    ) {
        self.localization = localization
        self.countItems = countItems
        let errorMessage = localization.string(
            "error.emptyFailed",
            defaultValue: "清空废纸篓失败，请检查“自动操作”权限"
        )
        self.emptyItems = emptyItems ?? {
            try await EmptyTrashPlugin.emptyTrashViaAppleScript(errorMessage: errorMessage)
        }
        self.countRefreshDelay = countRefreshDelay
        self.metadata = PluginMetadata(
            id: "empty-trash",
            title: localization.string("metadata.title", defaultValue: "清空废纸篓"),
            iconName: "trash",
            iconTint: Color(nsColor: .systemGray),
            order: 93,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "清空废纸篓中的所有项目"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: { localization.string("panel.button.empty", defaultValue: "清空") }
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: subtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: !isEmptying && itemCount > 0,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.automation,
                kind: .automation,
                title: localization.string("permission.automation.title", defaultValue: "Finder 自动化"),
                description: localization.string(
                    "permission.automation.description",
                    defaultValue: "用于读取并清空废纸篓。"
                )
            )
        ]
    }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.empty),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "trash", "delete"],
                systemImage: metadata.iconName,
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: metadata.title,
                    message: metadata.defaultDescription,
                    confirmButtonTitle: localization.string("panel.button.empty", defaultValue: "清空")
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.automatic, .background, .foregroundInteractive],
                executionTimeoutSeconds: 600
            ),
        ]
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        guard actionKey.providerID == metadata.id, actionKey.actionID == ActionID.empty else {
            return []
        }
        return [PermissionID.automation]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.empty else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return isEmptying ? .unavailable(subtitle) : .available
    }

    func refresh() {
        scheduleCountRefreshIfVisible()
    }

    func deactivate(reason _: PluginDeactivationReason) {
        countRefreshTask?.cancel()
        countRefreshTask = nil
        isPrimaryPanelVisible = false
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        guard surface == .primary else {
            return
        }

        isPrimaryPanelVisible = true
        scheduleCountRefresh()
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        guard surface == .primary else {
            return
        }

        isPrimaryPanelVisible = false
        countRefreshTask?.cancel()
        countRefreshTask = nil
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            if controlID == "execute" {
                emptyTrash()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.automation else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: lastErrorMessage == nil,
            footnote: lastErrorMessage
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.automation,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.empty else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.performCanonicalEmpty()
        }
    }

    // MARK: - Private

    private func scheduleCountRefresh() {
        countRefreshTask?.cancel()
        let delay = countRefreshDelay
        countRefreshTask = Task { @MainActor [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else {
                return
            }

            do {
                let count = try await self.countItems()
                guard !Task.isCancelled else { return }
                self.lastErrorMessage = nil
                if self.itemCount != count {
                    self.itemCount = count
                    self.onStateChange?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.itemCount = 0
                self.lastErrorMessage = error.localizedDescription
                self.onStateChange?()
            }
            self.countRefreshTask = nil
        }
    }

    private func scheduleCountRefreshIfVisible() {
        guard isPrimaryPanelVisible else {
            return
        }

        scheduleCountRefresh()
    }

    private var subtitle: String {
        if isEmptying {
            return localization.string("panel.subtitle.emptying", defaultValue: "清空中...")
        }
        if itemCount == 0 {
            return localization.string("panel.subtitle.empty", defaultValue: "废纸篓为空")
        }
        return localization.format("panel.subtitle.countFormat", defaultValue: "%d 个项目", itemCount)
    }

    @MainActor
    private func emptyTrash() {
        guard !isEmptying, itemCount > 0 else { return }
        isEmptying = true
        lastErrorMessage = nil
        onStateChange?()

        Task {
            _ = await self.finishEmptying()
        }
    }

    // MARK: - AppleScript helpers

    private static func fetchTrashItemCount() async throws -> Int {
        let script = "tell application \"Finder\" to count items of trash"
        return try await Task.detached(priority: .userInitiated) {
            guard let output = runOsascriptStandalone(script), let count = Int(output) else {
                throw NSError(
                    domain: "EmptyTrashPlugin",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取废纸篓，请检查“自动化”权限。"]
                )
            }
            return count
        }.value
    }

    private static func emptyTrashViaAppleScript(errorMessage: String) async throws {
        let script = "tell application \"Finder\" to empty trash"
        try await Task.detached(priority: .userInitiated) {
             if runOsascriptStandalone(script) == nil {
                throw NSError(
                    domain: "EmptyTrashPlugin",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
            }
        }.value
    }

    private func performCanonicalEmpty() async -> ActionExecutionResult {
        guard !isEmptying else {
            return .failed(message: subtitle)
        }

        let count: Int
        do {
            count = try await countItems()
            itemCount = count
            lastErrorMessage = nil
        } catch {
            itemCount = 0
            lastErrorMessage = error.localizedDescription
            onStateChange?()
            return .failed(message: error.localizedDescription)
        }
        guard count > 0 else {
            onStateChange?()
            return .succeeded(message: localization.string(
                "panel.subtitle.empty",
                defaultValue: "废纸篓为空"
            ))
        }

        isEmptying = true
        lastErrorMessage = nil
        onStateChange?()
        return await finishEmptying()
    }

    private func finishEmptying() async -> ActionExecutionResult {
        do {
            try await emptyItems()
            guard !Task.isCancelled else {
                isEmptying = false
                onStateChange?()
                return .cancelled
            }
            isEmptying = false
            itemCount = 0
            onStateChange?()
            scheduleCountRefreshIfVisible()
            return .succeeded()
        } catch {
            isEmptying = false
            lastErrorMessage = error.localizedDescription
            onStateChange?()
            scheduleCountRefreshIfVisible()
            logger.error("Empty trash failed: \(error)")
            return .failed(message: error.localizedDescription)
        }
    }
}

private func runOsascriptStandalone(_ script: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}
