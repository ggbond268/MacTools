import AppKit

/// System-managed glass on supported macOS versions, with a native material
/// fallback. The panel owns the outer shadow.
@MainActor
final class WindowSwitcherPaletteSurface: NSView {
    nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?
    let contentContainer = NSView()
    private var fallbackMaterial: NSVisualEffectView?
    private(set) var usesNativeGlass = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.frame = bounds
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 18
            glass.autoresizingMask = [.width, .height]
            // AppKit owns the system glass preference and accessibility response.
            // Use its contentView contract so controls stay above the material.
            glass.contentView = contentContainer
            addSubview(glass)
            usesNativeGlass = true
        } else {
            let material = NSVisualEffectView(frame: bounds)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.autoresizingMask = [.width, .height]
            addSubview(material)
            addSubview(contentContainer)
            fallbackMaterial = material
        }
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
        if usesNativeGlass {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            return
        }
        fallbackMaterial?.isHidden = workspace.accessibilityDisplayShouldReduceTransparency
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(
                workspace.accessibilityDisplayShouldReduceTransparency ? 1 : 0.12
            ).cgColor
            layer?.borderColor = (workspace.accessibilityDisplayShouldIncreaseContrast
                ? NSColor.labelColor : NSColor.separatorColor).cgColor
            layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        }
    }
}
