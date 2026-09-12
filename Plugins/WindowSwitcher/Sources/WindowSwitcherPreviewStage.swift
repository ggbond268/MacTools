import AppKit

/// A viewport, rather than an image-sized view: captures never participate in
/// the panel's minimum size. Only the fitted window receives a border/shadow.
@MainActor
final class WindowSwitcherPreviewStage: WindowSwitcherAppearanceView {
    private let floatingWindow = NSView()
    private let imageView = NSImageView()
    var image: NSImage? {
        didSet {
            imageView.image = image
            floatingWindow.isHidden = image == nil
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        floatingWindow.wantsLayer = true
        floatingWindow.layer?.cornerRadius = 8
        floatingWindow.layer?.shadowColor = NSColor.black.cgColor
        floatingWindow.layer?.shadowOpacity = 0.20
        floatingWindow.layer?.shadowRadius = 12
        floatingWindow.layer?.shadowOffset = CGSize(width: 0, height: -4)
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 8
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(floatingWindow)
        floatingWindow.addSubview(imageView)
        setAccessibilityElement(false)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func refreshAppearance() {
        super.refreshAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let contrast = WindowSwitcherAppearance.increasedContrast(effectiveAppearance)
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(
                NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : 0.45).cgColor
            imageView.layer?.borderColor = NSColor.labelColor.withAlphaComponent(contrast ? 0.65 : (dark ? 0.30 : 0.20)).cgColor
            imageView.layer?.borderWidth = contrast ? 1.5 : 0.75
            floatingWindow.layer?.shadowOpacity = dark ? 0.35 : 0.20
        }
    }

    override func layout() {
        super.layout()
        floatingWindow.frame = Self.fittedFrame(imageSize: image?.size ?? .zero, in: bounds)
        imageView.frame = floatingWindow.bounds
        floatingWindow.layer?.shadowPath = CGPath(roundedRect: floatingWindow.bounds,
                                                  cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    static func fittedFrame(imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let viewport = bounds.insetBy(dx: 20, dy: 18)
        guard viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Mirrors the command palette's explicit 72-by-15-point move target.
@MainActor
final class WindowSwitcherDragHandle: WindowSwitcherAppearanceView {
    var onDragBegan: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onDragBegan?()
        window.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(WindowSwitcherAppearance.increasedContrast(effectiveAppearance) ? 0.8 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: bounds.midY - 1.5,
                                        width: 28, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}
