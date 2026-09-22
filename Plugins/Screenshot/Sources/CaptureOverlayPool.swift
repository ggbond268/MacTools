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
        if topology != current {
            release()
            topology = current
        }
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = id.uint32Value
            // Hidden panels can remain attached to an inactive full-screen Space
            // without any display geometry changing. Only replace stale surfaces.
            if let window = windows[displayID] {
                guard !window.isOnActiveSpace else { continue }
                window.dismiss()
                window.close()
            }
            windows[displayID] = OverlayWindow(screen: screen, environment: environment)
        }
    }

    func window(for display: CaptureDisplay) -> OverlayWindow? { windows[display.id] }

    func release() {
        for window in windows.values { window.dismiss(); window.close() }
        windows.removeAll()
        topology.removeAll()
    }
}
