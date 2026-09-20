import ScreenCaptureKit

/// Owns the native stream until stop is acknowledged. Task cancellation is not a stop acknowledgement.
@MainActor
final class CaptureStreamSession: NSObject, SCStreamDelegate {
    private(set) var stream: SCStream!
    var onStarted: (() -> Void)?
    var onStopped: ((Result<Void, Error>) -> Void)?
    var onWaiting: (() -> Void)?
    private(set) var isStopped = false
    private(set) var failedToStart = false
    var canRetryStop: Bool { started && !startPending && !stopPending && !isStopped }
    private var started = false
    private var startPending = false
    private var stopPending = false
    private var stopRequested = false
    private var watchdog: Task<Void, Never>?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func start() {
        guard !started, !isStopped else { return }
        started = true
        startPending = true
        watchProgress()
        stream.startCapture { [self] error in
            Task { @MainActor in
                startPending = false
                if isStopped {
                    // A late successful start must not resurrect an already-ended session.
                    if error == nil { try? await stream.stopCapture() }
                    return
                }
                watchdog?.cancel()
                if let error {
                    failedToStart = true
                    ended(.failure(error))
                    return
                }
                if stopRequested { requestStop() } else { onStarted?() }
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        stopRequested = true
        guard started else { ended(.success(())); return }
        // Starting and stopping are serialized, including cancellation during startup.
        guard !startPending else { return }
        requestStop()
    }

    private func requestStop() {
        guard !isStopped, !stopPending else { return }
        stopPending = true
        watchProgress()
        stream.stopCapture { [self] error in
            Task { @MainActor in
                guard !isStopped else { return }
                stopPending = false
                watchdog?.cancel()
                if error != nil {
                    // Keep the owner and controls alive so stopping can be retried safely.
                    onWaiting?()
                } else { ended(.success(())) }
            }
        }
    }

    private func watchProgress() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !isStopped else { return }
            stopRequested = true
            onWaiting?()
        }
    }

    private func ended(_ result: Result<Void, Error>) {
        guard !isStopped else { return }
        isStopped = true
        watchdog?.cancel()
        watchdog = nil
        let completion = onStopped
        onStopped = nil
        onStarted = nil
        onWaiting = nil
        completion?(result)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in ended(.failure(error)) }
    }
}
