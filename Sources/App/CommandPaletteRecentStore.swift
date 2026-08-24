import Combine
import Foundation
import MacToolsPluginKit

@MainActor
protocol CommandPaletteRecentPersisting: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: CommandPaletteRecentPersisting {}

@MainActor
final class CommandPaletteRecentStore: ObservableObject {
    private struct Envelope: Codable {
        let formatVersion: Int
        let references: [ActionReference]
    }

    private enum DefaultsKey {
        static let references = "command-palette.recent-actions.v1"
        static let isEnabled = "command-palette.recent-actions.enabled"
    }

    static let currentFormatVersion = 1
    static let maximumReferenceCount = 30
    static let maximumPayloadByteCount = 64 * 1_024
    nonisolated static let maximumVisibleReferenceCount = 5

    @Published private(set) var references: [ActionReference]
    @Published private(set) var isEnabled: Bool
    private(set) var loadError: String?

    private let defaults: any CommandPaletteRecentPersisting

    convenience init(userDefaults: UserDefaults = .standard) {
        self.init(defaults: userDefaults)
    }

    init(defaults: any CommandPaletteRecentPersisting) {
        self.defaults = defaults
        let enabled = Self.loadEnabledState(defaults: defaults)
        isEnabled = enabled
        let loaded = Self.loadReferences(defaults: defaults)
        references = enabled ? loaded.references : []
        loadError = enabled ? loaded.error : nil
        if !enabled {
            defaults.removeObject(forKey: DefaultsKey.references)
        }
    }

    @discardableResult
    func recordSuccessful(_ reference: ActionReference) -> Bool {
        let persistedEnabled = Self.loadEnabledState(defaults: defaults)
        if isEnabled != persistedEnabled {
            isEnabled = persistedEnabled
        }
        guard persistedEnabled else {
            if !references.isEmpty {
                references.removeAll()
            }
            loadError = nil
            return false
        }
        guard reference.parameters.entries.isEmpty else {
            return false
        }

        let loaded = Self.loadReferences(defaults: defaults)
        guard loaded.error == nil else {
            references = []
            loadError = loaded.error
            return false
        }
        references = loaded.references
        loadError = nil

        var updated = loaded.references.filter { $0 != reference }
        updated.insert(reference, at: 0)
        if updated.count > Self.maximumReferenceCount {
            updated.removeLast(updated.count - Self.maximumReferenceCount)
        }
        return replaceReferences(updated)
    }

    @discardableResult
    func recordCompletion(
        of reference: ActionReference,
        outcome: ActionExecutionOutcome
    ) -> Bool {
        guard case .completed(.succeeded) = outcome else { return false }
        return recordSuccessful(reference)
    }

    /// Resolves persisted identities against the current action registry without making
    /// temporarily unavailable actions executable from stale data. Successful migrations are
    /// written back while unresolved identities remain available for a future provider reinstall.
    func resolvedReferences(
        using resolve: (ActionReference) -> ActionReference?
    ) -> [ActionReference] {
        let persistedEnabled = Self.loadEnabledState(defaults: defaults)
        if isEnabled != persistedEnabled {
            isEnabled = persistedEnabled
        }
        guard persistedEnabled else {
            if !references.isEmpty {
                references.removeAll()
            }
            loadError = nil
            return []
        }

        let loaded = Self.loadReferences(defaults: defaults)
        guard loaded.error == nil else {
            if !references.isEmpty {
                references = []
            }
            loadError = loaded.error
            return []
        }
        if references != loaded.references {
            references = loaded.references
        }
        loadError = nil

        var persistedReferences: [ActionReference] = []
        var resolvedReferences: [ActionReference] = []
        var persistedSet: Set<ActionReference> = []
        var resolvedSet: Set<ActionReference> = []

        for reference in loaded.references {
            guard let resolved = resolve(reference),
                  resolved.parameters.entries.isEmpty
            else {
                if persistedSet.insert(reference).inserted {
                    persistedReferences.append(reference)
                }
                continue
            }

            if persistedSet.insert(resolved).inserted {
                persistedReferences.append(resolved)
            }
            if resolvedSet.insert(resolved).inserted {
                resolvedReferences.append(resolved)
            }
        }

        if persistedReferences != loaded.references {
            _ = replaceReferences(persistedReferences)
        }
        return resolvedReferences
    }

