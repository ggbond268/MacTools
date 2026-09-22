import Foundation

/// Runs AppleScript source on a private serial queue with a timeout watchdog.
///
/// A hung AppleScript (for example one stuck behind a modal system dialog)
/// must not block later runs: when a run times out, the runner rotates onto a
/// fresh queue so the abandoned work item keeps only the old queue to itself.
/// Late results from a timed-out run are dropped by a per-run continuation
/// box, so a timed-out caller is resumed exactly once.
final class SerializedAppleScriptRunner: @unchecked Sendable {
    /// Identity of one queued run. The watchdog uses it to decide whether the
    /// queue still needs rotating for this particular run.
    struct RunToken: Equatable, Sendable {
        fileprivate let runID: Int
    }

    enum ExecutionError: Error, Equatable {
        case invalidScript
        case executionFailed
        case timeout
    }

    static let shared = SerializedAppleScriptRunner()

    static let defaultTimeout: TimeInterval = 1.0

    private let lock = NSLock()
    private var queue: DispatchQueue
    private let queueLabel: String
    private var nextRunID = 0
    private var lastRotatedRunID = -1
    private let defaultTimeout: TimeInterval

    init(
        timeout: TimeInterval = SerializedAppleScriptRunner.defaultTimeout,
        queueLabel: String = "com.mactools.aiassistant.applescript"
    ) {
        self.defaultTimeout = timeout
        self.queueLabel = queueLabel
        self.queue = DispatchQueue(label: queueLabel)
    }

    /// Executes AppleScript source off the main thread. Throws `.timeout` when
    /// the script does not finish within `timeout` (or the runner default).
    func execute(_ source: String, timeout: TimeInterval? = nil) async throws -> String? {
        let effectiveTimeout = timeout ?? defaultTimeout

        return try await withCheckedThrowingContinuation { continuation in
            let (token, workQueue) = beginRun()
            let box = SerializedAppleScriptContinuationBox()

            workQueue.async {
                guard let appleScript = NSAppleScript(source: source) else {
                    box.resume(continuation, throwing: ExecutionError.invalidScript)
                    return
                }

                var errorInfo: NSDictionary?
                let descriptor = appleScript.executeAndReturnError(&errorInfo)
                if errorInfo != nil {
                    box.resume(continuation, throwing: ExecutionError.executionFailed)
                } else {
                    box.resume(continuation, returning: descriptor.stringValue)
                }
            }

            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: SerializedAppleScriptRunner.nanoseconds(effectiveTimeout))
                guard let self else { return }
                let didTimeOut = box.resume(continuation, throwing: ExecutionError.timeout)
                if didTimeOut {
                    self.rotateQueueIfStuck(token)
                }
            }
        }
    }

    // MARK: - Internals

    private func beginRun() -> (RunToken, DispatchQueue) {
        lock.lock()
        defer { lock.unlock() }
        let token = RunToken(runID: nextRunID)
        nextRunID += 1
        return (token, queue)
    }

    /// Rotates to a fresh queue once per timed-out run so the next run is not
    /// stuck behind the abandoned work item.
    private func rotateQueueIfStuck(_ token: RunToken) {
        lock.lock()
        defer { lock.unlock() }
        guard token.runID > lastRotatedRunID else { return }
        lastRotatedRunID = token.runID
        queue = DispatchQueue(label: "\(queueLabel).rotated-\(token.runID)")
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(interval, 0) * 1_000_000_000)
    }
}

/// Once-only continuation guard: exactly one of the racing completions (script
/// result or watchdog timeout) resumes the awaiter, and the loser is dropped.
private final class SerializedAppleScriptContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    @discardableResult
    func resume(
        _ continuation: CheckedContinuation<String?, any Error>,
        returning value: String?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return false }
        didResume = true
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(
        _ continuation: CheckedContinuation<String?, any Error>,
        throwing error: any Error
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return false }
        didResume = true
        continuation.resume(throwing: error)
        return true
    }
}
