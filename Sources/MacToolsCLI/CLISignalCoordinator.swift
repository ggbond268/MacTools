import Darwin
import Foundation

final class CLISignalCoordinator {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var handled = false

    init(onSignal: @escaping @Sendable () -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let shouldHandle = lock.withLock {
                    guard !handled else { return false }
                    handled = true
                    return true
                }
                if shouldHandle { onSignal() }
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
