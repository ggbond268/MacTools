import AppKit
import QuartzCore

/// Selection chrome is composited independently of the CPU-drawn annotation canvas.
@MainActor
final class CaptureSelectionChrome {
    let root = CALayer()
    let shadow = CALayer()
    let outer = CAShapeLayer()
    let inner = CAShapeLayer()
    private let outside = CAShapeLayer()
    private struct Geometry: Equatable {
        let bounds: CGRect
        let rect: CGRect
        let radius: CGFloat
        let shadowSize: CGFloat
        let scale: CGFloat
    }
    private var geometry: Geometry?

    init(parent: CALayer) {
        root.addSublayer(shadow)
        root.addSublayer(outer)
        root.addSublayer(inner)
        shadow.mask = outside
        outside.fillRule = .evenOdd
        outside.fillColor = NSColor.black.cgColor
        for line in [outer, inner] {
            line.fillColor = nil
            line.lineWidth = 1
        }
        parent.addSublayer(root)
        clear()
    }

    func update(bounds: CGRect, selection: CGRect?, radius: CGFloat, shadowSize: CGFloat,
                shadowColor: NSColor, scale: CGFloat) {
        guard let rect = selection, !rect.isEmpty else { clear(); return }
        let next = Geometry(bounds: bounds, rect: rect, radius: radius, shadowSize: shadowSize, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.isHidden = false
        outer.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        inner.strokeColor = NSColor.controlAccentColor.cgColor
        shadow.shadowColor = shadowColor.cgColor
        guard next != geometry else { return }
        geometry = next
        root.frame = bounds
        for layer in [shadow, outside, outer, inner] {
            layer.frame = bounds
            layer.contentsScale = scale
        }
        outer.path = CGPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5),
                            cornerWidth: radius + 1.5, cornerHeight: radius + 1.5, transform: nil)
        inner.path = CGPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5),
                            cornerWidth: radius + 0.5, cornerHeight: radius + 0.5, transform: nil)
        shadow.isHidden = shadowSize == 0
        shadow.shadowOpacity = 0.5
        shadow.shadowRadius = shadowSize
        shadow.shadowOffset = CGSize(width: 0, height: -(shadowSize / 3).rounded())
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shadow.shadowPath = shape
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(shape)
        outside.path = mask
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.isHidden = true
        geometry = nil
        outer.path = nil
        inner.path = nil
        shadow.shadowPath = nil
        outside.path = nil
        CATransaction.commit()
    }
}

/// A small retained badge avoids redrawing the selected image area for a size change.
@MainActor
final class CaptureSizeBadge: NSView {
    private let environment: ScreenshotEnvironment
    private var sizeFormat = ""
    private var radiusFormat = ""
    private var shadowFormat = ""
    private var label = NSAttributedString(string: "")
    private var measurement: [Int] = []

    init(environment: ScreenshotEnvironment) {
        self.environment = environment
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func prepare() {
        sizeFormat = environment.string("overlay.selection.size", "%d × %d%@")
        radiusFormat = environment.string("overlay.selection.radius", "  R%d")
        shadowFormat = environment.string("overlay.selection.shadow", "  S%d")
        measurement = []
    }

    func update(selection: NSRect?, radius: CGFloat, shadowSize: CGFloat, in bounds: NSRect) {
        guard let rect = selection, !rect.isEmpty else { isHidden = true; return }
        let next = [Int(rect.width), Int(rect.height), Int(radius), Int(shadowSize)]
        if measurement != next {
            measurement = next
            let suffix = (radius > 0 ? String(format: radiusFormat, Int(radius)) : "")
                + (shadowSize > 0 ? String(format: shadowFormat, Int(shadowSize)) : "")
            label = NSAttributedString(string: String(format: sizeFormat, Int(rect.width), Int(rect.height), suffix),
                                       attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                    .foregroundColor: NSColor.white])
            let size = label.size()
            setFrameSize(NSSize(width: size.width + 20, height: size.height + 8))
            needsDisplay = true
        }
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + frame.height > bounds.maxY {
            origin = NSPoint(x: rect.minX + 6, y: rect.maxY - 6 - frame.height)
        }
        if origin != frame.origin { setFrameOrigin(origin) }
        isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        label.draw(at: NSPoint(x: 10, y: 4))
    }
}
