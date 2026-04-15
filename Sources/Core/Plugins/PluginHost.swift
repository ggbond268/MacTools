import Combine
import Foundation
import SwiftUI

@MainActor
final class PluginHost: ObservableObject {
    private struct ShortcutDescriptor {
        let itemID: String
        let pluginID: String
        let pluginTitle: String
        let definition: PluginShortcutDefinition
        let plugin: any FeaturePlugin
    }

    private let plugins: [any FeaturePlugin]
    private let shortcutStore: ShortcutStore
    private let pluginDisplayPreferencesStore: PluginDisplayPreferencesStore
    private let globalShortcutManager: GlobalShortcutManager

    private var shortcutErrors: [String: String] = [:]

    @Published private(set) var panelItems: [PluginPanelItem] = []
    @Published private(set) var featureManagementItems: [PluginFeatureManagementItem] = []
    @Published private(set) var permissionCards: [PluginPermissionCard] = []
    @Published private(set) var settingsCards: [PluginSettingsCard] = []
    @Published private(set) var shortcutItems: [ShortcutSettingsItem] = []
    @Published private(set) var hasActivePlugin = false
    @Published private(set) var settingsPresentationRequestCount = 0
    @Published var selectedSettingsDestination: SettingsDestination = .general

    convenience init() {
        self.init(
            plugins: [DisplayResolutionPlugin(), KeepAwakePlugin(), PhysicalCleanModePlugin()],
            shortcutStore: ShortcutStore(),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(),
            globalShortcutManager: GlobalShortcutManager()
        )
    }

    init(
        plugins: [any FeaturePlugin],
        shortcutStore: ShortcutStore,
        pluginDisplayPreferencesStore: PluginDisplayPreferencesStore,
        globalShortcutManager: GlobalShortcutManager
    ) {
        self.plugins = plugins.sorted {
            if $0.manifest.order == $1.manifest.order {
                return $0.manifest.title.localizedCompare($1.manifest.title) == .orderedAscending
            }

            return $0.manifest.order < $1.manifest.order
        }
        self.shortcutStore = shortcutStore
        self.pluginDisplayPreferencesStore = pluginDisplayPreferencesStore
        self.globalShortcutManager = globalShortcutManager

        for plugin in self.plugins {
            let pluginID = plugin.manifest.id

            plugin.onStateChange = { [weak self] in
                self?.rebuildDerivedState()
            }
            plugin.requestPermissionGuidance = { [weak self] permissionID in
                self?.requestPermissionGuidance(forPluginID: pluginID, permissionID: permissionID)
            }
            plugin.shortcutBindingResolver = { [weak self] shortcutDefinitionID in
                self?.resolvedBinding(forPluginID: pluginID, shortcutDefinitionID: shortcutDefinitionID)
            }
        }

        self.globalShortcutManager.onShortcutTriggered = { [weak self] shortcutID in
            self?.handleShortcutTrigger(shortcutID: shortcutID)
        }

        rebuildDerivedState()
        refreshAll()
    }

    func refreshAll() {
        for plugin in plugins {
            plugin.refresh()
        }

        rebuildDerivedState()
        syncGlobalShortcuts()
    }

    func isSwitchOn(for pluginID: String) -> Bool {
        panelItems.first(where: { $0.id == pluginID })?.isOn ?? false
    }

