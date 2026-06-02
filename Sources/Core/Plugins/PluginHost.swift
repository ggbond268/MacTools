import Combine
import Foundation
import SwiftUI
import MacToolsPluginKit

enum FeatureSettingsPane: Hashable {
    case installed
    case marketplace
    case configuration(String)
}

@MainActor
final class PluginHost: ObservableObject {
    private struct PluginDescriptor {
        let metadata: PluginMetadata
        let plugin: any MacToolsPlugin
        let capabilities: PluginPackageManifest.Capabilities?

        var hasPrimaryPanel: Bool {
            capabilities?.primaryPanel ?? true
        }

        var hasComponentPanel: Bool {
            capabilities?.componentPanel ?? true
        }

        var hasConfiguration: Bool {
            capabilities?.configuration ?? true
        }
    }

    private struct ShortcutDescriptor {
        let itemID: String
        let pluginID: String
        let pluginTitle: String
        let definition: PluginShortcutDefinition
        let plugin: any MacToolsPlugin
    }

    private let builtInPlugins: [any MacToolsPlugin]
    private let shortcutStore: ShortcutStore
    private let pluginDisplayPreferencesStore: PluginDisplayPreferencesStore
    private let globalShortcutManager: GlobalShortcutManager
    private let displayConfigurationObserver: (any DisplayConfigurationObserving)?
    private let accessibilityPermissionObserver: (any AccessibilityPermissionObserving)?
    private let displayTopologyRefreshDelay: Duration
    let dynamicPluginManager: DynamicPluginManager?
    private let pluginCatalogManager: PluginCatalogManager?

    private var dynamicPlugins: [any MacToolsPlugin] = []
    private var dynamicPluginCapabilitiesByID: [String: PluginPackageManifest.Capabilities] = [:]
    private var dynamicPluginCategoriesByID: [String: String?] = [:]
    private var shortcutErrors: [String: String] = [:]
    private var componentViewCache: [String: PluginComponentViewItem] = [:]
    private var configurationViewCache: [String: PluginConfigurationViewItem] = [:]
    private var isolatedPluginFailures: [String: String] = [:]
    private var isHandlingPluginAction = false
    private var displayTopologyRefreshTask: Task<Void, Never>?

    @Published private(set) var panelItems: [PluginPanelItem] = []
    @Published private(set) var componentItems: [PluginComponentItem] = []
    @Published private(set) var featureManagementItems: [PluginFeatureManagementItem] = []
    @Published private(set) var pluginConfigurationItems: [PluginConfigurationItem] = []
    @Published private(set) var permissionCards: [PluginPermissionCard] = []
    @Published private(set) var settingsCards: [PluginSettingsCard] = []
    @Published private(set) var shortcutItems: [ShortcutSettingsItem] = []
    @Published private(set) var pluginManagementItems: [PluginManagementItem] = []
    @Published private(set) var pluginCatalogStatus: PluginCatalogStatus = .unavailable
    @Published private(set) var hasActivePlugin = false
    @Published private(set) var settingsPresentationRequestCount = 0
    @Published var selectedSettingsDestination: SettingsDestination = .general
    @Published var selectedFeatureSettingsPane: FeatureSettingsPane = .installed

    /// 由 `MenuBarStatusItemController` 注入，返回状态栏图标按钮的屏幕 frame。
    var statusItemButtonFrameProvider: (() -> NSRect?)? = nil {
        didSet {
            configureHostStatusItemCallbacks(for: activePlugins)
        }
    }
    var resetStatusItemPosition: (() -> Void)? = nil {
        didSet {
            configureHostStatusItemCallbacks(for: activePlugins)
        }
    }

    convenience init() {
        let dynamicPluginManager = DynamicPluginManager()
        let pluginCatalogManager = PluginCatalogManager.live(dynamicPluginManager: dynamicPluginManager)
        self.init(
            plugins: BuiltInPluginRegistry().makePlugins(),
            dynamicPluginManager: dynamicPluginManager,
            pluginCatalogManager: pluginCatalogManager,
            shortcutStore: ShortcutStore(),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(),
            globalShortcutManager: GlobalShortcutManager(),
            displayConfigurationObserver: SystemDisplayConfigurationObserver(),
            accessibilityPermissionObserver: AccessibilityPermissionObserver()
        )
    }

    init(
        plugins: [any MacToolsPlugin],
        dynamicPluginManager: DynamicPluginManager? = nil,
        pluginCatalogManager: PluginCatalogManager? = nil,
        shortcutStore: ShortcutStore,
        pluginDisplayPreferencesStore: PluginDisplayPreferencesStore,
        globalShortcutManager: GlobalShortcutManager,
        displayConfigurationObserver: (any DisplayConfigurationObserving)? = nil,
        accessibilityPermissionObserver: (any AccessibilityPermissionObserving)? = nil,
        displayTopologyRefreshDelay: Duration = .milliseconds(180)
    ) {
        self.builtInPlugins = plugins.sorted {
            if $0.metadata.order == $1.metadata.order {
                return $0.metadata.title.localizedCompare($1.metadata.title) == .orderedAscending
            }

            return $0.metadata.order < $1.metadata.order
        }
        self.shortcutStore = shortcutStore
        self.pluginDisplayPreferencesStore = pluginDisplayPreferencesStore
        self.globalShortcutManager = globalShortcutManager
        self.displayConfigurationObserver = displayConfigurationObserver
        self.accessibilityPermissionObserver = accessibilityPermissionObserver
        self.displayTopologyRefreshDelay = displayTopologyRefreshDelay
        self.dynamicPluginManager = dynamicPluginManager
        self.pluginCatalogManager = pluginCatalogManager

        configureCallbacks(for: self.builtInPlugins)

        if let dynamicPluginManager {
            self.dynamicPlugins = dynamicPluginManager.loadInstalledPlugins()
            self.dynamicPluginCapabilitiesByID = dynamicPluginManager.installedCapabilitiesByID()
            self.dynamicPluginCategoriesByID = dynamicPluginManager.installedCategoriesByID()
            self.pluginManagementItems = dynamicPluginManager.pluginManagementItems
            self.pluginCatalogStatus = pluginCatalogManager?.status ?? .unavailable
            configureCallbacks(for: self.dynamicPlugins)
            // Pause any dynamic plugin that was hidden before this launch.
            pauseHiddenDynamicPlugins()
            dynamicPluginManager.onPluginsChanged = { [weak self] plugins in
                self?.replaceDynamicPlugins(plugins)
            }
        }

        self.globalShortcutManager.onShortcutTriggered = { [weak self] shortcutID in
            self?.handleShortcutTrigger(shortcutID: shortcutID)
        }

        self.displayConfigurationObserver?.onConfigurationChange = { [weak self] in
            self?.scheduleDisplayTopologyRefresh()
        }

        self.accessibilityPermissionObserver?.onPermissionChange = { [weak self] in
            self?.refreshAccessibilityPermissionNow()
        }

        refreshAll()
    }

