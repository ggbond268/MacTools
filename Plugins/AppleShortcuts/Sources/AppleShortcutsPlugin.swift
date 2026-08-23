import AppKit
import Foundation
import MacToolsPluginKit
import SwiftUI

public final class AppleShortcutsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppleShortcutsPluginProvider(context: context)
    }
}

@MainActor
private struct AppleShortcutsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [AppleShortcutsPlugin(context: context)]
    }
}

@MainActor
final class AppleShortcutsPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding,
    PluginActionSafetyStateChangeProviding,
    PluginActionExposureProviding,
    PluginSettingsSearchFocusing
{
    let metadata: PluginMetadata
    let store: AppleShortcutsStore
    let controller: AppleShortcutsController
    let settingsSearchFocusController = AppleShortcutsSettingsSearchFocusController()

    var onStateChange: (() -> Void)?
    var onActionSafetyStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let beforeActionRegistration: (@MainActor () async -> Void)?

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil,
        runner: (any AppleShortcutsCommandRunning)? = nil,
        visualMetadataLoader: (any AppleShortcutsVisualMetadataLoading)? = nil,
        now: @escaping () -> Date = { .now },
        beforeActionRegistration: (@MainActor () async -> Void)? = nil
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        let store = AppleShortcutsStore(storage: context.storage)
        self.localization = localization
        self.beforeActionRegistration = beforeActionRegistration
        self.store = store
        self.controller = AppleShortcutsController(
            runner: runner ?? ProcessAppleShortcutsCommandRunner(),
            visualMetadataLoader: visualMetadataLoader ?? AppleShortcutsVisualMetadataLoader(),
            localization: localization,
            now: now
        )
        self.metadata = PluginMetadata(
            id: "apple-shortcuts",
            title: localization.string("metadata.title", defaultValue: "Apple 快捷指令"),
            iconName: "square.stack.3d.up.fill",
            iconTint: Color(nsColor: .systemPurple),
            order: 74,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "发现并运行现有的 Apple 快捷指令"
            )
        )
        controller.onStateChange = { [weak self] in self?.onStateChange?() }
        store.onSafetyPolicyMutation = { [weak self] in self?.onActionSafetyStateChange?() }
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(
            description: localization.string(
                "metadata.description",
                defaultValue: "发现并运行现有的 Apple 快捷指令"
            ),
            scrolling: .selfManaged
        ) { [weak self] _ in
            if let self {
                AppleShortcutsSettingsView(plugin: self)
            } else {
                EmptyView()
            }
        }
        .onVisibilityChange { [weak self] visible in
            self?.controller.setSettingsVisible(visible)
        }
    }

    func focusSettingsSearch() {
        settingsSearchFocusController.requestFocus()
    }

    var actionDefinitions: [ActionDefinition] {
        controller.snapshot.discovery.shortcuts.map { item in
            let policy = store.policy(for: item.id)
            let title = item.name
            return ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: item.actionID),
                title: title,
                description: localization.format(
                    "action.description.format",
                    defaultValue: "运行 Apple 快捷指令“%@”。",
                    title
                ),
                keywords: actionKeywords(for: item, title: title),
                systemImage: "square.stack.3d.up.fill",
                risk: policy.requiresConfirmation ? .confirmationRequired : .safe,
                // Run Links always require confirmation, even when direct MacTools runs do not.
                // The action registry also requires this metadata for `.confirmAlways` actions.
                confirmation: ActionConfirmation(
                    title: localization.format(
                        "action.confirm.title.format",
                        defaultValue: "运行“%@”？",
                        title
                    ),
                    message: localization.string(
                        "action.confirm.message",
                        defaultValue: "此快捷指令将通过 Apple“快捷指令”运行，并可能访问其他应用或数据。"
                    ),
                    confirmButtonTitle: localization.string(
                        "action.confirm.button",
                        defaultValue: "运行"
                    )
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.background, .foregroundInteractive, .cancellable],
                executionTimeoutSeconds: ProcessAppleShortcutsCommandRunner.runTimeout
                    + ProcessAppleShortcutsCommandRunner.actionExecutionTimeoutGraceSeconds
            )
        }
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        controller.snapshot.discovery.shortcuts.map { item in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: item.actionID)
                ),
                title: item.name,
                subtitle: actionFolderSubtitle(for: item),
                presentationState: controller.isRunning(item.id) ? .active : .inactive
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard let item = item(for: reference) else {
            return .unavailable(localization.string(
                "action.unavailable.missing",
                defaultValue: "在 Apple“快捷指令”中找不到此项目。"
            ))
        }
        guard controller.isExecutableAvailable else {
            return .unavailable(localization.string(
                "action.unavailable.executable",
                defaultValue: "系统未提供“快捷指令”命令。"
            ))
        }
        guard !controller.isRunning(item.id) else {
            return .unavailable(localization.string(
                "action.unavailable.running",
                defaultValue: "此快捷指令正在运行。"
            ))
        }
        return .available
    }

    func exposurePolicy(
        for reference: ActionReference,
        on surface: ActionExposureSurface
    ) -> ActionExposurePolicy {
        surface == .appIntents ? .excluded : .automatic
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let item = item(for: invocation.reference) else {
            return ActionExecutionHandle { [localization] in
                .failed(message: localization.string(
                    "action.unavailable.missing",
                    defaultValue: "在 Apple“快捷指令”中找不到此项目。"
                ))
            }
        }
        return ActionExecutionHandle { [weak self] in
            guard !Task.isCancelled else { return .cancelled }
            guard let self else { return .cancelled }
            if let beforeActionRegistration = self.beforeActionRegistration {
                await beforeActionRegistration()
            }
            guard !Task.isCancelled else { return .cancelled }
            let startResult = controller.startExecution(
                shortcutID: item.id,
                name: item.name
            )
            switch startResult {
            case let .success(run):
                return await controller.waitForExecution(run, shortcutID: item.id)
            case .failure(.cancelled):
                return .cancelled
            case let .failure(error):
                return .failed(message: controller.executionStartMessage(for: error))
            }
        } cancel: { [weak self] in
            self?.controller.cancelExecution(shortcutID: item.id)
        }
    }

    func activate(context _: PluginRuntimeContext) { controller.activate() }
    func refresh() { controller.refreshIfNeeded() }
    func deactivate(reason _: PluginDeactivationReason) { controller.deactivate() }

    func makePortablePreferencesBackup() -> Data? { store.portableBackup() }
    func restorePortablePreferences(from data: Data) { _ = store.restorePortableBackup(data) }
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        store.restorePortableBackup(data)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        store.actionIDs(inPortableBackup: data)?.map {
            ActionReference(key: ActionKey(providerID: metadata.id, actionID: $0))
        }
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        item(for: reference) == nil ? .excluded : .requiresPluginPreferences
    }

    func item(id: UUID) -> AppleShortcutItem? {
        controller.snapshot.discovery.shortcuts.first { $0.id == id }
    }

    func folder(id: UUID) -> AppleShortcutFolder? {
        controller.snapshot.discovery.folders.first { $0.id == id }
    }

    func localized(_ key: String, defaultValue: String) -> String {
        localization.string(key, defaultValue: defaultValue)
    }

    func localizedFormat(_ key: String, defaultValue: String, _ argument: CVarArg) -> String {
        localization.format(key, defaultValue: defaultValue, argument)
    }

    func localizedFormat(
        _ key: String,
        defaultValue: String,
        _ firstArgument: CVarArg,
        _ secondArgument: CVarArg
    ) -> String {
        localization.format(
            key,
            defaultValue: defaultValue,
            firstArgument,
            secondArgument
        )
    }

    private func item(for reference: ActionReference) -> AppleShortcutItem? {
        guard reference.key.providerID == metadata.id,
              reference.schemaVersion == 1,
              reference.parameters.entries.isEmpty,
              let id = AppleShortcutsStore.shortcutID(fromActionID: reference.key.actionID) else {
            return nil
        }
        return item(id: id)
    }

    private func actionKeywords(
        for item: AppleShortcutItem,
        title: String
    ) -> [String] {
        let folderNames = folderNames(for: item)
        return [metadata.title, title, "Apple", "Shortcuts", "快捷指令"] + folderNames
    }

    private func actionFolderSubtitle(for item: AppleShortcutItem) -> String? {
        let names = folderNames(for: item)
        guard !names.isEmpty else { return nil }
        return AppleShortcutsSettingsFormatting.joinedFolderNames(names)
    }

    private func folderNames(for item: AppleShortcutItem) -> [String] {
        item.folderIDs
            .compactMap { folder(id: $0)?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
