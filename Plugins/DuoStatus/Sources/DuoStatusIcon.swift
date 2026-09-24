import AppKit
import CoreText

enum DuoIconAppearance {
    case light
    case dark
}

/// Vector artwork preserves battery colors while matching the menu bar's foreground appearance.
enum DuoStatusIcon {
    static let size = NSSize(width: 24, height: 24)
    private static let drawingPointSize: CGFloat = 18
    // Include the power badge and signal dots in one fixed optical center for every state.
    private static let artworkCenter = NSPoint(x: 9, y: 9.5)
    /// Three digits define the percentage type size, so "100" never clips the notch.
    private static let percentageReferenceText = "100"
    /// The numerals are laid out at this size and scaled into the notch.
    private static let percentageFontSize: CGFloat = 36

    /// A dedicated glyph for a precise Wi-Fi state. The renderer resolves this to
    /// `nil` when the matching option is off, which collapses the state back to
    /// the generic fan while the tooltip keeps naming the precise state.
    private enum DistinguishedWiFiGlyph {
        case noInternet
        case hotspot
        case shared
        case temporary
    }

    static func image(
        for snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions = .default,
        appearance: DuoIconAppearance = .light,
        pointSize: NSSize = size
    ) -> NSImage {
        let ringColor = batteryRingColor(for: snapshot, options: options)
        let bluetoothColor = DuoStatusIconMappings.shouldUseBluetoothGlyph(
            volume: snapshot.volume,
            wifi: snapshot.wifi,
            network: snapshot.network,
            options: options
        ) ? bluetoothGlyphColor(for: appearance) : nil
        // Status colors and the Bluetooth glyph opt out of template rendering, so
        // the foreground has to follow the menu bar appearance on its own.
        let usesStatusColor = ringColor != nil || bluetoothColor != nil
        let foreground: NSColor = usesStatusColor && appearance == .dark ? .white : .black
        let image = NSImage(size: pointSize, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = min(pointSize.width, pointSize.height) / drawingPointSize * options.iconSize.artworkScale
            let transform = NSAffineTransform()
            transform.translateX(by: pointSize.width / 2, yBy: pointSize.height / 2)
            transform.scale(by: scale)
            transform.translateX(by: -artworkCenter.x, yBy: -artworkCenter.y)
            transform.concat()
            drawBattery(snapshot, color: ringColor ?? foreground)
            drawBatteryTopGap(snapshot, options: options, color: foreground)
            drawNetwork(snapshot, options: options, bluetoothColor: bluetoothColor, color: foreground)
            drawBottomIndicator(snapshot, options: options, color: foreground)
            return true
        }
        image.isTemplate = !usesStatusColor
        return image
    }

    // The battery status-color ladder is adapted from Status Trio
    // (https://github.com/lingyired/status-trio, Apache-2.0).
    private static func batteryRingColor(
        for snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions
    ) -> NSColor? {
        switch DuoStatusIconMappings.batteryColorRole(snapshot.battery, options: options) {
        case .foreground: nil
        case .critical: .systemRed
        case .lowPower: .systemYellow
        case .charging: .systemGreen
        }
    }

    /// The Bluetooth mark keeps its own color in both appearances because the
    /// image stops being a template while it is showing.
    private static func bluetoothGlyphColor(for appearance: DuoIconAppearance) -> NSColor {
        switch appearance {
        case .light: NSColor(srgbRed: 0, green: 102.0 / 255.0, blue: 204.0 / 255.0, alpha: 1)
        case .dark: NSColor(srgbRed: 77.0 / 255.0, green: 163.0 / 255.0, blue: 1, alpha: 1)
        }
    }

    private static func drawBattery(_ snapshot: DuoSystemStatusSnapshot, color: NSColor) {
        let center = NSPoint(x: 9, y: 9.4)
        let radius: CGFloat = 7.3
        let lineWidth: CGFloat = 1.35
        strokeArc(center: center, radius: radius, start: 210, end: -30, width: lineWidth, opacity: 0.22, color: color)

        if let fraction = snapshot.batteryFraction, fraction.isFinite, fraction > 0 {
            strokeArc(
                center: center, radius: radius,
                start: 210, end: 210 - CGFloat(min(1, fraction)) * 240,
                width: lineWidth, opacity: 1, color: color
            )
        } else if snapshot.battery == .notPresent {
            // A dashed neutral arc distinguishes desktop Macs from an empty battery.
            for start in stride(from: 210.0, through: -10.0, by: -40) {
                strokeArc(center: center, radius: radius, start: start, end: start - 20, width: lineWidth, opacity: 0.55, color: color)
            }
        }

    }

