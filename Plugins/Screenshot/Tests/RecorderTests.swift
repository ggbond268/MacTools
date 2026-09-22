import AppKit
import MacToolsPluginKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class RecorderTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/Screenshot-recorder-test.mov")

    func testRecorderCreatesAHiddenRegionOutlineBeforeCaptureStarts() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Recording requires macOS 15") }
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let display = CaptureDisplay(id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                     captureRect: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 2)
        let region = try CaptureRegion(selection: CGRect(x: 100, y: 100, width: 300, height: 200), display: display)
        let environment = ScreenshotEnvironment(context: .init(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let recorder = Recorder(region: region, environment: environment)
        defer { recorder.cancel() }
        let outlines = app.windows.filter { !existing.contains(ObjectIdentifier($0)) }
            .compactMap { $0 as? CaptureRegionOutlineWindow }
        XCTAssertEqual(outlines.count, 1)
        let outline = try XCTUnwrap(outlines.first)
        XCTAssertEqual(outline.frame, region.globalRect.insetBy(dx: -3, dy: -3))
        XCTAssertFalse(outline.isVisible, "Preparation must not show controls before their capture exclusion is ready")
    }

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

    func testSlowFileCompletionWarnsWithoutDiscardingLateSuccess() async throws {
        let lifecycle = RecordingLifecycle(finishWarningDelay: .milliseconds(10), stopCapture: {})
        var results: [Result<URL, Error>] = []
        lifecycle.onFinish = { results.append($0) }
        lifecycle.stop()
        lifecycle.captureStopped(.success(()))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(lifecycle.phase, .waiting)
        XCTAssertTrue(results.isEmpty)
        lifecycle.fileCompleted(.success(url))
        XCTAssertEqual(try? results.first?.get(), url)
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

    func testFileFailureWaitsForCaptureCleanup() {
        var stops = 0
        let lifecycle = RecordingLifecycle { stops += 1 }
        var results = 0
        lifecycle.onFinish = { _ in results += 1 }
        lifecycle.fileCompleted(.failure(TestError.captureFailed))
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(results, 0)
        lifecycle.captureStopped(.success(()))
        XCTAssertEqual(results, 1)
    }

    func testCaptureFailureWaitsForTheWriterToReleaseItsFile() {
        let lifecycle = RecordingLifecycle {}
        lifecycle.recordingStarted()
        lifecycle.captureStopped(.failure(TestError.captureFailed))
        XCTAssertNil(lifecycle.result)
        lifecycle.fileCompleted(.success(url))
        guard case .failure(let error) = lifecycle.result else { return XCTFail("Stream failure was hidden") }
        XCTAssertTrue(error is TestError)
    }

    func testWaitingStateAllowsStopRetryWithoutEndingOwnership() {
        var stops = 0
        let lifecycle = RecordingLifecycle { stops += 1 }
        lifecycle.stop()
        lifecycle.waitingForCapture()
        XCTAssertNil(lifecycle.result)
        lifecycle.stop()
        XCTAssertEqual(stops, 2)
        lifecycle.captureStopped(.success(()))
        lifecycle.fileCompleted(.success(url))
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

    func testOnlyRegisteredControlsAreExcludedAndStartupCleanupLeavesHostWindowsAlone() throws {
        _ = NSApplication.shared
        let control = CaptureTestWindow()
        let outline = CaptureTestWindow()
        let hostWindow = CaptureTestWindow()
        let controls = CaptureControls([control, outline])
        XCTAssertEqual(try controls.windowIDs(available: [CGWindowID(control.windowNumber), CGWindowID(outline.windowNumber), CGWindowID(hostWindow.windowNumber)]),
                       [CGWindowID(control.windowNumber), CGWindowID(outline.windowNumber)])

        controls.hide()
        XCTAssertEqual(control.orderOutCalls, 1)
        XCTAssertEqual(outline.orderOutCalls, 1)
        XCTAssertEqual(hostWindow.orderOutCalls, 0)
    }

    func testMissingControlWindowPreventsCaptureUntilTheSnapshotContainsIt() throws {
        _ = NSApplication.shared
        let control = CaptureTestWindow()
        let controls = CaptureControls([control])
        defer { controls.hide() }

        do {
            _ = try controls.windowIDs(available: [])
            XCTFail("A missing control window must not silently become part of the recording")
        } catch {
            XCTAssertEqual(error as? ScreenshotControlError, .notReady)
        }
        XCTAssertEqual(try controls.windowIDs(available: [CGWindowID(control.windowNumber)]), [CGWindowID(control.windowNumber)])
    }

    private enum TestError: Error { case captureFailed }
}
@MainActor
private final class CaptureTestWindow: NSWindow {
    private(set) var orderOutCalls = 0

    init() {
        super.init(contentRect: NSRect(x: 100, y: 100, width: 80, height: 60),
                   styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func orderOut(_ sender: Any?) {
        orderOutCalls += 1
        super.orderOut(sender)
    }
}
