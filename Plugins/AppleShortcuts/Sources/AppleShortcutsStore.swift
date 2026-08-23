import Combine
import Foundation
import MacToolsPluginKit

struct AppleShortcutsSettingsState: Codable, Equatable, Sendable {
    var policies: [UUID: AppleShortcutPolicy] = [:]
}

@MainActor
final class AppleShortcutsStore: ObservableObject {
    private struct Envelope: Codable {
        let formatVersion: Int
        let state: AppleShortcutsSettingsState
    }

    private struct PortableEnvelope: Codable {
        let formatVersion: Int
        let policies: [UUID: AppleShortcutPolicy]
    }

    private struct LegacyEnvelope: Decodable {
        struct State: Decodable {
            let policies: [UUID: AppleShortcutPolicy]
        }

        let formatVersion: Int
        let state: State
    }

    static let currentFormatVersion = 2
    static let storageKey = "settings.v2"
    static let legacyStorageKey = "settings.v1"
    static let maximumPayloadByteCount = 1 * 1_024 * 1_024

    @Published private(set) var state = AppleShortcutsSettingsState()
    @Published private(set) var loadError: String?
    private(set) var didPersistPortablePreferencesDuringInitialization = false

    var onMutation: (() -> Void)?
    var onSafetyPolicyMutation: (() -> Void)?

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        didPersistPortablePreferencesDuringInitialization = reload()
    }

    func policy(for id: UUID) -> AppleShortcutPolicy { state.policies[id] ?? .default }

    func setRequiresConfirmation(
        _ value: Bool,
        for id: UUID
    ) -> Result<Void, AppleShortcutsStoreError> {
        updatePolicy(id: id) { $0.requiresConfirmation = value }
    }

    func portableBackup() -> Data? {
        guard loadError == nil,
              let data = try? encoder.encode(PortableEnvelope(
                  formatVersion: Self.currentFormatVersion,
                  policies: state.policies
              )),
              data.count <= Self.maximumPayloadByteCount else {
            return nil
        }
        return data
    }

    func actionIDs(inPortableBackup data: Data) -> [String]? {
        guard let portable = decodePortable(data) else { return nil }
        return portable.policies.keys.map(Self.actionID(for:)).sorted()
    }

    @discardableResult
    func restorePortableBackup(_ data: Data) -> Bool {
        guard let portable = decodePortable(data) else { return false }
        let restored = AppleShortcutsSettingsState(policies: portable.policies)
        guard restored != state || loadError != nil else { return true }
        do {
            try persist(restored)
            state = restored
            loadError = nil
            onMutation?()
            return true
        } catch {
            return false
        }
    }

    static func shortcutID(fromActionID actionID: String) -> UUID? {
        guard actionID.hasPrefix("run.") else { return nil }
        guard let id = UUID(uuidString: String(actionID.dropFirst(4))),
              actionID == Self.actionID(for: id) else { return nil }
        return id
    }

    static func actionID(for id: UUID) -> String {
        "run.\(id.uuidString.lowercased())"
    }

    private func updatePolicy(
        id: UUID,
        change: (inout AppleShortcutPolicy) -> Void
    ) -> Result<Void, AppleShortcutsStoreError> {
        let previousPolicy = policy(for: id)
        let result = mutate { updated in
            var policy = updated.policies[id] ?? .default
            change(&policy)
            updated.policies[id] = policy == .default ? nil : policy
        }
        if case .success = result, policy(for: id) != previousPolicy {
            onSafetyPolicyMutation?()
        }
        return result
    }

    private func mutate(
        _ change: (inout AppleShortcutsSettingsState) -> Void
    ) -> Result<Void, AppleShortcutsStoreError> {
        guard loadError == nil else { return .failure(.recoveryRequired) }
        var updated = state
        change(&updated)
        guard updated != state else { return .success(()) }
        do {
            try persist(updated)
            state = updated
            onMutation?()
            return .success(())
        } catch let error as AppleShortcutsStoreError {
            return .failure(error)
        } catch {
            return .failure(.invalidData)
        }
    }

    @discardableResult
    private func reload() -> Bool {
        if let rawValue = storage.object(forKey: Self.storageKey) {
            guard let data = rawValue as? Data,
                  data.count <= Self.maximumPayloadByteCount,
                  let envelope = try? decoder.decode(Envelope.self, from: data),
                  envelope.formatVersion == Self.currentFormatVersion else {
                loadError = "invalid-apple-shortcuts-settings"
                return false
            }
            state = envelope.state
            loadError = nil
            return false
        }

        guard let rawValue = storage.object(forKey: Self.legacyStorageKey) else {
            loadError = nil
            return false
        }
        guard let data = rawValue as? Data,
              data.count <= Self.maximumPayloadByteCount,
              let legacy = try? decoder.decode(LegacyEnvelope.self, from: data),
              legacy.formatVersion == 1 else {
            loadError = "invalid-apple-shortcuts-settings"
            return false
        }
        let migrated = AppleShortcutsSettingsState(policies: legacy.state.policies)
        do {
            try persist(migrated)
            state = migrated
            loadError = nil
            return true
        } catch {
            loadError = "invalid-apple-shortcuts-settings"
            return false
        }
    }

    private func persist(_ state: AppleShortcutsSettingsState) throws {
        let data = try encoder.encode(Envelope(
            formatVersion: Self.currentFormatVersion,
            state: state
        ))
        guard data.count <= Self.maximumPayloadByteCount else {
            throw AppleShortcutsStoreError.payloadTooLarge
        }
        let previous = storage.object(forKey: Self.storageKey)
        storage.set(data, forKey: Self.storageKey)
        guard storage.data(forKey: Self.storageKey) == data else {
            if let previous {
                storage.set(previous, forKey: Self.storageKey)
            } else {
                storage.removeObject(forKey: Self.storageKey)
            }
            throw AppleShortcutsStoreError.persistenceFailed
        }
    }

    private func decodePortable(_ data: Data) -> PortableEnvelope? {
        guard data.count <= Self.maximumPayloadByteCount,
              let portable = try? decoder.decode(PortableEnvelope.self, from: data),
              portable.formatVersion == Self.currentFormatVersion else {
            return nil
        }
        return portable
    }
}
