import AppKit
import MacToolsPluginKit
import ScreenCaptureKit

struct RecordRequest {
    let display: SCDisplay
    let sourceRect: CGRect   // Display-local points with a top-left origin.
    let width: Int           // Output pixels.
    let height: Int
    let scale: CGFloat       // Pixels per point, used for image DPI.
}

/// ScreenCaptureKit writes the recording directly to a movie file on macOS 15 and later.
@available(macOS 15, *)
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    var onFinish: ((Result<URL, Error>) -> Void)? {
        get { lifecycle.onFinish }
        set { lifecycle.onFinish = newValue }
    }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private let url: URL
    private let panel: RecordPanel
    private let environment: ScreenshotEnvironment
    private var timer: Timer?
    private var started = Date()
    private var isStarting = true
    private var ended = false
    private var cancelled = false
    private lazy var lifecycle = RecordingLifecycle(
        // Retain the stream until a queued stop can run, even after cleanup clears the property.
        stopCapture: { [stream = self.stream] in try await stream?.stopCapture() },
        onEnd: { [weak self] in self?.cleanUp() }
    )

    static func start(request: RecordRequest, environment: ScreenshotEnvironment) async throws -> Recorder {
        try Task.checkCancellation()
        let recorder = Recorder(environment: environment)
        do { try await recorder.begin(request) }
        catch {
            recorder.lifecycle.finish(.failure(error))
            if recorder.cancelled { throw CancellationError() }
            throw error
        }
        return recorder
    }

    private init(environment: ScreenshotEnvironment) {
        self.environment = environment
        url = environment.fileURL(prefix: environment.string("record.filename", "录屏"), ext: "mov")
        panel = RecordPanel(stopTitle: environment.string("record.stop", "停止"))
        super.init()
    }

    private func begin(_ request: RecordRequest) async throws {
        // Order the control bar first so ScreenCaptureKit can identify its window for exclusion.
        environment.registerCaptureControls([panel])
        panel.onStop = { [weak self] in self?.stop() }
        panel.show()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard !ended else { throw CancellationError() }
        let controlIDs = try environment.captureControlWindowIDs(availableWindowIDs: Set(content.windows.map(\.windowID)))
        let controls = content.windows.filter { controlIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: request.display, excludingWindows: controls)

        let config = SCStreamConfiguration()
        config.sourceRect = request.sourceRect
        config.width = request.width
        config.height = request.height
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        // Delegate callbacks can arrive while startCapture is suspended.
        self.stream = stream
        self.output = output
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        try Task.checkCancellation()
        if let result = lifecycle.result {
            Task { try? await stream.stopCapture() }
            _ = try result.get()
            throw RecordingError.endedDuringStartup
        }

        isStarting = false
        started = Date()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(updateElapsed),
                          userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        if isStarting { cancel(); return }
        hideControls()
        lifecycle.stop()
    }

    func cancel() {
        cancelled = true
        onFinish = nil
        lifecycle.finish(.failure(CancellationError()))
    }

    @objc private func updateElapsed() {
        panel.update(seconds: Int(Date().timeIntervalSince(started)))
    }

    private func hideControls() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func cleanUp() {
        ended = true
        environment.removeCaptureControls([panel])
        hideControls()
        let stream = stream
        if let stream, let output { try? stream.removeRecordingOutput(output) }
        self.stream = nil
        output = nil
        // A failed or cancelled stop needs an independent best-effort cleanup request.
        let failed: Bool
        if case .failure? = lifecycle.result { failed = true } else { failed = false }
        if (!lifecycle.isStopping || failed), let stream {
            Task { try? await stream.stopCapture() }
        }
    }

    // MARK: SCRecordingOutputDelegate / SCStreamDelegate
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in lifecycle.finish(.success(url)) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in lifecycle.finish(.failure(error)) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in lifecycle.finish(.failure(error)) }
    }
}

/// A movable recording control bar that does not activate the application.
@MainActor
final class RecordPanel: NSPanel {
    var onStop: (() -> Void)?
    private let label = NSTextField(labelWithString: "00:00")

    init(stopTitle: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let box = NSStackView()
        box.orientation = .horizontal
        box.spacing = 10
        box.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 8)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        box.addArrangedSubview(dot)

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        box.addArrangedSubview(label)

        let stop = NSButton(title: stopTitle, target: self, action: #selector(stopTapped))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        box.addArrangedSubview(stop)

        let size = box.fittingSize
        setContentSize(size)
        contentView = Glass.wrap(box, radius: size.height / 2, blending: .behindWindow)
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.minY + 24))
        PluginPresentationSafety.prepareForWindowOrdering(self)
        orderFrontRegardless()
    }

    func update(seconds: Int) {
        label.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func stopTapped() { onStop?() }
}
