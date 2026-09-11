import AppKit
import MacToolsPluginKit
import ScreenCaptureKit

/// Matches consecutive frames and appends the rows revealed by downward scrolling.
final class Stitcher {
    private(set) var pieces: [CGImage] = []
    private var lastGray: [UInt8] = []      // Horizontal downsampling preserves the original row count.
    private var width = 0, height = 0
    static let cols = 64
    private static let coarseStep = 4       // Sample every fourth row in the coarse search.

    private(set) var totalRows = 0
    private let maximumBytes: Int
    private let maximumHeight: Int

    init(maximumBytes: Int = 128 * 1024 * 1024, maximumHeight: Int = 32_768) {
        self.maximumBytes = maximumBytes
        self.maximumHeight = maximumHeight
    }

    func reset() {
        pieces.removeAll()
        lastGray.removeAll()
        totalRows = 0
        width = 0
        height = 0
    }

    /// Limits retained RGBA pixels before allocating grayscale data or copying a strip.
    private func validate(width: Int, rows: Int) throws {
        guard width > 0, rows > 0, rows <= maximumHeight,
              width <= maximumBytes / 4, rows <= maximumBytes / 4 / width else {
            throw ScrollCaptureError.outputTooLarge
        }
    }

    /// Returns the number of newly appended rows; zero means no new content was found.
    @discardableResult
    func push(_ frame: CGImage) throws -> Int {
        try Task.checkCancellation()
        try validate(width: frame.width, rows: frame.height)
        let gray = Self.grayColumns(frame)
        let replaces = pieces.isEmpty || frame.width != width || frame.height != height
        let added: Int
        if replaces {
            added = frame.height
        } else {
            added = try Self.offset(prev: lastGray, next: gray, height: height) ?? frame.height
        }
        let nextRows = replaces ? added : totalRows + added
        if added > 0 {
            try validate(width: frame.width, rows: nextRows)
            // Cropped CGImages retain their original provider. Draw into an independently
            // allocated bitmap so a few new rows cannot keep an entire capture alive.
            guard let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - added,
                                                        width: frame.width, height: added)),
                  let context = CGContext(data: nil, width: frame.width, height: added,
                                          bitsPerComponent: 8, bytesPerRow: frame.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScrollCaptureError.compositionFailed
            }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: frame.width, height: added))
            guard let copy = context.makeImage() else { throw ScrollCaptureError.compositionFailed }
            try Task.checkCancellation()
            if replaces { pieces = [copy] } else { pieces.append(copy) }
        }
        lastGray = gray
        width = frame.width
        height = frame.height
        totalRows = nextRows
        return added
    }

    func compose() throws -> CGImage? {
        try Task.checkCancellation()
        guard let first = pieces.first else { return nil }
        guard let ctx = CGContext(data: nil, width: first.width, height: totalRows, bitsPerComponent: 8,
                                  bytesPerRow: first.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = 0
        for piece in pieces {
            try Task.checkCancellation()
            ctx.draw(piece, in: CGRect(x: 0, y: totalRows - top - piece.height,
                                      width: piece.width, height: piece.height))
            top += piece.height
        }
        return ctx.makeImage()
    }

    /// Produces a narrow grayscale image with full vertical resolution and a top-left origin.
    static func grayColumns(_ image: CGImage) -> [UInt8] {
        let h = image.height
        var data = [UInt8](repeating: 0, count: cols * h)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: cols, height: h, bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: h))
        }
        return data
    }

    /// Searches all offsets coarsely, then refines near the best match using every row.
    static func offset(prev: [UInt8], next: [UInt8], height h: Int) throws -> Int? {
        let top = h * 12 / 100                        // Ignore fixed headers near the top edge.
        let minOverlap = max(h * 15 / 100, 8)
        let maxDy = h - minOverlap
        guard maxDy > 0 else { return nil }

        return try prev.withUnsafeBufferPointer { p in
            try next.withUnsafeBufferPointer { q in
                func error(_ dy: Int, step: Int) -> Double {
                    var sum = 0, n = 0, y = top
                    while y + dy < h {
                        let a = y * cols, b = (y + dy) * cols
                        for c in 0..<cols { sum += abs(Int(q[a + c]) - Int(p[b + c])) }
                        n += cols
                        y += step
                    }
                    return n == 0 ? .infinity : Double(sum) / Double(n)
                }
                var best = 0, bestErr = Double.infinity
                for dy in 0...maxDy {
                    try Task.checkCancellation()
                    let e = error(dy, step: coarseStep)
                    if e < bestErr { bestErr = e; best = dy }
                }
                let candidate = best
                bestErr = .infinity
                for dy in max(0, candidate - coarseStep)...min(maxDy, candidate + coarseStep) {
                    try Task.checkCancellation()
                    let e = error(dy, step: 1)
                    if e < bestErr { bestErr = e; best = dy }
                }
                return bestErr <= 6 ? best : nil     // Reject mean grayscale errors above 6/255.
            }
        }
    }

}

