import AppKit
import MacToolsPluginKit

/// A small, noninteractive surface whose redraws are coalesced by AppKit.
@MainActor
final class CaptureMagnifierView: NSView {
    private static let span: CGFloat = 20
    private static let zoom: CGFloat = 7
    private static let footer: CGFloat = 76
    private let environment: ScreenshotEnvironment
    private var image: CGImage?
    private var frozen: NSImage?
    private let sampleContext = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    private var imageSize = NSSize.zero
    private var point: NSPoint?
    private var format: MagnifierColorFormat = .rgb
    private var locale = Locale.current
    private var positionFormat = ""
    private var rgbFormat = ""
    private var hexFormat = ""
    private var hints: [NSAttributedString] = []
    private let valueAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    init(environment: ScreenshotEnvironment) {
        self.environment = environment
        super.init(frame: NSRect(x: 0, y: 0, width: Self.span * Self.zoom,
                                height: Self.span * Self.zoom + Self.footer))
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func prepare(image: CGImage, size: NSSize) {
        clear()
        self.image = image
        imageSize = size
        frozen = NSImage(cgImage: image, size: size)
        locale = PluginRuntimeLocalization.locale
        positionFormat = environment.string("overlay.magnifier.position", "坐标：%d, %d")
        rgbFormat = environment.string("overlay.magnifier.rgb", "RGB: %d, %d, %d")
        hexFormat = environment.string("overlay.magnifier.hex", "HEX: %@")
        hints = [environment.string("overlay.magnifier.copyHint", "Command + C 复制色值"),
                 environment.string("overlay.magnifier.formatHint", "Tab 切换 RGB、HEX")].map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 10),
                                                       .foregroundColor: NSColor.white.withAlphaComponent(0.72)])
        }
    }

    func clear() {
        isHidden = true
        image = nil
        frozen = nil
        point = nil
        hints.removeAll()
        layer?.contents = nil
    }

    func update(at point: NSPoint?, format: MagnifierColorFormat, in bounds: NSRect) {
        guard image != nil, let point else { isHidden = true; self.point = nil; return }
        if self.point != point || self.format != format {
            self.point = point
            self.format = format
            needsDisplay = true
        }
        let origin = Self.placement(at: point, size: frame.size, in: bounds)
        if frame.origin != origin { setFrameOrigin(origin) }
        isHidden = false
    }

    static func placement(at point: NSPoint, size: NSSize, in bounds: NSRect) -> NSPoint {
        var origin = NSPoint(x: point.x + 20, y: point.y - 20 - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = point.x - 20 - size.width }
        if origin.y < bounds.minY { origin.y = point.y + 20 }
        origin.x = min(max(bounds.minX, origin.x), max(bounds.minX, bounds.maxX - size.width))
        origin.y = min(max(bounds.minY, origin.y), max(bounds.minY, bounds.maxY - size.height))
        return origin
    }

    func color(at point: NSPoint) -> MagnifierColorValue? {
        guard let image, imageSize.width > 0 else { return nil }
        let scale = CGFloat(image.width) / imageSize.width
        let x = min(max(Int(floor(point.x * scale)), 0), image.width - 1)
        let y = min(max(Int(floor(CGFloat(image.height) - point.y * scale)), 0), image.height - 1)
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let sampleContext, let data = sampleContext.data else { return nil }
        // Convert from the captured image's profile explicitly; colorAt(x:y:)
        // can return a calibrated color instead of preserving the bitmap profile.
        sampleContext.setBlendMode(.copy)
        sampleContext.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        let alpha = max(1, Int(rgba[3]))
        func component(_ index: Int) -> Int { min(255, (Int(rgba[index]) * 255 + alpha / 2) / alpha) }
        return MagnifierColorValue(red: component(0), green: component(1), blue: component(2))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let point, let frozen, let color = color(at: point) else { return }
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        let imageRect = NSRect(x: 0, y: Self.footer, width: bounds.width, height: bounds.width)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(white: 0.08, alpha: 0.88).setFill()
        shape.fill()
        // Draw a region of the retained image instead of creating a zoom crop per frame.
        frozen.draw(in: imageRect,
                    from: NSRect(x: point.x - Self.span / 2, y: point.y - Self.span / 2,
                                 width: Self.span, height: Self.span),
                    operation: .sourceOver, fraction: 1, respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.none])
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.85).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: imageRect.midX, y: imageRect.minY))
        cross.line(to: NSPoint(x: imageRect.midX, y: imageRect.maxY))
        cross.move(to: NSPoint(x: imageRect.minX, y: imageRect.midY))
        cross.line(to: NSPoint(x: imageRect.maxX, y: imageRect.midY))
        cross.lineWidth = 1
        cross.stroke()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 0, y: imageRect.minY + 0.5))
        separator.line(to: NSPoint(x: bounds.maxX, y: imageRect.minY + 0.5))
        separator.stroke()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let position = String(format: positionFormat, locale: locale, Int(point.x), Int(imageSize.height - point.y))
        let value = format == .rgb
            ? String(format: rgbFormat, locale: locale, color.red, color.green, color.blue)
            : String(format: hexFormat, locale: locale, color.hex)
        let lines = [NSAttributedString(string: position, attributes: valueAttributes),
                     NSAttributedString(string: value, attributes: valueAttributes)] + hints
        for (index, line) in lines.enumerated() {
            line.draw(at: NSPoint(x: 8, y: Self.footer - 19 - CGFloat(index) * 16))
        }
    }
}
