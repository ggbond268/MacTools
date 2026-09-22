import AppKit
import XCTest

@testable import AIAssistantPlugin

/// Behavioral coverage for the hardened simulated-copy capture:
/// serialization, single ⌘C destination, cancellation, AppleScript fallback
/// boundaries, and the never-clobber-the-user's-clipboard restore guard.
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

    /// Thread-safe counter for AppleScript fallback invocations.
    private final class FallbackCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
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
        fallback: @escaping SimulatedCopySelectedTextCapture.AppleScriptFallback = {},
        pasteboardChangeTimeout: TimeInterval = 0.3
    ) -> SimulatedCopySelectedTextCapture {
        let box = PasteboardBox(pasteboard)
        return SimulatedCopySelectedTextCapture(
            copyEventSender: sender,
            appleScriptFallback: fallback,
            pasteboardProvider: { box.pasteboard },
            pasteboardChangeTimeout: pasteboardChangeTimeout
        )
    }

    // MARK: - Success path

    func testCaptureReturnsTextAndRestoresOriginalClipboard() async {
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
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
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

    func testNoFrontmostPIDFallsBackToSessionTapDestination() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()
        let capture = makeCapture(pasteboard: pasteboard) { pid in
            recorder.record(pid)
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
        }

        let result = await capture.capture(context: SelectedTextCaptureContext())

        // A nil process identifier means the sender used the session tap;
        // the important boundary is that exactly one destination was used.
        XCTAssertEqual(recorder.recordedCalls, [nil])
        XCTAssertEqual(result.text, "captured")
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

    // MARK: - AppleScript fallback boundaries

    func testFallbackRunsOnlyWhenPrimaryCopyMakesNoPasteboardChange() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let counter = FallbackCounter()
        let capture = makeCapture(pasteboard: pasteboard, fallback: { counter.increment() })

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertNil(result.text)
        XCTAssertNotNil(result.failureReason)
        XCTAssertEqual(counter.total, 1)
        // Nothing was captured, so the clipboard content stays untouched.
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testFallbackSkippedWhenPrimaryCopySucceeds() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let counter = FallbackCounter()
        let capture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                _ = pid
                box.pasteboard.clearContents()
                box.pasteboard.setString("captured", forType: .string)
            },
            fallback: { counter.increment() }
        )

        let result = await capture.capture(context: SelectedTextCaptureContext(frontmostApplicationProcessIdentifier: 4242))

        XCTAssertEqual(result.text, "captured")
        XCTAssertEqual(counter.total, 0)
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
            appleScriptFallback: {},
            pasteboardProvider: {
                withUnsafeCurrentTask { task in task?.cancel() }
                return box.pasteboard
            },
            pasteboardChangeTimeout: 0.3
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
        let counter = FallbackCounter()

        // A capture whose sender records but deliberately writes nothing holds
        // the gate through both pasteboard waits (~0.6s with the short
        // timeout), so any concurrent capture must still be waiting when the
        // checkpoint below runs.
        let slowCapture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                recorder.record(pid)
            },
            fallback: { counter.increment() }
        )
        let queuedCapture = makeCapture(
            pasteboard: pasteboard,
            sender: { pid in
                recorder.record(pid)
                box.pasteboard.clearContents()
                box.pasteboard.setString("queued-\(pid ?? -1)", forType: .string)
            },
            fallback: { counter.increment() }
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
        // Only the slow capture fell back; the queued one copied successfully.
        XCTAssertEqual(counter.total, 1)
    }

    func testCancelledWhileQueuedCaptureNeverSendsCopy() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)
        let recorder = CallRecorder()

        // The slow capture records but writes nothing, holding the gate for
        // both pasteboard waits while the queued capture waits behind it.
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

    // MARK: - Restore guard (never clobber the user's clipboard)

    func testRestoreProceedsWhenPasteboardUnchangedSinceCapture() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)

        let (snapshot, detectedCount) = await MainActor.run {
            let snapshot = PasteboardSnapshot.capture(from: box.pasteboard)
            // The simulated copy starts a new change session.
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
            return (snapshot, box.pasteboard.changeCount)
        }

        let restored = await SimulatedCopySelectedTextCapture.restoreIfUnchanged(
            snapshot: snapshot,
            expectedChangeCount: detectedCount,
            pasteboard: pasteboard
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoreSkippedWhenUserCopiedAfterCapture() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)

        let (snapshot, detectedCount) = await MainActor.run {
            let snapshot = PasteboardSnapshot.capture(from: box.pasteboard)
            // The simulated copy starts a new change session.
            box.pasteboard.clearContents()
            box.pasteboard.setString("captured", forType: .string)
            let detected = box.pasteboard.changeCount
            // The user copies something else after our simulated copy; that
            // copy is its own change session.
            box.pasteboard.clearContents()
            box.pasteboard.setString("user-copy", forType: .string)
            return (snapshot, detected)
        }

        let restored = await SimulatedCopySelectedTextCapture.restoreIfUnchanged(
            snapshot: snapshot,
            expectedChangeCount: detectedCount,
            pasteboard: pasteboard
        )

        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "user-copy")
    }

    func testRestoreSkippedWhenPasteboardNeverChanged() async {
        let pasteboard = makePrivatePasteboard(content: "original")
        let box = PasteboardBox(pasteboard)

        let snapshot = await MainActor.run {
            PasteboardSnapshot.capture(from: box.pasteboard)
        }

        // A nil expected count means our copy never modified the pasteboard;
        // restoring would needlessly bump the change count.
        let restored = await SimulatedCopySelectedTextCapture.restoreIfUnchanged(
            snapshot: snapshot,
            expectedChangeCount: nil,
            pasteboard: pasteboard
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
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

        // The watchdog must rotate the stuck queue so later runs work.
        let recovered = try? await runner.execute("2 * 3")
        XCTAssertEqual(recovered, "6")
    }
}
