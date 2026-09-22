import Foundation

/// File completion and stream termination are independent acknowledgements, in either order.
@MainActor
final class RecordingLifecycle {
    enum Phase { case starting, recording, stopping, finalizing, waiting, finished }
    private(set) var phase = Phase.starting { didSet { onPhaseChange?(phase) } }
    private(set) var result: Result<URL, Error>?
    var onPhaseChange: ((Phase) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    private let stopCapture: () -> Void
    private let finishWarningDelay: Duration
    private var captureEnded = false
    private var fileResult: Result<URL, Error>?
    private var captureFailure: Error?
    private var cancelled = false
    private var warningTask: Task<Void, Never>?

    init(finishWarningDelay: Duration = .seconds(30), stopCapture: @escaping () -> Void) {
        self.finishWarningDelay = finishWarningDelay
        self.stopCapture = stopCapture
    }

    func recordingStarted() {
        guard phase == .starting else { return }
        phase = .recording
    }

    func stop() {
        guard result == nil, !captureEnded, phase != .stopping else { return }
        phase = .stopping
        stopCapture()
    }

    func waitingForCapture() {
        guard result == nil, !captureEnded else { return }
        phase = .waiting
    }

    func fileCompleted(_ result: Result<URL, Error>) {
        guard self.result == nil, fileResult == nil else { return }
        fileResult = result
        if !captureEnded { stop() }
        settle()
    }

    func captureStopped(_ result: Result<Void, Error>) {
        guard self.result == nil, !captureEnded else { return }
        captureEnded = true
        if case .failure(let error) = result { captureFailure = error }
        if fileResult != nil { settle(); return }
        phase = .finalizing
        warningTask = Task { [weak self, finishWarningDelay] in
            do { try await Task.sleep(for: finishWarningDelay) } catch { return }
            guard let self, self.result == nil else { return }
            // Slow finalization is not evidence that the file is corrupt or that the writer stopped.
            phase = .waiting
        }
    }

    func cancel() {
        guard result == nil else { return }
        cancelled = true
        stop()
        settle()
    }

    func failBeforeCapture(_ error: Error) {
        guard result == nil else { return }
        captureEnded = true
        fileResult = .failure(error)
        settle()
    }

    private func settle() {
        guard result == nil, captureEnded, let fileResult else { return }
        let finalResult: Result<URL, Error>
        if cancelled { finalResult = .failure(CancellationError()) }
        else if let captureFailure { finalResult = .failure(captureFailure) }
        else { finalResult = fileResult }
        result = finalResult
        warningTask?.cancel()
        warningTask = nil
        phase = .finished
        let completion = onFinish
        onFinish = nil
        onPhaseChange = nil
        completion?(finalResult)
    }
}