    @discardableResult
    func clear() -> Bool {
        let previousValue = defaults.object(forKey: DefaultsKey.references)
        defaults.removeObject(forKey: DefaultsKey.references)
        guard defaults.object(forKey: DefaultsKey.references) == nil else {
            restore(previousValue, forKey: DefaultsKey.references)
            return false
        }
        references.removeAll()
        loadError = nil
        return true
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        let previousEnabledValue = defaults.object(forKey: DefaultsKey.isEnabled)
        let previousReferencesValue = defaults.object(forKey: DefaultsKey.references)

        defaults.set(enabled, forKey: DefaultsKey.isEnabled)
        if !enabled {
            defaults.removeObject(forKey: DefaultsKey.references)
        }

        let enabledWasPersisted = (defaults.object(forKey: DefaultsKey.isEnabled) as? Bool) == enabled
        let referencesWereCleared = enabled
            || defaults.object(forKey: DefaultsKey.references) == nil
        guard enabledWasPersisted, referencesWereCleared else {
            restore(previousEnabledValue, forKey: DefaultsKey.isEnabled)
            restore(previousReferencesValue, forKey: DefaultsKey.references)
            return false
        }

        isEnabled = enabled
        if enabled {
            let loaded = Self.loadReferences(defaults: defaults)
            references = loaded.references
            loadError = loaded.error
        } else {
            references.removeAll()
            loadError = nil
        }
        return true
    }

    private func replaceReferences(_ updated: [ActionReference]) -> Bool {
        guard updated.count <= Self.maximumReferenceCount,
              Set(updated).count == updated.count,
              updated.allSatisfy({ $0.parameters.entries.isEmpty })
        else {
            return false
        }
        if updated == references {
            return true
        }

        do {
            let data = try JSONEncoder().encode(
                Envelope(
                    formatVersion: Self.currentFormatVersion,
                    references: updated
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else { return false }
            let previousValue = defaults.object(forKey: DefaultsKey.references)
            defaults.set(data, forKey: DefaultsKey.references)
            guard defaults.data(forKey: DefaultsKey.references) == data else {
                restore(previousValue, forKey: DefaultsKey.references)
                return false
            }
            references = updated
            loadError = nil
            return true
        } catch {
            return false
        }
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func loadEnabledState(
        defaults: any CommandPaletteRecentPersisting
    ) -> Bool {
        guard defaults.object(forKey: DefaultsKey.isEnabled) != nil else {
            return true
        }
        return (defaults.object(forKey: DefaultsKey.isEnabled) as? Bool) ?? false
    }

    private static func loadReferences(
        defaults: any CommandPaletteRecentPersisting
    ) -> (references: [ActionReference], error: String?) {
        guard let storedValue = defaults.object(forKey: DefaultsKey.references) else {
            return ([], nil)
        }
        guard let data = storedValue as? Data else {
            return ([], "invalid-recent-actions-payload")
        }
        guard data.count <= maximumPayloadByteCount else {
            return ([], "recent-actions-payload-too-large")
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.formatVersion == currentFormatVersion,
                  envelope.references.count <= maximumReferenceCount,
                  Set(envelope.references).count == envelope.references.count,
                  envelope.references.allSatisfy({ $0.parameters.entries.isEmpty })
            else {
                return ([], "unsupported-recent-actions-payload")
            }
            return (envelope.references, nil)
        } catch {
            return ([], "invalid-recent-actions-payload")
        }
    }
}
