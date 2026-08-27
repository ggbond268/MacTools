import XCTest
import MacToolsPluginKit
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSequentialPasteSessionTests: XCTestCase {
    func testQueueRejectsEmptyAndOversizedInputWithoutTruncating() {
        XCTAssertThrowsError(try ClipboardSequentialPasteSession(source: .explicitQueue, itemIDs: [])) {
            XCTAssertEqual($0 as? ClipboardSequentialQueueError, .empty)
        }
        XCTAssertThrowsError(
            try ClipboardSequentialPasteSession(
                source: .explicitQueue,
                itemIDs: (0...ClipboardSequentialPasteSession.maximumItemCount).map { _ in UUID() }
            )
        ) {
            XCTAssertEqual(
                $0 as? ClipboardSequentialQueueError,
                .exceedsMaximumItemCount(maximum: ClipboardSequentialPasteSession.maximumItemCount)
            )
        }
    }

    func testQueueDeduplicatesWhilePreservingOrder() throws {
        let first = UUID()
        let second = UUID()
        let session = try ClipboardSequentialPasteSession(
            source: .explicitQueue,
            itemIDs: [first, second, first]
        )
        XCTAssertEqual(session.itemIDs, [first, second])
    }

    func testPasteSkipUnavailablePreviousAndRestartTransitions() throws {
        let ids = [UUID(), UUID(), UUID()]
        var session = try ClipboardSequentialPasteSession(source: .explicitQueue, itemIDs: ids)

        session.recordSuccessfulPaste()
        XCTAssertEqual(session.nextItemID, ids[1])
        XCTAssertEqual(session.statuses, [.pasted, .pending, .pending])

        session.markCurrentUnavailable()
        XCTAssertEqual(session.nextItemID, ids[2])
        XCTAssertEqual(session.statuses[1], .unavailable)

        session.moveToPrevious()
        XCTAssertEqual(session.nextItemID, ids[1])

        session.skip()
        XCTAssertEqual(session.nextItemID, ids[2])
        XCTAssertEqual(session.statuses[1], .skipped)

        session.restart()
        XCTAssertEqual(session.nextItemID, ids[0])
        XCTAssertEqual(session.statuses, [.pending, .pending, .pending])
    }

    func testActiveExplicitQueueIsImmutableUntilCompletionOrCancellation() throws {
        let first = UUID()
        let second = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        try coordinator.startExplicitQueue(itemIDs: [first])
        XCTAssertThrowsError(try coordinator.startExplicitQueue(itemIDs: [second])) {
            XCTAssertEqual($0 as? ClipboardSequentialQueueError, .activeQueueExists)
        }
        XCTAssertEqual(coordinator.session?.itemIDs, [first])

        coordinator.cancel()
        XCTAssertNoThrow(try coordinator.startExplicitQueue(itemIDs: [second]))
        XCTAssertEqual(coordinator.session?.itemIDs, [second])
    }

    func testCoordinatorPrefersAndRestoresExplicitQueue() throws {
        let explicitID = UUID()
        let recentID = UUID()
        let store = ClipboardSequentialPasteMemoryStore()
        let coordinator = ClipboardSequentialPasteCoordinator(store: store)

        try coordinator.startExplicitQueue(itemIDs: [explicitID])
        XCTAssertEqual(coordinator.nextItemID(recentHistoryItemIDs: [recentID]), explicitID)
        XCTAssertEqual(store.session?.source, .explicitQueue)

        let restored = ClipboardSequentialPasteCoordinator(store: store)
        XCTAssertEqual(restored.nextItemID(recentHistoryItemIDs: [recentID]), explicitID)
    }

    func testStartingAfterCompletionUsesOnlyTheNewItems() throws {
        let completedID = UUID()
        let newID = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        try coordinator.startExplicitQueue(itemIDs: [completedID])
        let operation = try XCTUnwrap(coordinator.nextOperation(recentHistoryItemIDs: []))
        XCTAssertTrue(coordinator.recordSuccessfulPaste(operation: operation))
        try coordinator.startExplicitQueue(itemIDs: [newID])

        XCTAssertEqual(coordinator.session?.itemIDs, [newID])
        XCTAssertEqual(coordinator.session?.nextItemID, newID)
    }

    func testOperationCannotAdvanceAChangedOrReplacedSession() throws {
        let first = UUID()
        let second = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        try coordinator.startExplicitQueue(itemIDs: [first, second])
        let firstOperation = try XCTUnwrap(coordinator.nextOperation(recentHistoryItemIDs: []))
        coordinator.skip()
        XCTAssertFalse(coordinator.recordSuccessfulPaste(operation: firstOperation))
        XCTAssertEqual(coordinator.session?.nextItemID, second)

        coordinator.cancel()
        try coordinator.startExplicitQueue(itemIDs: [first])
        XCTAssertFalse(coordinator.recordSuccessfulPaste(operation: firstOperation))
        XCTAssertEqual(coordinator.session?.nextItemID, first)
    }

    func testImplicitQueueUsesBoundedSnapshotAndResetsForExternalCopy() {
        let recentIDs = (0..<125).map { _ in UUID() }
        let coordinator = ClipboardSequentialPasteCoordinator()

        XCTAssertEqual(coordinator.nextItemID(recentHistoryItemIDs: recentIDs), recentIDs[0])
        XCTAssertEqual(coordinator.session?.totalCount, 100)
        coordinator.resetImplicitQueueForExternalCopy()
        XCTAssertNil(coordinator.session)
    }

    func testActiveImplicitQueueProtectsItsSnapshotUntilReset() {
        let start = Date(timeIntervalSince1970: 1_000)
        let ids = [UUID(), UUID()]
        let coordinator = ClipboardSequentialPasteCoordinator()

        XCTAssertEqual(coordinator.nextItemID(recentHistoryItemIDs: ids, now: start), ids[0])
        XCTAssertEqual(coordinator.protectedItemIDs(), Set(ids))

        coordinator.resetImplicitQueueForExternalCopy()
        XCTAssertTrue(coordinator.protectedItemIDs().isEmpty)
    }

    func testImplicitQueueRemainsActiveUntilClipboardReset() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let recentID = UUID()
        let replacementID = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        XCTAssertEqual(
            coordinator.nextItemID(recentHistoryItemIDs: [recentID], now: start),
            recentID
        )
        XCTAssertEqual(
            coordinator.nextItemID(
                recentHistoryItemIDs: [replacementID],
                now: start.addingTimeInterval(11)
            ),
            recentID
        )

        coordinator.cancel()
        try coordinator.startExplicitQueue(itemIDs: [recentID], now: start)
        XCTAssertEqual(
            coordinator.nextItemID(
                recentHistoryItemIDs: [replacementID],
                now: start.addingTimeInterval(1_000)
            ),
            recentID
        )
    }

    func testPluginStorageRoundTripsExplicitQueueAndClearsCompletion() throws {
        let storage = SequentialPasteTestPluginStorage()
        let store = PluginStorageClipboardSequentialPasteStore(storage: storage)
        var session = try ClipboardSequentialPasteSession(
            source: .explicitQueue,
            itemIDs: [UUID(), UUID()]
        )
        session.recordSuccessfulPaste()
        store.saveExplicitSession(session)

        let restored = try XCTUnwrap(store.loadExplicitSession())
        XCTAssertEqual(restored.cursor, 1)

        session.recordSuccessfulPaste()
        store.saveExplicitSession(session)
        XCTAssertNil(store.loadExplicitSession())
        XCTAssertTrue(storage.values.isEmpty)
    }

    func testDecodingRejectsMalformedPersistedQueueState() throws {
        let session = try ClipboardSequentialPasteSession(
            source: .explicitQueue,
            itemIDs: [UUID(), UUID()]
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["cursor"] = 2
        object["statuses"] = ["pending", "pending"]
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(
            ClipboardSequentialPasteSession.self,
            from: malformed
        ))
    }
}

@MainActor
private final class SequentialPasteTestPluginStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
