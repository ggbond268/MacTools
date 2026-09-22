import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardPanelUpdateTests: XCTestCase {

    func testUnsaveInSavedScopeRefillsTheVisiblePageAndInvalidatesOldAction() async throws {
        var items = makeItems(ClipboardHistoryPanelModel.resultPageSize + 2)
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
        XCTAssertEqual(model.scopedItemCount, items.count - 1)
        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
        XCTAssertFalse(model.visibleItems.contains { $0.id == firstID })
        XCTAssertTrue(model.hasMoreResults)
    }

    func testMetadataUpdatesDuringSearchPublishCurrentResults() async {
        var items = makeItems(3)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.query = "needle"
        items[1].setSavedMetadata(.init(title: "needle", savedAt: .now))
        model.updateItems(items, changedIDs: [items[1].id])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [items[1].id])
        items[1].setSavedMetadata(nil)
        model.updateItems(items, changedIDs: [items[1].id])
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)
    }

    func testReusedItemOutsideFilteredPageMovesToFrontInHistoryAndSavedScopes() async {
        for mode in [ClipboardPanelMode.all, .history, .saved] {
            var items = makeItems(ClipboardHistoryPanelModel.resultPageSize + 1)
            for index in items.indices {
                items[index].setSavedMetadata(.init(title: "Saved", savedAt: .distantPast))
            }
            let model = ClipboardHistoryPanelModel()
            model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
            model.mode = mode
            model.query = "MT88"
            await model.waitForSearchForTesting()
            let focus = model.selectedItemID
            let tailIndex = items.index(before: items.endIndex)
            XCTAssertFalse(model.visibleItems.contains { $0.id == items[tailIndex].id })

            items[tailIndex].lastUsedAt = .now
            items[tailIndex].configurePayloadLoader({
                XCTFail("Recency updates must use metadata without reading payloads")
                throw CocoaError(.fileReadNoSuchFile)
            }, discardCachedPayload: true)
            model.updateItems(items, revision: 2, changedIDs: [items[tailIndex].id])
            await model.waitForSearchForTesting()

            XCTAssertEqual(model.visibleItems.first?.id, items[tailIndex].id)
            XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
            XCTAssertTrue(model.hasMoreResults)
            XCTAssertEqual(model.selectedItemID, focus)
            XCTAssertEqual(model.query, "MT88")
        }
    }

    private func makeItems(_ count: Int) -> [ClipboardHistoryItem] {
        (0..<count).map { index in
            ClipboardHistoryItem(id: UUID(), text: "MT88 tripod \(index)",
                capturedAt: Date(timeIntervalSince1970: TimeInterval(count - index)),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        }
    }
}
