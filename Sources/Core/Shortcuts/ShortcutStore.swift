import Foundation
import MacToolsPluginKit

@MainActor
final class ShortcutStore {
    private enum DefaultsKey {
        static let prefix = "shortcut.customization."
    }

    let userDefaults: UserDefaults
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.userDefaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    func customization(for shortcutID: String) -> ShortcutCustomization {
        let key = storageKey(for: shortcutID)

        guard let data = userDefaults.data(forKey: key) else {
            return .inheritDefault
        }

        do {
            return try decoder.decode(ShortcutCustomization.self, from: data)
        } catch {
            userDefaults.removeObject(forKey: key)
            return .inheritDefault
        }
    }

    func setCustomization(_ customization: ShortcutCustomization, for shortcutID: String) {
        let key = storageKey(for: shortcutID)
        guard self.customization(for: shortcutID) != customization else { return }

        switch customization {
        case .inheritDefault:
            userDefaults.removeObject(forKey: key)
        case .custom, .cleared:
            guard let data = try? encoder.encode(customization) else {
                return
            }

            userDefaults.set(data, forKey: key)
        }
        guard self.customization(for: shortcutID) == customization else { return }
        preferencesBackupChangeReporter?.didPersist(.shortcuts)
    }

    func customizations(for shortcutIDs: [String]) -> [String: ShortcutCustomization] {
        shortcutIDs.reduce(into: [:]) { result, shortcutID in
            let customization = customization(for: shortcutID)
            guard customization != .inheritDefault else {
                return
            }

            result[shortcutID] = customization
        }
    }

    func removeCustomizations(forPluginID pluginID: String) {
        let prefix = DefaultsKey.prefix + pluginID + ".shortcut."
        let matchingKeys = userDefaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(prefix)
        }
        guard !matchingKeys.isEmpty else { return }
        for key in matchingKeys {
            userDefaults.removeObject(forKey: key)
        }
        guard matchingKeys.allSatisfy({ userDefaults.object(forKey: $0) == nil }) else { return }
        preferencesBackupChangeReporter?.didPersist(.shortcuts)
    }

    func resolvedBinding(for shortcutID: String, default defaultBinding: ShortcutBinding?) -> ShortcutBinding? {
        ShortcutStore.resolve(
            customization: customization(for: shortcutID),
            defaultBinding: defaultBinding
        )
    }

    static func resolve(customization: ShortcutCustomization, defaultBinding: ShortcutBinding?) -> ShortcutBinding? {
        switch customization {
        case .inheritDefault:
            return defaultBinding
        case let .custom(binding):
            return binding
        case .cleared:
            return nil
        }
    }

    private func storageKey(for shortcutID: String) -> String {
        DefaultsKey.prefix + shortcutID
    }
}