    func setSwitchValue(_ isOn: Bool, for pluginID: String) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handlePanelAction(.setSwitch(isOn))
        rebuildDerivedState()
    }

    func setDisclosureExpanded(_ isExpanded: Bool, for pluginID: String) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handlePanelAction(.setDisclosureExpanded(isExpanded))
        rebuildDerivedState()
    }

    func setPanelSelectionValue(
        _ optionID: String,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handlePanelAction(.setSelection(controlID: controlID, optionID: optionID))
        rebuildDerivedState()
    }

    func setPanelNavigationSelectionValue(
        _ optionID: String,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handlePanelAction(
            .setNavigationSelection(controlID: controlID, optionID: optionID)
        )
        rebuildDerivedState()
    }

    func setPanelDateValue(
        _ date: Date,
        controlID: String,
        for pluginID: String
    ) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handlePanelAction(.setDate(controlID: controlID, value: date))
        rebuildDerivedState()
    }

    func performSettingsAction(pluginID: String, actionID: String) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handleSettingsAction(id: actionID)
        rebuildDerivedState()
    }

    func performPermissionAction(pluginID: String, permissionID: String) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        plugin.handlePermissionAction(id: permissionID)
        rebuildDerivedState()
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

    private func plugin(for pluginID: String) -> (any FeaturePlugin)? {
        plugins.first(where: { $0.manifest.id == pluginID })
    }

    private func rebuildDerivedState() {
        let orderedPlugins = orderedPlugins()

        panelItems = orderedPlugins.compactMap { plugin in
            let manifest = plugin.manifest
            let state = plugin.panelState

            guard
                state.isVisible,
                pluginDisplayPreferencesStore.isVisible(
                    manifest.id,
                    defaultPluginIDs: defaultPluginIDs
                )
            else {
                return nil
            }

            let description = state.errorMessage ?? state.subtitle

            return PluginPanelItem(
                id: manifest.id,
                title: manifest.title,
                iconName: manifest.iconName,
                iconTint: manifest.iconTint,
                controlStyle: manifest.controlStyle,
                menuActionBehavior: manifest.menuActionBehavior,
                description: description.isEmpty ? manifest.defaultDescription : description,
                helpText: description.isEmpty ? manifest.defaultDescription : description,
                descriptionTone: state.errorMessage == nil ? .secondary : .error,
                isOn: state.isOn,
                isExpanded: state.isExpanded,
                isEnabled: state.isEnabled,
                detail: state.detail
            )
        }

        featureManagementItems = orderedPlugins.map { plugin in
            let manifest = plugin.manifest

            return PluginFeatureManagementItem(
                id: manifest.id,
                title: manifest.title,
                description: manifest.defaultDescription,
                iconName: manifest.iconName,
                iconTint: manifest.iconTint,
                isVisible: pluginDisplayPreferencesStore.isVisible(
                    manifest.id,
                    defaultPluginIDs: defaultPluginIDs
                ),
                isActive: plugin.panelState.isOn
            )
        }

        settingsCards = orderedPlugins.flatMap { plugin in
            plugin.settingsSections.map { section in
                PluginSettingsCard(
                    id: "\(plugin.manifest.id).\(section.id)",
                    pluginID: plugin.manifest.id,
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

        permissionCards = orderedPlugins.flatMap { plugin in
            plugin.permissionRequirements.map { requirement in
                let state = plugin.permissionState(for: requirement.id)

                return PluginPermissionCard(
                    id: "\(plugin.manifest.id).permission.\(requirement.id)",
                    pluginID: plugin.manifest.id,
                    permissionID: requirement.id,
                    title: "\(plugin.manifest.title) · \(requirement.title)",
                    description: requirement.description,
                    statusText: state.isGranted ? "已授权" : "未授权",
                    statusSystemImage: state.isGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                    statusTone: state.isGranted ? .positive : .caution,
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

        hasActivePlugin = plugins.contains(where: { $0.panelState.isOn })
    }

    private func shortcutDescriptors() -> [ShortcutDescriptor] {
        orderedPlugins().flatMap { plugin in
            plugin.shortcutDefinitions.map { definition in
                ShortcutDescriptor(
                    itemID: shortcutItemID(
                        pluginID: plugin.manifest.id,
                        shortcutDefinitionID: definition.id
                    ),
                    pluginID: plugin.manifest.id,
                    pluginTitle: plugin.manifest.title,
                    definition: definition,
                    plugin: plugin
                )
            }
        }
    }

    private var defaultPluginIDs: [String] {
        plugins.map(\.manifest.id)
    }

    private func orderedPluginIDs() -> [String] {
        pluginDisplayPreferencesStore.orderedPluginIDs(defaultPluginIDs: defaultPluginIDs)
    }

    private func orderedPlugins() -> [any FeaturePlugin] {
        let pluginsByID = Dictionary(uniqueKeysWithValues: plugins.map { ($0.manifest.id, $0) })

        return orderedPluginIDs().compactMap { pluginsByID[$0] }
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

        descriptor.plugin.handleShortcutAction(id: descriptor.definition.actionID)
        rebuildDerivedState()
    }

    private func requestPermissionGuidance(forPluginID pluginID: String, permissionID: String) {
        guard let plugin = plugin(for: pluginID) else {
            return
        }

        guard plugin.permissionRequirements.contains(where: { $0.id == permissionID }) else {
            return
        }

        selectedSettingsDestination = .general
        settingsPresentationRequestCount += 1
    }

    private func permissionActionTitle(
        for kind: PluginPermissionKind,
        isGranted: Bool
    ) -> String {
        switch kind {
        case .accessibility:
            return isGranted ? "检查授权状态" : "前往授权"
        }
    }
}
