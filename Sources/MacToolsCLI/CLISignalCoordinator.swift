import Darwin
import Foundation

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
