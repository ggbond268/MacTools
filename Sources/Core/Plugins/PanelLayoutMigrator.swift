import Foundation

/// Read-only DTOs for the two pre-multiview preference stores and old backups.
struct LegacyPanelLayout: Decodable {
    struct Entry: Decodable {
        let pluginID: String
        let surface: String
        let instanceID: String?

        var templateID: String { "\(surface):\(pluginID)" }
        var id: String { instanceID.map { "instance:\($0)" } ?? templateID }
    }

    var panels = MenuBarPanelDefinition.defaults
    var assignments: [String: String] = [:]
    var orders: [String: [String]] = [:]
    var instances: [Entry] = []
    var removedDefaultEntries: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case panels, assignments, orders, instances, removedDefaultEntries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        panels = try values.decodeIfPresent([MenuBarPanelDefinition].self, forKey: .panels) ?? panels
        assignments = try values.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:]
        orders = try values.decodeIfPresent([String: [String]].self, forKey: .orders) ?? [:]
        instances = try values.decodeIfPresent([Entry].self, forKey: .instances) ?? []
        removedDefaultEntries = try values.decodeIfPresent(Set<String>.self, forKey: .removedDefaultEntries) ?? []
    }
}

struct LegacyPanelDisplayPreferences {
    let generalOrder: [String]
    let dashboardOrder: [String]
    let featureOrder: [String]
    let dashboardHidden: Set<String>
    let featureHidden: Set<String>
    let explicitDashboardHidden: Set<String>
    let explicitFeatureHidden: Set<String>

    init(data: Data? = nil, additionalHidden: Set<String> = []) throws {
        let object: [String: Any]
        if let data {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (decoded["version"] as? Int ?? 1) <= 4 else {
                throw CocoaError(.coderReadCorrupt)
            }
            object = decoded
        } else { object = [:] }
        generalOrder = object["generalPluginOrder"] as? [String]
            ?? object["orderedPluginIDs"] as? [String] ?? []
        dashboardOrder = object["dashboardOrderedPluginIDs"] as? [String] ?? []
        featureOrder = object["featurePanelOrderedPluginIDs"] as? [String] ?? []
        let legacy = Set(object["legacyHiddenPluginIDs"] as? [String] ?? [])
            .union(object["globallyHiddenPluginIDs"] as? [String] ?? [])
            .union(object["pendingLegacyDisabledPluginIDs"] as? [String] ?? [])
            .union(additionalHidden)
        let shared = (object["version"] as? Int ?? 1) < 4
            ? Set(object["hiddenPluginIDs"] as? [String] ?? []) : []
        explicitDashboardHidden = Set(object["dashboardHiddenPluginIDs"] as? [String] ?? [])
        explicitFeatureHidden = Set(object["featurePanelHiddenPluginIDs"] as? [String] ?? [])
        dashboardHidden = explicitDashboardHidden.union(legacy).union(shared)
        featureHidden = explicitFeatureHidden.union(legacy).union(shared)
    }

    init(backup: PluginDisplayPreferencesBackup) {
        generalOrder = backup.orderedPluginIDs
        dashboardOrder = backup.dashboardOrderedPluginIDs ?? []
        featureOrder = backup.featurePanelOrderedPluginIDs ?? []
        dashboardHidden = Set(backup.dashboardHiddenPluginIDs ?? backup.hiddenPluginIDs)
        featureHidden = Set(backup.featurePanelHiddenPluginIDs ?? backup.hiddenPluginIDs)
        explicitDashboardHidden = Set(backup.dashboardHiddenPluginIDs ?? [])
        explicitFeatureHidden = Set(backup.featurePanelHiddenPluginIDs ?? [])
    }
}

/// Shared legacy preferences need capability discovery before materialization.
/// Keeping only this seed avoids inventing a second view for a single-view plugin.
struct LegacyPanelSeed: Codable, Equatable, Sendable {
    let generalOrder: [String]
    let dashboardHidden: Set<String>
    let featureHidden: Set<String>
    var resolvedPluginIDs: Set<String> = []

