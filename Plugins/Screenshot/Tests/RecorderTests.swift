import AppKit
import MacToolsPluginKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class RecorderTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Screenshot-recorder-test.mov")

    func testStopIsIdempotentAndWaitsForFileCompletion() async {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var stops = 0
        var cleanups = 0
        var results: [Result<URL, Error>] = []
        let lifecycle = RecordingLifecycle(stopCapture: {
            stops += 1
            signal.yield(())
        }, onEnd: { cleanups += 1 })
        lifecycle.onFinish = { results.append($0) }

        lifecycle.stop()
        lifecycle.stop()
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(cleanups, 0)

        lifecycle.finish(.success(url))
        lifecycle.finish(.failure(TestError.captureFailed))
        lifecycle.stop()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try? results.first?.get(), url)
        XCTAssertEqual(cleanups, 1)
        XCTAssertEqual(stops, 1)
    }

    func testStopFailureIsReportedAndCleanedUpOnce() async {
        let (events, signal) = AsyncStream<Result<URL, Error>>.makeStream()
        var cleanups = 0
        let lifecycle = RecordingLifecycle(stopCapture: { throw TestError.captureFailed }, onEnd: { cleanups += 1 })
        lifecycle.onFinish = { signal.yield($0) }
        lifecycle.stop()
        var iterator = events.makeAsyncIterator()
        guard case .failure(let error) = await iterator.next() else {
            return XCTFail("Stopping capture must not report a failure as a saved movie")
        }
        XCTAssertTrue(error is TestError)
        lifecycle.finish(.success(url))
        XCTAssertEqual(cleanups, 1)
    }

    func testMissingOutputCallbackTimesOutAsFailure() async {
        let (events, signal) = AsyncStream<Result<URL, Error>>.makeStream()
        var cleanups = 0
        let lifecycle = RecordingLifecycle(finishTimeout: .milliseconds(20), stopCapture: {}, onEnd: { cleanups += 1 })
        lifecycle.onFinish = { signal.yield($0) }
        lifecycle.stop()
        var iterator = events.makeAsyncIterator()
        guard case .failure(RecordingError.finishTimedOut) = await iterator.next() else {
            return XCTFail("Missing file completion must report a timeout")
        }
        lifecycle.finish(.success(url))
        XCTAssertEqual(cleanups, 1)
    }

    func testTimeoutAlsoBoundsAHangingStopCapture() async {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var resumeStop: CheckedContinuation<Void, Error>?
        var results: [Result<URL, Error>] = []
        let lifecycle = RecordingLifecycle(finishTimeout: .milliseconds(20), stopCapture: {
            try await withCheckedThrowingContinuation { resumeStop = $0 }
        }, onEnd: {})
        lifecycle.onFinish = { results.append($0); signal.yield(()) }
        lifecycle.stop()
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        XCTAssertNotNil(resumeStop)
        resumeStop?.resume(throwing: TestError.captureFailed)
        await Task.yield()
        XCTAssertEqual(results.count, 1)
        guard case .failure(RecordingError.finishTimedOut) = results.first else {
            return XCTFail("A hung stop request must release the session and report its timeout")
        }
    }

    func testEarlyResultWaitsForItsHandlerAndIsDeliveredOnce() {
        var cleanups = 0
        var results: [Result<URL, Error>] = []
        let lifecycle = RecordingLifecycle(stopCapture: { XCTFail("The session has already ended") },
                                           onEnd: { cleanups += 1 })
        lifecycle.finish(.failure(TestError.captureFailed))
        XCTAssertEqual(cleanups, 1)
        lifecycle.onFinish = { results.append($0) }
        lifecycle.onFinish = { _ in XCTFail("Completion must be delivered only once") }
        lifecycle.finish(.success(url))
        lifecycle.stop()
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else { return XCTFail("The early failure was lost") }
        XCTAssertTrue(error is TestError)
        XCTAssertEqual(cleanups, 1)
    }

    func testCompletionCancelsTimeoutAndIgnoresLateErrors() async throws {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var results: [Result<URL, Error>] = []
        let lifecycle = RecordingLifecycle(finishTimeout: .milliseconds(20), stopCapture: { signal.yield(()) }, onEnd: {})
        lifecycle.onFinish = { results.append($0) }
        lifecycle.stop()
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        lifecycle.finish(.success(url))
        try await Task.sleep(for: .milliseconds(40))
        lifecycle.finish(.failure(TestError.captureFailed))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try? results.first?.get(), url)
    }

    func testOnlyRegisteredControlsAreExcludedAndStartupCleanupLeavesHostWindowsAlone() throws {
        _ = NSApplication.shared
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let control = CaptureTestWindow(number: 101)
        let outline = CaptureTestWindow(number: 102)
        let hostWindow = CaptureTestWindow(number: 103)
        environment.registerCaptureControls([control, outline])
        XCTAssertEqual(try environment.captureControlWindowIDs(availableWindowIDs: [101, 102, 103]), [101, 102])

        environment.closeAll()
        XCTAssertEqual(control.orderOutCalls, 1)
        XCTAssertEqual(outline.orderOutCalls, 1)
        XCTAssertEqual(hostWindow.orderOutCalls, 0)
    }

    func testMissingControlWindowPreventsCaptureUntilTheSnapshotContainsIt() throws {
        _ = NSApplication.shared
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let control = CaptureTestWindow(number: 101)
        environment.registerCaptureControls([control])
        defer { environment.closeAll() }

        do {
            _ = try environment.captureControlWindowIDs(availableWindowIDs: [103])
            XCTFail("A missing control window must not silently become part of the recording")
        } catch {
            XCTAssertEqual(error as? ScreenshotControlError, .notReady)
        }
        XCTAssertEqual(try environment.captureControlWindowIDs(availableWindowIDs: [101, 103]), [101])
    }

    private enum TestError: Error { case captureFailed }
}

@MainActor
private final class CaptureTestWindow: NSWindow {
    private let testNumber: Int
    private(set) var orderOutCalls = 0
    override var windowNumber: Int { testNumber }

    init(number: Int) {
        testNumber = number
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }

    override func orderOut(_ sender: Any?) { orderOutCalls += 1 }
}
