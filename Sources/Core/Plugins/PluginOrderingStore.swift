import Foundation

/// Plugin management order is independent of panel placements.
@MainActor
final class PluginOrderingStore {
    static let storageKey = "plugin.managementOrder"
    private let userDefaults: UserDefaults
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private var order: [String]
    private var preservesUnknownData = false

    init(userDefaults: UserDefaults = .standard,
         preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil) {
        self.userDefaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
        if let saved = userDefaults.array(forKey: Self.storageKey) as? [String] {
            order = saved
        } else if let data = userDefaults.data(forKey: MenuBarPanelStore.legacyDisplayStorageKey) {
            do {
                order = try LegacyPanelDisplayPreferences(data: data).generalOrder
                userDefaults.set(order, forKey: Self.storageKey)
            } catch {
                order = []
                preservesUnknownData = true
            }
        } else { order = [] }
    }

    func orderedPluginIDs(defaultPluginIDs: [String]) -> [String] {
        reloadRecoveredOrderIfNeeded()
        let available = Set(defaultPluginIDs)
        var seen: Set<String> = []
        return (order + defaultPluginIDs).filter { available.contains($0) && seen.insert($0).inserted }
    }

    func setOrderedPluginIDs(_ ids: [String], defaultPluginIDs: [String]) {
        reloadRecoveredOrderIfNeeded()
        guard !preservesUnknownData else { return }
        var seen: Set<String> = []
        let requested = (ids + defaultPluginIDs).filter { seen.insert($0).inserted }
        let moving = Set(requested)
        var iterator = requested.makeIterator()
        var next = order.compactMap { moving.contains($0) ? iterator.next() : $0 }
        while let id = iterator.next() { next.append(id) }
        persist(next)
    }

    func removePlugin(_ id: String) {
        reloadRecoveredOrderIfNeeded()
        persist(order.filter { $0 != id })
    }

    private func reloadRecoveredOrderIfNeeded() {
        guard preservesUnknownData,
              userDefaults.object(forKey: MenuBarPanelStore.legacyDisplayStorageKey) == nil,
              let saved = userDefaults.array(forKey: Self.storageKey) as? [String] else { return }
        // The panel store retires an unreadable source only after an explicit
        // reset/import has persisted its replacement. Resume the existing instance.
        order = saved
        preservesUnknownData = false
    }

    private func persist(_ next: [String]) {
        guard !preservesUnknownData, next != order else { return }
        order = next
        userDefaults.set(order, forKey: Self.storageKey)
        preferencesBackupChangeReporter?.didPersist(.pluginDisplay)
    }
}
