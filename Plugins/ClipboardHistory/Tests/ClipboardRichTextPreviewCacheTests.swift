import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardRichTextPreviewCacheTests: XCTestCase {
    func testSwitchingReusesRecentPreviewsWithinCapacityAndRetriesFailures() async {
        let first = item("First"), second = item("Second"), third = item("Third")
        var reads: [UUID: Int] = [:]
        let cache = ClipboardRichTextPreviewCache(maximumCount: 2) { item in
            reads[item.id, default: 0] += 1
            if item.id == third.id, reads[item.id] == 1 {
                return .fallback(item.text, isTruncated: false)
            }
            return .plainText(item.text, isSimplified: true)
        }

        _ = await cache.preview(for: first)
        _ = await cache.preview(for: second)
        _ = await cache.preview(for: first)
        XCTAssertEqual(reads[first.id], 1)

        _ = await cache.preview(for: third)
        XCTAssertNil(cache.cachedPreview(for: third))
        _ = await cache.preview(for: third)
        XCTAssertEqual(reads[third.id], 2)
        XCTAssertNil(cache.cachedPreview(for: second))
        XCTAssertNotNil(cache.cachedPreview(for: first))

        let edited = item("Edited", id: first.id)
        XCTAssertNil(cache.cachedPreview(for: edited))
        _ = await cache.preview(for: edited)
        XCTAssertNil(cache.cachedPreview(for: first))
        XCTAssertNotNil(cache.cachedPreview(for: edited))
        cache.retain { $0.itemID != edited.id }
        XCTAssertNil(cache.cachedPreview(for: edited))
    }

    func testInvalidatedInFlightPreviewCannotReturnOrRetainDeletedContent() async {
        let selected = item("Removed during preview")
        let started = expectation(description: "Preview started")
        var completion: CheckedContinuation<ClipboardRichTextPreviewResult, Never>?
        let cache = ClipboardRichTextPreviewCache { _ in
            await withCheckedContinuation {
                completion = $0
                started.fulfill()
            }
        }
        let request = Task { await cache.preview(for: selected) }
        await fulfillment(of: [started], timeout: 5)
        cache.retain { _ in false }
        completion?.resume(returning: .plainText(selected.text, isSimplified: true))
        let result = await request.value
        guard case .unavailable = result else {
            return XCTFail("An invalidated preview must not be presented")
        }
        XCTAssertNil(cache.cachedPreview(for: selected))
    }

    func testOversizedRichTextPreviewUsesMetadataWithoutReadingOriginalPayload() async {
        let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.html,
                  data: Data(repeating: 32, count: ClipboardRichTextPreviewPolicy.maximumFormattedByteCount + 1)),
            .init(typeIdentifier: ClipboardRepresentationType.plainText,
                  data: Data("Saved text summary".utf8)),
        ])])
        let selected = ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        selected.configurePayloadLoader({
            XCTFail("A simplified preview must not read the original rich-text payload")
            throw CocoaError(.fileReadNoSuchFile)
        }, discardCachedPayload: true)

        let result = await ClipboardRichTextPreviewCache().preview(for: selected)
        guard case let .plainText(text, isSimplified) = result else {
            return XCTFail("Expected the saved text summary")
        }
        XCTAssertEqual(text, "Saved text summary")
        XCTAssertTrue(isSimplified)
    }

    private func item(_ text: String, id: UUID = UUID()) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: id, text: text, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}
