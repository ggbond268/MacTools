import MacToolsPluginKit
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsStoreTests: XCTestCase {
    func testOnlyNonDefaultSafetyPoliciesArePersisted() throws {
        let storage = AppleShortcutsTestStorage()
        let store = AppleShortcutsStore(storage: storage)
        let id = UUID()

        try store.setRequiresConfirmation(false, for: id).get()
        XCTAssertEqual(store.policy(for: id).requiresConfirmation, false)
        XCTAssertEqual(store.state.policies.count, 1)

        try store.setRequiresConfirmation(true, for: id).get()
        XCTAssertEqual(store.policy(for: id), .default)
        XCTAssertTrue(store.state.policies.isEmpty)
    }

    func testPolicyMutationNotifiesSafetyRegistryOnlyForActualChanges() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let id = UUID()
        var mutationCount = 0
        store.onSafetyPolicyMutation = { mutationCount += 1 }

        try store.setRequiresConfirmation(false, for: id).get()
        try store.setRequiresConfirmation(false, for: id).get()

        XCTAssertEqual(mutationCount, 1)
    }

    func testPortableBackupContainsOnlyConfiguredPolicies() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let id = UUID()
        try store.setRequiresConfirmation(false, for: id).get()
        let backup = try XCTUnwrap(store.portableBackup())

        XCTAssertEqual(store.actionIDs(inPortableBackup: backup), [AppleShortcutsStore.actionID(for: id)])

        let restored = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertFalse(restored.policy(for: id).requiresConfirmation)
    }

    func testIdenticalPortableRestoreDoesNotReportMutation() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let id = UUID()
        try store.setRequiresConfirmation(false, for: id).get()
        let backup = try XCTUnwrap(store.portableBackup())
        var mutationCount = 0
        store.onMutation = { mutationCount += 1 }

        XCTAssertTrue(store.restorePortableBackup(backup))

        XCTAssertEqual(mutationCount, 0)
    }

    func testLegacyEnablementSettingsMigrateOnlySafetyPolicies() throws {
        let id = UUID()
        let legacyPayload = try JSONEncoder().encode(LegacyEnvelope(
            formatVersion: 1,
            state: .init(
                explicitlyEnabledIDs: [id],
                syncedFolders: [:],
                excludedIDs: [],
                policies: [id: AppleShortcutPolicy(requiresConfirmation: false)],
                trackedRecords: [:]
            )
        ))
        let storage = AppleShortcutsTestStorage()
        storage.set(legacyPayload, forKey: AppleShortcutsStore.legacyStorageKey)

        let store = AppleShortcutsStore(storage: storage)

        XCTAssertEqual(store.policy(for: id), AppleShortcutPolicy(requiresConfirmation: false))
        XCTAssertNotNil(storage.data(forKey: AppleShortcutsStore.storageKey))
        XCTAssertTrue(store.didPersistPortablePreferencesDuringInitialization)
    }
}

private struct LegacyEnvelope: Codable {
    struct State: Codable {
        let explicitlyEnabledIDs: Set<UUID>
        let syncedFolders: [UUID: LegacyFolder]
        let excludedIDs: Set<UUID>
        let policies: [UUID: AppleShortcutPolicy]
        let trackedRecords: [UUID: LegacyRecord]
    }

    struct LegacyFolder: Codable {
        let id: UUID
        let lastKnownName: String
        let memberIDs: Set<UUID>
    }

    struct LegacyRecord: Codable {
        let id: UUID
        let lastKnownName: String
        let lastKnownFolderIDs: Set<UUID>
    }

    let formatVersion: Int
    let state: State
}