    /// Fills the ring's top gap with the charging bolt, the plug, or the battery
    /// percentage. An empty gap leaves the ring closed and draws nothing.
    ///
    /// The gap-content selection and the percentage typography are adapted from
    /// Status Trio (https://github.com/lingyired/status-trio, Apache-2.0); the
    /// 18pt artwork, the bolt, and the plug are this plugin's own.
    private static func drawBatteryTopGap(
        _ snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions,
        color: NSColor
    ) {
        let content = DuoStatusIconMappings.batteryGapContent(snapshot.battery, options: options)
        guard content != .empty else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Enlarge inward from the top edge so the badge stays inside the menu-bar canvas.
        let transform = NSAffineTransform()
        transform.translateX(by: 9, yBy: 17.7)
        transform.scale(by: 1.4)
        transform.translateX(by: -9, yBy: -17.7)
        transform.concat()

        // Keep a power indicator visible when charging pauses or the battery is full.
        // The percentage needs a wider notch so three digits fit between the arc ends.
        let gap = content == .percentage
            ? NSRect(x: 5.6, y: 14, width: 6.8, height: 4)
            : NSRect(x: 7.25, y: 14, width: 3.5, height: 4)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: gap, xRadius: 0.4, yRadius: 0.4).fill()
        NSGraphicsContext.restoreGraphicsState()

