import AppKit
import MacToolsPluginKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class RecorderTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Screenshot-recorder-test.mov")

    func testStopIsIdempotentAndWaitsForBothAcknowledgements() {
        var stops = 0
        var results: [Result<URL, Error>] = []
        let lifecycle = RecordingLifecycle { stops += 1 }
        lifecycle.onFinish = { results.append($0) }
        lifecycle.recordingStarted()
        lifecycle.stop()
        lifecycle.stop()
        XCTAssertEqual(stops, 1)
        lifecycle.fileCompleted(.success(url))
        XCTAssertTrue(results.isEmpty)
        lifecycle.captureStopped(.success(()))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try? results.first?.get(), url)
        lifecycle.fileCompleted(.failure(TestError.captureFailed))
        lifecycle.captureStopped(.failure(TestError.captureFailed))
        XCTAssertEqual(results.count, 1)
    }

    func testStopAcknowledgementAloneDoesNotMeanFileIsReady() {
        let lifecycle = RecordingLifecycle {}
        var result: Result<URL, Error>?
        lifecycle.onFinish = { result = $0 }
        lifecycle.stop()
        lifecycle.captureStopped(.success(()))
        XCTAssertEqual(lifecycle.phase, .finalizing)
        XCTAssertNil(result)
        lifecycle.fileCompleted(.success(url))
        XCTAssertEqual(try? result?.get(), url)
    }

    func testCancellationStillWaitsForNativeStop() {
        var stops = 0
        let lifecycle = RecordingLifecycle { stops += 1 }
        var result: Result<URL, Error>?
        lifecycle.onFinish = { result = $0 }
        lifecycle.cancel()
        XCTAssertEqual(stops, 1)
        XCTAssertNil(result)
        lifecycle.fileCompleted(.success(url))
        XCTAssertNil(result)
        lifecycle.captureStopped(.success(()))
        guard case .failure(let error) = result else { return XCTFail("Cancellation was lost") }
        XCTAssertTrue(error is CancellationError)
    }

    func testCaptureFailureCannotBecomeASavedMovie() {
        let lifecycle = RecordingLifecycle {}
        var results: [Result<URL, Error>] = []
        lifecycle.onFinish = { results.append($0) }
        lifecycle.fileCompleted(.success(url))
        lifecycle.captureStopped(.failure(TestError.captureFailed))
        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results.first else { return XCTFail("Capture failure was hidden") }
        XCTAssertTrue(error is TestError)
    }

    func testCancellationWaitsForFileFinalizationAfterNativeStop() {
        let lifecycle = RecordingLifecycle {}
        lifecycle.recordingStarted()
        lifecycle.cancel()
        lifecycle.captureStopped(.success(()))
        XCTAssertNil(lifecycle.result)
        lifecycle.fileCompleted(.success(url))
        guard case .failure(let error) = lifecycle.result else { return XCTFail("Cancellation was lost") }
        XCTAssertTrue(error is CancellationError)
    }

    func testStartupFailureEndsOnceWithoutRequestingAnUnstartedStream() {
        let lifecycle = RecordingLifecycle { XCTFail("No native capture was started") }
        var results = 0
        lifecycle.onFinish = { _ in results += 1 }
        lifecycle.failBeforeCapture(TestError.captureFailed)
        lifecycle.cancel()
        lifecycle.recordingStarted()
        XCTAssertEqual(results, 1)
        XCTAssertEqual(lifecycle.phase, .finished)
    }

    private enum TestError: Error { case captureFailed }
}
