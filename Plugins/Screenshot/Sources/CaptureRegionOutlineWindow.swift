import AppKit
import MacToolsPluginKit

/// A passive region indicator, excluded from capture alongside the session's status panel.
@MainActor
final class CaptureRegionOutlineWindow: NSPanel {
    static let lineWidth: CGFloat = 3

    init(region: CaptureRegion) {
        // Keep the stroke on the target display, including selections touching its edges.
        let frame = region.globalRect.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth)
            .intersection(region.display.frame)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = CaptureRegionOutlineView(frame: NSRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        PluginPresentationSafety.prepareForWindowOrdering(self)
        orderFrontRegardless()
    }
}

@MainActor
private final class CaptureRegionOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let width = CaptureRegionOutlineWindow.lineWidth
        let path = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        path.stroke()
    }
}
