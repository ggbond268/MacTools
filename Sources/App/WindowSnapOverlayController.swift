import AppKit
import MacToolsPluginKit

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

            // Draw a dark halo first so the guide remains legible over both light and
            // dark window content, then draw the semantic accent line on top.
            path.lineWidth = guide.isHighlighted ? 5 : 4
            NSColor.black.withAlphaComponent(0.32).setStroke()
            path.stroke()

            path.lineWidth = guide.isHighlighted ? 2.5 : 2
            NSColor.controlAccentColor
                .withAlphaComponent(guide.isHighlighted ? 1 : 0.82)
                .setStroke()
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

    var presentedPanelForTests: WindowSnapOverlayPanel? { overlayPanel }

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

        // Relative ordering below a borderless floating panel is not guaranteed to bring an
        // unowned auxiliary window on screen. Keep this mouse-transparent, nonactivating overlay
        // in front for the short drag session so the guides are always visible.
        let restoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            restoringTextEditingIn: window
        )
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        restoration?.restore()
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
        panel.isFloatingPanel = true
        // Setting isFloatingPanel can reset the level to .floating, so assign the higher
        // level afterward. The dragged command palette can otherwise cover this overlay
        // when AppKit raises it again during performDrag.
        panel.level = .statusBar
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
