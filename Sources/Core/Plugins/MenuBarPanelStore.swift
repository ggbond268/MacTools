import Foundation

struct MenuBarPanelDefinition: Codable, Equatable, Identifiable, Sendable {
    static let componentsID = "components"
    static let featuresID = "features"
    static let maximumCount = 5
    static let maximumNameLength = 24

    let id: String
    var name: String
    var systemImage: String
    var isHidden = false

    var isDefault: Bool { id == Self.componentsID || id == Self.featuresID }

    var title: String {
        if !name.isEmpty { return name }
        return switch id {
        case Self.componentsID:
            AppL10n.plugins("plugin.panel.components", defaultValue: "组件面板")
        case Self.featuresID:
            AppL10n.plugins("plugin.panel.features", defaultValue: "功能面板")
        default:
            FeatureL10n.string("新面板")
        }
    }

    static func nextName(avoiding names: Set<String>) -> String {
        var number = 1
        while names.contains(FeatureL10n.format("面板 %lld", number)) { number += 1 }
        return FeatureL10n.format("面板 %lld", number)
    }

    static var defaults: [Self] {
        [
            Self(id: componentsID, name: "", systemImage: "square.grid.2x2"),
            Self(id: featuresID, name: "", systemImage: "switch.2"),
        ]
    }
}

struct MenuBarPanelEntry: Codable, Hashable, Identifiable, Sendable {
    let pluginID: String
    let surface: PluginDisplaySurface

    var instanceID: String? = nil

    var templateID: String { surface.panelEntryID(pluginID: pluginID) }
    var id: String { instanceID.map { "instance:\($0)" } ?? templateID }
    // Existing surface views use plugin IDs; copies need distinct presentation identities.
    var presentationID: String { instanceID == nil ? pluginID : id }
}

struct MenuBarPanelLayoutChange {
    let before: MenuBarPanelConfiguration
    let after: MenuBarPanelConfiguration
}

extension PluginDisplaySurface {
    var defaultPanelID: String {
        self == .dashboard ? MenuBarPanelDefinition.componentsID : MenuBarPanelDefinition.featuresID
    }

    func panelEntryID(pluginID: String) -> String { "\(rawValue):\(pluginID)" }
}

struct MenuBarPanelConfiguration: Codable, Equatable, Sendable {
    var version = 2
    var panels = MenuBarPanelDefinition.defaults
    // Default entries remain implicit so newly installed plugins keep their original surface.
    var assignments: [String: String] = [:]
    var orders: [String: [String]] = [:]
    var instances: [MenuBarPanelEntry] = []
    var removedDefaultEntries: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, panels, assignments, orders, instances, removedDefaultEntries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        panels = try values.decode([MenuBarPanelDefinition].self, forKey: .panels)
        assignments = try values.decode([String: String].self, forKey: .assignments)
        orders = try values.decode([String: [String]].self, forKey: .orders)
        instances = try values.decodeIfPresent([MenuBarPanelEntry].self, forKey: .instances) ?? []
        removedDefaultEntries = try values.decodeIfPresent(Set<String>.self, forKey: .removedDefaultEntries) ?? []
    }

    /// Names are presentation state derived from the current tab order, not shortcut identity.
    var displayPanels: [MenuBarPanelDefinition] {
        panels.enumerated().map { index, panel in
            var panel = panel
            panel.name = FeatureL10n.format("面板 %lld", index + 1)
            return panel
        }
    }

    func applyingLegacyClickBehavior(_ behavior: String?) -> Self {
        guard behavior == "swapped" else { return self }
        var result = self
        result.panels.reverse()
        return result
    }

    func panelID(pluginID: String, surface: PluginDisplaySurface) -> String {
        self.panelID(for: MenuBarPanelEntry(pluginID: pluginID, surface: surface))
    }

    func panelID(for entry: MenuBarPanelEntry) -> String {
        assignments[entry.id] ?? entry.surface.defaultPanelID
    }

    func orderedIDs(_ pluginIDs: [String], surface: PluginDisplaySurface, panelID: String) -> [String] {
        orderedEntries(pluginIDs.map { MenuBarPanelEntry(pluginID: $0, surface: surface) }, panelID: panelID)
            .map(\.pluginID)
    }

    func orderedEntries(_ entries: [MenuBarPanelEntry], panelID: String) -> [MenuBarPanelEntry] {
        let available = Set(entries.map(\.templateID))
        let candidates = entries.filter { !removedDefaultEntries.contains($0.id) }
            + instances.filter { available.contains($0.templateID) }
        let assigned = candidates.filter { self.panelID(for: $0) == panelID }
        let lookup = Dictionary(assigned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = (orders[panelID] ?? []).compactMap { lookup[$0] }
        let savedIDs = Set(saved.map(\.id))
        return saved + assigned.filter { !savedIDs.contains($0.id) }
    }

    func normalized() -> Self {
        var result = self
        result.version = 2
        var seen: Set<String> = []
        let defaults = MenuBarPanelDefinition.defaults
        var customCount = 0
        var usedNames = Set(panels.map {
            String($0.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MenuBarPanelDefinition.maximumNameLength))
        })
        result.panels = panels.compactMap { panel in
            guard !panel.id.isEmpty, seen.insert(panel.id).inserted else { return nil }
            if !panel.isDefault {
                guard customCount < MenuBarPanelDefinition.maximumCount - defaults.count else { return nil }
                customCount += 1
            }
            var panel = panel
            panel.name = String(
                panel.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(MenuBarPanelDefinition.maximumNameLength)
            )
            if panel.name.isEmpty && !panel.isDefault {
                panel.name = MenuBarPanelDefinition.nextName(avoiding: usedNames)
                usedNames.insert(panel.name)
            }
            if panel.systemImage.isEmpty { panel.systemImage = "square.grid.2x2" }
            return panel
        }
        for panel in defaults where !result.panels.contains(where: { $0.id == panel.id }) {
            result.panels.append(panel)
        }
        if result.panels.allSatisfy(\.isHidden) { result.panels[0].isHidden = false }
        let validIDs = Set(result.panels.map(\.id))
        var instanceIDs: Set<String> = []
        result.instances = instances.filter {
            !$0.pluginID.isEmpty && $0.instanceID.flatMap(UUID.init(uuidString:)) != nil
                && instanceIDs.insert($0.id).inserted
        }
        result.removedDefaultEntries = removedDefaultEntries.filter { !$0.hasPrefix("instance:") }
        result.assignments = assignments.filter {
            validIDs.contains($0.value) && (!$0.key.hasPrefix("instance:") || instanceIDs.contains($0.key))
        }
        result.orders = orders.filter { validIDs.contains($0.key) }.mapValues { entries in
            var seen: Set<String> = []
            return entries.filter { seen.insert($0).inserted }
        }
        return result
    }
}

