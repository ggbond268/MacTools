import AppKit

/// A viewport, rather than an image-sized view: captures never participate in
/// the panel's minimum size. Only the fitted window receives a border/shadow.
@MainActor
final class WindowSwitcherPreviewStage: WindowSwitcherAppearanceView {
    private let floatingWindow = NSView()
    private let imageView = NSImageView()
    var onRequestDetail: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
    private(set) var zoomScale: CGFloat = 1
    private(set) var panOffset = CGPoint.zero
    private var dragPoint: CGPoint?

    var image: NSImage? {
        didSet {
            if image == nil { fit() }
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
        layer?.masksToBounds = true
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
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
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
        clampPan()
        floatingWindow.frame = displayedFrame
        imageView.frame = floatingWindow.bounds
        floatingWindow.layer?.shadowPath = CGPath(roundedRect: floatingWindow.bounds,
                                                  cornerWidth: 8, cornerHeight: 8, transform: nil)
    }

    override var acceptsFirstResponder: Bool { image != nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    var displayedFrame: CGRect {
        let fitted = Self.fittedFrame(imageSize: image?.size ?? .zero, in: bounds)
        let size = CGSize(width: fitted.width * zoomScale, height: fitted.height * zoomScale)
        return CGRect(x: fitted.midX - size.width / 2 + panOffset.x,
                      y: fitted.midY - size.height / 2 + panOffset.y, width: size.width, height: size.height)
    }

    func fit() {
        zoomScale = 1; panOffset = .zero; dragPoint = nil
        needsLayout = true
        setAccessibilityValue("100%")
        window?.invalidateCursorRects(for: self)
    }

    func zoom(by factor: CGFloat, at anchor: CGPoint? = nil) {
        guard image != nil, factor.isFinite, factor > 0 else { return }
        let old = displayedFrame
        guard old.width > 0, old.height > 0 else { return }
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard anchor.x.isFinite, anchor.y.isFinite else { return }
        let next = min(4, max(1, zoomScale * factor))
        guard next != zoomScale else { return }
        let ratio = next / zoomScale
        zoomScale = next
        panOffset.x = anchor.x - (anchor.x - old.minX) * ratio - (bounds.midX - old.width * ratio / 2)
        panOffset.y = anchor.y - (anchor.y - old.minY) * ratio - (bounds.midY - old.height * ratio / 2)
        clampPan()
        needsLayout = true
        setAccessibilityValue("\(Int(zoomScale * 100))%")
        window?.invalidateCursorRects(for: self)
        if zoomScale > 1 { onRequestDetail?() }
    }

    func pan(by delta: CGPoint) {
        guard image != nil, zoomScale > 1, delta.x.isFinite, delta.y.isFinite else { return }
        panOffset.x += delta.x; panOffset.y += delta.y
        clampPan(); needsLayout = true
    }

    private func clampPan() {
        let fitted = Self.fittedFrame(imageSize: image?.size ?? .zero, in: bounds)
        let viewport = bounds.insetBy(dx: 20, dy: 18)
        let x = max(0, (fitted.width * zoomScale - max(0, viewport.width)) / 2)
        let y = max(0, (fitted.height * zoomScale - max(0, viewport.height)) / 2)
        panOffset = CGPoint(x: min(x, max(-x, panOffset.x)), y: min(y, max(-y, panOffset.y)))
    }

    override func magnify(with event: NSEvent) {
        if image != nil { window?.makeFirstResponder(self) }
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self); return
        }
        guard image != nil else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { fit(); return }
        dragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let dragPoint { pan(by: CGPoint(x: point.x - dragPoint.x, y: point.y - dragPoint.y)) }
        dragPoint = point
    }

    override func mouseUp(with event: NSEvent) { dragPoint = nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if image != nil, zoomScale > 1 { addCursorRect(bounds, cursor: .openHand) }
    }

    override func keyDown(with event: NSEvent) {
        if zoomScale > 1, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            let deltas: [UInt16: CGPoint] = [123: CGPoint(x: 40, y: 0), 124: CGPoint(x: -40, y: 0),
                                          125: CGPoint(x: 0, y: 40), 126: CGPoint(x: 0, y: -40)]
            if let delta = deltas[event.keyCode] { pan(by: delta); return }
        }
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }

    static func fittedFrame(imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else { return .zero }
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
