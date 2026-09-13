import Foundation

/// Stopping capture is distinct from receiving confirmation that its output file is complete.
@MainActor
final class RecordingLifecycle {
    var onFinish: ((Result<URL, Error>) -> Void)? {
        didSet { deliverResult() }
    }
    private(set) var result: Result<URL, Error>?
    private(set) var isStopping = false

    private var stopCapture: (() async throws -> Void)?
    private let onEnd: () -> Void
    private let finishTimeout: Duration
    private var stopTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var delivered = false

    init(finishTimeout: Duration = .seconds(3),
         stopCapture: @escaping () async throws -> Void,
         onEnd: @escaping () -> Void) {
        self.finishTimeout = finishTimeout
        self.stopCapture = stopCapture
        self.onEnd = onEnd
    }

    func stop() {
        guard result == nil, !isStopping, let stopCapture else { return }
        isStopping = true
        stopTask = Task { [weak self, stopCapture] in
            do { try await stopCapture() }
            catch { self?.finish(.failure(error)) }
        }
        // Bound both a hanging stop request and a missing recording-output callback.
        timeoutTask = Task { [weak self, finishTimeout] in
            do {
                try await Task.sleep(for: finishTimeout)
                try Task.checkCancellation()
                self?.finish(.failure(RecordingError.finishTimedOut))
            } catch { /* Normal completion cancels the timeout. */ }
        }
    }

    func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        stopTask?.cancel()
        timeoutTask?.cancel()
        stopTask = nil
        timeoutTask = nil
        stopCapture = nil
        onEnd()
        deliverResult()
    }

    private func deliverResult() {
        guard !delivered, let result, let onFinish else { return }
        delivered = true
        // Preserve early delegate events until the caller installs its completion handler.
        onFinish(result)
        self.onFinish = nil
    }

    deinit {
        stopTask?.cancel()
        timeoutTask?.cancel()
    }
}

enum RecordingError: Error {
    case finishTimedOut
    case endedDuringStartup
}
