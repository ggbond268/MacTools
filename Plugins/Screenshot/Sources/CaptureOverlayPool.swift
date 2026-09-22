import AppKit

/// Owns one hidden, reusable native surface per display. Idle surfaces retain no captured pixels.
@MainActor
final class CaptureOverlayPool {
    private let environment: ScreenshotEnvironment
    private var windows: [CGDirectDisplayID: OverlayWindow] = [:]
    private var topology: [CaptureDisplay] = []

    init(environment: ScreenshotEnvironment) { self.environment = environment }

    func prepare() {
        let current = CaptureDisplay.current()
        guard topology != current else { return }
        release()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            windows[id.uint32Value] = OverlayWindow(screen: screen, environment: environment)
        }
        topology = current
    }

    func window(for display: CaptureDisplay) -> OverlayWindow? { windows[display.id] }

    func release() {
        for window in windows.values { window.dismiss(); window.close() }
        windows.removeAll()
        topology.removeAll()
    }
}