    var pluginIDs: Set<String> { Set(generalOrder).union(dashboardHidden).union(featureHidden) }
}

enum PanelLayoutMigrator {
    static func migrate(_ legacy: LegacyPanelLayout,
                        preferences: LegacyPanelDisplayPreferences? = nil) -> MenuBarPanelConfiguration {
        var result = MenuBarPanelConfiguration()
        result.panels = legacy.panels
        var templates: [String] = []
        var seen: Set<String> = []
        func append(_ key: String) {
            if itemKey(key) != nil, seen.insert(key).inserted { templates.append(key) }
        }
        if let preferences {
            let seed = LegacyPanelSeed(generalOrder: preferences.generalOrder,
                dashboardHidden: preferences.dashboardHidden, featureHidden: preferences.featureHidden)
            result.legacySeed = seed.pluginIDs.isEmpty ? nil : seed
            for id in preferences.dashboardOrder { append("dashboard:\(id)") }
            for id in preferences.featureOrder { append("featurePanel:\(id)") }
            for id in preferences.explicitDashboardHidden.sorted() { append("dashboard:\(id)") }
            for id in preferences.explicitFeatureHidden.sorted() { append("featurePanel:\(id)") }
        }
        for panel in legacy.panels {
            for key in legacy.orders[panel.id, default: []] { append(key) }
        }
        for key in legacy.assignments.keys.sorted() { append(key) }
        for key in legacy.removedDefaultEntries.sorted() { append(key) }
        for entry in legacy.instances { append(entry.templateID) }

        var entriesByLegacyID: [String: MenuBarPanelPlacement] = [:]
        var destinationByLegacyID: [String: String] = [:]
        var allIDs: [String] = []
        func isHidden(_ key: PluginPanelItemKey) -> Bool {
            key.itemID == "widget"
                ? preferences?.dashboardHidden.contains(key.pluginID) == true
                : preferences?.featureHidden.contains(key.pluginID) == true
        }
        func add(_ legacyID: String, template: String, instanceID: UUID? = nil) {
            guard let key = itemKey(template) else { return }
            result.initializedItems.insert(key)
            guard !isHidden(key), entriesByLegacyID[legacyID] == nil else { return }
            entriesByLegacyID[legacyID] = MenuBarPanelPlacement(id: instanceID ?? UUID(), item: key)
            destinationByLegacyID[legacyID] = legacy.assignments[legacyID]
                ?? (key.itemID == "widget" ? MenuBarPanelDefinition.componentsID : MenuBarPanelDefinition.featuresID)
            allIDs.append(legacyID)
        }
        for template in templates {
            guard let key = itemKey(template) else { continue }
            result.initializedItems.insert(key)
            if !legacy.removedDefaultEntries.contains(template) { add(template, template: template) }
        }
        for entry in legacy.instances {
            guard let id = entry.instanceID.flatMap(UUID.init(uuidString:)) else { continue }
            add(entry.id, template: entry.templateID, instanceID: id)
        }
        let destinations = Set(destinationByLegacyID.values).union(legacy.panels.map(\.id))
        for panelID in destinations.sorted() {
            var used: Set<String> = []
            let ordered = (legacy.orders[panelID, default: []] + allIDs).filter {
                destinationByLegacyID[$0] == panelID && used.insert($0).inserted
            }
            result.placementsByPanelID[panelID] = ordered.compactMap { entriesByLegacyID[$0] }
        }
        return result.normalized()
    }

    private static func itemKey(_ legacyID: String) -> PluginPanelItemKey? {
        let parts = legacyID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "dashboard": return PluginPanelItemKey(pluginID: parts[1], itemID: "widget")
        case "featurePanel": return PluginPanelItemKey(pluginID: parts[1], itemID: "control")
        default: return nil
        }
    }
}
