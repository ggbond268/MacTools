import Foundation

/// Runs AppleScript source in a short-lived `/usr/bin/osascript` child process.
///
/// A hung AppleScript (for example one stuck behind a modal system dialog) can
/// no longer block later runs: both the timeout watchdog and task cancellation
/// terminate the child process, so a timed-out script actually stops executing
/// instead of being abandoned on a queue. There is no queue rotation because
/// runs are serialized through a cancel-aware gate that never wedges: each run
/// owns its process, and a terminated run releases its turn immediately.
final class SerializedAppleScriptRunner: @unchecked Sendable {
    enum ExecutionError: Error, Equatable {
        case invalidScript
        case executionFailed
        case timeout
    }

    static let shared = SerializedAppleScriptRunner()

    static let defaultTimeout: TimeInterval = 1.0

    private let gate = AppleScriptExecutionGate()
    private let defaultTimeout: TimeInterval

    init(timeout: TimeInterval = SerializedAppleScriptRunner.defaultTimeout) {
        self.defaultTimeout = timeout
    }

    /// Executes AppleScript source off the main thread and returns the
    /// trimmed stdout (nil when the script produces no output). Throws
    /// `.timeout` when the script does not finish within `timeout` (or the
    /// runner default). Cancelling the surrounding task terminates the child
    /// process and throws `CancellationError`.
    func execute(_ source: String, timeout: TimeInterval? = nil) async throws -> String? {
        let effectiveTimeout = timeout ?? defaultTimeout

        guard await gate.waitTurn() else {
            // Cancelled while queued: no script was started.
            throw CancellationError()
        }
        defer {
            Task { await gate.finishTurn() }
        }

        try Task.checkCancellation()

        guard !source.isEmpty else {
            throw ExecutionError.invalidScript
        }

        let box = AppleScriptRunBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if box.begin(continuation: continuation) {
                    do {
                        let process = try Self.launchScriptProcess(source: source, box: box)
                        box.adopt(process: process)
                        Self.scheduleWatchdog(process: process, box: box, timeout: effectiveTimeout)
                    } catch {
                        box.launchFailed()
                    }
                } else {
                    // Cancellation won the race before the continuation was
                    // registered, so this body resumes it instead.
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            box.cancelRun()
        }
    }

    // MARK: - Process plumbing

    private static func launchScriptProcess(
        source: String,
        box: AppleScriptRunBox
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        // Keep stdin/stderr closed so no script can block on unread pipes.
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.terminationHandler = { [box] process in
            box.processDidTerminate(process, stdout: stdout)
        }
        try process.run()
        return process
    }

    private static func scheduleWatchdog(
        process: Process,
        box: AppleScriptRunBox,
        timeout: TimeInterval
    ) {
        guard timeout > 0 else {
            box.timeOutRun()
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) { [weak process] in
            guard let process, process.isRunning else { return }
            box.timeOutRun()
        }
    }
}

/// Cancel-aware serialization for script runs: one run in flight at a time.
///
/// Mirrors `CaptureSerializationGate`: waiters are granted the turn in FIFO
/// order, and a waiter whose task is cancelled while queued is dequeued and
/// never granted the turn, so cancellation cannot wedge the gate.
private actor AppleScriptExecutionGate {
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

        return await withTaskCancellationHandler {
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

/// Owns one run's process + continuation. Guarantees the awaiter is resumed
/// exactly once and the child process is terminated on watchdog fire or task
/// cancellation, so the script cannot keep executing after its caller gave up.
private final class AppleScriptRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<String?, any Error>?
    private var didResume = false

    /// Registers the continuation. Returns false when the run was already
    /// resolved by a racing cancellation, in which case the caller owns
    /// resuming the passed continuation itself.
    func begin(continuation: CheckedContinuation<String?, any Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        self.continuation = continuation
        return true
    }

    func adopt(process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    /// Watchdog fired: resume with `.timeout` and stop the script.
    func timeOutRun() {
        resumeAndTerminate(throwing: SerializedAppleScriptRunner.ExecutionError.timeout)
    }

    /// Surrounding task cancelled: resume with `CancellationError` and stop
    /// the script.
    func cancelRun() {
        resumeAndTerminate(throwing: CancellationError())
    }

    /// The child could not be launched.
    func launchFailed() {
        lock.lock()
        defer { lock.unlock() }
        resumeLocked(throwing: SerializedAppleScriptRunner.ExecutionError.executionFailed)
        process = nil
    }

    /// The child exited on its own (watchdog/cancel completions are no-ops).
    func processDidTerminate(_ process: Process, stdout: Pipe) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else {
            self.process = nil
            return
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        didResume = true
        if process.terminationStatus == 0 {
            continuation?.resume(returning: output?.isEmpty == false ? output : nil)
        } else {
            continuation?.resume(throwing: SerializedAppleScriptRunner.ExecutionError.executionFailed)
        }
        continuation = nil
        self.process = nil
    }

    private func resumeAndTerminate(throwing error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        resumeLocked(throwing: error)
        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }
    }

    /// Must be called while holding `lock`.
    private func resumeLocked(throwing error: any Error) {
        guard !didResume else { return }
        didResume = true
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
