import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class WindowSwitcherPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        WindowSwitcherPluginProvider(context: context)
    }
}

@MainActor
private struct WindowSwitcherPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            WindowSwitcherPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class WindowSwitcherPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing,
    PluginShortcutEventHandling, PluginActionProviding, PluginActionPermissionProviding {
    private enum SettingsID {
        static let enabled = "enabled"
        static let mode = "mode"
        static let sortMode = "sort-mode"
    }
    private enum Session {
        case direct(entries: [WindowSwitcherAppEntry], selectedIndex: Int)
        case keyWindow(entries: [WindowSwitcherAppEntry])
    }

    let metadata: PluginMetadata

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    let store: WindowSwitcherStore

    private let localization: PluginLocalization
    private let appCatalog: WindowSwitcherAppCatalog
    private let overlayController: WindowSwitcherOverlayController
    private let shortcutTap: WindowSwitcherShortcutTap
    private let sessionEntriesProvider: (@MainActor () async -> [WindowSwitcherAppEntry])?
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool

    private var isAccessibilityGranted: Bool
    private var lastErrorMessage: String?
    private var session: Session?
    private var isPreparingSession = false
    private var pendingDirectRelease = false
    private var pendingDirectAdvance = 0
    private var pendingDirectReversed = false
    private var sessionPreparationGeneration: UInt64 = 0
    private var sessionPreparationTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    private var activationTask: Task<Void, Never>?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        appCatalog: WindowSwitcherAppCatalog = WindowSwitcherAppCatalog(),
        overlayController: WindowSwitcherOverlayController = WindowSwitcherOverlayController(),
        shortcutTap: WindowSwitcherShortcutTap = WindowSwitcherShortcutTap(),
        sessionEntriesProvider: (@MainActor () async -> [WindowSwitcherAppEntry])? = nil,
        accessibilityTrusted: @escaping @MainActor () -> Bool = WindowSwitcherAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = WindowSwitcherAccessibilityCheck.requestTrust(prompt:)
    ) {
        self.localization = localization
        self.store = WindowSwitcherStore(storage: context.storage)
        self.appCatalog = appCatalog
        self.overlayController = overlayController
        self.shortcutTap = shortcutTap
        self.sessionEntriesProvider = sessionEntriesProvider
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isAccessibilityGranted = accessibilityTrusted()
        self.metadata = PluginMetadata(
            id: WindowSwitcherConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "窗口切换"),
            iconName: "rectangle.2.swap",
            iconTint: Color(nsColor: .systemIndigo),
            order: 64,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速切换正在运行的窗口"
            )
        )

        self.appCatalog.onChange = { [weak self] in
            self?.onStateChange?()
        }
        self.overlayController.onSelect = { [weak self] entry in
            self?.select(entry)
        }
        self.overlayController.onQuit = { [weak self] entry in
            self?.quit(entry)
        }
        self.overlayController.onShortcutChange = { [weak self] entry, token in
            self?.changeShortcut(for: entry, to: token) ?? .unavailable
        }
        self.overlayController.onCancel = { [weak self] in
            self?.cancelSession()
        }
        self.shortcutTap.onShortcutPressed = { [weak self] reversed, isRepeat in
            self?.handleShortcutPressed(reversed: reversed, isRepeat: isRepeat)
        }
        self.shortcutTap.onShortcutReleased = { [weak self] in
            self?.handleShortcutReleased()
        }
        self.shortcutTap.onAccessibilityRevoked = { [weak self] in
            self?.refreshAccessibilityPermission()
        }
        self.shortcutTap.onEscape = { [weak self] in
            self?.cancelSession()
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: WindowSwitcherConstants.accessibilityPermissionID,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于接管切换快捷键并切换其他应用窗口。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: WindowSwitcherConstants.shortcutDefinitionID,
                title: localization.string("shortcut.switcher.title", defaultValue: "窗口切换"),
                description: localization.string(
                    "shortcut.switcher.description",
                    defaultValue: "显示或切换正在运行的窗口。"
                ),
                actionID: WindowSwitcherConstants.shortcutActionID,
                scope: .whilePluginActive,
                defaultBinding: WindowSwitcherShortcutBindingStore.defaultBinding,
                isRequired: true,
                settingsGroupID: "window-switcher",
                settingsGroupTitle: localization.string("shortcut.group.title", defaultValue: "窗口切换"),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "修改用于唤起窗口切换的快捷键。"
                )
            ),
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: WindowSwitcherConstants.shortcutActionID
                ),
                title: localization.string(
                    "shortcut.switcher.title",
                    defaultValue: "窗口切换"
                ),
                description: localization.string(
                    "shortcut.switcher.description",
                    defaultValue: "显示或切换正在运行的窗口。"
                ),
                keywords: [metadata.title, "Window Switcher"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    func permissionRequirementIDs(for actionKey: ActionKey) -> [String] {
        actionKey == actionDefinitions.first?.key
            ? [WindowSwitcherConstants.accessibilityPermissionID]
            : []
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key == actionDefinitions.first?.key else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        guard store.configuration.isEnabled else {
            return .unavailable(localization.string(
                "settings.status.disabled.description",
                defaultValue: "暂停快捷键监听，系统默认切换保持不变。"
            ))
        }
        guard isAccessibilityGranted else {
            return .unavailable(localization.string(
                "error.accessibilityRequired",
                defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。"
            ))
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }
        // Canonical actions have no key-up phase. Always open the interactive
        // chooser instead of starting a direct-cycle session that could never commit.
        return ActionExecutionHandle { @MainActor [weak self] in
            guard let self,
                  let generation = self.beginSessionPreparation(),
                  await self.beginKeyWindowSession(generation: generation)
            else {
                return .failed(message: PluginKitLocalization.actionUnavailable)
            }

            return .succeeded()
        }
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "status",
                    title: localization.string("settings.status.sectionTitle", defaultValue: "状态"),
                    systemImage: "power",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.enabled,
                            title: localization.string("settings.status.title", defaultValue: "启用窗口切换"),
                            description: store.configuration.isEnabled
                                ? localization.string("settings.status.enabled.description", defaultValue: "接管切换快捷键，显示并切换应用窗口。")
                                : localization.string("settings.status.disabled.description", defaultValue: "暂停快捷键监听，系统默认切换保持不变。"),
                            systemImage: "rectangle.2.swap",
                            control: .toggle(isOn: store.configuration.isEnabled)
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "switching-mode",
                    title: localization.string("settings.mode.sectionTitle", defaultValue: "切换模式"),
                    systemImage: "rectangle.2.swap",
                    rows: [
                        PluginSettingsRow(
                            id: SettingsID.mode,
                            title: localization.string("settings.mode.title", defaultValue: "默认行为"),
                            description: settingsModeDescription,
                            systemImage: "keyboard",
                            control: .picker(
                                selectionID: store.configuration.mode.rawValue,
                                options: [
                                    PluginSettingsOption(
                                        id: WindowSwitcherMode.keyWindow.rawValue,
                                        title: localization.string("settings.mode.keyWindow", defaultValue: "按键直达")
                                    ),
                                    PluginSettingsOption(
                                        id: WindowSwitcherMode.directCycle.rawValue,
                                        title: localization.string("settings.mode.directCycle", defaultValue: "连续切换")
                                    )
                                ],
                                style: .segmented
                            )
                        ),
                        PluginSettingsRow(
                            id: SettingsID.sortMode,
                            title: localization.string("settings.sort.title", defaultValue: "排序"),
                            description: settingsSortDescription,
                            systemImage: "arrow.up.arrow.down",
                            control: .picker(
                                selectionID: store.configuration.sortMode.rawValue,
                                options: [
                                    PluginSettingsOption(
                                        id: WindowSwitcherSortMode.recentUse.rawValue,
                                        title: localization.string("settings.sort.recentUse", defaultValue: "最近使用")
                                    ),
                                    PluginSettingsOption(
                                        id: WindowSwitcherSortMode.fixed.rawValue,
                                        title: localization.string("settings.sort.fixed", defaultValue: "固定排序")
                                    )
                                ],
                                style: .segmented
                            )
                        )
                    ]
                )
            ]
        )
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
        syncCatalogDiscovery()
        syncShortcutTap()
    }

    func deactivate(reason: PluginDeactivationReason) {
        shortcutTap.stop()
        appCatalog.stop()
        overlayController.hide()
        session = nil
        invalidateSessionPreparation()
        invalidateActivation()
    }

    func refresh() {
        refreshAccessibilityPermission()
        syncCatalogDiscovery()
        syncShortcutTap()
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == WindowSwitcherConstants.accessibilityPermissionID else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == WindowSwitcherConstants.accessibilityPermissionID else {
            return
        }

        handleAccessibilityPermissionAction()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value):
            guard controlID == SettingsID.enabled else { return }
            store.setEnabled(value)
        case let .setSelection(controlID, optionID):
            switch controlID {
            case SettingsID.mode:
                guard let mode = WindowSwitcherMode(rawValue: optionID) else { return }
                store.setMode(mode)
            case SettingsID.sortMode:
                guard let sortMode = WindowSwitcherSortMode(rawValue: optionID) else { return }
                store.setSortMode(sortMode)
            default:
                return
            }
        default:
            return
        }
        configurationDidChange()
    }

    func handleShortcutAction(id: String) {
        guard id == WindowSwitcherConstants.shortcutActionID,
              store.configuration.isEnabled
        else {
            return
        }

        handleShortcutPressed(reversed: false, isRepeat: false)
    }

    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {
        guard id == WindowSwitcherConstants.shortcutActionID,
              store.configuration.isEnabled
        else {
            return
        }

        switch phase {
        case .pressed:
            handleShortcutPressed(reversed: false, isRepeat: false)
        case .released:
            handleShortcutReleased()
        }
    }

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            shortcutTap.stop()
            appCatalog.stop()
            overlayController.hide()
            session = nil
            invalidateSessionPreparation()
            invalidateActivation()
            if store.configuration.isEnabled {
                lastErrorMessage = localization.string(
                    "error.accessibilityRevoked",
                    defaultValue: "辅助功能权限已关闭，窗口切换已暂停。"
                )
            }
        } else if !previous && isAccessibilityGranted {
            lastErrorMessage = nil
            syncCatalogDiscovery()
            syncShortcutTap()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private var settingsModeDescription: String {
        switch store.configuration.mode {
        case .keyWindow:
            localization.string(
                "settings.mode.keyWindow.description",
                defaultValue: "显示固定窗口，按条目上方字母直达。"
            )
        case .directCycle:
            localization.string(
                "settings.mode.directCycle.description",
                defaultValue: "按住快捷键循环选择，松开后切换窗口。"
            )
        }
    }

    private var settingsSortDescription: String {
        switch store.configuration.sortMode {
        case .recentUse:
            localization.string(
                "settings.sort.recentUse.description",
                defaultValue: "按最近使用的应用排列，便于快速回到上一个窗口。"
            )
        case .fixed:
            localization.string(
                "settings.sort.fixed.description",
                defaultValue: "按应用名称稳定排列，位置更容易记住。"
            )
        }
    }

    private func configurationDidChange() {
        overlayController.hide()
        session = nil
        invalidateSessionPreparation()
        invalidateActivation()
        if !store.configuration.isEnabled {
            lastErrorMessage = nil
        }
        syncCatalogDiscovery()
        syncShortcutTap()
        onStateChange?()
    }

    func handleShortcutPressed(reversed: Bool, isRepeat: Bool) {
        guard store.configuration.isEnabled else {
            return
        }

        var startsNewGesture = false
        if !isRepeat, session == nil {
            if isPreparingSession, pendingDirectRelease {
                pendingDirectRelease = false
                pendingDirectAdvance = 0
                pendingDirectReversed = reversed
                startsNewGesture = true
            } else if !isPreparingSession {
                pendingDirectRelease = false
                pendingDirectAdvance = 0
                pendingDirectReversed = false
            }
        }

        guard ensureAccessibilityForInvocation() else {
            return
        }

        switch store.configuration.mode {
        case .keyWindow:
            requestKeyWindowSession()
        case .directCycle:
            if case .direct = session {
                advanceDirectSession(by: reversed ? -1 : 1)
            } else if isPreparingSession {
                if !startsNewGesture {
                    pendingDirectAdvance = pendingDirectAdvance &+ (reversed ? -1 : 1)
                }
            } else {
                requestDirectSession(reversed: reversed)
            }
        }
    }

    private func handleShortcutReleased() {
        guard store.configuration.isEnabled else {
            return
        }

        refreshAccessibilityPermission()
        guard isAccessibilityGranted else {
            cancelSession()
            return
        }

        guard case .direct = session else {
            if store.configuration.mode == .directCycle, isPreparingSession {
                pendingDirectRelease = true
            }
            return
        }

        commitDirectSession()
    }

    private func requestDirectSession(reversed: Bool) {
        guard let generation = beginSessionPreparation() else {
            return
        }
        pendingDirectReversed = reversed

        sessionPreparationTask = Task { @MainActor [weak self] in
            await self?.beginDirectSession(generation: generation)
        }
    }

    private func beginDirectSession(generation: UInt64) async {
        guard generation == sessionPreparationGeneration,
              isPreparingSession
        else {
            return
        }

        defer {
            if generation == sessionPreparationGeneration {
                isPreparingSession = false
                sessionPreparationTask = nil
                pendingDirectAdvance = 0
                pendingDirectReversed = false
            }
        }
        let entries = await sessionEntries()
        refreshAccessibilityPermission()
        guard generation == sessionPreparationGeneration,
              !Task.isCancelled,
              store.configuration.isEnabled,
              isAccessibilityGranted,
              !entries.isEmpty
        else {
            return
        }

        let initialIndex = initialDirectSelectionIndex(
            in: entries,
            reversed: pendingDirectReversed
        )
        let selectedIndex = Self.directSelectionIndex(
            startingAt: initialIndex,
            advancingBy: pendingDirectAdvance,
            count: entries.count
        )
        pendingDirectAdvance = 0

        session = .direct(entries: entries, selectedIndex: selectedIndex)
        overlayController.showDirect(
            entries: entries,
            selectedID: entries[selectedIndex].id,
            shortcutText: currentShortcutText
        )

        if pendingDirectRelease {
            pendingDirectRelease = false
            commitDirectSession()
        }
    }

    private func advanceDirectSession(by delta: Int) {
        guard case let .direct(entries, selectedIndex) = session,
              !entries.isEmpty
        else {
            return
        }

        let nextIndex = Self.directSelectionIndex(
            startingAt: selectedIndex,
            advancingBy: delta,
            count: entries.count
        )
        session = .direct(entries: entries, selectedIndex: nextIndex)
        overlayController.updateDirectSelection(selectedID: entries[nextIndex].id)
    }

    private func commitDirectSession() {
        guard case let .direct(entries, selectedIndex) = session,
              entries.indices.contains(selectedIndex)
        else {
            cancelSession()
            return
        }

        let entry = entries[selectedIndex]
        overlayController.hide()
        session = nil
        requestActivation(for: entry)
    }

    private func requestKeyWindowSession() {
        guard let generation = beginSessionPreparation() else {
            return
        }

        sessionPreparationTask = Task { @MainActor [weak self] in
            _ = await self?.beginKeyWindowSession(generation: generation)
        }
    }

    private func beginKeyWindowSession(generation: UInt64) async -> Bool {
        guard generation == sessionPreparationGeneration,
              isPreparingSession
        else {
            return false
        }

        defer {
            if generation == sessionPreparationGeneration {
                isPreparingSession = false
                sessionPreparationTask = nil
            }
        }

        guard ensureAccessibilityForInvocation() else {
            return false
        }

        if case .keyWindow(_) = session, overlayController.isVisible {
            return true
        }

        let entries = store.assignShortcuts(
            to: await appCatalog.entries(sortMode: store.configuration.sortMode)
        )
        refreshAccessibilityPermission()
        guard generation == sessionPreparationGeneration,
              !Task.isCancelled,
              store.configuration.isEnabled,
              isAccessibilityGranted,
              !entries.isEmpty
        else {
            return false
        }

        session = .keyWindow(entries: entries)
        overlayController.showKeyWindow(
            entries: entries,
            shortcutText: currentShortcutText
        )
        return true
    }

    private func initialDirectSelectionIndex(in entries: [WindowSwitcherAppEntry], reversed: Bool) -> Int {
        guard entries.count > 1 else {
            return 0
        }

        let anchorIndex = appCatalog.frontmostApplicationID().flatMap { appID in
            entries.firstIndex { $0.appIdentifier == appID }
        } ?? 0
        let delta = reversed ? -1 : 1
        return Self.directSelectionIndex(
            startingAt: anchorIndex,
            advancingBy: delta,
            count: entries.count
        )
    }

    static func directSelectionIndex(startingAt index: Int, advancingBy delta: Int, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }

        let normalizedDelta = delta % count
        return (index + normalizedDelta + count) % count
    }

    private func sessionEntries() async -> [WindowSwitcherAppEntry] {
        if let sessionEntriesProvider {
            return await sessionEntriesProvider()
        }

        return await appCatalog.entries(sortMode: store.configuration.sortMode)
    }

    private func select(_ entry: WindowSwitcherAppEntry) {
        refreshAccessibilityPermission()
        guard store.configuration.isEnabled,
              isAccessibilityGranted
        else {
            return
        }

        session = nil
        requestActivation(for: entry)
    }

    private func quit(_ entry: WindowSwitcherAppEntry) {
        appCatalog.quitApplication(entry)
        removeEntries(forAppIdentifier: entry.appIdentifier)
    }

    private func changeShortcut(
        for entry: WindowSwitcherAppEntry,
        to token: String?
    ) -> WindowSwitcherShortcutCustomizationResult {
        guard case let .keyWindow(entries) = session else {
            return .unavailable
        }

        let result = store.setManualShortcut(token, for: entry.id, in: entries)
        if case let .updated(updatedEntries) = result {
            session = .keyWindow(entries: updatedEntries)
            onStateChange?()
        }
        return result
    }

    private func cancelSession() {
        overlayController.hide()
        session = nil
        invalidateSessionPreparation()
        invalidateActivation()
    }

    private func requestActivation(for entry: WindowSwitcherAppEntry) {
        activationGeneration &+= 1
        let generation = activationGeneration
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.appCatalog.activate(entry)
            guard !Task.isCancelled,
                  self.activationGeneration == generation
            else {
                return
            }

            self.activationTask = nil
        }
    }

    private func invalidateActivation() {
        activationGeneration &+= 1
        activationTask?.cancel()
        activationTask = nil
    }

    private func removeEntries(forAppIdentifier appIdentifier: String) {
        switch session {
        case let .direct(entries, selectedIndex):
            let filteredEntries = entries.filter { $0.appIdentifier != appIdentifier }
            guard !filteredEntries.isEmpty else {
                cancelSession()
                return
            }

            let nextIndex = min(selectedIndex, filteredEntries.count - 1)
            session = .direct(entries: filteredEntries, selectedIndex: nextIndex)
            overlayController.updateEntries(
                entries: filteredEntries,
                selectedID: filteredEntries[nextIndex].id
            )
        case let .keyWindow(entries):
            let filteredEntries = entries.filter { $0.appIdentifier != appIdentifier }
            guard !filteredEntries.isEmpty else {
                cancelSession()
                return
            }

            session = .keyWindow(entries: filteredEntries)
            overlayController.updateEntries(entries: filteredEntries, selectedID: nil)
        case nil:
            return
        }
    }

    private func ensureAccessibilityForInvocation() -> Bool {
        refreshAccessibilityPermission()
        guard isAccessibilityGranted else {
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。"
            )
            requestPermissionGuidance?(WindowSwitcherConstants.accessibilityPermissionID)
            onStateChange?()
            return false
        }

        lastErrorMessage = nil
        syncShortcutTap()
        return true
    }

    private func handleAccessibilityPermissionAction() {
        if isAccessibilityGranted {
            refreshAccessibilityPermission()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            lastErrorMessage = nil
            syncCatalogDiscovery()
            syncShortcutTap()
        } else {
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。"
            )
        }
        onStateChange?()
    }

    private func syncShortcutTap() {
        shortcutTap.reloadBinding()
        if store.configuration.isEnabled && isAccessibilityGranted {
            shortcutTap.start()
        } else {
            shortcutTap.stop()
        }
    }

    private func syncCatalogDiscovery() {
        if store.configuration.isEnabled && isAccessibilityGranted {
            appCatalog.start()
        } else {
            appCatalog.stop()
        }
    }

    private func beginSessionPreparation() -> UInt64? {
        guard !isPreparingSession else {
            return nil
        }

        invalidateActivation()
        isPreparingSession = true
        pendingDirectAdvance = 0
        return sessionPreparationGeneration
    }

    private func invalidateSessionPreparation() {
        sessionPreparationGeneration &+= 1
        sessionPreparationTask?.cancel()
        sessionPreparationTask = nil
        isPreparingSession = false
        pendingDirectRelease = false
        pendingDirectAdvance = 0
        pendingDirectReversed = false
    }

    private var currentShortcutText: String {
        let binding = shortcutBindingResolver?(WindowSwitcherConstants.shortcutDefinitionID)
            ?? WindowSwitcherShortcutBindingStore.resolvedBinding()
            ?? WindowSwitcherShortcutBindingStore.defaultBinding
        return ShortcutFormatter.displayString(for: binding)
    }
}