/// Actor isolation keeps matching, copying, and final composition off the main actor.
actor ScrollStitchingWorker {
    private let stitcher: Stitcher

    init(maximumBytes: Int = 128 * 1024 * 1024, maximumHeight: Int = 32_768) {
        stitcher = Stitcher(maximumBytes: maximumBytes, maximumHeight: maximumHeight)
    }

    func push(_ image: CGImage) throws -> (added: Int, totalRows: Int) {
        let added = try stitcher.push(image)
        return (added, stitcher.totalRows)
    }

    func compose() throws -> CGImage {
        defer { stitcher.reset() }
        guard !stitcher.pieces.isEmpty else { throw ScrollCaptureError.noFrames }
        guard let image = try stitcher.compose() else { throw ScrollCaptureError.compositionFailed }
        return image
    }

    func clear() { stitcher.reset() }
}

/// Capture completion must recheck the session after every suspension point.
@MainActor
final class ScrollCapture {
    var onProgress: ((Double) -> Void)?
    var onFinish: ((Result<CGImage?, Error>) -> Void)?

    private let captureImage: @MainActor () async throws -> CGImage
    private let worker: ScrollStitchingWorker
    private var compositionTask: Task<Void, Never>?
    private var busy = false
    private var processing = false
    private var finishing = false
    private var done = false

    init(worker: ScrollStitchingWorker = ScrollStitchingWorker(),
         captureImage: @escaping @MainActor () async throws -> CGImage) {
        self.worker = worker
        self.captureImage = captureImage
    }