    deinit {
        displayTopologyRefreshTask?.cancel()
    }

    func refreshAll() {
        handlePluginAction(rebuildAfterAction: false) {
            for plugin in activePlugins {
                guardPluginCall(plugin, operation: "refresh") {
                    plugin.refresh()
                }
            }
        }

        syncGlobalShortcuts()
        rebuildDerivedState()
    }

    func refreshDisplayTopology() {
        displayTopologyRefreshTask?.cancel()
        refreshDisplayTopologyNow()
    }

    func isSwitchOn(for pluginID: String) -> Bool {
        panelItems.first(where: { $0.id == pluginID })?.isOn ?? false
    }

    func setSwitchValue(_ isOn: Bool, for pluginID: String) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set switch") {
                primaryPanel.handleAction(.setSwitch(isOn))
            }
        }
    }

    func setDisclosureExpanded(_ isExpanded: Bool, for pluginID: String) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set disclosure") {
                primaryPanel.handleAction(.setDisclosureExpanded(isExpanded))
            }
        }
    }

    func setPanelSelectionValue(
        _ optionID: String,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set selection") {
                primaryPanel.handleAction(.setSelection(controlID: controlID, optionID: optionID))
            }
        }
    }

    func setPanelNavigationSelectionValue(
        _ optionID: String,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set navigation selection") {
                primaryPanel.handleAction(
                    .setNavigationSelection(controlID: controlID, optionID: optionID)
                )
            }
        }
    }

    func clearPanelNavigationSelection(
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "clear navigation selection") {
                primaryPanel.handleAction(.clearNavigationSelection(controlID: controlID))
            }
        }
    }

    func setPanelDateValue(
        _ date: Date,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set date") {
                primaryPanel.handleAction(.setDate(controlID: controlID, value: date))
            }
        }
    }

    func setPanelSliderValue(
        _ value: Double,
        controlID: String,
        for pluginID: String,
        phase: PluginPanelAction.SliderPhase
    ) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "set slider") {
                primaryPanel.handleAction(.setSlider(controlID: controlID, value: value, phase: phase))
            }
        }
    }

    func invokePanelAction(controlID: String, for pluginID: String) {
        guard let plugin = corePlugin(for: pluginID),
              let primaryPanel = plugin.primaryPanel
        else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "invoke panel action") {
                primaryPanel.handleAction(.invokeAction(controlID: controlID))
            }
        }
    }

    func performSettingsAction(pluginID: String, actionID: String) {
        guard let plugin = corePlugin(for: pluginID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "settings action") {
                plugin.handleSettingsAction(id: actionID)
            }
        }
    }

    func performPermissionAction(pluginID: String, permissionID: String) {
        guard let plugin = corePlugin(for: pluginID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(plugin, operation: "permission action") {
                plugin.handlePermissionAction(id: permissionID)
            }
        }
    }

    func setShortcutBinding(_ binding: ShortcutBinding, for shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(.custom(binding), for: descriptor)
    }

    func clearShortcut(for shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(.cleared, for: descriptor)
    }

    func resetShortcut(for shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        applyShortcutCustomization(.inheritDefault, for: descriptor)
    }

    func presentPluginConfiguration(pluginID: String) {
        rebuildDerivedState()

        guard pluginConfigurationItems.contains(where: { $0.id == pluginID }) else {
            return
        }

        selectFeatureSettingsPane(.configuration(pluginID))
        selectedSettingsDestination = .pluginConfiguration
        settingsPresentationRequestCount += 1
    }

    func presentPluginMarketplace() {
        selectedFeatureSettingsPane = .marketplace
        selectedSettingsDestination = .pluginConfiguration
        settingsPresentationRequestCount += 1
    }

    func presentInstalledPlugins() {
        selectedFeatureSettingsPane = .installed
        selectedSettingsDestination = .pluginConfiguration
        settingsPresentationRequestCount += 1
    }

    func selectFeatureSettingsPane(_ pane: FeatureSettingsPane) {
        switch pane {
        case .installed, .marketplace:
            selectedFeatureSettingsPane = pane
        case let .configuration(pluginID):
            guard pluginConfigurationItems.contains(where: { $0.id == pluginID }) else {
                return
            }

            selectedFeatureSettingsPane = pane
        }
    }

    func clearShortcutError(for shortcutID: String) {
        guard shortcutErrors.removeValue(forKey: shortcutID) != nil else {
            return
        }

        rebuildDerivedState()
    }

    func setFeatureVisibility(_ isVisible: Bool, for pluginID: String) {
        pluginDisplayPreferencesStore.setVisibility(
            isVisible,
            for: pluginID,
            defaultPluginIDs: defaultPluginIDs
        )
        // For dynamic plugins, pause/resume side effects with visibility.
        // The plugin stays loaded so it remains visible in the 已安装 list.
        if dynamicPlugins.contains(where: { $0.metadata.id == pluginID }) {
            if isVisible {
                dynamicPluginManager?.resumePlugin(pluginID)
            } else {
                dynamicPluginManager?.pausePlugin(pluginID)
            }
        }
        rebuildDerivedState()
    }

    func canMoveFeatureManagementItem(id pluginID: String, by offset: Int) -> Bool {
        let orderedPluginIDs = orderedPluginIDs()

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return false
        }

        let targetIndex = currentIndex + offset
        return orderedPluginIDs.indices.contains(targetIndex)
    }

    func moveFeatureManagementItem(id pluginID: String, by offset: Int) {
        var orderedPluginIDs = orderedPluginIDs()

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return
        }

        let targetIndex = currentIndex + offset

        guard orderedPluginIDs.indices.contains(targetIndex) else {
            return
        }

        let movedPluginID = orderedPluginIDs.remove(at: currentIndex)
        orderedPluginIDs.insert(movedPluginID, at: targetIndex)

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func moveFeatureManagementItem(id pluginID: String, toOffset targetOffset: Int) {
        var orderedPluginIDs = orderedPluginIDs()

        guard let currentIndex = orderedPluginIDs.firstIndex(of: pluginID) else {
            return
        }

        let clampedOffset = min(max(targetOffset, 0), orderedPluginIDs.count)

        guard currentIndex != clampedOffset, currentIndex + 1 != clampedOffset else {
            return
        }

        orderedPluginIDs.move(
            fromOffsets: IndexSet(integer: currentIndex),
            toOffset: clampedOffset
        )

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func moveFeatureManagementItems(fromOffsets: IndexSet, toOffset: Int) {
        var orderedPluginIDs = orderedPluginIDs()
        orderedPluginIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)

        pluginDisplayPreferencesStore.setOrderedPluginIDs(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        rebuildDerivedState()
    }

    func componentViewItem(for itemID: String, dismiss: @escaping () -> Void) -> PluginComponentViewItem {
        componentViewItem(for: itemID, dismiss: dismiss, isPanelVisible: true)
    }

    func componentViewItem(
        for itemID: String,
        dismiss: @escaping () -> Void,
        isPanelVisible: Bool
    ) -> PluginComponentViewItem {
        if let cachedItem = componentViewCache[itemID] {
            return cachedItem
        }

        guard let plugin = corePlugin(for: itemID),
              let componentPanel = plugin.componentPanel
        else {
            let item = PluginComponentViewItem(id: itemID, content: AnyView(EmptyView()))
            componentViewCache[itemID] = item
            return item
        }

        let context = PluginComponentContext(
            pluginID: itemID,
            dismiss: dismiss,
            isPanelVisible: isPanelVisible
        )
        let content = guardedValue(
            for: plugin,
            operation: "make component view",
            componentPanel.makeView(context: context)
        ) ?? AnyView(EmptyView())

        let item = PluginComponentViewItem(
            id: itemID,
            content: content
        )
        componentViewCache[itemID] = item
        if isPluginIsolated(plugin) {
            rebuildDerivedState()
        }
        return item
    }

    func pluginConfigurationViewItem(for pluginID: String) -> PluginConfigurationViewItem {
        if let cachedItem = configurationViewCache[pluginID] {
            return cachedItem
        }

        let configurations = orderedPluginDescriptors()
            .filter { $0.metadata.id == pluginID && $0.hasConfiguration }
            .compactMap { descriptor -> (any MacToolsPlugin, PluginConfiguration)? in
                guard let configuration = guardedOptionalValue(
                    for: descriptor.plugin,
                    operation: "read plugin configuration",
                    descriptor.plugin.configuration
                ) else {
                    return nil
                }

                return (descriptor.plugin, configuration)
            }

        guard corePlugin(for: pluginID) != nil else {
            rebuildDerivedState()
            return PluginConfigurationViewItem(id: pluginID, content: AnyView(EmptyView()))
        }

        let context = PluginConfigurationContext(pluginID: pluginID)
        let content: AnyView

        switch configurations.count {
        case 0:
            content = AnyView(EmptyView())
        case 1:
            content = guardedConfigurationView(
                for: configurations[0].0,
                configuration: configurations[0].1,
                context: context
            )
        default:
            let views = configurations.map {
                guardedConfigurationView(
                    for: $0.0,
                    configuration: $0.1,
                    context: context
                )
            }
            content = AnyView(
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Swift.Array(views.enumerated()), id: \.offset) { entry in
                        entry.element
                    }
                }
            )
        }

        guard corePlugin(for: pluginID) != nil else {
            rebuildDerivedState()
            return PluginConfigurationViewItem(id: pluginID, content: AnyView(EmptyView()))
        }

        let item = PluginConfigurationViewItem(id: pluginID, content: content)
        configurationViewCache[pluginID] = item
        return item
    }

    func discardComponentViews() {
        componentViewCache.removeAll()
    }

    func refreshPluginCatalog() async {
        await pluginCatalogManager?.refreshCatalog()
        syncPluginManagementState()
    }

    func installPluginFromCatalog(pluginID: String) async throws {
        guard let pluginCatalogManager else {
            return
        }

        try await pluginCatalogManager.installPlugin(id: pluginID)
        syncPluginManagementState()
    }

    func updatePluginFromCatalog(pluginID: String) async throws {
        guard let pluginCatalogManager else {
            return
        }

        try await pluginCatalogManager.updatePlugin(id: pluginID)
        syncPluginManagementState()
    }

    func updateAvailablePluginsFromCatalog() async throws {
        guard let pluginCatalogManager else {
            return
        }

        defer {
            syncPluginManagementState()
        }

        try await pluginCatalogManager.updateAvailablePlugins()
    }

    func installPluginPackage(from sourceURL: URL) throws {
        try dynamicPluginManager?.installPluginPackage(from: sourceURL)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func updatePluginPackage(from sourceURL: URL) throws {
        try dynamicPluginManager?.updatePluginPackage(from: sourceURL)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func setDynamicPluginEnabled(_ isEnabled: Bool, pluginID: String) {
        if isEnabled {
            isolatedPluginFailures.removeValue(forKey: pluginID)
        }

        dynamicPluginManager?.setPluginEnabled(isEnabled, pluginID: pluginID)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    func uninstallDynamicPlugin(pluginID: String, removeData: Bool = false) throws {
        try dynamicPluginManager?.uninstallPlugin(pluginID: pluginID, removeData: removeData)
        pluginCatalogManager?.rebuildManagementItems()
        syncPluginManagementState()
    }

    private var plugins: [any MacToolsPlugin] {
        builtInPlugins + dynamicPlugins
    }

    private var activePlugins: [any MacToolsPlugin] {
        plugins.filter { isolatedPluginFailures[$0.metadata.id] == nil }
    }

    private func corePlugin(for pluginID: String) -> (any MacToolsPlugin)? {
        activePlugins.first(where: { $0.metadata.id == pluginID })
    }

    private func configureCallbacks(for plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            let pluginID = plugin.metadata.id

            plugin.onStateChange = { [weak self] in
                self?.rebuildDerivedStateAfterPluginChange()
            }
            plugin.requestPermissionGuidance = { [weak self] permissionID in
                self?.requestPermissionGuidance(forPluginID: pluginID, permissionID: permissionID)
            }
            plugin.shortcutBindingResolver = { [weak self] shortcutDefinitionID in
                self?.resolvedBinding(forPluginID: pluginID, shortcutDefinitionID: shortcutDefinitionID)
            }
            if let configurationPresenting = plugin as? any PluginConfigurationPresenting {
                configurationPresenting.requestPluginConfigurationPresentation = { [weak self] requestedPluginID in
                    guard requestedPluginID == pluginID else { return }
                    self?.presentPluginConfiguration(pluginID: pluginID)
                }
            }
            if let anchorable = plugin as? any DropZoneAnchorProviding {
                anchorable.anchorRectProvider = { [weak self] in
                    self?.statusItemButtonFrameProvider?()
                }
            }
            configureHostStatusItemCallbacks(for: [plugin])
        }
    }

    private func configureHostStatusItemCallbacks(for plugins: [any MacToolsPlugin]) {
        for plugin in plugins {
            guard let recoverable = plugin as? any MenuBarHostStatusItemRecovering else { continue }
            recoverable.hostStatusItemFrameProvider = { [weak self] in
                self?.statusItemButtonFrameProvider?()
            }
            recoverable.resetHostStatusItemPosition = { [weak self] in
                self?.resetStatusItemPosition?()
            }
        }
    }

    private func replaceDynamicPlugins(_ plugins: [any MacToolsPlugin]) {
        discardComponentViews()
        configurationViewCache.removeAll()
        syncPluginManagementState()
        dynamicPlugins = plugins.sorted {
            if $0.metadata.order == $1.metadata.order {
                return $0.metadata.title.localizedCompare($1.metadata.title) == .orderedAscending
            }

            return $0.metadata.order < $1.metadata.order
        }
        configureCallbacks(for: dynamicPlugins)
        // Re-apply pause for any plugin that is currently hidden.
        pauseHiddenDynamicPlugins()
        rebuildDerivedState()
        syncGlobalShortcuts()
    }

    private func pauseHiddenDynamicPlugins() {
        for plugin in dynamicPlugins
            where !pluginDisplayPreferencesStore.isVisible(
                plugin.metadata.id, defaultPluginIDs: defaultPluginIDs
            )
        {
            dynamicPluginManager?.pausePlugin(plugin.metadata.id)
        }
    }

    private func syncPluginManagementState() {
        dynamicPluginCapabilitiesByID = dynamicPluginManager?.installedCapabilitiesByID() ?? [:]
        dynamicPluginCategoriesByID = dynamicPluginManager?.installedCategoriesByID() ?? [:]
        pluginManagementItems = dynamicPluginManager?.pluginManagementItems ?? []
        pluginCatalogStatus = pluginCatalogManager?.status ?? .unavailable
    }

    private func rebuildDerivedState() {
        let isolatedPluginCountAtStart = isolatedPluginFailures.count
        let orderedDescriptors = orderedPluginDescriptors()
        let panelStatesByID = Dictionary(
            uniqueKeysWithValues: orderedDescriptors.compactMap { descriptor -> (String, PluginPanelState)? in
                guard descriptor.hasPrimaryPanel else {
                    return nil
                }

                let plugin = descriptor.plugin
                guard !isPluginIsolated(plugin) else {
                    return nil
                }

                guard let primaryPanel = plugin.primaryPanel else {
                    return nil
                }

                guard let state = guardedValue(
                    for: plugin,
                    operation: "read primary panel state",
                    primaryPanel.primaryPanelState
                ) else {
                    return nil
                }

                return (plugin.metadata.id, state)
            }
        )
        let componentStatesByID = Dictionary(
            uniqueKeysWithValues: orderedDescriptors.compactMap { descriptor -> (String, PluginComponentState)? in
                guard descriptor.hasComponentPanel else {
                    return nil
                }

                let plugin = descriptor.plugin
                guard !isPluginIsolated(plugin) else {
                    return nil
                }

                guard let componentPanel = plugin.componentPanel else {
                    return nil
                }

                guard let state = guardedValue(
                    for: plugin,
                    operation: "read component panel state",
                    componentPanel.componentPanelState
                ) else {
                    return nil
                }

                return (plugin.metadata.id, state)
            }
        )

        panelItems = orderedDescriptors.compactMap { descriptor in
            guard descriptor.hasPrimaryPanel else {
                return nil
            }

            let plugin = descriptor.plugin
            let metadata = plugin.metadata
            guard
                let primaryPanel = plugin.primaryPanel,
                let state = panelStatesByID[metadata.id]
            else {
                return nil
            }

            guard
                state.isVisible,
                pluginDisplayPreferencesStore.isVisible(
                    metadata.id,
                    defaultPluginIDs: defaultPluginIDs
                )
            else {
                return nil
            }

            let description = state.errorMessage ?? state.subtitle
            let descriptor = primaryPanel.primaryPanelDescriptor

            return PluginPanelItem(
                id: metadata.id,
                title: metadata.title,
                iconName: metadata.iconName,
                iconTint: metadata.iconTint,
                controlStyle: descriptor.controlStyle,
                menuActionBehavior: descriptor.menuActionBehavior,
                description: description.isEmpty ? metadata.defaultDescription : description,
                helpText: description.isEmpty ? metadata.defaultDescription : description,
                descriptionTone: state.errorMessage == nil ? .secondary : .error,
                isOn: state.isOn,
                isExpanded: state.isExpanded,
                isEnabled: state.isEnabled,
                detail: state.detail,
                buttonActionID: descriptor.controlStyle == .button ? "execute" : nil,
                buttonTitle: descriptor.buttonTitle
            )
        }

        componentItems = orderedDescriptors.compactMap { descriptor in
            guard descriptor.hasComponentPanel else {
                return nil
            }

            let plugin = descriptor.plugin
            let metadata = plugin.metadata
            guard
                let componentPanel = plugin.componentPanel,
                let state = componentStatesByID[metadata.id]
            else {
                return nil
            }

            guard
                state.isVisible,
                pluginDisplayPreferencesStore.isVisible(
                    metadata.id,
                    defaultPluginIDs: defaultPluginIDs
                )
            else {
                return nil
            }

            let description = state.errorMessage ?? state.subtitle

            return PluginComponentItem(
                id: metadata.id,
                title: metadata.title,
                iconName: metadata.iconName,
                iconTint: metadata.iconTint,
                description: description.isEmpty ? metadata.defaultDescription : description,
                helpText: description.isEmpty ? metadata.defaultDescription : description,
                descriptionTone: state.errorMessage == nil ? .secondary : .error,
                span: componentPanel.descriptor.span,
                isActive: state.isActive,
                isEnabled: state.isEnabled
            )
        }
        trimComponentViewCache(keeping: Set(componentItems.map(\.id)))

        featureManagementItems = orderedDescriptors.map { descriptor in
            let metadata = descriptor.metadata

            return PluginFeatureManagementItem(
                id: metadata.id,
                title: metadata.title,
                description: metadata.defaultDescription,
                iconName: metadata.iconName,
                iconTint: metadata.iconTint,
                isVisible: pluginDisplayPreferencesStore.isVisible(
                    metadata.id,
                    defaultPluginIDs: defaultPluginIDs
                ),
                isActive: panelStatesByID[metadata.id]?.isOn == true
                    || componentStatesByID[metadata.id]?.isActive == true,
                presentation: presentation(for: descriptor),
                category: dynamicPluginCategoriesByID[metadata.id] ?? nil
            )
        }

        settingsCards = orderedCorePlugins().flatMap { plugin in
            let sections = guardedValue(
                for: plugin,
                operation: "read settings sections",
                plugin.settingsSections
            ) ?? []

            return sections.map { section in
                PluginSettingsCard(
                    id: "\(plugin.metadata.id).\(section.id)",
                    pluginID: plugin.metadata.id,
                    title: section.title,
                    description: section.description,
                    statusText: section.status.text,
                    statusSystemImage: section.status.systemImage,
                    statusTone: section.status.tone,
                    footnote: section.footnote,
                    buttonTitle: section.buttonTitle,
                    actionID: section.actionID
                )
            }
        }

        permissionCards = orderedCorePlugins().flatMap { plugin -> [PluginPermissionCard] in
            let requirements = guardedValue(
                for: plugin,
                operation: "read permission requirements",
                plugin.permissionRequirements
            ) ?? []

            return requirements.compactMap { requirement -> PluginPermissionCard? in
                guard let state = guardedValue(
                    for: plugin,
                    operation: "read permission state",
                    plugin.permissionState(for: requirement.id)
                ) else {
                    return nil
                }

                return PluginPermissionCard(
                    id: "\(plugin.metadata.id).permission.\(requirement.id)",
                    pluginID: plugin.metadata.id,
                    permissionID: requirement.id,
                    title: requirement.title,
                    description: requirement.description,
                    iconSystemImage: permissionIconName(for: requirement.kind),
                    statusText: state.statusText ?? (state.isGranted ? "已授权" : "未授权"),
                    statusSystemImage: state.statusSystemImage ?? (state.isGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"),
                    statusTone: state.statusTone ?? (state.isGranted ? .positive : .caution),
                    footnote: state.footnote,
                    buttonTitle: permissionActionTitle(
                        for: requirement.kind,
                        isGranted: state.isGranted
                    )
                )
            }
        }

        shortcutItems = shortcutDescriptors().map { descriptor in
            let customization = shortcutStore.customization(for: descriptor.itemID)
            let binding = resolvedBinding(for: descriptor)

            return ShortcutSettingsItem(
                id: descriptor.itemID,
                pluginID: descriptor.pluginID,
                pluginTitle: descriptor.pluginTitle,
                title: descriptor.definition.title,
                description: descriptor.definition.description,
                bindingText: ShortcutFormatter.displayString(for: binding),
                isRequired: descriptor.definition.isRequired,
                canClear: !descriptor.definition.isRequired && binding != nil,
                usesDefaultValue: customization == .inheritDefault,
                errorMessage: shortcutErrors[descriptor.itemID]
            )
        }

        pluginConfigurationItems = buildPluginConfigurationItems(
            settingsCards: settingsCards,
            permissionCards: permissionCards,
            shortcutItems: shortcutItems
        )
        // 清空所有配置视图缓存，确保状态改变时视图能刷新
        configurationViewCache.removeAll()
        trimConfigurationViewCache(keeping: Set(pluginConfigurationItems.map(\.id)))
        syncSelectedFeatureSettingsPane()

        hasActivePlugin = panelStatesByID.values.contains(where: \.isOn)
            || componentStatesByID.values.contains(where: \.isActive)

        if isolatedPluginFailures.count > isolatedPluginCountAtStart {
            rebuildDerivedState()
        }
    }

    private func handlePluginAction(rebuildAfterAction: Bool = true, _ action: () -> Void) {
        guard !isHandlingPluginAction else {
            action()
            return
        }

        isHandlingPluginAction = true

        action()

        isHandlingPluginAction = false
        if rebuildAfterAction {
            rebuildDerivedState()
        }
    }

    private func rebuildDerivedStateAfterPluginChange() {
        guard !isHandlingPluginAction else {
            return
        }

        rebuildDerivedState()
    }

    private func guardedValue<T>(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ value: @autoclosure () -> T
    ) -> T? {
        guard !isPluginIsolated(plugin) else {
            return nil
        }

        switch PluginInvocationGuard.value(operation: operation, value) {
        case let .success(value):
            return value
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return nil
        }
    }

    private func guardedOptionalValue<T>(
        for plugin: any MacToolsPlugin,
        operation: String,
        _ value: @autoclosure () -> T?
    ) -> T? {
        guard !isPluginIsolated(plugin) else {
            return nil
        }

        switch PluginInvocationGuard.value(operation: operation, value) {
        case let .success(value):
            return value
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
            return nil
        }
    }

    private func guardPluginCall(
        _ plugin: any MacToolsPlugin,
        operation: String,
        _ action: () -> Void
    ) {
        guard !isPluginIsolated(plugin) else {
            return
        }

        switch PluginInvocationGuard.run(operation: operation, action) {
        case .success:
            break
        case let .failure(failure):
            isolatePlugin(plugin, operation: operation, failure: failure)
        }
    }

    private func guardedConfigurationView(
        for plugin: any MacToolsPlugin,
        configuration: PluginConfiguration,
        context: PluginConfigurationContext
    ) -> AnyView {
        guardedValue(
            for: plugin,
            operation: "make configuration view",
            configuration.makeView(context)
        ) ?? AnyView(EmptyView())
    }

    private func isPluginIsolated(_ plugin: any MacToolsPlugin) -> Bool {
        isolatedPluginFailures[plugin.metadata.id] != nil
    }

    private func isolatePlugin(
        _ plugin: any MacToolsPlugin,
        operation: String,
        failure: PluginInvocationFailure
    ) {
        let pluginID = plugin.metadata.id
        let message = failure.localizedDescription

        guard isolatedPluginFailures[pluginID] == nil else {
            return
        }

        isolatedPluginFailures[pluginID] = message
        componentViewCache.removeValue(forKey: pluginID)
        configurationViewCache.removeValue(forKey: pluginID)
        shortcutErrors = shortcutErrors.filter { !$0.key.hasPrefix("\(pluginID).shortcut.") }

        AppLog.pluginHost.error(
            "Plugin \(pluginID, privacy: .public) isolated after \(operation, privacy: .public): \(message, privacy: .public)"
        )

        switch PluginInvocationGuard.run(operation: "deactivate isolated plugin \(pluginID)", {
            plugin.deactivate(reason: .disabled)
        }) {
        case .success:
            break
        case let .failure(deactivateFailure):
            AppLog.pluginHost.error(
                "Plugin \(pluginID, privacy: .public) failed during isolation deactivate: \(deactivateFailure.localizedDescription, privacy: .public)"
            )
        }

        plugin.onStateChange = nil
        plugin.requestPermissionGuidance = nil
        plugin.shortcutBindingResolver = nil
        if let configurationPresenting = plugin as? any PluginConfigurationPresenting {
            configurationPresenting.requestPluginConfigurationPresentation = nil
        }
        syncGlobalShortcuts()
    }

    private func scheduleDisplayTopologyRefresh() {
        displayTopologyRefreshTask?.cancel()
        let refreshDelay = displayTopologyRefreshDelay
        displayTopologyRefreshTask = Task { @MainActor [weak self, refreshDelay] in
            do {
                try await Task.sleep(for: refreshDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.refreshDisplayTopologyNow()
        }
    }

    private func refreshDisplayTopologyNow() {
        displayTopologyRefreshTask = nil
        handlePluginAction {
            for plugin in activePlugins {
                if let displayTopologyRefreshing = plugin as? DisplayTopologyRefreshing {
                    guardPluginCall(plugin, operation: "refresh display topology") {
                        displayTopologyRefreshing.refreshDisplayTopology()
                    }
                }
            }
        }
    }

    private func refreshAccessibilityPermissionNow() {
        handlePluginAction {
            for plugin in activePlugins {
                if let accessibilityRefreshing = plugin as? AccessibilityPermissionRefreshing {
                    guardPluginCall(plugin, operation: "refresh accessibility permission") {
                        accessibilityRefreshing.refreshAccessibilityPermission()
                    }
                }
            }
        }
    }

    private func buildPluginConfigurationItems(
        settingsCards: [PluginSettingsCard],
        permissionCards: [PluginPermissionCard],
        shortcutItems: [ShortcutSettingsItem]
    ) -> [PluginConfigurationItem] {
        orderedPluginDescriptors().compactMap { descriptor in
            let pluginID = descriptor.metadata.id
            let matchingSettingsCards = settingsCards.filter { $0.pluginID == pluginID }
            let matchingPermissionCards = permissionCards.filter { $0.pluginID == pluginID }
            let matchingShortcutItems = shortcutItems.filter { $0.pluginID == pluginID }
            let configurations: [PluginConfiguration]
            if descriptor.hasConfiguration,
               let configuration = guardedOptionalValue(
                    for: descriptor.plugin,
                    operation: "read plugin configuration",
                    descriptor.plugin.configuration
               ) {
                configurations = [configuration]
            } else {
                configurations = []
            }
            let hasConfigurationSurface = !matchingSettingsCards.isEmpty
                || !matchingPermissionCards.isEmpty
                || !matchingShortcutItems.isEmpty
                || !configurations.isEmpty

            guard hasConfigurationSurface else {
                return nil
            }

            return PluginConfigurationItem(
                id: pluginID,
                pluginID: pluginID,
                title: descriptor.metadata.title,
                description: configurations.first?.description ?? descriptor.metadata.defaultDescription,
                iconName: descriptor.metadata.iconName,
                iconTint: descriptor.metadata.iconTint,
                settingsCards: matchingSettingsCards,
                permissionCards: matchingPermissionCards,
                shortcutItems: matchingShortcutItems,
                hasCustomConfiguration: !configurations.isEmpty,
                prefersFullHeight: configurations.first?.prefersFullHeight ?? false
            )
        }
    }

    private func shortcutDescriptors() -> [ShortcutDescriptor] {
        orderedCorePlugins().flatMap { plugin in
            let definitions = guardedValue(
                for: plugin,
                operation: "read shortcut definitions",
                plugin.shortcutDefinitions
            ) ?? []

            return definitions.map { definition in
                ShortcutDescriptor(
                    itemID: shortcutItemID(
                        pluginID: plugin.metadata.id,
                        shortcutDefinitionID: definition.id
                    ),
                    pluginID: plugin.metadata.id,
                    pluginTitle: plugin.metadata.title,
                    definition: definition,
                    plugin: plugin
                )
            }
        }
    }

    private var defaultPluginIDs: [String] {
        defaultPluginDescriptors().map(\.metadata.id)
    }

    private func orderedPluginIDs() -> [String] {
        pluginDisplayPreferencesStore.orderedPluginIDs(defaultPluginIDs: defaultPluginIDs)
    }

    private func orderedPlugins() -> [any MacToolsPlugin] {
        let pluginsByID = pluginsByID()

        return orderedPluginIDs().compactMap { pluginsByID[$0] }
    }

    private func orderedCorePlugins() -> [any MacToolsPlugin] {
        orderedPluginDescriptors().map(\.plugin)
    }

    private func orderedPluginDescriptors() -> [PluginDescriptor] {
        let descriptorsByID = descriptorsByID()

        return orderedPluginIDs().compactMap { descriptorsByID[$0] }
    }

    private func pluginsByID() -> [String: any MacToolsPlugin] {
        activePlugins.reduce(into: [String: any MacToolsPlugin]()) { result, plugin in
            let id = plugin.metadata.id

            if result[id] == nil {
                result[id] = plugin
            }
        }
    }

    private func descriptorsByID() -> [String: PluginDescriptor] {
        defaultPluginDescriptors().reduce(into: [String: PluginDescriptor]()) { result, descriptor in
            let id = descriptor.metadata.id

            if result[id] == nil {
                result[id] = descriptor
            }
        }
    }

    private func defaultPluginDescriptors() -> [PluginDescriptor] {
        let descriptors = builtInPlugins
            .map { PluginDescriptor(metadata: $0.metadata, plugin: $0, capabilities: nil) }
            + dynamicPlugins.map {
                PluginDescriptor(
                    metadata: $0.metadata,
                    plugin: $0,
                    capabilities: dynamicPluginCapabilitiesByID[$0.metadata.id]
                )
            }

        return descriptors
            .filter { !isPluginIsolated($0.plugin) }
            .sorted { lhs, rhs in
                if lhs.metadata.order == rhs.metadata.order {
                    return lhs.metadata.title.localizedCompare(rhs.metadata.title) == .orderedAscending
                }

                return lhs.metadata.order < rhs.metadata.order
            }
    }

    private func presentation(for descriptor: PluginDescriptor) -> PluginFeaturePresentation {
        if let capabilities = descriptor.capabilities {
            switch (capabilities.primaryPanel, capabilities.componentPanel) {
            case (true, true):
                return .featureAndComponentPanel
            case (true, false):
                return .featurePanel
            case (false, true):
                return .componentPanel
            case (false, false):
                return .featurePanel
            }
        }

        let plugin = descriptor.plugin
        switch (plugin.primaryPanel, plugin.componentPanel) {
        case (.some, .some):
            return .featureAndComponentPanel
        case (.some, .none):
            return .featurePanel
        case (.none, .some):
            return .componentPanel
        case (.none, .none):
            return .featurePanel
        }
    }

    private func trimComponentViewCache(keeping visibleComponentIDs: Set<String>) {
        componentViewCache = componentViewCache.filter { visibleComponentIDs.contains($0.key) }
    }

    private func trimConfigurationViewCache(keeping configurationPluginIDs: Set<String>) {
        configurationViewCache = configurationViewCache.filter {
            configurationPluginIDs.contains($0.key)
        }
    }

    private func syncSelectedFeatureSettingsPane() {
        guard case let .configuration(pluginID) = selectedFeatureSettingsPane else {
            return
        }

        let availableIDs = Set(pluginConfigurationItems.map(\.id))
        if !availableIDs.contains(pluginID) {
            selectedFeatureSettingsPane = .installed
        }
    }

    private func shortcutDescriptor(for shortcutID: String) -> ShortcutDescriptor? {
        shortcutDescriptors().first(where: { $0.itemID == shortcutID })
    }

    private func shortcutItemID(pluginID: String, shortcutDefinitionID: String) -> String {
        "\(pluginID).shortcut.\(shortcutDefinitionID)"
    }

    private func resolvedBinding(for descriptor: ShortcutDescriptor) -> ShortcutBinding? {
        shortcutStore.resolvedBinding(
            for: descriptor.itemID,
            default: descriptor.definition.defaultBinding
        )
    }

    private func resolvedBinding(forPluginID pluginID: String, shortcutDefinitionID: String) -> ShortcutBinding? {
        guard let descriptor = shortcutDescriptors().first(where: {
            $0.pluginID == pluginID && $0.definition.id == shortcutDefinitionID
        }) else {
            return nil
        }

        return resolvedBinding(for: descriptor)
    }

    private func applyShortcutCustomization(
        _ customization: ShortcutCustomization,
        for descriptor: ShortcutDescriptor
    ) {
        do {
            try validateShortcutCustomization(customization, for: descriptor)
            shortcutStore.setCustomization(customization, for: descriptor.itemID)
            shortcutErrors.removeValue(forKey: descriptor.itemID)
            rebuildDerivedState()
            syncGlobalShortcuts()
        } catch let error as ShortcutValidationError {
            shortcutErrors[descriptor.itemID] = error.localizedDescription
            rebuildDerivedState()
        } catch {
            shortcutErrors[descriptor.itemID] = error.localizedDescription
            rebuildDerivedState()
        }
    }

    private func validateShortcutCustomization(
        _ customization: ShortcutCustomization,
        for descriptor: ShortcutDescriptor
    ) throws {
        let candidate = ShortcutStore.resolve(
            customization: customization,
            defaultBinding: descriptor.definition.defaultBinding
        )

        if descriptor.definition.isRequired && candidate == nil {
            throw ShortcutValidationError.requiredShortcut
        }

        if let candidate {
            guard !candidate.modifiers.isEmpty else {
                throw ShortcutValidationError.missingModifier
            }

            guard !ShortcutKeyCode.isModifier(candidate.keyCode) else {
                throw ShortcutValidationError.modifierOnly
            }

            if let conflict = shortcutDescriptors().first(where: {
                $0.itemID != descriptor.itemID && resolvedBinding(for: $0) == candidate
            }) {
                throw ShortcutValidationError.duplicate(
                    ownerDescription: "\(conflict.pluginTitle) · \(conflict.definition.title)"
                )
            }
        }
    }

    private func syncGlobalShortcuts() {
        let registrations = shortcutDescriptors().compactMap { descriptor -> GlobalShortcutManager.Registration? in
            guard descriptor.definition.scope == .global else {
                return nil
            }

            guard let binding = resolvedBinding(for: descriptor) else {
                return nil
            }

            return GlobalShortcutManager.Registration(
                shortcutID: descriptor.itemID,
                binding: binding
            )
        }

        globalShortcutManager.updateBindings(registrations)
    }

    private func handleShortcutTrigger(shortcutID: String) {
        guard let descriptor = shortcutDescriptor(for: shortcutID) else {
            return
        }

        handlePluginAction {
            guardPluginCall(descriptor.plugin, operation: "shortcut action") {
                descriptor.plugin.handleShortcutAction(id: descriptor.definition.actionID)
            }
        }
    }

    private func requestPermissionGuidance(forPluginID pluginID: String, permissionID: String) {
        guard activePlugins.contains(where: { plugin in
            plugin.metadata.id == pluginID
                && (guardedValue(
                    for: plugin,
                    operation: "read permission requirements",
                    plugin.permissionRequirements
                ) ?? []).contains(where: { $0.id == permissionID })
        }) else {
            return
        }

        presentPluginConfiguration(pluginID: pluginID)
    }

    private func permissionActionTitle(
        for kind: PluginPermissionKind,
        isGranted: Bool
    ) -> String {
        switch kind {
        case .accessibility:
            return isGranted ? "检查授权状态" : "前往授权"
        case .calendarFullAccess:
            return isGranted ? "检查授权状态" : "请求授权"
        case .automation:
            return "打开设置"
        case .screenRecording:
            return isGranted ? "检查授权状态" : "前往授权"
        }
    }

    private func permissionIconName(for kind: PluginPermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "accessibility"
        case .calendarFullAccess:
            return "calendar"
        case .automation:
            return "cursorarrow.click.2"
        case .screenRecording:
            return "rectangle.dashed.badge.record"
        }
    }
}
