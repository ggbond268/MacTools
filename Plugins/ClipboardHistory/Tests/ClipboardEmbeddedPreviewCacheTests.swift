import AppKit
import ImageIO
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardEmbeddedPreviewCacheTests: XCTestCase {
    func testRealPNGThumbnailIsPixelBoundedAndReusedOnRetinaDisplays() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2_400, height: 1_800,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_800))
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let clip = ClipboardHistoryItem(id: UUID(), payload: .init(pasteboardItems: [
            .init(representations: [.init(typeIdentifier: ClipboardRepresentationType.png, data: png as Data)])
        ]), capturedAt: .distantPast, sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        var decodes = 0
        let cache = ClipboardEmbeddedPreviewCache { item in
            decodes += 1
            return await ClipboardEmbeddedPreviewLoader.load(for: item)
        }
        let first = await cache.image(for: clip)
        let second = await cache.image(for: clip)
        let preview = try XCTUnwrap(first)
        XCTAssertTrue(preview === second)
        XCTAssertEqual(preview.representations.first?.pixelsWide, 1_600)
        XCTAssertEqual(preview.representations.first?.pixelsHigh, 1_200)
        XCTAssertEqual(cache.totalCost, 1_600 * 1_200 * 8)
        XCTAssertEqual(decodes, 1)
        let alternate = ClipboardHistoryItem(id: UUID(), payload: .init(pasteboardItems: [
            .init(representations: [
                .init(typeIdentifier: ClipboardRepresentationType.tiff, data: Data([0])),
                .init(typeIdentifier: ClipboardRepresentationType.png, data: png as Data),
            ])
        ]), capturedAt: .now, sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        let recovered = await ClipboardEmbeddedPreviewLoader.loadResult(for: alternate)
        XCTAssertNotNil(recovered.image, "An unreadable first representation must not hide a valid alternative")
    }

    func testRevisitReusesPreviewButPayloadChangeDoesNot() async {
        var reads = 0
        let cache = ClipboardEmbeddedPreviewCache { _ in
            reads += 1
            return NSImage(size: NSSize(width: 10, height: 10))
        }
        let first = item("first")
        let second = item("second")
        _ = await cache.image(for: first)
        _ = await cache.image(for: second)
        _ = await cache.image(for: first)
        XCTAssertEqual(reads, 2)
        var saved = first
        saved.setSavedMetadata(.init(title: "Saved", savedAt: .now))
        _ = await cache.image(for: saved)
        XCTAssertEqual(reads, 2, "Bookmark metadata must not invalidate a content preview")
        let replaced = item("replacement", id: first.id)
        _ = await cache.image(for: replaced)
        XCTAssertEqual(reads, 3)
    }

    func testLRUEvictionAndHardByteLimit() async {
        var reads = 0
        let cache = ClipboardEmbeddedPreviewCache(maximumCost: 1_600, maximumCount: 2) { _ in
            reads += 1
            return NSImage(size: NSSize(width: 10, height: 10))
        }
        let a = item("a"), b = item("b"), c = item("c")
        _ = await cache.image(for: a)
        _ = await cache.image(for: b)
        _ = cache.cachedImage(for: a)
        _ = await cache.image(for: c)
        XCTAssertNotNil(cache.cachedImage(for: a))
        XCTAssertNil(cache.cachedImage(for: b))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalCost, 1_600)
        XCTAssertEqual(reads, 3)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testCoalescesConcurrentConsumersIncludingUncacheableImage() async {
        for budget in [0, 2_000] {
            let gate = PreviewGate()
            let cache = ClipboardEmbeddedPreviewCache(maximumCost: budget, loader: { _ in await gate.load() })
            let clip = item("shared")
            let first = Task { await cache.image(for: clip) }
            let second = Task { await cache.image(for: clip) }
            await gate.waitForStart()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(gate.reads, 1)
            gate.resume()
            let firstResult = await first.value
            let secondResult = await second.value
            XCTAssertNotNil(firstResult)
            XCTAssertNotNil(secondResult)
            XCTAssertEqual(cache.count, budget == 0 ? 0 : 1)
        }
    }

    func testCancellingOneConsumerDoesNotCancelItsPeer() async {
        let gate = PreviewGate()
        let cache = ClipboardEmbeddedPreviewCache(loader: { _ in await gate.load() })
        let clip = item("shared")
        let first = Task { await cache.image(for: clip) }
        let second = Task { await cache.image(for: clip) }
        await gate.waitForStart()
        for _ in 0..<10 { await Task.yield() }
        first.cancel()
        gate.resume()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertNotNil(secondResult)
        XCTAssertEqual(cache.count, 1)
    }

    func testInvalidationRejectsLateDecodeAndDoesNotCacheFailure() async {
        for clearAll in [true, false] {
            let gate = PreviewGate()
            let cache = ClipboardEmbeddedPreviewCache(loader: { _ in await gate.load() })
            let clip = item("deleted")
            let request = Task { await cache.image(for: clip) }
            await gate.waitForStart()
            if clearAll { cache.removeAll() }
            else { cache.retain { $0.itemID != clip.id } }
            gate.resume()
            let result = await request.value
            XCTAssertNil(result)
            XCTAssertEqual(cache.count, 0)
        }
        var attempts = 0
        let cache = ClipboardEmbeddedPreviewCache { _ in attempts += 1; return nil }
        let clip = item("retry")
        _ = await cache.image(for: clip)
        _ = await cache.image(for: clip)
        XCTAssertEqual(attempts, 2)
    }

    func testFailureIsExplicitAndRetryCanProduceAnImage() async {
        var attempts = 0
        let cache = ClipboardEmbeddedPreviewCache { _ in
            attempts += 1
            return attempts == 1 ? nil : NSImage(size: NSSize(width: 10, height: 10))
        }
        let presentation = ClipboardEmbeddedPreviewPresentation()
        if case .loading = presentation.state {} else { XCTFail("Initial state must show loading") }
        let clip = item("retry")
        await presentation.load(clip, cache: cache)
        if case .failed(.decodingFailed) = presentation.state {} else { XCTFail("Failure must be explicit") }
        await presentation.load(clip, cache: cache)
        if case .ready = presentation.state {} else { XCTFail("Retry must replace the error with a preview") }
        XCTAssertEqual(attempts, 2)
    }

    func testLoadingIsVisibleUntilCompletionAndResetRejectsLateImage() async {
        let gate = PreviewGate()
        let cache = ClipboardEmbeddedPreviewCache { _ in await gate.load() }
        let presentation = ClipboardEmbeddedPreviewPresentation()
        let clip = item("pending")
        let request = Task { await presentation.load(clip, cache: cache) }
        await gate.waitForStart()
        if case .loading = presentation.state {} else { XCTFail("A pending read must show loading") }
        presentation.reset()
        cache.cancelPendingLoads()
        gate.resume()
        await request.value
        if case .loading = presentation.state {} else { XCTFail("Closed previews must reject late results") }
        XCTAssertEqual(cache.count, 0)
    }

    func testOrdinaryCloseRetainsCompletedPreviewButDeletionEvictsIt() async {
        var reads = 0
        let cache = ClipboardEmbeddedPreviewCache { _ in
            reads += 1
            return NSImage(size: NSSize(width: 10, height: 10))
        }
        let clip = item("reopen")
        _ = await cache.image(for: clip)
        cache.cancelPendingLoads()
        _ = await cache.image(for: clip)
        XCTAssertEqual(reads, 1)
        cache.retain { $0.itemID != clip.id }
        XCTAssertNil(cache.cachedImage(for: clip))
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testDecodeFailureAndUnsupportedFormatHaveDifferentReasons() async {
        let unsupported = await ClipboardEmbeddedPreviewLoader.loadResult(for: item("text"))
        XCTAssertNil(unsupported.image)
        if case .unsupportedRepresentation = unsupported.failure {} else { XCTFail("Missing representation must remain distinguishable") }
        let invalidImage = ClipboardHistoryItem(id: UUID(), payload: .init(pasteboardItems: [
            .init(representations: [.init(typeIdentifier: ClipboardRepresentationType.png, data: Data([0]))])
        ]), capturedAt: .now, sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        let result = await ClipboardEmbeddedPreviewLoader.loadResult(for: invalidImage)
        XCTAssertNil(result.image)
        if case .decodingFailed = result.failure {} else { XCTFail("Corrupt image must report decoding failure") }
        invalidImage.configurePayloadLoader({ throw CocoaError(.fileReadNoSuchFile) }, discardCachedPayload: true)
        let unreadable = await ClipboardEmbeddedPreviewLoader.loadResult(for: invalidImage)
        if case .payloadUnavailable = unreadable.failure {} else { XCTFail("Storage failure must remain distinguishable from decoding failure") }
    }

    private func item(_ text: String, id: UUID = UUID()) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: id, text: text, capturedAt: .distantPast,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}

@MainActor
private final class PreviewGate {
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private(set) var reads = 0

    func load() async -> NSImage? {
        reads += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitForStart() async {
        for _ in 0..<1_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Preview loader never started")
    }

    func resume() {
        continuation?.resume(returning: NSImage(size: NSSize(width: 10, height: 10)))
        continuation = nil
    }
}
