import Darwin
import Foundation

final class CLICommandTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int32, Error>?
    private var isCancelled = false

    func install(_ task: Task<Int32, Error>) {
        lock.withLock {
            self.task = task
            if isCancelled { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            task?.cancel()
        }
    }
}

final class CLISignalState: @unchecked Sendable {
    private let lock = NSLock()
    private var handled = false
    private var finished = false

    func beginHandlingSignal() -> Bool {
        lock.withLock {
            guard !handled, !finished else { return false }
            handled = true
            return true
        }
    }

    func beginFinishing() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }
}

final class CLISignalCoordinator {
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [(signal: Int32, handler: sig_t?)] = []
    private let lock = NSLock()
    private let state = CLISignalState()
    private let installSignalHandler: @Sendable (Int32, sig_t?) -> sig_t?
    private let onSignal: @Sendable () -> Void

    init(
        signalNumbers: [Int32] = [SIGINT, SIGTERM],
        installSignalHandler: @escaping @Sendable (Int32, sig_t?) -> sig_t? = {
            signal($0, $1)
        },
        onSignal: @escaping @Sendable () -> Void
    ) {
        self.installSignalHandler = installSignalHandler
        self.onSignal = onSignal
        for signalNumber in signalNumbers {
            let previousHandler = installSignalHandler(signalNumber, SIG_IGN)
            previousHandlers.append((signalNumber, previousHandler))
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.handleSignal()
            }
            source.resume()
            sources.append(source)
        }
    }

    func finish() {
        guard state.beginFinishing() else { return }
        let resources = lock.withLock { () -> (
            sources: [DispatchSourceSignal],
            handlers: [(signal: Int32, handler: sig_t?)]
        ) in
            let resources = (sources, previousHandlers)
            sources = []
            previousHandlers = []
            return resources
        }
        resources.sources.forEach { $0.cancel() }
        resources.handlers.forEach {
            _ = installSignalHandler($0.signal, $0.handler ?? SIG_DFL)
        }
    }

    deinit {
        finish()
    }

    private func handleSignal() {
        if state.beginHandlingSignal() { onSignal() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
