import Foundation

@MainActor
final class PluginDisplayPreferencesStore {
    private enum DefaultsKey {
        static let storage = "plugin.display.preferences"
    }

    private struct StoredPreferences: Codable, Equatable {
        var orderedPluginIDs: [String] = []
        var hiddenPluginIDs: Set<String> = []
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func orderedPluginIDs(defaultPluginIDs: [String]) -> [String] {
        normalizedPreferences(defaultPluginIDs: defaultPluginIDs).orderedPluginIDs
    }

    func isVisible(_ pluginID: String, defaultPluginIDs: [String]) -> Bool {
        !normalizedPreferences(defaultPluginIDs: defaultPluginIDs).hiddenPluginIDs.contains(pluginID)
    }

    func setVisibility(
        _ isVisible: Bool,
        for pluginID: String,
        defaultPluginIDs: [String]
    ) {
        var preferences = normalizedPreferences(defaultPluginIDs: defaultPluginIDs)

        if isVisible {
            preferences.hiddenPluginIDs.remove(pluginID)
        } else {
            preferences.hiddenPluginIDs.insert(pluginID)
        }

        persist(preferences)
    }

    func setOrderedPluginIDs(
        _ orderedPluginIDs: [String],
        defaultPluginIDs: [String]
    ) {
        var preferences = normalizedPreferences(defaultPluginIDs: defaultPluginIDs)
        preferences.orderedPluginIDs = normalizeOrder(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        persist(preferences)
    }

    private func normalizedPreferences(defaultPluginIDs: [String]) -> StoredPreferences {
        let stored = loadPreferences()
        let normalized = StoredPreferences(
            orderedPluginIDs: normalizeOrder(
                stored.orderedPluginIDs,
                defaultPluginIDs: defaultPluginIDs
            ),
            hiddenPluginIDs: Set(
                stored.hiddenPluginIDs.filter { defaultPluginIDs.contains($0) }
            )
        )

        if normalized != stored {
            persist(normalized)
        }

        return normalized
    }

    private func loadPreferences() -> StoredPreferences {
        guard let data = userDefaults.data(forKey: DefaultsKey.storage) else {
            return StoredPreferences()
        }

        do {
            return try decoder.decode(StoredPreferences.self, from: data)
        } catch {
            userDefaults.removeObject(forKey: DefaultsKey.storage)
            return StoredPreferences()
        }
    }

    private func persist(_ preferences: StoredPreferences) {
        guard let data = try? encoder.encode(preferences) else {
            return
        }

        userDefaults.set(data, forKey: DefaultsKey.storage)
    }

    private func normalizeOrder(
        _ orderedPluginIDs: [String],
        defaultPluginIDs: [String]
    ) -> [String] {
        let validPluginIDs = Set(defaultPluginIDs)
        var seenPluginIDs: Set<String> = []
        var result: [String] = []

        for pluginID in orderedPluginIDs where validPluginIDs.contains(pluginID) {
            guard seenPluginIDs.insert(pluginID).inserted else {
                continue
            }

            result.append(pluginID)
        }

        for pluginID in defaultPluginIDs where seenPluginIDs.insert(pluginID).inserted {
            result.append(pluginID)
        }

        return result
    }
}
