import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardRichTextPreviewCacheTests: XCTestCase {
    func testOrdinaryCloseReusesPreparedLightAndDarkDocument() async {
        var reads = 0
        let cache = ClipboardRichTextPreviewCache { _ in
            reads += 1
            return .formatted(.init(AttributedString("Readable text")))
        }
        let item = clip("First")
        _ = await cache.preview(for: item)
        cache.invalidatePendingLoad()
        guard case let .formatted(document) = await cache.preview(for: item) else {
            return XCTFail("Expected the prepared document")
        }
        XCTAssertEqual(String(document.light.characters), "Readable text")
        XCTAssertEqual(String(document.dark.characters), "Readable text")
        XCTAssertEqual(reads, 1)
    }

    func testOnlyLastDocumentIsRetainedAndExplicitDiscardForcesReload() async {
        var reads = 0
        let cache = ClipboardRichTextPreviewCache { item in
            reads += 1
            return .plainText(item.text, isSimplified: true)
        }
        let first = clip("First")
        let second = clip("Second")
        _ = await cache.preview(for: first)
        _ = await cache.preview(for: second)
        _ = await cache.preview(for: first)
        XCTAssertEqual(reads, 3)
        cache.removeAll()
        _ = await cache.preview(for: first)
        XCTAssertEqual(reads, 4)
    }

    func testChangedPayloadAndDeletedItemInvalidateThePreview() async {
        var reads = 0
        let cache = ClipboardRichTextPreviewCache { item in
            reads += 1
            return .plainText(item.text, isSimplified: true)
        }
        let first = clip("First")
        let replacement = clip("Replacement", id: first.id)
        _ = await cache.preview(for: first)
        _ = await cache.preview(for: replacement)
        XCTAssertEqual(reads, 2)
        cache.retain { $0 == ClipboardEmbeddedPreviewKey(replacement) }
        _ = await cache.preview(for: replacement)
        XCTAssertEqual(reads, 2)
        cache.retain { _ in false }
        _ = await cache.preview(for: replacement)
        XCTAssertEqual(reads, 3)
    }

    func testFailedReadsAreRetried() async {
        var reads = 0
        let cache = ClipboardRichTextPreviewCache { _ in
            reads += 1
            return reads == 1 ? .fallback("Saved text", isTruncated: false) : .unavailable
        }
        let item = clip("First")
        for _ in 0..<3 { _ = await cache.preview(for: item) }
        XCTAssertEqual(reads, 3)
    }

    func testDiscardDuringImportRejectsLateResult() async {
        var resume: CheckedContinuation<ClipboardRichTextPreviewResult, Never>?
        var reads = 0
        let cache = ClipboardRichTextPreviewCache { _ in
            reads += 1
            if reads == 1 { return await withCheckedContinuation { resume = $0 } }
            return .plainText("Current", isSimplified: true)
        }
        let item = clip("First")
        let pending = Task { await cache.preview(for: item) }
        while resume == nil { await Task.yield() }
        cache.removeAll()
        resume?.resume(returning: .plainText("Stale", isSimplified: true))
        guard case .unavailable = await pending.value else { return XCTFail("Discarded import must not publish") }
        guard case let .plainText(text, _) = await cache.preview(for: item) else {
            return XCTFail("Expected a fresh read")
        }
        XCTAssertEqual(text, "Current")
        XCTAssertEqual(reads, 2)
    }

    func testCancelledImportCannotPopulateCache() async {
        var reads = 0
        let cache = ClipboardRichTextPreviewCache { _ in
            reads += 1
            if reads == 1 { try? await Task.sleep(for: .seconds(60)) }
            return .plainText("Preview", isSimplified: true)
        }
        let item = clip("First")
        let pending = Task { await cache.preview(for: item) }
        while reads == 0 { await Task.yield() }
        pending.cancel()
        guard case .unavailable = await pending.value else { return XCTFail("Cancelled import must not publish") }
        _ = await cache.preview(for: item)
        XCTAssertEqual(reads, 2)
    }

    private func clip(_ text: String, id: UUID = UUID()) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: id, text: text, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}
