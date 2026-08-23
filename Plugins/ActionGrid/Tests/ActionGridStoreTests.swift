import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridStoreTests: XCTestCase {
    func testKeyboardMoveCommandsRespectGridBoundaries() {
        let first = ActionGridEntryMoveAvailability(
            slot: 0,
            maximumEntryCount: ActionGridStore.maximumEntryCount
        )
        XCTAssertFalse(first.canMoveUp)
        XCTAssertTrue(first.canMoveDown)
        XCTAssertEqual(
            ActionGridAccessibilityMoveActions(availability: first).actions,
            [.down]
        )

        let middle = ActionGridEntryMoveAvailability(
            slot: 4,
            maximumEntryCount: ActionGridStore.maximumEntryCount
        )
        XCTAssertTrue(middle.canMoveUp)
        XCTAssertTrue(middle.canMoveDown)
        XCTAssertEqual(
            ActionGridAccessibilityMoveActions(availability: middle).actions,
            [.up, .down]
        )

        let last = ActionGridEntryMoveAvailability(
            slot: ActionGridStore.maximumEntryCount - 1,
            maximumEntryCount: ActionGridStore.maximumEntryCount
        )
        XCTAssertTrue(last.canMoveUp)
        XCTAssertFalse(last.canMoveDown)
        XCTAssertEqual(
            ActionGridAccessibilityMoveActions(availability: last).actions,
            [.up]
        )
    }

    func testDragPayloadRoundTripsOnlyNamespacedEntryIdentifiers() {
        let entryID = UUID()

        XCTAssertEqual(
            ActionGridDragPayload.decode(ActionGridDragPayload.encode(entryID)),
            entryID
        )
        XCTAssertNil(ActionGridDragPayload.decode(entryID.uuidString))
        XCTAssertNil(ActionGridDragPayload.decode("mactools-action-grid:not-a-uuid"))
        XCTAssertNil(ActionGridDragPayload.decode(nil))
    }

    func testAddReplaceClearAndReorderAreBoundedAndPersistent() {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let references = (0 ..< 10).map {
            ActionReference(key: ActionKey(providerID: "provider", actionID: "action-\($0)"))
        }

        for reference in references.prefix(9) {
            XCTAssertTrue(store.add(reference: reference))
        }
        XCTAssertFalse(store.add(reference: references[9]))
        XCTAssertFalse(store.add(reference: references[0]))

        let firstID = store.entries[0].id
        XCTAssertTrue(store.move(fromOffsets: [0], toOffset: 9))
        XCTAssertEqual(store.entries.last?.id, firstID)
        XCTAssertTrue(store.replace(id: firstID, reference: references[9]))
        XCTAssertTrue(store.remove(id: store.entries[0].id))

        let reloaded = ActionGridStore(storage: storage)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(reloaded.entries.count, 8)
    }

    func testAddAndReplaceValidateTitleBeforePersistingEitherField() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let original = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "original")
        )
        let replacement = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "replacement")
        )
        XCTAssertTrue(store.add(
            reference: original,
            customTitle: "Original title",
            in: nil,
            at: 4
        ))
        let entryID = try XCTUnwrap(store.entry(at: 4, in: nil)?.id)
        let oversizedTitle = String(
            repeating: "x",
            count: ActionGridEntry.maximumCustomTitleByteCount + 1
        )

        XCTAssertFalse(store.replace(
            id: entryID,
            reference: replacement,
            customTitle: oversizedTitle
        ))
        XCTAssertEqual(store.entry(at: 4, in: nil)?.reference, original)
        XCTAssertEqual(store.entry(at: 4, in: nil)?.customTitle, "Original title")
        XCTAssertFalse(store.add(
            reference: replacement,
            customTitle: oversizedTitle,
            in: nil,
            at: 5
        ))
        XCTAssertNil(store.entry(at: 5, in: nil))
        XCTAssertEqual(ActionGridStore(storage: storage).entries, store.entries)
    }

    func testMissingActionsRemainStoredAndMigrateWhenProviderReturns() {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let old = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "versioned"),
            schemaVersion: 1
        )
        XCTAssertTrue(store.add(reference: old))
        var providerIsAvailable = false
        let context = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { reference in
                providerIsAvailable
                    ? ActionReference(key: reference.key, schemaVersion: 2, parameters: reference.parameters)
                    : nil
            },
            canPresent: { true },
            present: { _, _ in true }
        )

        XCTAssertFalse(store.migrate(using: context))
        XCTAssertEqual(store.entries.first?.reference, old)
        providerIsAvailable = true
        XCTAssertTrue(store.migrate(using: context))
        XCTAssertEqual(store.entries.first?.reference.schemaVersion, 2)
    }

    func testMigratedAliasesPreserveBothCellsAndTheirMetadata() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let key = ActionKey(providerID: "provider", actionID: "versioned")
        let legacy = ActionReference(key: key, schemaVersion: 1)
        let current = ActionReference(key: key, schemaVersion: 2)
        XCTAssertTrue(store.add(reference: legacy, in: nil, at: 1))
        XCTAssertTrue(store.add(reference: current, in: nil, at: 7))
        let legacyID = try XCTUnwrap(store.entry(at: 1, in: nil)?.id)
        let currentID = try XCTUnwrap(store.entry(at: 7, in: nil)?.id)
        XCTAssertTrue(store.setCustomTitle(id: legacyID, title: "Legacy alias"))
        let context = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { reference in
                ActionReference(
                    key: reference.key,
                    schemaVersion: 2,
                    parameters: reference.parameters
                )
            },
            canPresent: { true },
            present: { _, _ in true }
        )

        XCTAssertTrue(store.migrate(using: context))
        XCTAssertEqual(store.entries.map(\.id), [legacyID, currentID])
        XCTAssertEqual(store.entries.map(\.slot), [1, 7])
        XCTAssertEqual(store.entries.map(\.reference), [current, current])
        XCTAssertEqual(store.entries.first?.customTitle, "Legacy alias")
        XCTAssertEqual(ActionGridStore(storage: storage).entries, store.entries)
    }

    func testCorruptPayloadFailsClosedWithoutDeletingBytesAndPortableBackupRoundTrips() throws {
        let storage = ActionGridTestStorage()
        let corrupt = Data("not-json".utf8)
        storage.values["layout.v1"] = corrupt
        let failed = ActionGridStore(storage: storage)

        XCTAssertTrue(failed.entries.isEmpty)
        XCTAssertEqual(failed.loadError, "invalid-grid-layout")
        XCTAssertFalse(failed.add(reference: ActionReference(
            key: ActionKey(providerID: "provider", actionID: "must-not-overwrite")
        )))
        XCTAssertEqual(storage.data(forKey: "layout.v1"), corrupt)

        let sourceStorage = ActionGridTestStorage()
        let source = ActionGridStore(storage: sourceStorage)
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        XCTAssertTrue(source.add(reference: reference))
        let backup = try XCTUnwrap(source.portableBackup())
        let destination = ActionGridStore(storage: ActionGridTestStorage())
        XCTAssertTrue(destination.restorePortableBackup(backup))
        XCTAssertEqual(destination.entries.map(\.reference), [reference])
        XCTAssertNotEqual(destination.entries.first?.id, nil)
    }

    func testCorruptingWriteRestoresPreviousLayoutBytes() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let original = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "original")
        )
        XCTAssertTrue(store.add(reference: original))
        let originalEntries = store.entries
        let storedData = try XCTUnwrap(storage.data(forKey: "layout.v1"))
        storage.enqueueWriteBehaviors([.corrupt, .accept], forKey: "layout.v1")

        XCTAssertFalse(store.add(reference: ActionReference(
            key: ActionKey(providerID: "provider", actionID: "rejected")
        )))

        XCTAssertEqual(store.entries, originalEntries)
        XCTAssertEqual(storage.data(forKey: "layout.v1"), storedData)
        XCTAssertEqual(ActionGridStore(storage: storage).entries, originalEntries)
    }

    func testFailedWriteRollbackReloadsRecoveryRequiredLayoutState() {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        XCTAssertTrue(store.add(reference: ActionReference(
            key: ActionKey(providerID: "provider", actionID: "original")
        )))
        storage.enqueueWriteBehaviors([.corrupt, .ignore], forKey: "layout.v1")

        XCTAssertFalse(store.add(reference: ActionReference(
            key: ActionKey(providerID: "provider", actionID: "rejected")
        )))

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.loadError, "invalid-grid-layout")
        XCTAssertEqual(storage.object(forKey: "layout.v1") as? String, "corrupt")
    }

    func testWrongTypedLayoutIsRecoveryRequiredAndNotOverwritten() {
        let storage = ActionGridTestStorage()
        storage.values["layout.v1"] = "invalid"
        let store = ActionGridStore(storage: storage)

        XCTAssertEqual(store.loadError, "invalid-grid-layout")
        XCTAssertFalse(store.add(reference: ActionReference(
            key: ActionKey(providerID: "provider", actionID: "must-not-overwrite")
        )))
        XCTAssertEqual(storage.object(forKey: "layout.v1") as? String, "invalid")
    }

    func testNestedFoldersPersistReorderAndRespectDepthLimit() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        XCTAssertTrue(store.addFolder(title: "System", in: nil))
        let systemID = try XCTUnwrap(store.entries.first?.id)
        XCTAssertTrue(store.addFolder(title: "Display", in: systemID))
        let displayID = try XCTUnwrap(store.entries(in: systemID).first?.id)
        XCTAssertTrue(store.addFolder(title: "Power", in: displayID))
        let powerID = try XCTUnwrap(store.entries(in: displayID).first?.id)

        let sleep = ActionReference(
            key: ActionKey(providerID: "display-sleep", actionID: "sleep")
        )
        let lock = ActionReference(
            key: ActionKey(providerID: "lock-screen", actionID: "lock")
        )
        XCTAssertTrue(store.add(reference: sleep, in: powerID))
        XCTAssertTrue(store.add(reference: lock, in: powerID))
        XCTAssertTrue(store.move(entryID: lockID(in: store, folderID: powerID), toIndex: 0, in: powerID))
        XCTAssertEqual(store.entries(in: powerID).map(\.reference), [lock, sleep])

        XCTAssertFalse(store.addFolder(title: "Too Deep", in: powerID))
        let reloaded = ActionGridStore(storage: storage)
        XCTAssertEqual(reloaded.entries(in: powerID).map(\.reference), [lock, sleep])

        let backup = try XCTUnwrap(reloaded.portableBackup())
        XCTAssertEqual(
            reloaded.actionReferences(inPortableBackup: backup),
            [lock, sleep]
        )
        let restored = ActionGridStore(storage: ActionGridTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertEqual(restored.entries, reloaded.entries)
    }

    func testPortableBackupRemovesNestedLocalActionsAndRestoreRejectsThem() throws {
        let store = ActionGridStore(storage: ActionGridTestStorage())
        XCTAssertTrue(store.addFolder(title: "Folder", in: nil))
        let folderID = try XCTUnwrap(store.entries.first?.id)
        let portable = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "portable")
        )
        let local = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "local")
        )
        XCTAssertTrue(store.add(reference: portable, in: folderID, at: 0))
        XCTAssertTrue(store.add(reference: local, in: folderID, at: 1))
        let context = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            canExport: { $0 != local },
            canRestore: { $0 != local },
            canPresent: { true },
            present: { _, _ in true }
        )

        let filteredBackup = try XCTUnwrap(store.portableBackup(using: context))
        let restored = ActionGridStore(storage: ActionGridTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(filteredBackup, using: context))
        XCTAssertEqual(restored.entries(in: restored.entries.first?.id).map(\.reference), [portable])

        let unfilteredBackup = try XCTUnwrap(store.portableBackup())
        XCTAssertFalse(restored.restorePortableBackup(unfilteredBackup, using: context))
    }

    func testRequestedSlotsPreserveEmptyCellsAcrossReloadAndMove() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let first = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "first")
        )
        let last = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "last")
        )

        XCTAssertTrue(store.add(reference: first, in: nil, at: 0))
        XCTAssertTrue(store.add(reference: last, in: nil, at: 8))
        XCTAssertEqual(store.entries.map(\.slot), [0, 8])
        XCTAssertNil(store.entry(at: 4, in: nil))
        XCTAssertEqual(store.entry(at: 8, in: nil)?.reference, last)
        XCTAssertEqual(store.firstAvailableSlot(in: nil), 1)

        let lastID = try XCTUnwrap(store.entry(at: 8, in: nil)?.id)
        XCTAssertTrue(store.move(entryID: lastID, toIndex: 4, in: nil))
        XCTAssertEqual(store.entries.map(\.slot), [0, 4])

        let reloaded = ActionGridStore(storage: storage)
        XCTAssertEqual(reloaded.entries.map(\.slot), [0, 4])
        XCTAssertEqual(reloaded.entry(at: 4, in: nil)?.reference, last)
    }

    func testFolderCanBeCreatedInRequestedSlot() throws {
        let store = ActionGridStore(storage: ActionGridTestStorage())

        XCTAssertTrue(store.addFolder(title: "System", in: nil, at: 6))
        let folder = try XCTUnwrap(store.entry(at: 6, in: nil))
        XCTAssertEqual(folder.customTitle, "System")
        XCTAssertNotNil(folder.folder)
        XCTAssertNil(store.entry(at: 0, in: nil))
    }

    func testVersionTwoOrderedLayoutMigratesToExplicitSlots() throws {
        struct LegacyEntry: Encodable {
            let id: UUID
            let reference: ActionReference
            let customTitle: String?
            let folder: LegacyFolder?
        }
        struct LegacyFolder: Encodable {
            let systemImage: String
            let entries: [LegacyEntry]
        }
        struct LegacyEnvelope: Encodable {
            let formatVersion: Int
            let entries: [LegacyEntry]
        }

        let storage = ActionGridTestStorage()
        let references = (0 ..< 3).map {
            ActionReference(key: ActionKey(providerID: "provider", actionID: "legacy-\($0)"))
        }
        storage.values["layout.v1"] = try JSONEncoder().encode(
            LegacyEnvelope(
                formatVersion: 2,
                entries: references.map {
                    LegacyEntry(id: UUID(), reference: $0, customTitle: nil, folder: nil)
                }
            )
        )

        let plugin = ActionGridPlugin(context: PluginRuntimeContext(
            pluginID: "action-grid",
            storage: storage
        ))
        let store = plugin.store
        var persistenceNotifications = 0
        plugin.onPersistentPreferencesChange = { persistenceNotifications += 1 }

        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.entries.map(\.slot), [0, 1, 2])
        XCTAssertEqual(store.entries.map(\.reference), references)
        XCTAssertTrue(store.didPersistPortablePreferencesDuringInitialization)
        XCTAssertEqual(persistenceNotifications, 1)
    }

    func testIdenticalPortableRestoreDoesNotEmitPersistentPreferenceSignal() throws {
        let plugin = ActionGridPlugin(context: PluginRuntimeContext(
            pluginID: "action-grid",
            storage: ActionGridTestStorage()
        ))
        let backup = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        var persistenceNotifications = 0
        plugin.onPersistentPreferencesChange = { persistenceNotifications += 1 }
        persistenceNotifications = 0

        XCTAssertTrue(plugin.restorePortablePreferencesReportingResult(from: backup))

        XCTAssertEqual(persistenceNotifications, 0)
    }

    private func lockID(in store: ActionGridStore, folderID: UUID) -> UUID {
        store.entries(in: folderID)[1].id
    }
}