@MainActor
final class MenuBarPanelStore {
    static let storageKey = "menuBar.panelConfiguration"
    static let selectionStorageKey = "menuBar.lastSelectedPanelID"
    static let legacyClickBehaviorStorageKey = "menuBar.clickBehaviorPreference"
    private let userDefaults: UserDefaults
    private let reporter: PreferencesBackupChangeReporter?
    private(set) var configuration: MenuBarPanelConfiguration

    init(userDefaults: UserDefaults, reporter: PreferencesBackupChangeReporter? = nil) {
        self.userDefaults = userDefaults
        self.reporter = reporter
        let storedData = userDefaults.data(forKey: Self.storageKey)
        var canMigrateLegacyBehavior = storedData == nil
        if let data = storedData,
            let stored = try? JSONDecoder().decode(MenuBarPanelConfiguration.self, from: data),
            (1...2).contains(stored.version)
        {
            configuration = stored.normalized()
            canMigrateLegacyBehavior = true
        } else {
            configuration = MenuBarPanelConfiguration()
        }

        if canMigrateLegacyBehavior,
           let legacyBehavior = userDefaults.string(forKey: Self.legacyClickBehaviorStorageKey) {
            replace(configuration.applyingLegacyClickBehavior(legacyBehavior))
            userDefaults.removeObject(forKey: Self.legacyClickBehaviorStorageKey)
        }
    }

    var lastSelectedPanelID: String {
        let visiblePanels = configuration.panels.filter { !$0.isHidden }
        let saved = userDefaults.string(forKey: Self.selectionStorageKey)
        return visiblePanels.first { $0.id == saved }?.id
            ?? visiblePanels.first?.id ?? MenuBarPanelDefinition.componentsID
    }

    func rememberSelection(id: String) {
        guard configuration.panels.contains(where: { $0.id == id && !$0.isHidden }),
              userDefaults.string(forKey: Self.selectionStorageKey) != id else { return }
        // Selection is local navigation state, not a portable layout change.
        userDefaults.set(id, forKey: Self.selectionStorageKey)
    }

    @discardableResult
    func replace(_ configuration: MenuBarPanelConfiguration) -> Bool {
        guard (1...2).contains(configuration.version) else { return false }
        let normalized = configuration.normalized()
        guard normalized != self.configuration,
            let data = try? JSONEncoder().encode(normalized)
        else { return false }
        userDefaults.set(data, forKey: Self.storageKey)
        self.configuration = normalized
        if let selectedID = userDefaults.string(forKey: Self.selectionStorageKey),
           !normalized.panels.contains(where: { $0.id == selectedID && !$0.isHidden })
        {
            userDefaults.removeObject(forKey: Self.selectionStorageKey)
        }
        reporter?.didPersist(.pluginDisplay)
        return true
    }

    @discardableResult
    func addPanel() -> String? {
        guard configuration.panels.count < MenuBarPanelDefinition.maximumCount else { return nil }
        var next = configuration
        let id = UUID().uuidString.lowercased()
        next.panels.append(
            MenuBarPanelDefinition(
                id: id,
                name: MenuBarPanelDefinition.nextName(avoiding: Set(next.panels.map(\.title))),
                systemImage: "star"
            ))
        replace(next)
        return id
    }

    func updatePanel(_ panel: MenuBarPanelDefinition) {
        guard let index = configuration.panels.firstIndex(where: { $0.id == panel.id }) else { return }
        var next = configuration
        next.panels[index] = panel
        replace(next)
    }

