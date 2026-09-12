import AppKit
import MacToolsPluginKit

@MainActor
enum WindowSwitcherAppearance {
    static func increasedContrast(_ appearance: NSAppearance) -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || appearance.name == .accessibilityHighContrastAqua
            || appearance.name == .accessibilityHighContrastDarkAqua
    }

    static func selectionColor(_ appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(increasedContrast(appearance) ? 0.40 : (dark ? 0.26 : 0.16))
    }

    static func highlighted(_ text: String, ranges: [NSRange]) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text)
        for range in ranges {
            // Treat the match as a color pair: inherited dark-mode label colors
            // are not readable on the system's yellow find highlight.
            value.addAttributes([.backgroundColor: NSColor.yellow, .foregroundColor: NSColor.black], range: range)
        }
        return value
    }
}

/// Layer colors must refresh when appearance, accent, or accessibility changes.
@MainActor
class WindowSwitcherAppearanceView: NSView {
    nonisolated(unsafe) private var colorObserver: NSObjectProtocol?
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        colorObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAppearance() }
            }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAppearance() }
            }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let colorObserver { NotificationCenter.default.removeObserver(colorObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() { needsDisplay = true }
}

/// Match the command palette's shared field and toolbar geometry without
/// replacing the switcher's native search responder and input-method handling.
@MainActor
private func drawPaletteField(in bounds: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                            xRadius: PluginPaletteMetrics.searchCornerRadius,
                            yRadius: PluginPaletteMetrics.searchCornerRadius)
    NSColor.textBackgroundColor.setFill(); path.fill()
    NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
}

@MainActor
final class WindowSwitcherHeaderSurface: NSView {
    var isFocused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        drawPaletteField(in: bounds)
        if isFocused {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                   xRadius: PluginPaletteMetrics.searchCornerRadius,
                                   yRadius: PluginPaletteMetrics.searchCornerRadius)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            ring.lineWidth = 2; ring.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class WindowSwitcherToolbarButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}
