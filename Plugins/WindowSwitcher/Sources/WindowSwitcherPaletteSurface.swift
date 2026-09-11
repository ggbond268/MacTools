import AppKit

/// Matches the command palette and clipboard: a continuous 14-point outline,
/// semantic background, and a subtle border. The panel owns the outer shadow.
@MainActor
final class WindowSwitcherPaletteSurface: NSView {
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        let workspace = NSWorkspace.shared
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(
                workspace.accessibilityDisplayShouldReduceTransparency ? 1 : 0.98
            ).cgColor
            layer?.borderColor = (workspace.accessibilityDisplayShouldIncreaseContrast
                ? NSColor.labelColor : NSColor.separatorColor).cgColor
            layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        }
    }
}
