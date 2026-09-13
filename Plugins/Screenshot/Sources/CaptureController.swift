import AppKit
import MacToolsPluginKit
import ScreenCaptureKit

/// Freezes each display, then edits the frozen images in plugin-owned overlays.
@MainActor
final class CaptureController {
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    var onRecord: ((RecordRequest) -> Void)?
    var onScroll: ((RecordRequest, NSRect) -> Void)?

    private let quick: Bool
    private let environment: ScreenshotEnvironment
    private var overlays: [OverlayWindow] = []
    private var startTask: Task<Void, Never>?
    private var captureTasks: [Task<CGImage, Error>] = []
    private var finished = false

    init(quick: Bool, environment: ScreenshotEnvironment) {
        self.quick = quick
        self.environment = environment
    }

    func start() {
        guard !finished, startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            defer {
                for task in captureTasks { task.cancel() }
                captureTasks.removeAll()
                startTask = nil
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard !finished else { return }
                let windows = onScreenWindows()
                let targets = NSScreen.screens.compactMap { screen -> (NSScreen, SCDisplay)? in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value })
                    else { return nil }
                    return (screen, display)
                }
                guard !targets.isEmpty else {
                    onError?(environment.string("capture.noDisplay", "没有可截图的显示器"))
                    dismiss()
                    return
                }

                // Keep ScreenCaptureKit objects on the main actor while requests run concurrently.
                captureTasks = targets.map { screen, display in
                    let scale = screen.backingScaleFactor
                    return Task { @MainActor in
                        try Task.checkCancellation()
                        let image = try await Self.captureImage(display: display, scale: scale)
                        try Task.checkCancellation()
                        return image
                    }
                }
                var images: [CGImage] = []
                for task in captureTasks { images.append(try await task.value) }
                try Task.checkCancellation()
                guard !finished else { return }

                for (index, (screen, display)) in targets.enumerated() {
                    let localWindows = windows
                        .map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
                        .filter { $0.intersects(NSRect(origin: .zero, size: screen.frame.size)) }
                    let overlay = OverlayWindow(screen: screen, frozen: images[index], windows: localWindows,
                                                quick: quick, environment: environment)
                    overlay.onComplete = { [weak self] png, mode in
                        guard let self, !finished else { return }
                        dismiss()
                        ScreenshotOutput.save(png, mode: mode, environment: environment)
                    }
                    overlay.onCancel = { [weak self] in self?.dismiss() }
                    overlay.onRecord = { [weak self] rect in
                        guard let self, !finished else { return }
                        let request = Self.request(for: rect, screen: screen, display: display)
                        dismiss()
                        onRecord?(request)
                    }
                    overlay.onScroll = { [weak self] rect in
                        guard let self, !finished else { return }
                        let request = Self.request(for: rect, screen: screen, display: display)
                        dismiss()
                        onScroll?(request, rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
                    }
                    overlay.onPin = { [weak self] png, frame, shadowed in
                        guard let self, !finished else { return }
                        dismiss()
                        environment.pin(png, at: frame, bakedShadow: shadowed,
                                        name: "\(environment.string("output.screenshotName", "截图")) \(environment.stamp()).png")
                        environment.showToast(environment.string("pin.created", "已钉在屏幕上，双击或 Esc 关闭"))
                    }
                    overlays.append(overlay)
                }

                PluginPresentationSafety.prepareForWindowOrdering()
                NSApp.activate(ignoringOtherApps: true)
                for overlay in overlays { overlay.orderFrontRegardless() }
                let mouse = NSEvent.mouseLocation
                (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
            } catch {
                guard !finished, !Task.isCancelled else { return }
                onError?(environment.format("capture.failed", "截图失败：%@", error.localizedDescription))
                dismiss()
            }
        }
    }

    func dismiss() {
        guard !finished else { return }
        finished = true
        startTask?.cancel()
        startTask = nil
        for task in captureTasks { task.cancel() }
        captureTasks.removeAll()
        for overlay in overlays { overlay.dismiss() }
        overlays.removeAll()
        onFinish?()
    }

    private static func request(for rect: NSRect, screen: NSScreen, display: SCDisplay) -> RecordRequest {
        let scale = screen.backingScaleFactor
        return RecordRequest(
            display: display,
            sourceRect: Geometry.cropRect(viewRect: rect, scale: 1, imagePixelHeight: screen.frame.height),
            width: Int((rect.width * scale).rounded()), height: Int((rect.height * scale).rounded()), scale: scale)
    }

    private static func captureImage(display: SCDisplay, scale: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func onScreenWindows() -> [NSRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Self.selectableWindowRects(from: windows, primaryHeight: primaryHeight)
    }

    static func selectableWindowRects(from windows: [[String: Any]], primaryHeight: CGFloat) -> [NSRect] {
        return windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1
            else { return nil }
            // CoreGraphics uses a top-left origin; Cocoa uses a bottom-left origin.
            return NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        }
    }
}
