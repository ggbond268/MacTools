import AppKit
import ApplicationServices
import Carbon
import Foundation
import MacToolsPluginKit

/// Captures selected text by simulating a single ⌘C and reading the pasteboard.
///
/// Safety properties required by the capture pipeline:
/// - Concurrent captures are serialized: only one simulated copy is ever in
///   flight, and a cancelled waiter releases the turn instead of wedging it.
/// - Exactly one ⌘C is posted per capture, either to the frontmost process or
///   to the session tap — never both.
/// - The clipboard is restored only when the user has not copied anything
///   else in the meantime (pasteboard change-count guard).
/// - The System Events AppleScript fallback runs off the main thread through
///   `SerializedAppleScriptRunner` with a watchdog timeout.
struct SimulatedCopySelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .simulatedCopy

    /// Posts one simulated ⌘C. A positive process identifier delivers the
    /// keystroke to that process only; otherwise the event goes to the session
    /// tap. Exactly one destination is used per call.
    typealias CopyEventSender = @Sendable (pid_t?) -> Void

    /// AppleScript fallback invoked when the primary CGEvent path made no
    /// pasteboard change. Runs off the main actor.
    typealias AppleScriptFallback = @Sendable () async -> Void

    /// Supplies the pid of the current frontmost application so the fallback
    /// can verify that the captured target still has focus before an
    /// untargeted System Events keystroke is sent.
    typealias FrontmostPIDProvider = @Sendable () -> pid_t?

    /// Supplies the pasteboard to observe (tests use a private pasteboard).
    typealias PasteboardProvider = @Sendable () -> NSPasteboard

    private static let gate = CaptureSerializationGate()

    private let localization: PluginLocalization
    private let copyEventSender: CopyEventSender
    private let appleScriptFallback: AppleScriptFallback
    private let frontmostPIDProvider: FrontmostPIDProvider
    private let pasteboardProvider: PasteboardProvider
    private let pasteboardChangeTimeout: TimeInterval

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        copyEventSender: @escaping CopyEventSender = SimulatedCopySelectedTextCapture.postCommandC,
        appleScriptFallback: @escaping AppleScriptFallback = SimulatedCopySelectedTextCapture.runAppleScriptFallback,
        frontmostPIDProvider: @escaping FrontmostPIDProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        pasteboardProvider: @escaping PasteboardProvider = { NSPasteboard.general },
        pasteboardChangeTimeout: TimeInterval = 0.35
    ) {
        self.localization = localization
        self.copyEventSender = copyEventSender
        self.appleScriptFallback = appleScriptFallback
        self.frontmostPIDProvider = frontmostPIDProvider
        self.pasteboardProvider = pasteboardProvider
        self.pasteboardChangeTimeout = pasteboardChangeTimeout
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        guard AccessibilityCheck.isTrusted() else {
            return failure(
                context: context,
                reason: localization.string("capture.error.permissionRequired", defaultValue: "需要辅助功能授权")
            )
        }

        let acquiredTurn = await Self.gate.waitTurn()
        guard acquiredTurn else {
            // Cancelled while waiting for an in-flight capture; nothing was
            // sent, so there is nothing to restore.
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }
        defer { Task { await Self.gate.finishTurn() } }

        let pasteboard = pasteboardProvider()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        await Self.waitForModifierKeysToClear()

        if Task.isCancelled {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        // Single ⌘C: the sender picks exactly one destination.
        copyEventSender(context.frontmostApplicationProcessIdentifier)

        // The detected change count is recorded the moment the pasteboard
        // changes, so a later user copy produces a different count and the
        // restore step can detect it.
        var capturedChangeCount = await Self.waitForPasteboardChange(
            from: baselineChangeCount,
            in: pasteboard,
            timeout: pasteboardChangeTimeout
        )
        if capturedChangeCount == nil && !Task.isCancelled {
            // Fallback through System Events for apps that filter synthetic
            // CGEvents. The keystroke is untargeted, so it may only run while
            // the host-captured target is still frontmost; when the target is
            // unknown (nil pid) or focus has moved elsewhere the retry is
            // skipped instead of risking a copy from an unrelated app. The
            // script runs off the main thread, bounded by the serialized
            // runner's watchdog.
            if isCapturedTargetStillFrontmost(context) {
                await appleScriptFallback()
                capturedChangeCount = await Self.waitForPasteboardChange(
                    from: baselineChangeCount,
                    in: pasteboard,
                    timeout: pasteboardChangeTimeout
                )
            }
        }

        let text = pasteboard.string(forType: .string)

        // Restore only when the pasteboard still holds exactly what the
        // simulated copy produced; never clobber content the user copied
        // after we did. When nothing changed there is nothing to restore.
        let restored = Self.restoreIfUnchanged(
            snapshot: snapshot,
            expectedChangeCount: capturedChangeCount,
            pasteboard: pasteboard
        )
        if !restored {
            return failure(
                context: context,
                reason: localization.string("capture.error.restorePasteboardFailed", defaultValue: "无法恢复剪贴板")
            )
        }

        if Task.isCancelled {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        guard capturedChangeCount != nil, let text, !text.isEmpty else {
            // No pasteboard change means the simulated copy never happened.
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        return SelectedTextCaptureResult(
            text: text,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: nil,
            // Pasteboard content cannot be attributed: a change count only
            // proves that something changed. The coordinator must show this
            // text for confirmation instead of sending it to the provider.
            requiresUserConfirmation: true
        )
    }

    /// The System Events fallback keystroke is untargeted, so it must only run
    /// while the process the host captured is still the frontmost app. A nil
    /// captured pid can never be verified and is treated as not frontmost.
    private func isCapturedTargetStillFrontmost(_ context: SelectedTextCaptureContext) -> Bool {
        guard let capturedPID = context.frontmostApplicationProcessIdentifier, capturedPID > 0 else {
            return false
        }
        return frontmostPIDProvider() == capturedPID
    }

    /// Restores the snapshot only when the pasteboard still holds exactly what
    /// the simulated copy produced (same change count). Returns false without
    /// touching the pasteboard when the user copied something else meanwhile.
    /// A nil expected count means our copy never modified the pasteboard, so
    /// there is nothing to restore and the clipboard is left untouched.
    @MainActor
    static func restoreIfUnchanged(
        snapshot: PasteboardSnapshot,
        expectedChangeCount: Int?,
        pasteboard: NSPasteboard
    ) -> Bool {
        guard let expectedChangeCount else { return true }
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        return snapshot.restore(to: pasteboard)
    }

    // MARK: - Default seams

    nonisolated private static func postCommandC(pid: pid_t?) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: false
              )
        else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if let pid, pid > 0 {
            // Deliver to the frontmost process only; also posting to the
            // session tap would trigger the copy twice.
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            return
        }

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    nonisolated private static func runAppleScriptFallback() async {
        _ = try? await SerializedAppleScriptRunner.shared.execute(
            "tell application \"System Events\" to keystroke \"c\" using command down"
        )
    }

    // MARK: - Helpers

    /// Polls until the pasteboard changes away from `baselineChangeCount`.
    /// Returns the change count observed at the moment the change was first
    /// detected (before the settle delay), or nil on timeout/cancellation.
    @MainActor
    private static func waitForPasteboardChange(
        from baselineChangeCount: Int,
        in pasteboard: NSPasteboard,
        timeout: TimeInterval
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled {
                return nil
            }
            if pasteboard.changeCount != baselineChangeCount {
                let detectedChangeCount = pasteboard.changeCount
                // Give the writing application a moment to finish populating
                // pasteboard data before we read it.
                try? await Task.sleep(nanoseconds: 20_000_000)
                return detectedChangeCount
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    @MainActor
    private static func waitForModifierKeysToClear() async {
        let trackedModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(0.2)

        while Date() < deadline {
            if Task.isCancelled {
                return
            }
            let current = CGEventSource.flagsState(.combinedSessionState)
            if current.intersection(trackedModifiers).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func failure(context: SelectedTextCaptureContext, reason: String) -> SelectedTextCaptureResult {
        SelectedTextCaptureResult(
            text: nil,
            strategyID: strategyID,
            isEditable: false,
            sourceApplicationBundleID: context.frontmostApplicationBundleID,
            failureReason: reason
        )
    }
}

/// Serializes simulated-copy operations: one capture in flight at a time.
///
/// Waiters are granted the turn in FIFO order. A waiter whose task is
/// cancelled while queued is dequeued and never granted the turn, so
/// cancellation cannot wedge the gate; a granted-but-cancelled holder still
/// calls `finishTurn` promptly (the capture flow checks `Task.isCancelled`
/// right after acquiring and on every later branch).
private actor CaptureSerializationGate {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []
    /// Markers for cancellations that raced ahead of continuation registration.
    private var cancelledBeforeQueued: Set<UInt64> = []
    private var nextWaiterID: UInt64 = 0

    /// Returns true when the caller acquired this round's turn, false when the
    /// caller was cancelled while waiting (it then owns no turn).
    func waitTurn() async -> Bool {
        if !isBusy {
            isBusy = true
            return true
        }

        let id = nextWaiterID
        nextWaiterID += 1

        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if cancelledBeforeQueued.remove(id) != nil {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return granted
    }

    func finishTurn() {
        guard isBusy else { return }
        guard let next = waiters.first else {
            isBusy = false
            return
        }
        waiters.removeFirst()
        isBusy = true
        next.continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            // Not queued yet: remember the cancellation so registration can
            // resolve it immediately.
            cancelledBeforeQueued.insert(id)
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
