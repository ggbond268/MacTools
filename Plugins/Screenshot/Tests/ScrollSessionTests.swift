import CoreGraphics
import Foundation
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class ScrollSessionTests: XCTestCase {
    func testFinishReturnsCapturedImageOnlyOnce() async throws {
        let frame = try makeFrame()
        var captures = 0
        var progress: [Double] = []
        var results: [Result<CGImage?, Error>] = []
        let capture = ScrollCapture { captures += 1; return frame }
        capture.onProgress = { progress.append($0) }
        capture.onFinish = { results.append($0) }
        await capture.tick()
        capture.finish()
        try await waitUntil { results.count == 1 }
        capture.finish()
        capture.cancel()
        await capture.tick()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(progress, [1])
        XCTAssertEqual(results.count, 1)
        let image = try XCTUnwrap(try XCTUnwrap(results.first).get())
        XCTAssertEqual(image.width, frame.width)
        XCTAssertEqual(image.height, frame.height)
    }

    func testOverlappingTicksDoNotStartAnotherCapture() async throws {
        let delayed = DelayedImage()
        let capture = ScrollCapture { try await delayed.capture() }
        var updates = 0
        capture.onProgress = { _ in updates += 1 }
        let pending = Task { await capture.tick() }
        await delayed.waitUntilStarted()
        await capture.tick()
        XCTAssertEqual(delayed.calls, 1)
        try delayed.resume(.success(makeFrame()))
        await pending.value
        XCTAssertEqual(updates, 1)
        capture.cancel()
    }

    func testCaptureFailureIsReportedOnceAndStopsCapture() async throws {
        var captures = 0
        var results: [Result<CGImage?, Error>] = []
        let capture = ScrollCapture { captures += 1; throw TestError.captureFailed }
        capture.onFinish = { results.append($0) }
        await capture.tick()
        await capture.tick()
        capture.finish()
        capture.cancel()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = try XCTUnwrap(results.first) else { return XCTFail("A capture failure was hidden") }
        XCTAssertEqual(error as? TestError, .captureFailed)
    }

    func testCancelDiscardsAnInFlightImage() async throws {
        let delayed = DelayedImage()
        let capture = ScrollCapture { try await delayed.capture() }
        var updates = 0
        var results: [Result<CGImage?, Error>] = []
        capture.onProgress = { _ in updates += 1 }
        capture.onFinish = { results.append($0) }
        let pending = Task { await capture.tick() }
        await delayed.waitUntilStarted()
        capture.cancel()
        capture.finish()
        try delayed.resume(.success(makeFrame()))
        await pending.value
        await capture.tick()
        XCTAssertEqual(delayed.calls, 1)
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(try XCTUnwrap(results.first).get())
    }

    func testFinishDiscardsAnInFlightImage() async throws {
        let first = try makeFrame()
        let delayed = DelayedImage()
        var captures = 0
        let capture = ScrollCapture {
            captures += 1
            return captures == 1 ? first : try await delayed.capture()
        }
        var progress: [Double] = []
        var results: [Result<CGImage?, Error>] = []
        capture.onProgress = { progress.append($0) }
        capture.onFinish = { results.append($0) }
        await capture.tick()
        let pending = Task { await capture.tick() }
        await delayed.waitUntilStarted()
        capture.finish()
        try delayed.resume(.success(makeFrame(height: 256)))
        await pending.value
        try await waitUntil { results.count == 1 }
        capture.finish()
        XCTAssertEqual(progress, [1])
        XCTAssertEqual(results.count, 1)
        let image = try XCTUnwrap(try XCTUnwrap(results.first).get())
        XCTAssertEqual(image.height, first.height)
    }

    func testLateCaptureFailureCannotReplaceCancellation() async throws {
        let delayed = DelayedImage()
        let capture = ScrollCapture { try await delayed.capture() }
        var results: [Result<CGImage?, Error>] = []
        capture.onFinish = { results.append($0) }
        let pending = Task { await capture.tick() }
        await delayed.waitUntilStarted()
        capture.cancel()
        try delayed.resume(.failure(TestError.captureFailed))
        await pending.value
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(try XCTUnwrap(results.first).get())
    }

    func testFinishingBeforeFirstFrameIsAnError() async throws {
        var captures = 0
        var result: Result<CGImage?, Error>?
        let capture = ScrollCapture { captures += 1; return try self.makeFrame() }
        capture.onFinish = { result = $0 }
        capture.finish()
        await capture.tick()
        try await waitUntil { result != nil }
        XCTAssertEqual(captures, 0)
        guard case .failure(let error) = try XCTUnwrap(result) else { return XCTFail("Missing frames must be an error") }
        XCTAssertEqual(error as? ScrollCaptureError, .noFrames)
    }

    func testStitcherReconstructsADocumentAcrossDifferentScrollOffsets() throws {
        let width = 400, height = 2400, viewport = 900
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var seed: UInt32 = 12345
        func random() -> CGFloat {
            seed = seed &* 1664525 &+ 1013904223
            return CGFloat((seed >> 8) & 0xFFFF) / 65535
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<600 {
            context.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
            context.fill(CGRect(x: random() * 380, y: random() * 2380, width: 8 + random() * 60, height: 4 + random() * 20))
        }
        let document = try XCTUnwrap(context.makeImage())
        let stitcher = Stitcher()
        for offset in [0, 300, 650, 650, 1100, 1500] {
            try stitcher.push(try XCTUnwrap(document.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport))))
        }
        let output = try XCTUnwrap(try stitcher.compose())
        XCTAssertEqual(output.height, document.height)
        XCTAssertEqual(Stitcher.grayColumns(output), Stitcher.grayColumns(document))
    }

    func testHostWindowsRemainSelectableAlongsideOtherApplications() {
        let hostID = ProcessInfo.processInfo.processIdentifier
        let hostBounds = CGRect(x: 20, y: 40, width: 200, height: 100)
        let otherBounds = CGRect(x: 250, y: 60, width: 300, height: 200)
        let info: [[String: Any]] = [
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: hostID,
             kCGWindowAlpha as String: 1.0, kCGWindowBounds as String: hostBounds.dictionaryRepresentation],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: hostID + 1,
             kCGWindowAlpha as String: 1.0, kCGWindowBounds as String: otherBounds.dictionaryRepresentation],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: hostID,
             kCGWindowAlpha as String: 0.0, kCGWindowBounds as String: hostBounds.dictionaryRepresentation],
        ]
        XCTAssertEqual(CaptureController.selectableWindowRects(from: info, primaryHeight: 900), [
            CGRect(x: 20, y: 760, width: 200, height: 100),
            CGRect(x: 250, y: 640, width: 300, height: 200),
        ])
    }

    func testSmallScrollStripsDoNotRetainCapturedFrameProviders() throws {
        let stats = CaptureBufferStats()
        let stitcher = Stitcher()
        for offset in stride(from: 0, through: 19, by: 1) {
            try autoreleasepool {
                let frame = try trackedFrame(offset: offset, stats: stats)
                XCTAssertEqual(try stitcher.push(frame), offset == 0 ? 360 : 1)
            }
            XCTAssertEqual(stats.liveBytes, 0, "Retained strips must own only their copied pixels")
        }
        XCTAssertEqual(stitcher.totalRows, 379)
        XCTAssertEqual(try stitcher.compose()?.height, 379)
    }

    func testAccumulatedOutputCannotExceedThePixelBudget() throws {
        let stats = CaptureBufferStats()
        let stitcher = Stitcher(maximumBytes: 64 * 4 * 367)
        try stitcher.push(trackedFrame(offset: 0, stats: stats))
        try stitcher.push(trackedFrame(offset: 4, stats: stats))
        XCTAssertThrowsError(try stitcher.push(trackedFrame(offset: 8, stats: stats))) {
            XCTAssertEqual($0 as? ScrollCaptureError, .outputTooLarge)
        }
        XCTAssertEqual(stitcher.totalRows, 364)
        XCTAssertEqual(try stitcher.compose()?.height, 364)
    }

    func testWorkerReadsCapturePixelsOffTheMainThread() async throws {
        let stats = CaptureBufferStats()
        let frame = try trackedFrame(offset: 0, stats: stats)
        let initialReads = stats.mainThreadReads
        let worker = ScrollStitchingWorker()
        _ = try await worker.push(frame)
        XCTAssertGreaterThan(stats.backgroundReads, 0)
        XCTAssertEqual(stats.mainThreadReads, initialReads)
        let output = try await worker.compose()
        XCTAssertEqual(output.height, frame.height)
    }

    func testFinishWaitsForAnAcceptedFrameToFinishProcessing() async throws {
        let gate = DispatchSemaphore(value: 0)
        let stats = CaptureBufferStats(firstBackgroundReadGate: gate)
        let frame = try trackedFrame(offset: 0, stats: stats)
        let capture = ScrollCapture { frame }
        var results: [Result<CGImage?, Error>] = []
        capture.onFinish = { results.append($0) }
        let tick = Task { await capture.tick() }
        defer { gate.signal(); tick.cancel() }
        try await waitUntil { stats.backgroundReads > 0 }
        capture.finish()
        XCTAssertTrue(results.isEmpty)
        gate.signal()
        await tick.value
        try await waitUntil { !results.isEmpty }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results[0].get()?.height, frame.height)
    }

    nonisolated private func trackedFrame(offset: Int, stats: CaptureBufferStats) throws -> CGImage {
        let buffer = CapturePixelBuffer(offset: offset, stats: stats)
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: { info in
            let buffer = Unmanaged<CapturePixelBuffer>.fromOpaque(info!).takeUnretainedValue()
            buffer.stats.recordRead()
            return UnsafeRawPointer(buffer.bytes)
        }, releaseBytePointer: nil, getBytesAtPosition: nil, releaseInfo: { info in
            Unmanaged<CapturePixelBuffer>.fromOpaque(info!).release()
        })
        let retained = Unmanaged.passRetained(buffer)
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: off_t(buffer.count), callbacks: &callbacks) else {
            retained.release()
            throw TestError.captureFailed
        }
        return try XCTUnwrap(CGImage(width: 64, height: 360, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for scrolling capture completion")
    }

    func testOutputLimitRejectsOversizeFrameWithoutChangingAcceptedPixels() throws {
        let stitcher = Stitcher(maximumBytes: 32 * 128 * 4, maximumHeight: 256)
        try stitcher.push(makeFrame())
        XCTAssertThrowsError(try stitcher.push(makeFrame(height: 129))) {
            XCTAssertEqual($0 as? ScrollCaptureError, .outputTooLarge)
        }
        XCTAssertEqual(try stitcher.compose()?.height, 128)
        let heightLimited = Stitcher(maximumHeight: 127)
        XCTAssertThrowsError(try heightLimited.push(makeFrame()))
        XCTAssertTrue(heightLimited.pieces.isEmpty)
    }

    func testOutputLimitIsReportedOnceAndStopsCapture() async throws {
        let worker = ScrollStitchingWorker(maximumHeight: 100)
        let frame = try makeFrame()
        let capture = ScrollCapture(worker: worker) { frame }
        var results: [Result<CGImage?, Error>] = []
        capture.onFinish = { results.append($0) }
        await capture.tick()
        await capture.tick()
        capture.finish()
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else { return XCTFail("Missing output limit error") }
        XCTAssertEqual(error as? ScrollCaptureError, .outputTooLarge)
    }

    func testCancellingPendingCompositionDeliversOnlyCancellation() async throws {
        let frame = try makeFrame()
        let capture = ScrollCapture { frame }
        var results: [Result<CGImage?, Error>] = []
        capture.onFinish = { results.append($0) }
        await capture.tick()
        capture.finish()
        capture.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(try XCTUnwrap(results.first).get())
    }

    private func makeFrame(height: Int = 128) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private enum TestError: Error { case captureFailed }
}

