import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardEmbeddedPreviewPresentationTests: XCTestCase {
    func testCachedSelectionReplacesPendingPreviewAndRejectsItsLateResult() async {
        let first = item("First"), second = item("Second")
        let firstImage = NSImage(size: NSSize(width: 20, height: 20))
        let secondImage = NSImage(size: NSSize(width: 30, height: 30))
        let started = expectation(description: "First preview started")
        var completion: CheckedContinuation<NSImage?, Never>?
        let cache = ClipboardEmbeddedPreviewCache { item in
            if item.id == second.id { return secondImage }
            return await withCheckedContinuation {
                completion = $0
                started.fulfill()
            }
        }
        _ = await cache.image(for: second)
        let presentation = ClipboardEmbeddedPreviewPresentation()
        let pending = Task { await presentation.load(first, cache: cache) }
        await fulfillment(of: [started], timeout: 5)

        await presentation.load(second, cache: cache)
        completion?.resume(returning: firstImage)
        await pending.value

        guard case let .ready(image) = presentation.state else {
            return XCTFail("The current cached selection must remain visible")
        }
        XCTAssertTrue(image === secondImage)
    }

    private func item(_ text: String) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), text: text, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}
