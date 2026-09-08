import AppKit
import MacToolsPluginKit
import QuartzCore

final class WindowSnapOverlayView: NSView {
    private struct GuideLayers {
        let halo: CAShapeLayer
        let accent: CAShapeLayer
    }

    private var guideLayers: [String: GuideLayers] = [:]
    private(set) var renderedGuides: [WindowSnapGuide] = []
    var renderedLayerCount: Int { guideLayers.count * 2 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
    }

    func render(_ guides: [WindowSnapGuide], screenFrame: CGRect) {
        renderedGuides = guides.map { guide in
            WindowSnapGuide(
                id: guide.id,
                role: guide.role,
                orientation: guide.orientation,
                start: localPoint(for: guide.start, screenFrame: screenFrame),
                end: localPoint(for: guide.end, screenFrame: screenFrame),
                isHighlighted: guide.isHighlighted
            )
        }

        let liveIDs = Set(renderedGuides.map(\.id))
        for id in Array(guideLayers.keys) where !liveIDs.contains(id) {
            guideLayers[id]?.halo.removeFromSuperlayer()
            guideLayers[id]?.accent.removeFromSuperlayer()
            guideLayers[id] = nil
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            CATransaction.flush()
        }

        for guide in renderedGuides {
            let layers = guideLayers[guide.id] ?? makeGuideLayers(for: guide.id)
            let path = CGMutablePath()
            path.move(to: guide.start)
            path.addLine(to: guide.end)

            layers.halo.frame = bounds
            layers.halo.path = path
            layers.halo.lineWidth = guide.isHighlighted ? 5 : 4

            layers.accent.frame = bounds
            layers.accent.path = path
            layers.accent.lineWidth = guide.isHighlighted ? 2.5 : 2
            layers.accent.strokeColor = NSColor.controlAccentColor
                .withAlphaComponent(guide.isHighlighted ? 1 : 0.82)
                .cgColor
        }
    }

    func clear() {
        renderedGuides = []
        guideLayers.values.forEach {
            $0.halo.removeFromSuperlayer()
            $0.accent.removeFromSuperlayer()
        }
        guideLayers.removeAll(keepingCapacity: true)
    }

    private func localPoint(for point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    private func makeGuideLayers(for id: String) -> GuideLayers {
        let halo = CAShapeLayer()
        halo.name = id + ".halo"
        halo.fillColor = nil
        halo.strokeColor = NSColor.black.withAlphaComponent(0.32).cgColor
        halo.lineCap = .round

        let accent = CAShapeLayer()
        accent.name = id + ".accent"
        accent.fillColor = nil
        accent.lineCap = .round

        layer?.addSublayer(halo)
        layer?.addSublayer(accent)
        let layers = GuideLayers(halo: halo, accent: accent)
        guideLayers[id] = layers
        return layers
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
    var renderedGuidesForTests: [WindowSnapGuide] { overlayView?.renderedGuides ?? [] }
    var renderedLayerCountForTests: Int { overlayView?.renderedLayerCount ?? 0 }

    func showGuides(
        _ guides: [WindowSnapGuide],
        on screen: NSScreen,
        relativeTo window: NSWindow?
    ) {
        let panel = overlayPanel ?? makeOverlayPanel()
        overlayPanel = panel

        if panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        overlayView?.frame = panel.contentView?.bounds ?? .zero
        panel.contentView?.layoutSubtreeIfNeeded()
        overlayView?.render(guides, screenFrame: screen.frame)

        // Relative ordering below a borderless floating panel is not guaranteed to bring an
        // unowned auxiliary window on screen. Keep this mouse-transparent, nonactivating overlay
        // in front for the short drag session so the guides are always visible.
        let restoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            restoringTextEditingIn: window
        )
        panel.orderFrontRegardless()
        restoration?.restore()
    }

    func hide() {
        overlayPanel?.orderOut(nil)
        overlayView?.clear()
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

        let view = WindowSnapOverlayView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = view
        overlayView = view

        return panel
    }
}
