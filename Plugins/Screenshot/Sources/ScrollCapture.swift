import AppKit

/// Capture completion must recheck the session after every suspension point.
@MainActor
final class ScrollCapture {
    var onProgress: ((Double) -> Void)?
    var onUnmatched: (() -> Void)?
    var onFinish: ((Result<CGImage?, Error>) -> Void)?

    private let worker: ScrollStitchingWorker
    private var compositionTask: Task<Void, Never>?
    private var processing = false
    private var finishing = false
    private var done = false

    init(worker: ScrollStitchingWorker = ScrollStitchingWorker()) {
        self.worker = worker
    }

    func append(_ frame: CGImage) async {
        guard !done, !finishing, !processing else { return }
        processing = true
        do {
            let progress = try await worker.push(frame)
            processing = false
            guard !done else { return }
            if finishing { compose(); return }
            if progress.added > 0 {
                onProgress?(Double(progress.totalRows) / Double(frame.height))
            } else if !progress.matched { onUnmatched?() }
        } catch {
            processing = false
            guard !done else { return }
            if error is CancellationError { cancel() } else { end(.failure(error)) }
        }
    }

    func finish() {
        guard !done, !finishing else { return }
        finishing = true
        // Include an accepted frame before composition, regardless of actor scheduling order.
        guard !processing else { return }
        compose()
    }

    private func compose() {
        compositionTask = Task { [weak self, worker] in
            do {
                let image = try await worker.compose()
                guard !Task.isCancelled else { return }
                self?.end(.success(image))
            } catch {
                guard !Task.isCancelled else { return }
                self?.end(.failure(error))
            }
        }
    }

    func cancel() { end(.success(nil)) }

    private func end(_ result: Result<CGImage?, Error>) {
        guard !done else { return }
        done = true
        compositionTask?.cancel()
        compositionTask = nil
        Task { [worker] in await worker.clear() }
        onFinish?(result)
    }
}

enum ScrollCaptureError: Error {
    case noFrames, compositionFailed, outputTooLarge
}