@MainActor
private final class DelayedImage {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { started = $0 }
    }

    func capture() async throws -> CGImage {
        calls += 1
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func resume(_ result: Result<CGImage, Error>) throws {
        let pending = try XCTUnwrap(continuation)
        continuation = nil
        pending.resume(with: result)
    }
}

private final class CaptureBufferStats: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var mainReads = 0
    private var otherReads = 0
    private let firstBackgroundReadGate: DispatchSemaphore?
    init(firstBackgroundReadGate: DispatchSemaphore? = nil) {
        self.firstBackgroundReadGate = firstBackgroundReadGate
    }
    var liveBytes: Int { lock.withLock { bytes } }
    var mainThreadReads: Int { lock.withLock { mainReads } }
    var backgroundReads: Int { lock.withLock { otherReads } }
    func changeBytes(_ delta: Int) { lock.withLock { bytes += delta } }
    func recordRead() {
        let firstBackgroundRead = lock.withLock {
            if Thread.isMainThread { mainReads += 1; return false }
            otherReads += 1
            return otherReads == 1
        }
        if firstBackgroundRead { _ = firstBackgroundReadGate?.wait(timeout: .now() + 2) }
    }
}

private final class CapturePixelBuffer {
    let bytes: UnsafeMutablePointer<UInt8>
    let count = 64 * 360 * 4
    let stats: CaptureBufferStats
    init(offset: Int, stats: CaptureBufferStats) {
        self.stats = stats
        bytes = .allocate(capacity: count)
        bytes.initialize(repeating: 255, count: count)
        for y in 0..<360 {
            for x in 0..<64 {
                var value = UInt32((y + offset) * 64 + x) &+ 1
                value ^= value >> 16
                value = value &* 0x7feb352d
                value ^= value >> 15
                let gray = UInt8(truncatingIfNeeded: value)
                let index = (y * 64 + x) * 4
                bytes[index] = gray
                bytes[index + 1] = gray
                bytes[index + 2] = gray
            }
        }
        stats.changeBytes(count)
    }
    deinit {
        bytes.deallocate()
        stats.changeBytes(-count)
    }
}
