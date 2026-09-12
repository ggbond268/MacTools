import AppKit
import CoreImage

enum Shape {
    case rect(NSRect)
    case ellipse(NSRect)
    case line(from: NSPoint, to: NSPoint)
    case arrow(from: NSPoint, to: NSPoint)
    case pen([NSPoint])
    case text(String, at: NSPoint)
    case tag(Int, at: NSPoint)
    case redaction(NSRect)
    case mosaic(NSRect)
    case blur(NSRect)
}

struct Stroke {
    var color: NSColor
    var width: CGFloat

    /// Stroke presets also select text sizes, matching the annotation toolbar.
    var fontSize: CGFloat {
        switch width {
        case 2: return 14
        case 4: return 18
        default: return 24
        }
    }
}

struct Item {
    let shape: Shape
    let stroke: Stroke

    static func qrMask(_ rect: NSRect) -> Item {
        Item(shape: .redaction(rect.insetBy(dx: -6, dy: -6)), stroke: Stroke(color: .black, width: 0))
    }
}

/// Draw annotations and export the frozen image without depending on overlay interaction state.
@MainActor
final class AnnotationRenderer {
    private let cgImage: CGImage
    private let scale: CGFloat
    private let bounds: NSRect
    private let frozen: NSImage
    private lazy var ciContext = CIContext()
    private var blurCache: [String: CGImage] = [:]

    init(image: CGImage, scale: CGFloat, size: NSSize) {
        cgImage = image
        self.scale = scale
        bounds = NSRect(origin: .zero, size: size)
        frozen = NSImage(cgImage: image, size: size)
    }

    func clearCache() { blurCache.removeAll() }

    static func shadowMargin(for shadowSize: CGFloat) -> CGFloat {
        shadowSize > 0 ? (shadowSize * 2 + shadowOffset(for: shadowSize)).rounded(.up) : 0
    }

    private static func shadowOffset(for shadowSize: CGFloat) -> CGFloat {
        (shadowSize / 3).rounded()
    }

    /// NSShadow blur and offset use device pixels; offscreen Retina output supplies its scale.
    func drawShadow(for rect: NSRect, radius: CGFloat, shadowSize: CGFloat,
                    shadowColor: NSColor, deviceScale: CGFloat) {
        guard shadowSize > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shadow = NSShadow()
        shadow.shadowBlurRadius = shadowSize * deviceScale
        shadow.shadowOffset = NSSize(width: 0, height: -Self.shadowOffset(for: shadowSize) * deviceScale)
        shadow.shadowColor = shadowColor.withAlphaComponent(0.5)
        shadow.set()
        shadowColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    func drawItems(_ items: [Item], draft: Item? = nil, selection: NSRect) {
        for item in items {
            if case .redaction = item.shape { continue }
            draw(item, cache: true, selection: selection)
        }
        // Draft geometry changes every frame, so it must not grow the blur cache.
        if let draft { draw(draft, cache: false, selection: selection) }
        // Blur and mosaic sample the frozen source; keep masks above those effects.
        for item in items {
            if case .redaction = item.shape { draw(item, cache: true, selection: selection) }
        }
    }

    private func draw(_ item: Item, cache: Bool, selection: NSRect) {
        item.stroke.color.set()
        let width = item.stroke.width
        switch item.shape {
        case .rect(let r):
            stroke(NSBezierPath(rect: r), width: width)
        case .ellipse(let r):
            stroke(NSBezierPath(ovalIn: r), width: width)
        case .line(let from, let to):
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            stroke(path, width: width)
        case .arrow(let from, let to):
            let line = NSBezierPath()
            line.move(to: from)
            line.line(to: to)
            stroke(line, width: width)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let len = 8 + width * 2, spread: CGFloat = .pi / 7
            let head = NSBezierPath()
            head.move(to: to)
            head.line(to: NSPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread)))
            head.line(to: NSPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread)))
            head.close()
            head.fill()
        case .pen(let points):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            stroke(path, width: width)
        case .text(let string, let origin):
            NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: item.stroke.fontSize), .foregroundColor: item.stroke.color,
            ]).draw(at: origin)
        case .tag(let number, let at):
            let r = NSRect(x: at.x - 11, y: at.y - 11, width: 22, height: 22)
            NSBezierPath(ovalIn: r).fill()
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: item.stroke.color == .white ? NSColor.black : NSColor.white,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        case .redaction(let r):
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setBlendMode(.copy)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(r.intersection(selection).intersection(bounds))
            context.restoreGState()
        case .mosaic(let r):
            drawMosaic(in: r, selection: selection)
        case .blur(let r):
            drawBlur(in: r, cache: cache, selection: selection)
        }
    }

    private func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.stroke()
    }

    private func drawMosaic(in rect: NSRect, selection: NSRect) {
        guard let (sub, r) = crop(rect, selection: selection), let cg = NSGraphicsContext.current?.cgContext else { return }
        let block: CGFloat = 10
        let w = max(1, Int(r.width / block)), h = max(1, Int(r.height / block))
        guard let tiny = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        tiny.interpolationQuality = .high
        tiny.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = tiny.makeImage() else { return }

        cg.saveGState()
        cg.interpolationQuality = .none
        cg.draw(small, in: r)
        cg.restoreGState()
    }

    private func drawBlur(in rect: NSRect, cache: Bool, selection: NSRect) {
        guard let (sub, r) = crop(rect, selection: selection), let cg = NSGraphicsContext.current?.cgContext else { return }
        let key = "\(r)"
        let out: CGImage
        if let hit = blurCache[key] {
            out = hit
        } else {
            let extent = CGRect(x: 0, y: 0, width: sub.width, height: sub.height)

            // Extend edge pixels before blurring to avoid a dark border.
            let blurred = CIImage(cgImage: sub).clampedToExtent()
                .applyingGaussianBlur(sigma: 6 * scale)
                .cropped(to: extent)
            guard let made = ciContext.createCGImage(blurred, from: extent) else { return }
            out = made
            if cache { blurCache[key] = made }
        }
        cg.draw(out, in: r)
    }

    /// Convert bottom-left view points to top-left frozen-image pixels.
    func crop(_ rect: NSRect, selection: NSRect) -> (CGImage, NSRect)? {
        let r = rect.intersection(selection).intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        let px = Geometry.cropRect(viewRect: r, scale: scale, imagePixelHeight: CGFloat(cgImage.height))
        guard let sub = cgImage.cropping(to: px) else { return nil }
        return (sub, r)
    }

    /// Preview and export share drawing; only the destination context and scale differ.
    func render(selection: NSRect, items: [Item], draft: Item? = nil, radius: CGFloat,
                shadowSize: CGFloat, shadowColor: NSColor) -> Data? {
        guard !selection.isEmpty else { return nil }
        let m = Self.shadowMargin(for: shadowSize)
        let size = NSSize(width: selection.width + m * 2, height: selection.height + m * 2)
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        ctx.cgContext.translateBy(x: m - selection.minX, y: m - selection.minY)
        drawShadow(for: selection, radius: radius, shadowSize: shadowSize, shadowColor: shadowColor, deviceScale: scale)
        NSBezierPath(roundedRect: selection, xRadius: radius, yRadius: radius).setClip()
        frozen.draw(in: bounds)
        drawItems(items, draft: draft, selection: selection)
        NSGraphicsContext.restoreGraphicsState()

        // Preserve logical dimensions in PNG DPI metadata instead of doubling document size on Retina.
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }
}
