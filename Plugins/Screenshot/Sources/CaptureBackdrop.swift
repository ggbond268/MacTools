import AppKit
import QuartzCore

/// Retains the original display image independently of frequently redrawn annotation chrome.
@MainActor
final class CaptureBackdrop {
    let imageLayer = CALayer()
    let dimLayer = CAShapeLayer()
    private struct DimmingGeometry: Equatable {
        let bounds: CGRect
        let selection: CGRect?
        let radius: CGFloat
    }
    private var dimmingGeometry: DimmingGeometry?

    init(parent: CALayer) {
        imageLayer.contentsGravity = .resize
        imageLayer.isOpaque = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.48).cgColor
        for layer in [imageLayer, dimLayer] {
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                             "path": NSNull(), "hidden": NSNull(), "contentsScale": NSNull()]
            parent.addSublayer(layer)
        }
    }

    func prepare(image: CGImage, bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.contentsScale = scale
        imageLayer.contents = image
        dimLayer.frame = bounds
        dimLayer.contentsScale = scale
        update(bounds: bounds, selection: nil, radius: 0)
        CATransaction.commit()
    }

    func update(bounds: CGRect, selection: CGRect?, radius: CGFloat) {
        let geometry = DimmingGeometry(bounds: bounds, selection: selection, radius: radius)
        guard geometry != dimmingGeometry else { return }
        dimmingGeometry = geometry
        let path = CGMutablePath()
        path.addRect(bounds)
        if let selection, !selection.isEmpty {
            path.addRoundedRect(in: selection, cornerWidth: radius, cornerHeight: radius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.path = path
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        dimLayer.path = nil
        dimmingGeometry = nil
        CATransaction.commit()
    }
}

/// AppKit owns this view's backing layer; the frozen image is a separate sibling layer.
@MainActor
final class CaptureAnnotationView: NSView {
    var drawContent: ((NSRect) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        drawContent?(dirtyRect)
    }
}
