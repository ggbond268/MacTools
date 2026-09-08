import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardContentPreviewTests: XCTestCase {
    func testRichTextReadFailureKeepsCachedTextAndRetryLoadsFormatting() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.rtf, data: Data("{\\rtf1\\ansi Full content}".utf8)),
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Cached content".utf8)),
        ])])
        let item = clip(payload)
        item.configurePayloadLoader({ throw CocoaError(.fileReadNoSuchFile) }, discardCachedPayload: true)
        let failed = await ClipboardRichTextPreviewLoader.load(for: item, fallbackText: item.text)
        guard case let .fallback(text, truncated) = failed else { return XCTFail("Keep readable cached text on failure") }
        XCTAssertEqual(text, "Cached content")
        XCTAssertFalse(truncated)
        item.configurePayloadLoader({ payload }, discardCachedPayload: true)
        let retried = await ClipboardRichTextPreviewLoader.load(for: item, fallbackText: item.text)
        guard case let .formatted(text) = retried else { return XCTFail("Retry should attempt formatted loading again") }
        XCTAssertEqual(String(text.characters), "Full content")
        XCTAssertNil(item.payload)
    }

    func testRichTextFailureWithNoFallbackRemainsAnExplicitFailure() async {
        let item = clip(.plainText(""))
        item.configurePayloadLoader({ throw CocoaError(.fileReadNoSuchFile) }, discardCachedPayload: true)
        let result = await ClipboardRichTextPreviewLoader.load(for: item, fallbackText: "")
        guard case .unavailable = result else { return XCTFail("No content should become an explicit failure") }
    }

    func testLongTextPagesPreserveAllUnicodeWithoutLoadingInitialPage() async throws {
        let original = String(repeating: "A👨‍👩‍👧‍👦e\u{301}\n", count: 2400)
        let payload = ClipboardHistoryPayload.plainText(original)
        let item = clip(payload)
        item.configurePayloadLoader({ throw CocoaError(.fileReadNoSuchFile) }, discardCachedPayload: true)
        let initial = try await ClipboardTextPreviewPage.load(item: item, number: 0)
        XCTAssertEqual(initial.text.count, 4096)
        XCTAssertTrue(initial.hasMore)
        XCTAssertNil(item.payload, "Initial presentation must use metadata only")
        item.configurePayloadLoader({ payload }, discardCachedPayload: true)
        var combined = initial.text
        var page = initial
        while page.hasMore {
            page = try await ClipboardTextPreviewPage.load(item: item, number: page.number + 1)
            XCTAssertLessThanOrEqual(page.text.count, 4096)
            XCTAssertNil(item.payload)
            combined += page.text
        }
        XCTAssertEqual(combined, original)
        let back = try await ClipboardTextPreviewPage.load(item: item, number: 0)
        XCTAssertEqual(back, initial)
        XCTAssertEqual(try item.loadPayload().plainText, original, "Preview navigation must not modify copied content")
    }

    func testTextPageReadFailureCanBeRetried() async throws {
        let payload = ClipboardHistoryPayload.plainText(String(repeating: "x", count: 5000))
        let item = clip(payload)
        item.configurePayloadLoader({ throw CocoaError(.fileReadNoSuchFile) }, discardCachedPayload: true)
        do {
            _ = try await ClipboardTextPreviewPage.load(item: item, number: 1)
            XCTFail("An unreadable next page must report failure")
        } catch { }
        item.configurePayloadLoader({ payload }, discardCachedPayload: true)
        let page = try await ClipboardTextPreviewPage.load(item: item, number: 1)
        XCTAssertEqual(page.text.count, 904)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(item.payload)
    }

    func testNativeColorReadFailureRetryAndUnsupportedContent() async throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: NSColor.red, requiringSecureCoding: true)
        let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.color, data: data)
        ])])
        let item = clip(payload)
        item.configurePayloadLoader({ throw CocoaError(.fileReadNoSuchFile) }, discardCachedPayload: true)
        guard case .failed = await ClipboardNativeColorPreviewLoader.load(item: item) else { return XCTFail("Read failure needs Retry") }
        item.configurePayloadLoader({ payload }, discardCachedPayload: true)
        guard case .value = await ClipboardNativeColorPreviewLoader.load(item: item) else { return XCTFail("Valid color should load on Retry") }
        XCTAssertNil(item.payload)
        guard case .unsupported = await ClipboardNativeColorPreviewLoader.load(item: clip(.plainText("text"))) else {
            return XCTFail("Unsupported content must be distinguished from a failed read")
        }
    }

    func testQuickLookFailureDistinguishesMissingFileAndExistingFile() async {
        let url = URL(fileURLWithPath: "/synthetic/preview.pdf")
        let missing = await ClipboardFilePreviewLoader.load(url: url, scale: 1,
            generate: { _ in throw CocoaError(.fileReadNoSuchFile) }, fileExists: { _ in false })
        guard case .missing = missing else { return XCTFail("Missing file must be explained") }
        let failed = await ClipboardFilePreviewLoader.load(url: url, scale: 1,
            generate: { _ in throw CocoaError(.fileReadCorruptFile) }, fileExists: { _ in true })
        guard case .failed = failed else { return XCTFail("Existing but unpreviewable file must still show a failure") }
        let recovered = await ClipboardFilePreviewLoader.load(url: url, scale: 1,
            generate: { _ in NSImage(size: NSSize(width: 10, height: 10)) },
            fileExists: { _ in XCTFail("Successful previews do not need another file probe"); return true })
        guard case .image = recovered else { return XCTFail("Retry must accept a successful thumbnail") }
    }

    func testCorruptRichTextUsesReadableFallbackWithoutCallingItOversized() {
        let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.rtf, data: Data([0, 1, 2]))
        ])])
        guard case let .fallback(text, _) = ClipboardRichTextPreviewPolicy.makePreview(payload: payload, fallbackText: "Readable") else {
            return XCTFail("Decode failure should offer cached text and Retry, not claim the content was too large")
        }
        XCTAssertEqual(text, "Readable")
    }

    func testCancelledFilePreviewRejectsLateThumbnail() async {
        var continuation: CheckedContinuation<NSImage, Never>?
        let task = Task {
            await ClipboardFilePreviewLoader.load(url: URL(fileURLWithPath: "/synthetic/file.pdf"), scale: 1,
                generate: { _ in await withCheckedContinuation { continuation = $0 } },
                fileExists: { _ in XCTFail("Cancelled requests must not start another file probe"); return true })
        }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation)
        task.cancel()
        continuation?.resume(returning: NSImage(size: NSSize(width: 10, height: 10)))
        guard case .failed = await task.value else { return XCTFail("A late image must not become a successful preview") }
    }

    private func clip(_ payload: ClipboardHistoryPayload) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}
