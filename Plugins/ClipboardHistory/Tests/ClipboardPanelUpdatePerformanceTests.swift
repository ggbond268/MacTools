import Combine
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardPanelUpdatePerformanceTests: XCTestCase {
    func testUsageAndBookmarkPatchVisibleRowWithoutSearchOrSelectionChanges() async {
        var items = makeItems(80)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.setMultiSelectionEnabled(true)
        model.toggleMultiSelection(for: items[1].id)
        let selection = model.selectedItemIDs
        let focused = model.selectedItemID
        let order = model.visibleItems.map(\.id)
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        items[0].lastUsedAt = .now
        items[0].setSavedMetadata(.init(title: "Saved", savedAt: .now))
        model.updateItems(items, changedIDs: [items[0].id])
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleItems.first, items.first)
        XCTAssertEqual(model.visibleItems.map(\.id), order)
        XCTAssertEqual(model.selectedItemIDs, selection)
        XCTAssertEqual(model.selectedItemID, focused)
        XCTAssertEqual(notifications, 1, "Only the changed page should publish, not searching/selection state")
        model.updateItems(items, changedIDs: [items[0].id])
        XCTAssertEqual(notifications, 1, "An identical acknowledgement should publish nothing")
        withExtendedLifetime(subscription) {}
    }

    func testUnsaveInSavedScopeRefillsTheVisiblePageAndInvalidatesOldAction() async throws {
        var items = makeItems(80)
        for index in items.indices { items[index].setSavedMetadata(.init(title: "Saved", savedAt: .distantPast)) }
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.mode = .saved
        await model.waitForSearchForTesting()
        let firstID = try XCTUnwrap(model.visibleItems.first?.id)
        model.selectedItemID = firstID
        let context = try XCTUnwrap(model.actionContext)
        let index = try XCTUnwrap(items.firstIndex { $0.id == firstID })
        items[index].setSavedMetadata(nil)
        model.updateItems(items, changedIDs: [firstID])
        XCTAssertFalse(model.canPerformAction(in: context))
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.scopedItemCount, 79)
        XCTAssertEqual(model.visibleItems.count, 50)
        XCTAssertFalse(model.visibleItems.contains { $0.id == firstID })
        XCTAssertTrue(model.hasMoreResults)
    }

    func testMetadataCanEnterAndLeaveAnActiveSearch() async {
        var items = makeItems(3)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.query = "needle"
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)
        items[1].setSavedMetadata(.init(title: "needle", savedAt: .now))
        model.updateItems(items, changedIDs: [items[1].id])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [items[1].id])
        items[1].setSavedMetadata(nil)
        model.updateItems(items, changedIDs: [items[1].id])
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)
    }

    func testUpdateWhileSearchIsPendingCannotPublishOldMetadata() async {
        var items = makeItems(100)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        model.query = "MT88"
        items[0].setSavedMetadata(.init(title: "Latest title", savedAt: .now))
        model.updateItems(items, changedIDs: [items[0].id])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.first?.savedMetadata?.title, "Latest title")
    }

    func testReopenRestoresInitialScopeFiltersAndLatestSelectionWithoutSearching() async {
        var items = makeItems(3)
        items[1].setSavedMetadata(.init(title: "Saved", savedAt: .now))
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
        await model.waitForSearchForTesting()
        let initialIDs = model.visibleItems.map(\.id)
        let initialFamilies = model.availableFilterFamilies
        model.mode = .saved
        model.query = "Saved"
        await model.waitForSearchForTesting()
        model.setMultiSelectionEnabled(true)
        model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.mode, .all)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedItemID, items[0].id)
        XCTAssertEqual(model.visibleItems.map(\.id), initialIDs)
        XCTAssertEqual(model.availableFilterFamilies, initialFamilies)
        XCTAssertFalse(model.isMultiSelectionEnabled)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    func testReopenAfterMutationDoesNotRestoreStalePageOrFilters() async {
        var items = makeItems(3)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        items[0].setSavedMetadata(.init(title: "Newly saved", savedAt: .now))
        model.updateItems(items, changedIDs: [items[0].id])
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.availableScopeModes.contains(.saved))
        XCTAssertTrue(model.visibleItems.first(where: { $0.id == items[0].id })?.isSaved == true)
    }

    func testChangedRevisionRejectsSameCountWarmPage() async {
        let original = makeItems(3)
        let replacement = makeItems(3)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(
            items: original,
            historyRevision: 10,
            savedRevision: 4
        )
        await model.waitForSearchForTesting()

        model.prepareForPresentation(
            items: replacement,
            historyRevision: 11,
            savedRevision: 4
        )
        await model.waitForSearchForTesting()

        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set(replacement.map(\.id)))
        XCTAssertTrue(Set(model.visibleItems.map(\.id)).isDisjoint(with: Set(original.map(\.id))))
    }

    func testReorderedSnapshotThenTargetedUpdateUsesCorrectIndex() async {
        var items = makeItems(3)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        items.swapAt(0, 2)
        items[1].lastUsedAt = .now
        model.updateItems(items)
        await model.waitForSearchForTesting()
        items[0].setSavedMetadata(.init(title: "Correct item", savedAt: .now))
        model.updateItems(items, changedIDs: [items[0].id])
        XCTAssertEqual(model.visibleItems.first(where: { $0.id == items[0].id })?.savedMetadata?.title, "Correct item")
        XCTAssertEqual(model.scopedItemCount, 3)
    }

    func testLargeWarmReopenAndMetadataPatchStayWithinBudget() async {
        var items = makeItems(50_000)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
        await model.waitForSearchForTesting()
        var start = ContinuousClock.now
        model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
        let reopen = ContinuousClock.now - start
        XCTAssertFalse(model.isSearching)
        XCTAssertLessThan(reopen, .milliseconds(50))
        items[0].lastUsedAt = .now
        start = .now
        model.updateItems(items, changedIDs: [items[0].id])
        let patch = ContinuousClock.now - start
        XCTAssertFalse(model.isSearching)
        XCTAssertLessThan(patch, .milliseconds(150))
        print("Clipboard 50k warm reopen: \(reopen); targeted metadata patch: \(patch)")
    }

    func testLargeColdPresentationPreparationReturnsWithoutBlockingTheUI() async {
        let items = makeItems(50_000)
        let model = ClipboardHistoryPanelModel()

        let start = ContinuousClock.now
        model.prepareForPresentationAsynchronously(items: items)
        let scheduling = ContinuousClock.now - start

        XCTAssertTrue(model.isPreparingPresentation)
        XCTAssertLessThan(
            scheduling,
            .milliseconds(100),
            "Cold presentation analysis must be scheduled off the main actor"
        )
        await model.waitForPresentationPreparationForTesting()
        await model.waitForSearchForTesting()

        XCTAssertFalse(model.isPreparingPresentation)
        XCTAssertEqual(model.scopedItemCount, items.count)
        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
        print("Clipboard 50k cold presentation scheduling: \(scheduling)")
    }

    func testLargeReactivationFilterRefreshReturnsWithoutBlockingTheUI() async {
        let items = makeItems(50_000)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()

        let start = ContinuousClock.now
        model.refreshFiltersForReactivation(items: items)
        let scheduling = ContinuousClock.now - start

        XCTAssertLessThan(
            scheduling,
            .milliseconds(100),
            "Returning to Clipboard must schedule collection-wide filter analysis off the main actor"
        )
        await model.waitForFilterRefreshForTesting()
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.scopedItemCount, items.count)
        print("Clipboard 50k reactivation filter scheduling: \(scheduling)")
    }

    func testCancelledPresentationPreparationStopsDetachedCollectionScan() async throws {
        let checkpoints = ClipboardPreparationCheckpointCounter()
        let model = ClipboardHistoryPanelModel(
            presentationPreparationCheckpointForTesting: {
                checkpoints.increment()
                Thread.sleep(forTimeInterval: 0.001)
            }
        )
        model.prepareForPresentationAsynchronously(items: makeItems(50_000))
        for _ in 0..<200 where checkpoints.value < 3 {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThanOrEqual(checkpoints.value, 3)

        model.cancelPresentationPreparation()
        try await Task.sleep(for: .milliseconds(30))
        let stoppedCount = checkpoints.value
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(
            checkpoints.value,
            stoppedCount,
            "Cancelling the panel preparation must stop its detached scan, not only discard its result"
        )
    }

    private func makeItems(_ count: Int) -> [ClipboardHistoryItem] {
        (0..<count).map { index in
            ClipboardHistoryItem(id: UUID(), text: "MT88 tripod \(index)",
                capturedAt: Date(timeIntervalSince1970: TimeInterval(count - index)),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        }
    }
}

private final class ClipboardPreparationCheckpointCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
