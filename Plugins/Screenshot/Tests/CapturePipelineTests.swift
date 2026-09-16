import AppKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class CapturePipelineTests: XCTestCase {
    func testCollectionBoundsConcurrencyAndKeepsDisplayIdentity() async throws {
        let delayed = DelayedDisplays()
        let displays = (1...5).map { display(id: UInt32($0)) }
        let task = Task { try await CapturePipeline.collect(displays) { try await delayed.capture($0.id) } }
        try await waitUntil { delayed.started.count == 3 }
        XCTAssertEqual(Set(delayed.started), [1, 2, 3])
        try delayed.complete(3)
        try await waitUntil { delayed.started.count == 4 }
        try delayed.complete(2)
        try await waitUntil { delayed.started.count == 5 }
        for id: UInt32 in [5, 1, 4] { try delayed.complete(id) }
        let images = try await task.value
        XCTAssertEqual(images.count, 5)
        XCTAssertEqual(delayed.highWater, 3)
        for (id, image) in images { XCTAssertEqual(image.width, Int(id)) }
    }

    func testCancellationStopsSubmittingPendingDisplays() async throws {
        let delayed = DelayedDisplays()
        let displays = (1...5).map { display(id: UInt32($0)) }
        let task = Task { try await CapturePipeline.collect(displays) { try await delayed.capture($0.id) } }
        try await waitUntil { delayed.started.count == 3 }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else { return XCTFail("A cancelled collection published images") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(delayed.started.count, 3)
        for id: UInt32 in [1, 2, 3] { try delayed.complete(id) }
    }

    func testCompletionAcceptsOnlyTheFirstCallback() async throws {
        let value = try await CaptureCompletion<Int>.receive { completion in
            completion(.success(7))
            completion(.success(9))
        }
        XCTAssertEqual(value, 7)
    }

    func testCancelledBeforeSubmissionDoesNotStartCapture() async {
        var started = false
        let task = Task {
            try await CaptureCompletion<Int>.receive { _ in started = true }
        }
        task.cancel()
        guard case .failure(let error) = await task.result else { return XCTFail("Cancellation was ignored") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(started)
    }

    func testDeadlineDiscardsLateCallbacks() async throws {
        var callback: (@Sendable (Result<Int, Error>) -> Void)?
        do {
            _ = try await CaptureCompletion<Int>.receive(timeout: .milliseconds(10)) { callback = $0 }
            XCTFail("A missing callback must time out")
        } catch { XCTAssertEqual(error as? CaptureFailure, .timedOut) }
        callback?(.success(1))
        callback?(.failure(CaptureFailure.unavailable))
        await Task.yield()
    }

    func testRetinaFrameValidationRejectsStaleResolution() throws {
        let target = display(id: 1, scale: 2)
        XCTAssertEqual(target.pixelWidth, 16)
        XCTAssertEqual(target.pixelHeight, 12)
        XCTAssertNoThrow(try target.validate(makeImage(width: 16, height: 12)))
        XCTAssertThrowsError(try target.validate(makeImage(width: 8, height: 6))) {
            XCTAssertEqual($0 as? CaptureFailure, .displayChanged)
        }
    }

    private func display(id: UInt32, scale: CGFloat = 1) -> CaptureDisplay {
        let frame = CGRect(x: -8, y: 12, width: 8, height: 6)
        return CaptureDisplay(id: id, frame: frame, captureRect: frame, scale: scale)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "Asynchronous capture did not advance")
        if !condition() { throw CaptureFailure.timedOut }
    }
}

@MainActor
private final class DelayedDisplays {
    var started: [UInt32] = []
    var highWater = 0
    private var callbacks: [UInt32: @Sendable (Result<CGImage, Error>) -> Void] = [:]

    func capture(_ id: UInt32) async throws -> CGImage {
        try await CaptureCompletion<CGImage>.receive { completion in
            started.append(id)
            callbacks[id] = completion
            highWater = max(highWater, callbacks.count)
        }
    }

    func complete(_ id: UInt32) throws {
        let callback = try XCTUnwrap(callbacks.removeValue(forKey: id))
        callback(.success(try makeImage(width: Int(id), height: 6)))
    }
}

private func makeImage(width: Int, height: Int) throws -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    return try XCTUnwrap(context?.makeImage())
}
