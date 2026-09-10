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
            stitcher.push(try XCTUnwrap(document.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport))))
        }
        let output = try XCTUnwrap(stitcher.compose())
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