        switch content {
        case .bolt:
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 9.5, y: 17.7))
            bolt.line(to: NSPoint(x: 7.7, y: 15.6))
            bolt.line(to: NSPoint(x: 9, y: 15.6))
            bolt.line(to: NSPoint(x: 8.5, y: 14.1))
            bolt.line(to: NSPoint(x: 10.3, y: 16.3))
            bolt.line(to: NSPoint(x: 9, y: 16.3))
            bolt.close()
            color.setFill()
            bolt.fill()
        case .plug:
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7.9, y: 14.8, width: 2.2, height: 1.7), xRadius: 0.5, yRadius: 0.5).fill()
            for x in [8.4, 9.6] {
                strokeLine(from: NSPoint(x: x, y: 16.3), to: NSPoint(x: x, y: 17.4), width: 0.65, opacity: 1, color: color)
            }
            strokeLine(from: NSPoint(x: 9, y: 14.3), to: NSPoint(x: 9, y: 14.8), width: 0.7, opacity: 1, color: color)
        case .percentage:
            drawBatteryPercentage(snapshot.battery.percentage, in: gap, color: color)
        case .empty:
            break
        }
    }

    /// The numerals always use the foreground color: a red ring plus red digits
    /// reads as one blob at menu-bar size.
    private static func drawBatteryPercentage(_ percentage: Int, in gap: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let fit = percentageFit(in: gap) else { return }

        let line = percentageLine(String(min(999, max(0, percentage))), color: color)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard bounds.width.isFinite, bounds.height.isFinite else { return }

        context.saveGState()
        defer { context.restoreGState() }
        // Type is measured and drawn at a comfortable point size and then scaled
        // into the notch, so the rounded design keeps one optical variant.
        context.translateBy(x: gap.midX, y: gap.midY)
        context.scaleBy(x: fit, y: fit)
        context.setFillColor(color.cgColor)
        context.textMatrix = .identity
        // The glyph bounds are relative to the text origin, so center them on the gap.
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
    }

    /// Scale that fits "100" into the notch, so three digits never clip and every
    /// reading keeps the same type size.
    private static func percentageFit(in gap: NSRect) -> CGFloat? {
        let bounds = CTLineGetBoundsWithOptions(
            percentageLine(percentageReferenceText, color: .black),
            [.useGlyphPathBounds]
        )
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        // Inset the notch so the digits never touch the arc's cut ends.
        let fit = min((gap.width - 0.7) / bounds.width, gap.height * 0.82 / bounds.height)
        return fit.isFinite && fit > 0 ? fit : nil
    }

    private static func percentageLine(_ text: String, color: NSColor) -> CTLine {
        let size = percentageFontSize
        let attributes: [NSAttributedString.Key: Any] = [
            .font: percentageFont(size: size),
            .kern: -size * 0.04,
            .foregroundColor: color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func percentageFont(size: CGFloat) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let descriptor = fallback.fontDescriptor.withDesign(.rounded) else { return fallback }
        return NSFont(descriptor: descriptor, size: size) ?? fallback
    }

    /// Center slot, first match wins: the Bluetooth mark, a wired connection's own
    /// mark, a distinguished Wi-Fi state, then the generic fan. Reachability, not
    /// the Wi-Fi state, still decides the fan's opacity and the offline slash, so
    /// an unchanged install keeps rendering exactly what it renders today.
    private static func drawNetwork(
        _ snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions,
        bluetoothColor: NSColor?,
        color: NSColor
    ) {
        if let bluetoothColor {
            drawBluetoothAudio(color: bluetoothColor)
            return
        }

        let opacity: CGFloat = snapshot.network == .connected ? 1 : 0.3
        if snapshot.network == .unknown {
            strokeLine(from: NSPoint(x: 7.2, y: 9), to: NSPoint(x: 10.8, y: 9), width: 1.2, opacity: 0.5, color: color)
            return
        }

        if snapshot.network == .connected, snapshot.connectionKind == .ethernet {
            // Match the chevrons and three dots in macOS's Ethernet icon.
            let chevrons = NSBezierPath()
            chevrons.move(to: NSPoint(x: 6.2, y: 11.4))
            chevrons.line(to: NSPoint(x: 4.8, y: 9.4))
            chevrons.line(to: NSPoint(x: 6.2, y: 7.4))
            chevrons.move(to: NSPoint(x: 11.8, y: 11.4))
            chevrons.line(to: NSPoint(x: 13.2, y: 9.4))
            chevrons.line(to: NSPoint(x: 11.8, y: 7.4))
            chevrons.lineWidth = 0.95
            chevrons.lineCapStyle = .round
            chevrons.lineJoinStyle = .round
            color.setStroke()
            chevrons.stroke()
            color.setFill()
            for x in [7.4, 9.0, 10.6] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.45, y: 8.95, width: 0.9, height: 0.9)).fill()
            }
        } else if snapshot.network == .connected, snapshot.connectionKind == .other {
            let circle = NSBezierPath(ovalIn: NSRect(x: 6.2, y: 5.6, width: 5.6, height: 5.6))
            circle.lineWidth = 1.1
            color.setStroke()
            circle.stroke()
            strokeLine(from: NSPoint(x: 7.5, y: 8.4), to: NSPoint(x: 8.6, y: 7.3), width: 1, opacity: 1, color: color)
            strokeLine(from: NSPoint(x: 8.6, y: 7.3), to: NSPoint(x: 10.6, y: 9.3), width: 1, opacity: 1, color: color)
        } else if let glyph = distinguishedWiFiGlyph(snapshot.wifi, options: options) {
            // A dedicated glyph already states the precise Wi-Fi state, so the
            // generic slash and pending-connection base stay out of its way.
            drawDistinguishedWiFi(glyph, color: color)
            return
        } else {
            drawWiFiConnection(opacity: opacity, color: color)
        }

        if snapshot.network == .disconnected {
            strokeLine(from: NSPoint(x: 6.3, y: 6.8), to: NSPoint(x: 11.7, y: 12), width: 1.2, opacity: 1, color: color)
        } else if snapshot.network == .requiresConnection {
            // A visible signal base distinguishes a pending connection from an unknown state.
            drawWiFiConnectionBase(opacity: 1, color: color)
        }
    }

    /// Resolves a precise Wi-Fi state to its own glyph, or to `nil` when the user
    /// left the matching option off and the state should read as plain Wi-Fi.
    private static func distinguishedWiFiGlyph(
        _ wifi: DuoSystemStatusSnapshot.WiFi,
        options: DuoStatusIconOptions
    ) -> DistinguishedWiFiGlyph? {
        switch wifi {
        case .noInternet: options.distinguishesNoInternet ? .noInternet : nil
        case .hotspot: options.distinguishesHotspot ? .hotspot : nil
        case .shared: options.distinguishesInternetSharing ? .shared : nil
        case .temporary: options.distinguishesTemporaryNetwork ? .temporary : nil
        case .connected, .disconnected, .off, .unavailable: nil
        }
    }

    private static func drawDistinguishedWiFi(_ glyph: DistinguishedWiFiGlyph, color: NSColor) {
        switch glyph {
        case .noInternet: drawNoInternet(color: color)
        case .hotspot: drawHotspot(color: color)
        case .shared: drawShared(color: color)
        case .temporary: drawTemporary(color: color)
        }
    }

    private static func drawWiFiConnection(opacity: CGFloat, color: NSColor) {
        // Wider concentric arcs and a rounded fan base match the Duo reference.
        let center = NSPoint(x: 9, y: 6.7)
        strokeArc(center: center, radius: 4.5, start: 135, end: 45, width: 1.25, opacity: opacity, color: color)
        strokeArc(center: center, radius: 2.6, start: 135, end: 45, width: 1.25, opacity: opacity, color: color)
        drawWiFiConnectionBase(opacity: opacity, color: color)
    }

    /// The fan, uniformly scaled about its own origin and re-centred. Used by the
    /// no-internet glyph so the badge has room without cutting into the arcs.
    private static func drawWiFiConnection(opacity: CGFloat, color: NSColor, scale: CGFloat, center: NSPoint) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.scale(by: scale)
        transform.translateX(by: -9, yBy: -6.7)
        transform.concat()
        drawWiFiConnection(opacity: opacity, color: color)
    }

    private static func drawWiFiConnectionBase(opacity: CGFloat, color: NSColor) {
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 8.1, y: 7.5))
        base.curve(to: NSPoint(x: 9.9, y: 7.5), controlPoint1: NSPoint(x: 8.6, y: 8.1), controlPoint2: NSPoint(x: 9.4, y: 8.1))
        base.curve(to: NSPoint(x: 9.9, y: 7.15), controlPoint1: NSPoint(x: 10, y: 7.4), controlPoint2: NSPoint(x: 10, y: 7.25))
        base.line(to: NSPoint(x: 9.2, y: 6.35))
        base.curve(to: NSPoint(x: 8.8, y: 6.35), controlPoint1: NSPoint(x: 9.1, y: 6.2), controlPoint2: NSPoint(x: 8.9, y: 6.2))
        base.line(to: NSPoint(x: 8.1, y: 7.15))
        base.curve(to: NSPoint(x: 8.1, y: 7.5), controlPoint1: NSPoint(x: 8, y: 7.25), controlPoint2: NSPoint(x: 8, y: 7.4))
        base.close()
        color.withAlphaComponent(opacity).setFill()
        base.fill()
    }

    /// Connected without internet: a smaller fan plus an exclamation badge.
    private static func drawNoInternet(color: NSColor) {
        // Shrink the fan and shift it left so the badge never overlaps the arcs.
        drawWiFiConnection(opacity: 1, color: color, scale: 0.82, center: NSPoint(x: 7.4, y: 6.9))
        strokeLine(from: NSPoint(x: 11.95, y: 9.5), to: NSPoint(x: 11.95, y: 11.4),
                   width: 1.05, opacity: 1, color: color)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 11.42, y: 7.65, width: 1.06, height: 1.06)).fill()
    }

    private static func drawHotspot(color: NSColor) {
        // Chain link, matching the system personal-hotspot metaphor: two capsules
        // on a -45 degree axis, the front one notched out of the back one.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: 9, yBy: 8.6)
        transform.rotate(byDegrees: -45)
        transform.concat()

        let back = NSBezierPath(roundedRect: NSRect(x: -3.35, y: -1.3, width: 3.85, height: 2.6),
                                xRadius: 1.3, yRadius: 1.3)
        back.lineWidth = 0.95
        color.setStroke()
        back.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(rect: NSRect(x: -1.0, y: -2.0, width: 2.0, height: 4.0)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let front = NSBezierPath(roundedRect: NSRect(x: -0.5, y: -1.3, width: 3.85, height: 2.6),
                                 xRadius: 1.3, yRadius: 1.3)
        front.lineWidth = 0.95
        color.setStroke()
        front.stroke()
    }

    private static func drawShared(color: NSColor) {
        // Stroked bowl plus a solid up arrow: no thin negative space, so it holds
        // together at menu-bar size where a filled wedge turns into a blob.
        strokeArc(center: NSPoint(x: 9, y: 9.5), radius: 4.2, start: 325, end: 215,
                  width: 1.15, opacity: 1, color: color)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 9, y: 11.35))
        arrow.line(to: NSPoint(x: 6.9, y: 9.25))
        arrow.line(to: NSPoint(x: 8.25, y: 9.25))
        arrow.line(to: NSPoint(x: 8.25, y: 7.45))
        arrow.line(to: NSPoint(x: 9.75, y: 7.45))
        arrow.line(to: NSPoint(x: 9.75, y: 9.25))
        arrow.line(to: NSPoint(x: 11.1, y: 9.25))
        arrow.close()
        color.setFill()
        arrow.fill()
    }

    /// Temporary network: a small display on a stand.
    private static func drawTemporary(color: NSColor) {
        color.setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 6.35, y: 7.9, width: 5.3, height: 3.4),
                                  xRadius: 0.7, yRadius: 0.7)
        screen.lineWidth = 0.95
        screen.stroke()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 8.45, y: 6.95, width: 1.1, height: 0.95)).fill()
        NSBezierPath(roundedRect: NSRect(x: 7.05, y: 6.25, width: 3.9, height: 0.8),
                     xRadius: 0.35, yRadius: 0.35).fill()
    }

    private static func drawBluetoothAudio(color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 7.45, y: 7.3))
        path.line(to: NSPoint(x: 10.55, y: 9.75))
        path.line(to: NSPoint(x: 9.0, y: 11.05))
        path.line(to: NSPoint(x: 9.0, y: 5.95))
        path.line(to: NSPoint(x: 10.55, y: 7.25))
        path.line(to: NSPoint(x: 7.45, y: 9.7))
        path.lineWidth = 0.95
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The four bottom dots read either Wi-Fi signal strength or output volume;
    /// volume can instead use a continuous bar.
    private static func drawBottomIndicator(
        _ snapshot: DuoSystemStatusSnapshot,
        options: DuoStatusIconOptions,
        color: NSColor
    ) {
        if DuoStatusIconMappings.usesVolumeBar(options: options) {
            drawVolumeBar(snapshot.volume, color: color)
            return
        }
        let level = min(4, max(0, DuoStatusIconMappings.bottomIndicatorSteps(snapshot: snapshot, options: options)))

        let centers: [NSPoint] = [
            NSPoint(x: 5.15, y: 3.25), NSPoint(x: 7.7, y: 2.25),
            NSPoint(x: 10.3, y: 2.25), NSPoint(x: 12.85, y: 3.25)
        ]
        for (index, center) in centers.enumerated() {
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 0.875, y: center.y - 0.875, width: 1.75, height: 1.75))
            color.withAlphaComponent(index < level ? 1 : 0.22).setFill()
            dot.fill()
        }
    }

    /// The volume bar follows the battery circle through the bottom gap and spans
    /// the same width as the dots, filling left to right. The volume arc style is
    /// adapted from Status Trio (https://github.com/lingyired/status-trio, Apache-2.0).
    private static func drawVolumeBar(_ volume: DuoSystemStatusSnapshot.Volume, color: NSColor) {
        let center = NSPoint(x: 9, y: 9.4)
        let radius: CGFloat = 7.3
        let lineWidth: CGFloat = 1.35
        let start: CGFloat = 237
        let end: CGFloat = 303
        strokeArc(center: center, radius: radius, start: start, end: end, width: lineWidth,
                  opacity: 0.22, color: color, clockwise: false)

        let fraction = DuoStatusIconMappings.volumeBarFraction(scalar: volume.scalar, isMuted: volume.isMuted)
        guard fraction > 0 else { return }
        strokeArc(center: center, radius: radius, start: start, end: start + (end - start) * CGFloat(fraction),
                  width: lineWidth, opacity: 1, color: color, clockwise: false)
    }

    private static func strokeArc(
        center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat, opacity: CGFloat,
        color: NSColor, clockwise: Bool = true
    ) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.withAlphaComponent(opacity).setStroke()
        path.stroke()
    }

    private static func strokeLine(from start: NSPoint, to end: NSPoint, width: CGFloat, opacity: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.withAlphaComponent(opacity).setStroke()
        path.stroke()
    }
}
