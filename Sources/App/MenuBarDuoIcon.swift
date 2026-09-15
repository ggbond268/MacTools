import AppKit

/// Vector artwork preserves battery colors while matching the menu bar's foreground appearance.
enum MenuBarDuoIcon {
    static let size = NSSize(width: 24, height: 24)
    private static let drawingPointSize: CGFloat = 18

    static func image(
        for snapshot: MenuBarSystemStatusSnapshot,
        appearance: MenuBarIconAppearance = .light
    ) -> NSImage {
        let ringColor = batteryRingColor(for: snapshot)
        let foreground: NSColor = ringColor != nil && appearance == .dark ? .white : .black
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: size.width / drawingPointSize)
            transform.concat()
            drawBattery(snapshot, color: ringColor ?? foreground)
            if snapshot.isExternalPowerConnected {
                drawPowerIndicator(isCharging: snapshot.isCharging, color: foreground)
            }
            drawNetwork(snapshot, color: foreground)
            drawWiFi(snapshot.wifi, color: foreground)
            return true
        }
        image.isTemplate = ringColor == nil
        return image
    }

    private static func batteryRingColor(for snapshot: MenuBarSystemStatusSnapshot) -> NSColor? {
        if snapshot.isCharging { return .systemGreen }
        if let fraction = snapshot.batteryFraction, fraction.isFinite, fraction < 0.2 {
            return .systemRed
        }
        return nil
    }

    private static func drawBattery(_ snapshot: MenuBarSystemStatusSnapshot, color: NSColor) {
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

    private static func drawPowerIndicator(isCharging: Bool, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Enlarge inward from the top edge so the badge stays inside the menu-bar canvas.
        let transform = NSAffineTransform()
        transform.translateX(by: 9, yBy: 17.7)
        transform.scale(by: 1.4)
        transform.translateX(by: -9, yBy: -17.7)
        transform.concat()

        // Keep a power indicator visible when charging pauses or the battery is full.
        let gap = NSBezierPath(roundedRect: NSRect(x: 7.25, y: 14, width: 3.5, height: 4), xRadius: 0.4, yRadius: 0.4)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        gap.fill()
        NSGraphicsContext.restoreGraphicsState()

        if isCharging {
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
        } else {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7.9, y: 14.8, width: 2.2, height: 1.7), xRadius: 0.5, yRadius: 0.5).fill()
            for x in [8.4, 9.6] {
                strokeLine(from: NSPoint(x: x, y: 16.3), to: NSPoint(x: x, y: 17.4), width: 0.65, opacity: 1, color: color)
            }
            strokeLine(from: NSPoint(x: 9, y: 14.3), to: NSPoint(x: 9, y: 14.8), width: 0.7, opacity: 1, color: color)
        }
    }

    private static func drawNetwork(_ snapshot: MenuBarSystemStatusSnapshot, color: NSColor) {
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

    private static func drawWiFiConnection(opacity: CGFloat, color: NSColor) {
        // Wider concentric arcs and a rounded fan base match the Duo reference.
        let center = NSPoint(x: 9, y: 6.7)
        strokeArc(center: center, radius: 4.5, start: 135, end: 45, width: 1.25, opacity: opacity, color: color)
        strokeArc(center: center, radius: 2.6, start: 135, end: 45, width: 1.25, opacity: opacity, color: color)
        drawWiFiConnectionBase(opacity: opacity, color: color)
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

    private static func drawWiFi(_ wifi: MenuBarSystemStatusSnapshot.WiFi, color: NSColor) {
        let level: Int
        if case let .connected(value) = wifi {
            level = min(4, max(0, value))
        } else {
            level = 0
        }

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

    private static func strokeArc(
        center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat, opacity: CGFloat,
        color: NSColor
    ) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
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

enum MenuBarSystemStatusDescription {
    static func text(for snapshot: MenuBarSystemStatusSnapshot) -> String {
        [batteryText(snapshot), wifiText(snapshot.wifi), networkText(snapshot.network)].joined(separator: "\n")
    }

    private static func batteryText(_ snapshot: MenuBarSystemStatusSnapshot) -> String {
        guard let fraction = snapshot.batteryFraction, fraction.isFinite else {
            return snapshot.battery == .notPresent
                ? AppL10n.settings("menuBarIcon.status.noBattery", defaultValue: "无内置电池")
                : AppL10n.settings("menuBarIcon.status.batteryUnavailable", defaultValue: "电量暂不可用")
        }
        let percentage = Int((min(1, max(0, fraction)) * 100).rounded())
        if snapshot.isCharging {
            return AppL10n.settingsFormat("menuBarIcon.status.chargingFormat", defaultValue: "电量 %d%%，正在充电", percentage)
        }
        if snapshot.isExternalPowerConnected {
            return AppL10n.settingsFormat("menuBarIcon.status.externalPowerFormat", defaultValue: "电量 %d%%，已接通电源", percentage)
        }
        return AppL10n.settingsFormat("menuBarIcon.status.batteryFormat", defaultValue: "电量 %d%%", percentage)
    }

    private static func wifiText(_ wifi: MenuBarSystemStatusSnapshot.WiFi) -> String {
        switch wifi {
        case let .connected(level):
            AppL10n.settingsFormat("menuBarIcon.status.wifiLevelFormat", defaultValue: "Wi-Fi 信号 %d/4", min(4, max(0, level)))
        case .off:
            AppL10n.settings("menuBarIcon.status.wifiOff", defaultValue: "Wi-Fi 已关闭")
        case .disconnected:
            AppL10n.settings("menuBarIcon.status.wifiDisconnected", defaultValue: "Wi-Fi 未连接")
        case .unavailable:
            AppL10n.settings("menuBarIcon.status.wifiUnavailable", defaultValue: "Wi-Fi 信号暂不可用")
        }
    }

    private static func networkText(_ network: MenuBarSystemStatusSnapshot.Network) -> String {
        switch network {
        case .connected:
            AppL10n.settings("menuBarIcon.status.networkConnected", defaultValue: "网络已连接")
        case .disconnected:
            AppL10n.settings("menuBarIcon.status.networkDisconnected", defaultValue: "网络未连接")
        case .requiresConnection:
            AppL10n.settings("menuBarIcon.status.networkConnecting", defaultValue: "网络等待连接")
        case .unknown:
            AppL10n.settings("menuBarIcon.status.networkUnknown", defaultValue: "网络状态暂不可用")
        }
    }
}
