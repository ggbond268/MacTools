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
/// - Exactly one ⌘C is posted to the host-captured application process.
/// - Clipboard content is never restored automatically: a change count
///   cannot prove which application wrote it.
struct SimulatedCopySelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID = .simulatedCopy

    /// Posts one simulated ⌘C to the captured application process.
    typealias CopyEventSender = @Sendable (pid_t?) -> Void

    /// Supplies the pasteboard to observe (tests use a private pasteboard).
    typealias PasteboardProvider = @Sendable () -> NSPasteboard

    private static let gate = CaptureSerializationGate()

    private let localization: PluginLocalization
    private let copyEventSender: CopyEventSender
    private let pasteboardProvider: PasteboardProvider
    private let pasteboardChangeTimeout: TimeInterval
    private let allowsSimulatedCopy: @MainActor @Sendable () -> Bool

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        copyEventSender: @escaping CopyEventSender = SimulatedCopySelectedTextCapture.postCommandC,
        pasteboardProvider: @escaping PasteboardProvider = { NSPasteboard.general },
        pasteboardChangeTimeout: TimeInterval = 0.35,
        allowsSimulatedCopy: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.localization = localization
        self.copyEventSender = copyEventSender
        self.pasteboardProvider = pasteboardProvider
        self.pasteboardChangeTimeout = pasteboardChangeTimeout
        self.allowsSimulatedCopy = allowsSimulatedCopy
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
        let baselineChangeCount = pasteboard.changeCount

        await Self.waitForModifierKeysToClear()

        if Task.isCancelled || !allowsSimulatedCopy() {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        guard let targetPID = context.frontmostApplicationProcessIdentifier,
              targetPID > 0 else {
            return failure(
                context: context,
                reason: localization.string("capture.error.missingSelection", defaultValue: "未找到选中文本")
            )
        }

        // Single ⌘C to the host-captured target.
        copyEventSender(targetPID)

        // Record the first observed change; reject the result if another
        // write occurs before it is read.
        let capturedChangeCount = await Self.waitForPasteboardChange(
            from: baselineChangeCount,
            in: pasteboard,
            timeout: pasteboardChangeTimeout
        )
        // A change can be caused by another application. Preserve whatever
        // is there and require explicit confirmation before using its text.
        let text = capturedChangeCount == pasteboard.changeCount
            ? pasteboard.string(forType: .string) : nil

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
            failureReason: nil
        )
    }

    // MARK: - Default seams

    nonisolated private static func postCommandC(pid: pid_t?) {
        guard let pid, pid > 0,
              let source = CGEventSource(stateID: .combinedSessionState),
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

        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
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