    func tick() async {
        guard !done, !finishing, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let frame = try await captureImage()
            guard !done, !finishing else { return }
            processing = true
            let progress = try await worker.push(frame)
            processing = false
            guard !done else { return }
            if finishing { compose(); return }
            if progress.added > 0 {
                onProgress?(Double(progress.totalRows) / Double(frame.height))
            }
        } catch {
            let wasProcessing = processing
            processing = false
            guard !done, !finishing || wasProcessing else { return }
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

/// Samples user-driven scrolling every 250 ms without synthesizing input events.
@MainActor
final class ScrollSession {
    var onFinish: ((Result<CGImage?, Error>) -> Void)?

    private var capture: ScrollCapture?
    private let outline: OutlineWindow
    private let panel: ScrollPanel
    private let environment: ScreenshotEnvironment
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private var done = false

    static func start(request: RecordRequest, outline: NSRect, environment: ScreenshotEnvironment) async throws -> ScrollSession {
        try Task.checkCancellation()
        let session = ScrollSession(outline: outline, environment: environment)
        do { try await session.begin(request) }
        catch {
            let cancelled = session.done
            session.cancel()
            if cancelled { throw CancellationError() }
            throw error
        }
        return session
    }

    private init(outline frame: NSRect, environment: ScreenshotEnvironment) {
        self.environment = environment
        panel = ScrollPanel(environment: environment)
        outline = OutlineWindow(around: frame)
        environment.registerCaptureControls([outline, panel])
        panel.onDone = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
        // Shareable content must see the control windows before their IDs can be excluded.
        PluginPresentationSafety.prepareForWindowOrdering(outline)
        outline.orderFrontRegardless()
        panel.show(near: frame)
    }

    private func begin(_ request: RecordRequest) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard !done else { throw CancellationError() }
        let controlIDs = try environment.captureControlWindowIDs(availableWindowIDs: Set(content.windows.map(\.windowID)))
        let controls = content.windows.filter { controlIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: request.display, excludingWindows: controls)
        let config = SCStreamConfiguration()
        config.sourceRect = request.sourceRect
        config.width = request.width
        config.height = request.height
        config.showsCursor = false
        let capture = ScrollCapture {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        self.capture = capture
        capture.onProgress = { [weak self] in self?.panel.update(screens: $0) }
        capture.onFinish = { [weak self] in self?.end($0) }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finish() {
        guard let capture else { cancel(); return }
        capture.finish()
    }

    func cancel() {
        if let capture { capture.cancel() } else { end(.success(nil)) }
    }

    private func end(_ result: Result<CGImage?, Error>) {
        guard !done else { return }
        done = true
        timer?.invalidate()
        timer = nil
        captureTask?.cancel()
        captureTask = nil
        environment.removeCaptureControls([outline, panel])
        outline.orderOut(nil)
        panel.orderOut(nil)
        onFinish?(result)
    }

    private func tick() {
        guard !done, captureTask == nil else { return }
        captureTask = Task { [weak self] in
            guard let self, !done else { return }
            defer { captureTask = nil }
            await capture?.tick()
        }
    }
}

/// Draws outside the capture rectangle and leaves input events to the underlying application.
@MainActor
final class OutlineWindow: NSWindow {
    init(around frame: NSRect) {
        let f = frame.insetBy(dx: -3, dy: -3)
        super.init(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = OutlineView(frame: NSRect(origin: .zero, size: f.size))
    }
}

@MainActor
private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        path.stroke()
    }
}

/// Progress, finish, and cancel controls for a scrolling capture.
@MainActor
final class ScrollPanel: NSPanel {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let environment: ScreenshotEnvironment

    init(environment: ScreenshotEnvironment) {
        self.environment = environment
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

        label.stringValue = environment.format("scroll.progress", "在框里向下滚动内容 · 已拼接 %.1f 屏", 0.0)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        box.addArrangedSubview(label)
        let cancel = NSButton(title: environment.string("scroll.cancel", "取消"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        box.addArrangedSubview(cancel)
        let done = NSButton(title: environment.string("scroll.finish", "完成"), target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.controlSize = .small
        box.addArrangedSubview(done)

        let size = box.fittingSize
        setContentSize(size)
        contentView = Glass.wrap(box, radius: size.height / 2, blending: .behindWindow)
    }

    /// Prefer the space below the capture area, falling back to the space above it.
    func show(near region: NSRect) {
        var origin = NSPoint(x: region.midX - frame.width / 2, y: region.minY - 12 - frame.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if origin.y < screen.visibleFrame.minY { origin.y = region.maxY + 12 }
        origin.x = min(max(screen.visibleFrame.minX, origin.x), screen.visibleFrame.maxX - frame.width)
        setFrameOrigin(origin)
        PluginPresentationSafety.prepareForWindowOrdering(self)
        orderFrontRegardless()
    }

    func update(screens: Double) {
        label.stringValue = environment.format("scroll.progress", "在框里向下滚动内容 · 已拼接 %.1f 屏", screens)
        if let size = contentView?.fittingSize { setContentSize(size) }
    }

    @objc private func doneTapped() { onDone?() }
    @objc private func cancelTapped() { onCancel?() }
}
