import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class CommandPaletteRecentStoreTests: XCTestCase {
    func testRecordsOnlyParameterFreeReferencesInMostRecentOrder() throws {
        let persistence = CommandPaletteRecentTestPersistence()
        let store = CommandPaletteRecentStore(defaults: persistence)
        let first = reference(actionID: "first")
        let second = reference(actionID: "second")
        let parameterized = ActionReference(
            key: ActionKey(providerID: "plugin", actionID: "private"),
            parameters: try ActionParameterSet(entries: [
                .init(name: "value", value: .string("secret-value"))
            ])
        )

        XCTAssertTrue(store.recordSuccessful(first))
        XCTAssertTrue(store.recordSuccessful(second))
        XCTAssertTrue(store.recordSuccessful(first))
        XCTAssertFalse(store.recordSuccessful(parameterized))

        XCTAssertEqual(store.references, [first, second])
        XCTAssertEqual(
            CommandPaletteRecentStore(defaults: persistence).references,
            [first, second]
        )
        let payload = try XCTUnwrap(persistence.data(
            forKey: "command-palette.recent-actions.v1"
        ))
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("secret-value"))
    }

    func testHistoryIsBoundedAndDeduplicated() {
        let store = CommandPaletteRecentStore(defaults: CommandPaletteRecentTestPersistence())

        for index in 0 ... CommandPaletteRecentStore.maximumReferenceCount {
            XCTAssertTrue(store.recordSuccessful(reference(actionID: "action-\(index)")))
        }

        XCTAssertEqual(store.references.count, CommandPaletteRecentStore.maximumReferenceCount)
        XCTAssertEqual(store.references.first, reference(actionID: "action-30"))
        XCTAssertFalse(store.references.contains(reference(actionID: "action-0")))
    }

    func testDisablingClearsHistoryAndStopsRecordingUntilReenabled() {
        let persistence = CommandPaletteRecentTestPersistence()
        let store = CommandPaletteRecentStore(defaults: persistence)
        let action = reference(actionID: "action")
        XCTAssertTrue(store.recordSuccessful(action))

        XCTAssertTrue(store.setEnabled(false))

        XCTAssertFalse(store.isEnabled)
        XCTAssertTrue(store.references.isEmpty)
        XCTAssertNil(persistence.object(forKey: "command-palette.recent-actions.v1"))
        XCTAssertFalse(store.recordSuccessful(action))

        XCTAssertTrue(store.setEnabled(true))
        XCTAssertTrue(store.recordSuccessful(action))
        XCTAssertEqual(store.references, [action])
    }

    func testLateCompletionMergesWithHistoryWrittenByANewerStore() {
        let persistence = CommandPaletteRecentTestPersistence()
        let olderStore = CommandPaletteRecentStore(defaults: persistence)
        let newerStore = CommandPaletteRecentStore(defaults: persistence)
        let newerAction = reference(actionID: "newer")
        let lateAction = reference(actionID: "late")

        XCTAssertTrue(newerStore.recordSuccessful(newerAction))
        XCTAssertTrue(olderStore.recordSuccessful(lateAction))

        XCTAssertEqual(
            CommandPaletteRecentStore(defaults: persistence).references,
            [lateAction, newerAction]
        )
    }

    func testLateCompletionCannotRestoreHistoryAfterAnotherStoreDisablesIt() {
        let persistence = CommandPaletteRecentTestPersistence()
        let olderStore = CommandPaletteRecentStore(defaults: persistence)
        let oldAction = reference(actionID: "old")
        XCTAssertTrue(olderStore.recordSuccessful(oldAction))
        let newerStore = CommandPaletteRecentStore(defaults: persistence)

        XCTAssertTrue(newerStore.setEnabled(false))
        XCTAssertFalse(olderStore.recordSuccessful(reference(actionID: "late")))
        XCTAssertFalse(olderStore.isEnabled)
        XCTAssertTrue(olderStore.references.isEmpty)

        XCTAssertTrue(olderStore.setEnabled(true))
        XCTAssertTrue(olderStore.references.isEmpty)

        let reloaded = CommandPaletteRecentStore(defaults: persistence)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertTrue(reloaded.references.isEmpty)
    }

    func testInvalidPayloadFailsClosedWithoutBeingOverwritten() {
        let persistence = CommandPaletteRecentTestPersistence()
        let invalidPayload = Data("not-json".utf8)
        persistence.set(invalidPayload, forKey: "command-palette.recent-actions.v1")

        let store = CommandPaletteRecentStore(defaults: persistence)

        XCTAssertTrue(store.references.isEmpty)
        XCTAssertNotNil(store.loadError)
        XCTAssertFalse(store.recordSuccessful(reference(actionID: "action")))
        XCTAssertEqual(
            persistence.data(forKey: "command-palette.recent-actions.v1"),
            invalidPayload
        )

        XCTAssertTrue(store.clear())
        XCTAssertNil(store.loadError)
        XCTAssertTrue(store.recordSuccessful(reference(actionID: "recovered")))
        XCTAssertEqual(store.references, [reference(actionID: "recovered")])
    }

    func testResolvedReferencesPersistMigrationsAndRetainUnavailableIdentities() {
        let persistence = CommandPaletteRecentTestPersistence()
        let store = CommandPaletteRecentStore(defaults: persistence)
        let unavailable = reference(actionID: "unavailable")
        let old = ActionReference(
            key: ActionKey(providerID: "plugin", actionID: "migrated"),
            schemaVersion: 1
        )
        let current = ActionReference(key: old.key, schemaVersion: 2)

        XCTAssertTrue(store.recordSuccessful(unavailable))
        XCTAssertTrue(store.recordSuccessful(old))

        let resolved = store.resolvedReferences { reference in
            reference == old ? current : nil
        }

        XCTAssertEqual(resolved, [current])
        XCTAssertEqual(store.references, [current, unavailable])
        XCTAssertEqual(
            CommandPaletteRecentStore(defaults: persistence).references,
            [current, unavailable]
        )
    }

    func testPersistenceFailureDoesNotPublishUnstoredHistory() {
        let persistence = CommandPaletteRecentTestPersistence()
        persistence.rejectWrites = true
        let store = CommandPaletteRecentStore(defaults: persistence)

        XCTAssertFalse(store.recordSuccessful(reference(actionID: "action")))
        XCTAssertTrue(store.references.isEmpty)
    }

    func testRecordsOnlySuccessfullyCompletedOutcomes() {
        let store = CommandPaletteRecentStore(defaults: CommandPaletteRecentTestPersistence())
        let succeeded = reference(actionID: "succeeded")

        XCTAssertFalse(store.recordCompletion(
            of: reference(actionID: "failed"),
            outcome: .completed(.failed(message: "failed"))
        ))
        XCTAssertFalse(store.recordCompletion(
            of: reference(actionID: "cancelled"),
            outcome: .completed(.cancelled)
        ))
        XCTAssertFalse(store.recordCompletion(
            of: reference(actionID: "rejected"),
            outcome: .rejected(.unavailable(nil))
        ))
        XCTAssertTrue(store.recordCompletion(
            of: succeeded,
            outcome: .completed(.succeeded())
        ))

        XCTAssertEqual(store.references, [succeeded])
    }

    func testRecentActionsAreExcludedFromPortableApplicationPreferences() throws {
        let suiteName = "CommandPaletteRecentStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CommandPaletteRecentStore(userDefaults: defaults)

        XCTAssertTrue(store.recordSuccessful(reference(actionID: "private-history")))

        let portablePreferences = PreferencesBackupStore(
            userDefaults: defaults
        ).applicationPreferences()
        let encoded = try JSONEncoder().encode(portablePreferences)
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self).contains("private-history")
        )
    }

    private func reference(actionID: String) -> ActionReference {
        ActionReference(key: ActionKey(providerID: "plugin", actionID: actionID))
    }
}

@MainActor
private final class CommandPaletteRecentTestPersistence: CommandPaletteRecentPersisting {
    var rejectWrites = false
    private var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectWrites else { return }
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        guard !rejectWrites else { return }
        values[defaultName] = nil
    }
}
