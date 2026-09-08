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
    private var panelsByGuideID: [String: WindowSnapOverlayPanel] = [:]
    private(set) var renderedGuidesForTests: [WindowSnapGuide] = []

    var presentedPanelsForTests: [WindowSnapOverlayPanel] {
        renderedGuidesForTests.compactMap { panelsByGuideID[$0.id] }
    }

    func showGuides(
        _ guides: [WindowSnapGuide],
        on screen: NSScreen,
        relativeTo window: NSWindow?
    ) {
        renderedGuidesForTests = guides
        let liveIDs = Set(guides.map(\.id))

        for id in Array(panelsByGuideID.keys) where !liveIDs.contains(id) {
            panelsByGuideID[id]?.orderOut(nil)
            panelsByGuideID[id] = nil
        }

        for guide in guides {
            let panel = panelsByGuideID[guide.id] ?? makeOverlayPanel()
            panelsByGuideID[guide.id] = panel
            let frame = panelFrame(for: guide, on: screen)
            if panel.frame != frame {
                panel.setFrame(frame, display: true)
            }
            let overlayView = panel.contentView as? WindowSnapOverlayView
            if overlayView?.renderedGuides != [guide] {
                overlayView?.frame = panel.contentView?.bounds ?? .zero
                overlayView?.render([guide], screenFrame: frame)
            }

            // A small dedicated window avoids the compositing and coordinate-space failures
            // seen with a transparent full-screen overlay during AppKit's tracking loop.
            if !panel.isVisible {
                let restoration = PluginPresentationSafety.prepareForWindowOrdering(
                    panel,
                    restoringTextEditingIn: window
                )
                panel.orderFrontRegardless()
                restoration?.restore()
            }
        }
    }

    func hide() {
        panelsByGuideID.values.forEach {
            $0.orderOut(nil)
            ($0.contentView as? WindowSnapOverlayView)?.clear()
        }
        renderedGuidesForTests = []
    }

    private func panelFrame(for guide: WindowSnapGuide, on screen: NSScreen) -> CGRect {
        let haloThickness: CGFloat = guide.isHighlighted ? 6 : 5
        let start = guide.start
        let end = guide.end

        let frame: CGRect
        switch guide.orientation {
        case .vertical:
            frame = CGRect(
                x: start.x - haloThickness / 2,
                y: min(start.y, end.y),
                width: haloThickness,
                height: max(1, abs(end.y - start.y))
            )
        case .horizontal:
            frame = CGRect(
                x: min(start.x, end.x),
                y: start.y - haloThickness / 2,
                width: max(1, abs(end.x - start.x)),
                height: haloThickness
            )
        }

        return frame.intersection(screen.frame)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = WindowSnapOverlayView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = view
        return panel
    }
}
