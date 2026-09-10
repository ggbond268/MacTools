import AppKit

/// Serializes capture modes and invalidates pending startup work when the plugin is disabled.
@MainActor
final class ScreenshotCoordinator {
    var onStateChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var isBusy: Bool { controller != nil || recorder != nil || scrollSession != nil || startupTask != nil }
    var isRecording: Bool { recorder != nil }
    var isScrolling: Bool { scrollSession != nil }

    private let environment: ScreenshotEnvironment
    private var controller: CaptureController?
    private var recorder: AnyObject?
    private var scrollSession: ScrollSession?
    private var startupTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(environment: ScreenshotEnvironment) { self.environment = environment }

    func capture(quick: Bool) {
        if #available(macOS 15, *), let recorder = recorder as? Recorder { recorder.stop(); return }
        if let scrollSession { scrollSession.finish(); return }
        guard !isBusy else { return }
        generation &+= 1
        let requestGeneration = generation
        let controller = CaptureController(quick: quick, environment: environment)
        self.controller = controller
        controller.onFinish = { [weak self] in
            guard let self, generation == requestGeneration else { return }
            self.controller = nil
            onStateChange?()
        }
        controller.onError = { [weak self] message in
            guard let self, generation == requestGeneration else { return }
            report(message)
        }
        controller.onRecord = { [weak self] request in
            guard let self, generation == requestGeneration else { return }
            startRecording(request)
        }
        controller.onScroll = { [weak self] request, rect in
            guard let self, generation == requestGeneration else { return }
            startScroll(request, outline: rect)
        }
        onStateChange?()
        controller.start()
    }

    func cancel() {
        generation &+= 1
        startupTask?.cancel()
        startupTask = nil
        controller?.onFinish = nil
        controller?.dismiss()
        controller = nil
        scrollSession?.onFinish = nil
        scrollSession?.cancel()
        scrollSession = nil
        if #available(macOS 15, *), let recorder = recorder as? Recorder { recorder.cancel() }
        recorder = nil
        environment.closeAll()
        onStateChange?()
    }

    private func startRecording(_ request: RecordRequest) {
        guard #available(macOS 15, *) else {
            report(environment.string("record.requiresNewerSystem", "录屏需要 macOS 15 或更高版本"))
            return
        }
        let requestGeneration = generation
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration { startupTask = nil; onStateChange?() }
            }
            do {
                let recorder = try await Recorder.start(request: request, environment: environment)
                guard generation == requestGeneration, !Task.isCancelled else { recorder.cancel(); return }
                self.recorder = recorder
                recorder.onFinish = { [weak self] result in
                    guard let self, generation == requestGeneration else { return }
                    self.recorder = nil
                    onStateChange?()
                    switch result {
                    case .success(let url):
                        let folderName = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
                        environment.showToast(environment.format("record.saved", "录屏已保存到「%@」", folderName))
                    case .failure(let error):
                        report(environment.format("record.failed", "录屏失败：%@", recordingErrorDescription(error)))
                    }
                }
            } catch {
                guard generation == requestGeneration, !Task.isCancelled, !(error is CancellationError) else { return }
                report(environment.format("record.startFailed", "录屏启动失败：%@", recordingErrorDescription(error)))
            }
        }
        onStateChange?()
    }

    private func startScroll(_ request: RecordRequest, outline: NSRect) {
        let requestGeneration = generation
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration { startupTask = nil; onStateChange?() }
            }
            do {
                let session = try await ScrollSession.start(request: request, outline: outline, environment: environment)
                guard generation == requestGeneration, !Task.isCancelled else { session.cancel(); return }
                scrollSession = session
                session.onFinish = { [weak self] result in
                    guard let self, generation == requestGeneration else { return }
                    scrollSession = nil
                    onStateChange?()
                    switch result {
                    case .success(let image):
                        if let image { ScreenshotOutput.finishLong(image, scale: request.scale, environment: environment) }
                    case .failure(let error):
                        report(environment.format("scroll.failed", "滚动截图失败：%@", scrollErrorDescription(error)))
                    }
                }
            } catch {
                guard generation == requestGeneration, !Task.isCancelled, !(error is CancellationError) else { return }
                report(environment.format("scroll.startFailed", "滚动截图启动失败：%@", captureErrorDescription(error)))
            }
        }
        onStateChange?()
    }

    private func recordingErrorDescription(_ error: Error) -> String {
        switch error {
        case RecordingError.finishTimedOut:
            return environment.string("record.finishTimedOut", "等待录屏文件写入完成超时，文件可能不完整")
        case RecordingError.endedDuringStartup:
            return environment.string("record.endedDuringStartup", "录屏在启动完成前结束")
        default: return captureErrorDescription(error)
        }
    }

    private func scrollErrorDescription(_ error: Error) -> String {
        switch error {
        case ScrollCaptureError.noFrames:
            return environment.string("scroll.noFrames", "尚未采集到图片，请稍后重试")
        case ScrollCaptureError.compositionFailed:
            return environment.string("scroll.compositionFailed", "无法合成长截图，请缩小截图范围后重试")
        default: return captureErrorDescription(error)
        }
    }

    private func captureErrorDescription(_ error: Error) -> String {
        if error is ScreenshotControlError {
            return environment.string("capture.controlsNotReady", "截图控制窗口尚未就绪，请重试")
        }
        return error.localizedDescription
    }

    private func report(_ message: String) {
        onError?(message)
        environment.showToast(message)
    }
}
