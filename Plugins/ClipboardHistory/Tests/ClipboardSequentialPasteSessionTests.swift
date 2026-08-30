import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardSequentialPasteSessionTests: XCTestCase {
    func testQueueRejectsEmptyOversizedAndExcessivePayloadInput() {
        XCTAssertThrowsError(try ClipboardSequentialPasteSession(explicitSnapshots: [])) {
            XCTAssertEqual($0 as? ClipboardSequentialQueueError, .empty)
        }
        XCTAssertThrowsError(try ClipboardSequentialPasteSession(
            explicitSnapshots: (0...ClipboardSequentialPasteSession.maximumItemCount).map {
                snapshot(UUID(), text: "\($0)")
            }
        )) {
            XCTAssertEqual(
                $0 as? ClipboardSequentialQueueError,
                .exceedsMaximumItemCount(maximum: ClipboardSequentialPasteSession.maximumItemCount)
            )
        }
        let oversized = ClipboardSequentialPasteSnapshot(
            sourceItemID: UUID(),
            payload: .plainText(String(
                repeating: "x",
                count: ClipboardSequentialPasteSession.maximumPayloadByteCount + 1
            )),
            expandsSnippetVariables: false
        )
        XCTAssertThrowsError(try ClipboardSequentialPasteSession(explicitSnapshots: [oversized])) {
            XCTAssertEqual(
                $0 as? ClipboardSequentialQueueError,
                .exceedsMaximumPayloadByteCount(
                    maximum: ClipboardSequentialPasteSession.maximumPayloadByteCount
                )
            )
        }
    }

    func testQueueFreezesPayloadAndDeduplicatesWhilePreservingOrder() throws {
        let first = UUID()
        let second = UUID()
        let session = try ClipboardSequentialPasteSession(explicitSnapshots: [
            snapshot(first, text: "original"),
            snapshot(second, text: "second"),
            snapshot(first, text: "changed"),
        ])
        XCTAssertEqual(session.itemIDs, [first, second])
        XCTAssertEqual(session.snapshots?.map(\.payload.plainText), ["original", "second"])
    }

    func testPasteSkipUnavailablePreviousAndRestartTransitions() throws {
        let ids = [UUID(), UUID(), UUID()]
        var session = try ClipboardSequentialPasteSession(
            explicitSnapshots: ids.map { snapshot($0) }
        )

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

    func testActiveExplicitQueueIsImmutableUntilCompletionOrCancellation() async throws {
        let first = UUID()
        let second = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        try await coordinator.startExplicitQueue(snapshots: [snapshot(first)])
        do {
            try await coordinator.startExplicitQueue(snapshots: [snapshot(second)])
            XCTFail("Expected active queue rejection")
        } catch {
            XCTAssertEqual(error as? ClipboardSequentialQueueError, .activeQueueExists)
        }
        XCTAssertEqual(coordinator.session?.itemIDs, [first])
        let didCancel = await coordinator.cancel()
        XCTAssertTrue(didCancel)
        try await coordinator.startExplicitQueue(snapshots: [snapshot(second)])
        XCTAssertEqual(coordinator.session?.itemIDs, [second])
    }

    func testCoordinatorRestoresFrozenExplicitQueue() async throws {
        let explicitID = UUID()
        let recentID = UUID()
        let store = ClipboardSequentialPasteMemoryStore()
        let coordinator = ClipboardSequentialPasteCoordinator(store: store)

        try await coordinator.startExplicitQueue(snapshots: [snapshot(explicitID, text: "frozen")])
        let firstNext = try await coordinator.nextItemID(recentHistoryItemIDs: [recentID])
        XCTAssertEqual(firstNext, explicitID)

        let restored = ClipboardSequentialPasteCoordinator(store: store)
        try await restored.restoreExplicitQueue()
        let restoredNext = try await restored.nextItemID(recentHistoryItemIDs: [recentID])
        XCTAssertEqual(restoredNext, explicitID)
        XCTAssertEqual(restored.session?.snapshots?.first?.payload.plainText, "frozen")
    }

    func testFirstPasteWaitsForPersistedQueueRestore() async throws {
        let persistedID = UUID()
        let recentID = UUID()
        let persisted = try ClipboardSequentialPasteSession(
            explicitSnapshots: [snapshot(persistedID, text: "persisted")]
        )
        let coordinator = ClipboardSequentialPasteCoordinator(
            store: ClipboardSequentialPasteMemoryStore(session: persisted)
        )

        let operation = try await coordinator.nextOperation(
            recentHistoryItemIDs: [recentID]
        )

        XCTAssertEqual(operation?.itemID, persistedID)
        XCTAssertEqual(operation?.snapshot?.payload.plainText, "persisted")
    }

    func testFailedProgressBlocksNextPasteUntilDurabilityRecovers() async throws {
        let ids = [UUID(), UUID()]
        let store = ControllableSequentialPasteStore()
        let coordinator = ClipboardSequentialPasteCoordinator(store: store)
        try await coordinator.startExplicitQueue(snapshots: ids.map { snapshot($0) })
        let operationValue = try await coordinator.nextOperation(recentHistoryItemIDs: [])
        let operation = try XCTUnwrap(operationValue)
        await store.setSaveFailure(true)

        let recorded = await coordinator.recordSuccessfulPaste(operation: operation)
        XCTAssertFalse(recorded)
        XCTAssertEqual(coordinator.session?.cursor, 1)
        XCTAssertNotNil(coordinator.persistenceError)
        do {
            _ = try await coordinator.nextOperation(recentHistoryItemIDs: [])
            XCTFail("Expected failed persistence to block the next paste")
        } catch {
            XCTAssertNotNil(coordinator.persistenceError)
        }

        await store.setSaveFailure(false)
        let recovered = try await coordinator.nextOperation(recentHistoryItemIDs: [])
        XCTAssertEqual(recovered?.itemID, ids[1])
        XCTAssertNil(coordinator.persistenceError)
    }

    func testFailedCancelKeepsActiveQueueVisibleForRetry() async throws {
        let store = ControllableSequentialPasteStore()
        let coordinator = ClipboardSequentialPasteCoordinator(store: store)
        try await coordinator.startExplicitQueue(snapshots: [snapshot(UUID())])
        await store.setSaveFailure(true)

        let firstCancel = await coordinator.cancel()
        XCTAssertFalse(firstCancel)
        XCTAssertNotNil(coordinator.session)
        XCTAssertNotNil(coordinator.persistenceError)

        await store.setSaveFailure(false)
        let secondCancel = await coordinator.cancel()
        XCTAssertTrue(secondCancel)
        XCTAssertNil(coordinator.session)
    }

    func testStorageResetDiscardsQueueAndPreventsReloadingItsOldSnapshot() async throws {
        let persistedID = UUID()
        let recentID = UUID()
        let persisted = try ClipboardSequentialPasteSession(
            explicitSnapshots: [snapshot(persistedID)]
        )
        let coordinator = ClipboardSequentialPasteCoordinator(
            store: ClipboardSequentialPasteMemoryStore(session: persisted)
        )

        coordinator.prepareForStorageReset()
        let next = try await coordinator.nextItemID(recentHistoryItemIDs: [recentID])

        XCTAssertEqual(next, recentID)
        XCTAssertEqual(coordinator.session?.source, .recentHistory)
    }

    func testStartingAfterCompletionUsesOnlyTheNewItems() async throws {
        let completedID = UUID()
        let newID = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        try await coordinator.startExplicitQueue(snapshots: [snapshot(completedID)])
        let operationValue = try await coordinator.nextOperation(recentHistoryItemIDs: [])
        let operation = try XCTUnwrap(operationValue)
        let didRecord = await coordinator.recordSuccessfulPaste(operation: operation)
        XCTAssertTrue(didRecord)
        try await coordinator.startExplicitQueue(snapshots: [snapshot(newID)])
        XCTAssertEqual(coordinator.session?.itemIDs, [newID])
    }

    func testOperationCannotAdvanceChangedOrReplacedSession() async throws {
        let first = UUID()
        let second = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()

        try await coordinator.startExplicitQueue(snapshots: [snapshot(first), snapshot(second)])
        let firstOperationValue = try await coordinator.nextOperation(recentHistoryItemIDs: [])
        let firstOperation = try XCTUnwrap(firstOperationValue)
        let didSkip = await coordinator.skip()
        XCTAssertTrue(didSkip)
        let advancedStaleOperation = await coordinator.recordSuccessfulPaste(operation: firstOperation)
        XCTAssertFalse(advancedStaleOperation)
        let didCancel = await coordinator.cancel()
        XCTAssertTrue(didCancel)
        try await coordinator.startExplicitQueue(snapshots: [snapshot(first)])
        let advancedReplacedOperation = await coordinator.recordSuccessfulPaste(operation: firstOperation)
        XCTAssertFalse(advancedReplacedOperation)
    }

    func testImplicitQueueUsesBoundedSnapshotAndResetsForExternalCopy() async throws {
        let recentIDs = (0..<125).map { _ in UUID() }
        let coordinator = ClipboardSequentialPasteCoordinator()
        let next = try await coordinator.nextItemID(recentHistoryItemIDs: recentIDs)
        XCTAssertEqual(next, recentIDs[0])
        XCTAssertEqual(coordinator.session?.totalCount, 100)
        coordinator.resetImplicitQueueForExternalCopy()
        XCTAssertNil(coordinator.session)
    }

    func testActiveImplicitQueueProtectsItsSnapshotUntilReset() async throws {
        let ids = [UUID(), UUID()]
        let coordinator = ClipboardSequentialPasteCoordinator()
        let next = try await coordinator.nextItemID(recentHistoryItemIDs: ids)
        XCTAssertEqual(next, ids[0])
        XCTAssertEqual(coordinator.protectedItemIDs(), Set(ids))
        coordinator.resetImplicitQueueForExternalCopy()
        XCTAssertTrue(coordinator.protectedItemIDs().isEmpty)
    }

    func testImplicitQueueRemainsActiveUntilClipboardReset() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let recentID = UUID()
        let replacementID = UUID()
        let coordinator = ClipboardSequentialPasteCoordinator()
        let initialNext = try await coordinator.nextItemID(
            recentHistoryItemIDs: [recentID],
            now: start
        )
        XCTAssertEqual(initialNext, recentID)
        let unchangedNext = try await coordinator.nextItemID(
            recentHistoryItemIDs: [replacementID],
            now: start.addingTimeInterval(11)
        )
        XCTAssertEqual(
            unchangedNext,
            recentID
        )
        let didCancel = await coordinator.cancel()
        XCTAssertTrue(didCancel)
        try await coordinator.startExplicitQueue(snapshots: [snapshot(recentID)], now: start)
        let explicitNext = try await coordinator.nextItemID(recentHistoryItemIDs: [replacementID])
        XCTAssertEqual(explicitNext, recentID)
    }

    func testEncryptedStoreRoundTripsAndClearsCompletedQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedClipboardSequentialPasteStore(
            databaseURL: directory.appendingPathComponent("clipboard.sqlite3"),
            keyStore: InMemoryClipboardHistoryKeyStore(),
            databaseAccess: ClipboardDatabaseAccessCoordinator()
        )
        var session = try ClipboardSequentialPasteSession(explicitSnapshots: [
            snapshot(UUID(), text: "one"), snapshot(UUID(), text: "two"),
        ])
        session.recordSuccessfulPaste()
        try await store.saveExplicitSession(session)
        let restored = try await store.loadExplicitSession()
        XCTAssertEqual(restored?.cursor, 1)
        session.recordSuccessfulPaste()
        try await store.saveExplicitSession(session)
        let completed = try await store.loadExplicitSession()
        XCTAssertNil(completed)
    }

    func testInvalidatedDatabaseBarrierRejectsLateSaveWithoutRecreatingPrivateData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let keyStore = InMemoryClipboardHistoryKeyStore()
        let databaseAccess = ClipboardDatabaseAccessCoordinator()
        let store = EncryptedClipboardSequentialPasteStore(
            databaseURL: databaseURL,
            keyStore: keyStore,
            databaseAccess: databaseAccess
        )
        let session = try ClipboardSequentialPasteSession(
            explicitSnapshots: [snapshot(UUID())]
        )
        databaseAccess.invalidate()

        do {
            try await store.saveExplicitSession(session)
            XCTFail("Expected the uninstall storage barrier to reject a late save")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryStoreError, .unavailableStorage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertNil(keyStore.currentKey)
    }

    func testDecodingRejectsMalformedPersistedQueueState() throws {
        let session = try ClipboardSequentialPasteSession(explicitSnapshots: [
            snapshot(UUID()), snapshot(UUID()),
        ])
        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["cursor"] = 2
        object["statuses"] = ["pending", "pending"]
        let malformed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(
            ClipboardSequentialPasteSession.self,
            from: malformed
        ))
    }

    private func snapshot(_ id: UUID, text: String = "value") -> ClipboardSequentialPasteSnapshot {
        ClipboardSequentialPasteSnapshot(
            sourceItemID: id,
            payload: .plainText(text),
            expandsSnippetVariables: false
        )
    }
}

private actor ControllableSequentialPasteStore: ClipboardSequentialPasteSessionPersisting {
    private var session: ClipboardSequentialPasteSession?
    private var failsSave = false

    func setSaveFailure(_ fails: Bool) {
        failsSave = fails
    }

    func loadExplicitSession() async throws -> ClipboardSequentialPasteSession? {
        session
    }

    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?) async throws {
        if failsSave { throw ClipboardHistoryStoreError.unavailableStorage }
        self.session = session
    }
}
