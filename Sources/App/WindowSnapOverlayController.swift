import AppKit

final class WindowSnapOverlayView: NSView {
    var guides: [WindowSnapGuide] = [] {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let window = self.window else { return }

        for guide in guides {
            let startInWindow = window.convertPoint(fromScreen: guide.start)
            let endInWindow = window.convertPoint(fromScreen: guide.end)

            let path = NSBezierPath()
            path.move(to: startInWindow)
            path.line(to: endInWindow)

            if guide.isHighlighted {
                path.lineWidth = 1.5
                NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            } else {
                path.lineWidth = 1.0
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
                let pattern: [CGFloat] = [4, 4]
                path.setLineDash(pattern, count: 2, phase: 0)
            }
            path.stroke()
        }
    }
}

final class WindowSnapOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowSnapOverlayController {
    private var overlayPanel: WindowSnapOverlayPanel?
    private var overlayView: WindowSnapOverlayView?

    func showGuides(
        _ guides: [WindowSnapGuide],
        on screen: NSScreen,
        relativeTo window: NSWindow?
    ) {
        let panel = overlayPanel ?? makeOverlayPanel()
        overlayPanel = panel

        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: true)
        }

        overlayView?.guides = guides

        if let window {
            panel.order(.below, relativeTo: window.windowNumber)
        } else {
            panel.orderFront(nil)
        }
    }

    func hide() {
        overlayPanel?.orderOut(nil)
        overlayView?.guides = []
    }

    private func makeOverlayPanel() -> WindowSnapOverlayPanel {
        let panel = WindowSnapOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let view = WindowSnapOverlayView()
        panel.contentView = view
        overlayView = view

        return panel
    }
}