    func deletePanel(id: String) {
        guard configuration.panels.contains(where: { $0.id == id && !$0.isDefault }) else { return }
        var next = configuration
        next.panels.removeAll { $0.id == id }
        // Removing overrides restores each entry to its own original default panel.
        next.assignments = next.assignments.filter { $0.value != id }
        next.orders.removeValue(forKey: id)
        replace(next)
    }

    func movePanel(id: String, toOffset: Int) {
        var next = configuration
        guard let index = next.panels.firstIndex(where: { $0.id == id }) else { return }
        let panel = next.panels.remove(at: index)
        let destination = min(max(toOffset - (toOffset > index ? 1 : 0), 0), next.panels.count)
        next.panels.insert(panel, at: destination)
        replace(next)
    }

    func assign(
        pluginID: String,
        surface: PluginDisplaySurface,
        to panelID: String,
        destinationOrder: [MenuBarPanelEntry]? = nil,
        visibleOrder: [MenuBarPanelEntry]? = nil
    ) {
        assign(MenuBarPanelEntry(pluginID: pluginID, surface: surface), to: panelID,
               destinationOrder: destinationOrder, visibleOrder: visibleOrder)
    }

    func assign(_ entry: MenuBarPanelEntry, to panelID: String,
                destinationOrder: [MenuBarPanelEntry]? = nil, visibleOrder: [MenuBarPanelEntry]? = nil) {
        guard configuration.panels.contains(where: { $0.id == panelID }),
              configuration.panelID(for: entry) != panelID else { return }
        var next = configuration
        let key = entry.id
        for id in Array(next.orders.keys) { next.orders[id]?.removeAll { $0 == key } }
        next.assignments[key] = panelID == entry.surface.defaultPanelID ? nil : panelID
        let requested = (destinationOrder?.map(\.id) ?? next.orders[panelID] ?? []).filter { $0 != key } + [key]
        next.orders[panelID] = Self.mergingOrder(requested, into: next.orders[panelID] ?? [])
        if let visibleOrder {
            next.orders[panelID] = Self.mergingOrder(visibleOrder.map(\.id), into: next.orders[panelID] ?? [])
        }
        replace(next)
    }

    @discardableResult
    func addInstance(of template: MenuBarPanelEntry, to panelID: String,
                     visibleOrder: [MenuBarPanelEntry], suppressDefault: Bool) -> MenuBarPanelEntry? {
        guard configuration.panels.contains(where: { $0.id == panelID }) else { return nil }
        let entry = MenuBarPanelEntry(pluginID: template.pluginID, surface: template.surface,
                                      instanceID: UUID().uuidString.lowercased())
        var next = configuration
        if suppressDefault { next.removedDefaultEntries.insert(template.templateID) }
        next.instances.append(entry)
        next.assignments[entry.id] = panelID == entry.surface.defaultPanelID ? nil : panelID
        next.orders[panelID] = Self.mergingOrder((visibleOrder + [entry]).map(\.id), into: next.orders[panelID] ?? [])
        return replace(next) ? entry : nil
    }

    func removeEntry(_ entry: MenuBarPanelEntry) {
        var next = configuration
        if entry.instanceID == nil { next.removedDefaultEntries.insert(entry.id) }
        else { next.instances.removeAll { $0.id == entry.id } }
        next.assignments.removeValue(forKey: entry.id)
        next.orders = next.orders.mapValues { $0.filter { $0 != entry.id } }
        replace(next)
    }

    func removePlugin(id: String) {
        var next = configuration
        let keys = Set(PluginDisplaySurface.allCases.map { $0.panelEntryID(pluginID: id) }
            + next.instances.filter { $0.pluginID == id }.map(\.id))
        next.instances.removeAll { $0.pluginID == id }
        next.removedDefaultEntries.subtract(keys)
        next.assignments = next.assignments.filter { !keys.contains($0.key) }
        next.orders = next.orders.mapValues { $0.filter { !keys.contains($0) } }
        replace(next)
    }

    func setOrder(_ pluginIDs: [String], surface: PluginDisplaySurface, panelID: String) {
        setOrder(pluginIDs.map { MenuBarPanelEntry(pluginID: $0, surface: surface) }, panelID: panelID)
    }

    func setOrder(_ entries: [MenuBarPanelEntry], panelID: String, preserving baseline: [MenuBarPanelEntry]? = nil) {
        guard configuration.panels.contains(where: { $0.id == panelID }) else { return }
        var next = configuration
        next.orders[panelID] = Self.mergingOrder(entries.map(\.id), into: baseline?.map(\.id) ?? next.orders[panelID] ?? [])
        replace(next)
    }

    private static func mergingOrder(_ requested: [String], into saved: [String]) -> [String] {
        let requestedSet = Set(requested)
        var iterator = requested.makeIterator()
        // Keep hidden or temporarily unavailable entries in their remembered slots.
        var reordered = saved.compactMap { key in
            requestedSet.contains(key) ? iterator.next() : key
        }
        while let key = iterator.next() { reordered.append(key) }
        return reordered
    }
}
