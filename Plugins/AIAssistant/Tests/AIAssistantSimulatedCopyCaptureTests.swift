import AppKit
import XCTest

@testable import AIAssistantPlugin

/// Behavioral coverage for the hardened simulated-copy capture:
/// serialization, single ⌘C destination, cancellation, and preservation of
/// clipboard changes whose owner cannot be verified.
///
/// All tests run against a private named pasteboard, never NSPasteboard.general.
@MainActor
final class AIAssistantSimulatedCopyCaptureTests: XCTestCase {
    // MARK: - Test doubles

    /// Thread-safe recorder for copy-event destinations.
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [pid_t?] = []

        func record(_ pid: pid_t?) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(pid)
        }

        var recordedCalls: [pid_t?] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// NSPasteboard is not Sendable; box it for the @Sendable seams.
    private final class PasteboardBox: @unchecked Sendable {
        let pasteboard: NSPasteboard

        init(_ pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }
    }

    // MARK: - Helpers

    // The capture flow gates on accessibility trust; pin the probe so the
    // behavioral tests below never depend on this machine's TCC state. The
    // parallel test workers each run one class at a time in their own process.
    override func setUp() async throws {
        AccessibilityCheck.trustProbe = { true }
    }

    override func tearDown() async throws {
        AccessibilityCheck.trustProbe = { AXIsProcessTrusted() }
    }

    /// Creates a private pasteboard preloaded with one string item.
    private func makePrivatePasteboard(content: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mactools.tests.simulated-copy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        return pasteboard
    }

    private func makeCapture(
        pasteboard: NSPasteboard,
        sender: @escaping SimulatedCopySelectedTextCapture.CopyEventSender = { _ in },
        pasteboardChangeTimeout: TimeInterval = 0.3
    ) -> SimulatedCopySelectedTextCapture {
        let box = PasteboardBox(pasteboard)
        return SimulatedCopySelectedTextCapture(
            copyEventSender: sender,
            pasteboardProvider: { box.pasteboard },
            pasteboardChangeTimeout: pasteboardChangeTimeout,
            allowsSimulatedCopy: { true }
        )
    }

    // MARK: - Success path

    func testConsentIsRecheckedBeforePostingCopy() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()
        var checks = 0
        let capture = SimulatedCopySelectedTextCapture(
            copyEventSender: { recorder.record($0) },
            pasteboardProvider: { box.pasteboard },
            allowsSimulatedCopy: { checks += 1; return false }
        )
        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))
        XCTAssertNil(result.text)
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(recorder.recordedCalls.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCaptureReturnsTextWithoutOverwritingChangedClipboard() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let capture = makeCapture(pasteboard: pasteboard) { pid in
            _ = pid
            // A real copy starts a new change session; only that bumps the
            // change count the capture flow waits for.
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
        }

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertEqual(result.text, "captured")
        XCTAssertEqual(result.strategyID, .simulatedCopy)
        XCTAssertNil(result.failureReason)
        XCTAssertEqual(pasteboard.string(forType: .string), "captured")
    }

    func testCopySenderCalledExactlyOnceWithFrontmostPID() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()
        let capture = makeCapture(pasteboard: pasteboard) { pid in
            recorder.record(pid)
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
        }

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4711))

        XCTAssertEqual(recorder.recordedCalls, [4711])
        XCTAssertEqual(result.text, "captured")
    }

    func testNoFrontmostPIDSkipsCopy() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()
        let capture = makeCapture(pasteboard: pasteboard) { pid in
            recorder.record(pid)
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
        }

        let result = await capture.capture(context: SelectedTextCaptureContext())

        XCTAssertTrue(recorder.recordedCalls.isEmpty)
        XCTAssertNil(result.text)
        XCTAssertNotNil(result.failureReason)
    }

    func testPermissionFailureSkipsCopyEntirely() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let recorder = CallRecorder()
        let capture = makeCapture(pasteboard: pasteboard) { pid in
            recorder.record(pid)
        }

        AccessibilityCheck.trustProbe = { false }
        defer { AccessibilityCheck.trustProbe = { AXIsProcessTrusted() } }

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertNil(result.text)
        XCTAssertNotNil(result.failureReason)
        XCTAssertEqual(result.failureReason, "需要辅助功能授权")
        XCTAssertTrue(recorder.recordedCalls.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    // MARK: - Failed copy

    func testFailedCopyDoesNotRetryWithUntargetedKeystroke() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let recorder = CallRecorder()
        let capture = makeCapture(pasteboard: pasteboard) { recorder.record($0) }

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertNil(result.text)
        XCTAssertNotNil(result.failureReason)
        XCTAssertEqual(recorder.recordedCalls, [4242])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testSuccessfulSimulatedCopyReturnsCapturedText() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let capture = makeCapture(pasteboard: pasteboard) { pid in
            _ = pid
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
        }

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        // 模拟复制成功捕获文本，直接返回文本内容供后续处理使用
        XCTAssertEqual(result.text, "captured")
        XCTAssertNil(result.failureReason)
    }

    // MARK: - Cancellation

    func testCancelledCaptureSendsNoCopy() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()

        // Deterministic cancellation: the pasteboard provider runs right after
        // the gate hands over the turn and before the copy checkpoint, and it
        // cancels the capture task so the post-modifier checkpoint trips.
        let cancellingCapture = SimulatedCopySelectedTextCapture(
            copyEventSender: { pid in
                recorder.record(pid)
                box.pasteboard.clearContents()
                box.pasteboard.setString("captured", forType: .string)
            },
            pasteboardProvider: {
                withUnsafeCurrentTask { task in task?.cancel() }
                return box.pasteboard
            },
            pasteboardChangeTimeout: 0.3,
            allowsSimulatedCopy: { true }
        )

        let result = await cancellingCapture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertNil(result.text)
        XCTAssertNotNil(result.failureReason)
        XCTAssertTrue(recorder.recordedCalls.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    // MARK: - Serialization

    func testConcurrentCapturesAreSerialized() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()
        // A capture whose sender records but deliberately writes nothing holds
        // the gate through its pasteboard wait, so any concurrent capture must
        // still be waiting when the checkpoint below runs.
        let slowCapture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                recorder.record(pid)
            }
        )
        let queuedCapture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                recorder.record(pid)
                box.pasteboard.clearContents()
                box.pasteboard.setString("queued-\(pid ?? -1)", forType: .string)
            }
        )

        let slowTask = Task { await slowCapture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 111)) }
        let queuedTask = Task { await queuedCapture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 222)) }

        try? await Task.sleep(nanoseconds: 150_000_000)
        // Only the first capture has posted its copy so far.
        XCTAssertEqual(recorder.recordedCalls, [111])

        let slowResult = await slowTask.value
        let queuedResult = await queuedTask.value

        XCTAssertNotNil(slowResult.failureReason)
        // The queued capture posted its own copy and read it back successfully.
        XCTAssertNil(queuedResult.failureReason)
        XCTAssertEqual(queuedResult.text, "queued-222")
        XCTAssertEqual(recorder.recordedCalls, [111, 222])
    }

    func testCancelledWhileQueuedCaptureNeverSendsCopy() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()

        // The slow capture records but writes nothing, holding the gate while
        // the queued capture waits behind it.
        let slowCapture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                recorder.record(pid)
            }
        )
        let queuedCapture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                recorder.record(pid)
                box.pasteboard.clearContents()
                box.pasteboard.setString("queued", forType: .string)
            }
        )

        let slowTask = Task { await slowCapture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 111)) }
        let queuedTask = Task { await queuedCapture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 222)) }

        try? await Task.sleep(nanoseconds: 100_000_000)
        queuedTask.cancel()

        let queuedResult = await queuedTask.value
        // The queued capture was cancelled while waiting for the gate (or at
        // its first checkpoint) and must not have posted a second ⌘C.
        XCTAssertEqual(recorder.recordedCalls, [111])
        XCTAssertNotNil(queuedResult.failureReason)

        let slowResult = await slowTask.value
        XCTAssertNotNil(slowResult.failureReason)
        XCTAssertEqual(recorder.recordedCalls, [111])
    }

    // MARK: - Unattributed clipboard changes

    func testUnrelatedClipboardWriteIsNeverRestored() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let capture = makeCapture(pasteboard: pasteboard) { _ in
            // The targeted copy failed, while another app wrote to the board.
            box.pasteboard.clearContents()
            box.pasteboard.setString("other-app", forType: .string)
        }
        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertEqual(pasteboard.string(forType: .string), "other-app")
        XCTAssertEqual(result.text, "other-app")
    }

    // MARK: - SerializedAppleScriptRunner

    func testAppleScriptRunnerExecutesHarmlessScript() async throws {
        let runner = SerializedAppleScriptRunner()
        let value = try await runner.execute("1 + 1")
        XCTAssertEqual(value, "2")
    }

    func testAppleScriptRunnerTimesOutAndSubsequentRunRecovers() async {
        let runner = SerializedAppleScriptRunner()
        let start = Date()

        do {
            _ = try await runner.execute("delay 3", timeout: 0.2)
            XCTFail("Expected the runner to time out")
        } catch let error as SerializedAppleScriptRunner.ExecutionError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)

        // The timed-out run must release the serial execution gate and
        // terminate its osascript child so later runs work.
        let recovered = try? await runner.execute("2 * 3")
        XCTAssertEqual(recovered, "6")
    }

    func testAppleScriptRunnerDrainsLargeOutput() async throws {
        let runner = SerializedAppleScriptRunner(timeout: 3)
        let output = try await runner.execute("set x to \"a\"\nrepeat 17 times\nset x to x & x\nend repeat\nreturn x")
        XCTAssertEqual(output?.count, 131072)
    }

    func testCancelledAppleScriptReleasesSerialTurn() async throws {
        let runner = SerializedAppleScriptRunner()
        let task = Task { try await runner.execute("delay 3") }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The next run may start only after the cancelled child exits.
        }

        let value = try await runner.execute("2 * 3")
        XCTAssertEqual(value, "6")
    }
}
