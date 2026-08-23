import Foundation
import MacToolsPluginKit

@MainActor
protocol ActionInvocationPresetPersisting: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: ActionInvocationPresetPersisting {}

struct ActionInvocationPreset: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    let reference: ActionReference
    let createdAt: Date

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        createdAt: Date = .now,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.reference = reference
        self.createdAt = createdAt
    }
}

enum ActionInvocationPresetError: Error, Equatable {
    case unknownAction
    case parameterlessAction
    case externalInvocationUnavailable
    case sensitiveParametersUnsupported
    case maximumPresetCountReached
    case persistenceFailed
    case unavailablePreset
}

@MainActor
final class ActionInvocationPresetStore {
    private struct Envelope: Codable {
        let formatVersion: Int
        let presets: [ActionInvocationPreset]
    }

    private enum DefaultsKey {
        static let presets = "actions.run-link-presets.v1"
    }

    static let maximumPresetCount = 256
    static let maximumPayloadByteCount = 512 * 1_024

    private let defaults: any ActionInvocationPresetPersisting
    var preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private(set) var loadError: String?

    init(
        userDefaults: UserDefaults = .standard,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.defaults = userDefaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    init(
        defaults: any ActionInvocationPresetPersisting,
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.defaults = defaults
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
    }

    func presets() -> [ActionInvocationPreset] {
        guard let storedValue = defaults.object(forKey: DefaultsKey.presets) else {
            loadError = nil
            return []
        }
        guard let data = storedValue as? Data else {
            loadError = "invalid-preset-payload"
            return []
        }
        guard data.count <= Self.maximumPayloadByteCount else {
            loadError = "preset-payload-too-large"
            return []
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.formatVersion == ActionInvocationPreset.currentFormatVersion,
                  envelope.presets.count <= Self.maximumPresetCount,
                  Set(envelope.presets.map(\.id)).count == envelope.presets.count,
                  envelope.presets.allSatisfy({
                      $0.formatVersion == ActionInvocationPreset.currentFormatVersion
                  }) else {
                loadError = "unsupported-preset-format"
                return []
            }
            loadError = nil
            return envelope.presets
        } catch {
            loadError = "invalid-preset-payload"
            return []
        }
    }

    func preset(id: UUID) -> ActionInvocationPreset? {
        presets().first { $0.id == id }
    }

    func preset(reference: ActionReference) -> ActionInvocationPreset? {
        presets()
            .filter { $0.reference == reference }
            .min { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func create(
        reference: ActionReference,
        registry: ActionRegistry
    ) -> Result<ActionInvocationPreset, ActionInvocationPresetError> {
        let registered: RegisteredAction
        switch registry.registeredAction(for: reference) {
        case let .success(action):
            registered = action
        case .failure:
            return .failure(.unknownAction)
        }
        guard registered.catalogEntry != nil else {
            return .failure(.unknownAction)
        }
        guard !registered.definition.parameters.isEmpty else {
            return .failure(.parameterlessAction)
        }
        guard registered.definition.externalInvocationPolicy != .unavailable else {
            return .failure(.externalInvocationUnavailable)
        }
        let definitionsByID = Dictionary(
            uniqueKeysWithValues: registered.definition.parameters.map { ($0.id, $0) }
        )
        guard reference.parameters.entries.allSatisfy({ entry in
            definitionsByID[entry.name]?.privacy != .sensitive
        }) else {
            return .failure(.sensitiveParametersUnsupported)
        }

        var stored = presets()
        guard loadError == nil else {
            return .failure(.persistenceFailed)
        }
        if let existing = stored
            .filter({ $0.reference == reference })
            .min(by: { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }) {
            return .success(existing)
        }
        guard stored.count < Self.maximumPresetCount else {
            return .failure(.maximumPresetCountReached)
        }
        let preset = ActionInvocationPreset(reference: reference)
        stored.append(preset)
        guard replaceAll(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(preset)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var stored = presets()
        guard loadError == nil else { return false }
        let originalCount = stored.count
        stored.removeAll { $0.id == id }
        guard stored.count != originalCount else {
            return false
        }
        return replaceAll(stored)
    }

    @discardableResult
    func delete(reference: ActionReference) -> Bool {
        var stored = presets()
        guard loadError == nil else { return false }
        let originalCount = stored.count
        stored.removeAll { $0.reference == reference }
        guard stored.count != originalCount else {
            return false
        }
        return replaceAll(stored)
    }

    @discardableResult
    func updateReference(id: UUID, reference: ActionReference) -> Bool {
        var stored = presets()
        guard loadError == nil else { return false }
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if stored[index].reference == reference {
            return true
        }
        stored[index] = ActionInvocationPreset(
            id: stored[index].id,
            reference: reference,
            createdAt: stored[index].createdAt,
            formatVersion: stored[index].formatVersion
        )
        return replaceAll(stored)
    }

    @discardableResult
    func replaceAll(_ presets: [ActionInvocationPreset]) -> Bool {
        _ = self.presets()
        guard loadError == nil else { return false }
        return replaceAll(presets, allowsRecovery: false)
    }

    @discardableResult
    func replaceAllForRecovery(_ presets: [ActionInvocationPreset]) -> Bool {
        replaceAll(presets, allowsRecovery: true)
    }

    private func replaceAll(
        _ presets: [ActionInvocationPreset],
        allowsRecovery: Bool
    ) -> Bool {
        let previousPresets = self.presets()
        let previousPayloadWasValid = loadError == nil
        guard allowsRecovery || previousPayloadWasValid else { return false }
        guard presets.count <= Self.maximumPresetCount,
              Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({
                  $0.formatVersion == ActionInvocationPreset.currentFormatVersion
              }) else {
            return false
        }
        if previousPayloadWasValid, previousPresets == presets {
            return true
        }
        do {
            let data = try JSONEncoder().encode(
                Envelope(
                    formatVersion: ActionInvocationPreset.currentFormatVersion,
                    presets: presets
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return false
            }
            let previousValue = defaults.object(forKey: DefaultsKey.presets)
            defaults.set(data, forKey: DefaultsKey.presets)
            guard defaults.data(forKey: DefaultsKey.presets) == data else {
                _ = restore(previousValue, forKey: DefaultsKey.presets)
                _ = self.presets()
                return false
            }
            loadError = nil
            preferencesBackupChangeReporter?.didPersist(.actionInvocationPresets)
            return true
        } catch {
            return false
        }
    }

    private func restore(_ value: Any?, forKey key: String) -> Bool {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        return valuesMatch(defaults.object(forKey: key), value)
    }

    private func valuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs as NSObject, rhs as NSObject):
            lhs.isEqual(rhs)
        default:
            false
        }
    }
}
