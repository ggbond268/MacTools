import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardPanelPresentationIndexTests: XCTestCase {
    func testMutationsKeepScopeCountsAndRecencyCurrent() {
        let newer = ClipboardHistoryItem(id: UUID(), text: "New", capturedAt: Date(timeIntervalSince1970: 200),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        var older = ClipboardHistoryItem(id: UUID(), text: "Old", capturedAt: Date(timeIntervalSince1970: 100),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        var index = ClipboardPanelPresentationIndex(items: [newer, older], savedItems: [])
        XCTAssertEqual(index.count(in: .history), 2)
        XCTAssertEqual(index.page(in: .history, limit: 1).map { $0.item.id }, [newer.id])

        older.lastUsedAt = Date(timeIntervalSince1970: 300)
        older.setSavedMetadata(.init(title: "Saved", savedAt: .distantPast))
        index.update(older, id: older.id)
        XCTAssertEqual(index.page(in: .all, limit: 2).map { $0.item.id }, [older.id, newer.id])
        XCTAssertEqual(index.count(in: .all), 2)
        XCTAssertEqual(index.count(in: .saved), 1)

        older.isInHistory = false
        index.update(older, id: older.id)
        XCTAssertEqual(index.page(in: .history, limit: 2).map { $0.item.id }, [newer.id])
        XCTAssertEqual(index.page(in: .saved, limit: 2).map { $0.item.id }, [older.id])

        let snippet = ClipboardSavedItem(title: "Snippet", savedKind: .snippet,
            createdAt: Date(timeIntervalSince1970: 400), payload: .plainText("Body"))
        index.updateSnippet(snippet, id: snippet.id)
        XCTAssertEqual(index.count(in: .all), 3)
        XCTAssertEqual(index.page(in: .snippets, limit: 1).map { $0.item.id }, [snippet.id])
        XCTAssertEqual(index.page(in: .all, limit: 1).map { $0.item.id }, [snippet.id])

        index.updateSnippet(nil, id: snippet.id)
        index.update(nil, id: newer.id)
        index.update(nil, id: older.id)
        XCTAssertEqual(index.scopeModes, [.all])
        XCTAssertTrue(index.contentFilters.isEmpty)
        XCTAssertTrue(index.semanticFilters.isEmpty)
        XCTAssertTrue(index.page(in: .all, limit: 1).isEmpty)
    }
}
