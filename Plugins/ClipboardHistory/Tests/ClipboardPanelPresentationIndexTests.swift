import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardPanelPresentationIndexTests: XCTestCase {
    func testIncrementalPagesAndCountsMatchFreshSearchThroughMixedMutations() {
        var items = (0..<120).map { number in
            ClipboardHistoryItem(id: UUID(), text: number.isMultiple(of: 3) ? "https://example.com/\(number)" : "Text \(number)",
                capturedAt: Date(timeIntervalSince1970: Double(number / 2)),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        }
        var snippets: [ClipboardSavedItem] = []
        var index = ClipboardPanelPresentationIndex(items: items, savedItems: snippets)
        for step in 0..<90 {
            let position = (step * 17) % items.count
            switch step % 3 {
            case 0:
                items[position].setSavedMetadata(.init(title: "Saved", savedAt: .now))
                index.update(items[position], id: items[position].id)
            case 1:
                let previous = items.remove(at: position)
                index.update(nil, id: previous.id)
                let recopy = ClipboardHistoryItem(id: previous.id, text: previous.text,
                    capturedAt: Date(timeIntervalSince1970: Double(1_000 + step)),
                    sourceApplication: nil, isPinned: false, lastUsedAt: nil)
                items.append(recopy)
                index.update(recopy, id: recopy.id)
            default:
                items[position].isInHistory = false
                items[position].setSavedMetadata(.init(title: "Saved only", savedAt: .now))
                index.update(items[position], id: items[position].id)
            }
            if step.isMultiple(of: 10) {
                let snippet = ClipboardSavedItem(title: "Snippet \(step)", savedKind: .snippet, payload: .plainText("Body"))
                snippets.append(snippet)
                index.updateSnippet(snippet, id: snippet.id)
            }
            if step.isMultiple(of: 11), !snippets.isEmpty {
                let removed = snippets.removeFirst()
                index.updateSnippet(nil, id: removed.id)
            }
            let rebuilt = ClipboardPanelPresentationIndex(items: items, savedItems: snippets)
            XCTAssertEqual(index.scopeModes, rebuilt.scopeModes)
            XCTAssertEqual(index.contentFilters, rebuilt.contentFilters)
            XCTAssertEqual(index.semanticFilters, rebuilt.semanticFilters)
            XCTAssertEqual(index.filterFamilies, rebuilt.filterFamilies)
            for mode in ClipboardPanelMode.allCases {
                let expected = ClipboardPanelBoundedSearch.collect(limit: 50) { collector in
                    for item in items {
                        let included = switch mode {
                        case .all: item.isInHistory || item.isSaved
                        case .history: item.isInHistory
                        case .saved: item.isSaved
                        case .snippets: false
                        }
                        if included { collector.consider(.init(item: item, isSnippet: false, sortDate: item.capturedAt)) }
                    }
                    if mode == .all || mode == .snippets {
                        for snippet in snippets {
                            collector.consider(.init(item: snippet.historyPresentationItem(), isSnippet: true, sortDate: snippet.updatedAt))
                        }
                    }
                }
                XCTAssertEqual(index.page(in: mode, limit: 50).map { $0.item.id }, expected.candidates.map { $0.item.id })
                XCTAssertEqual(index.count(in: mode), expected.matchingCount)
            }
        }
        for item in items { index.update(nil, id: item.id) }
        for snippet in snippets { index.updateSnippet(nil, id: snippet.id) }
        XCTAssertEqual(index.scopeModes, [.history])
        XCTAssertTrue(index.filterFamilies.isEmpty)
        XCTAssertTrue(index.contentFilters.isEmpty)
        XCTAssertTrue(index.semanticFilters.isEmpty)
        XCTAssertTrue(index.page(in: .all, limit: 50).isEmpty)
    }
}
