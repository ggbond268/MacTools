import AppKit
import CoreImage

/// A viewport, rather than an image-sized view: captures never participate in
/// the panel's minimum size. Only the fitted window receives a border/shadow.
@MainActor
final class WindowSwitcherPreviewStage: WindowSwitcherAppearanceView {
    private let floatingWindow = NSView()
    private let imageView = NSImageView()
    private let outgoingImageView = NSImageView()
    private var fadeTask: Task<Void, Never>?
    private var fadeGeneration = 0
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var hasOutgoingImage: Bool { outgoingImageView.image != nil }
    var hasOutgoingBlur: Bool { !outgoingImageView.contentFilters.isEmpty }
    var onRequestDetail: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
    private(set) var zoomScale: CGFloat = 1
    private(set) var panOffset = CGPoint.zero
    private var dragPoint: CGPoint?
    private lazy var magnificationGesture = NSMagnificationGestureRecognizer(
        target: self, action: #selector(handleMagnification(_:)))

    var image: NSImage? {
        didSet {
            if image != nil { clearTransition() }
            if image == nil { fit() }
            magnificationGesture.isEnabled = image != nil
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
        // Attach recognition to the entire viewport, including the image and
        // empty margins. AppKit dispatches recognizers before view responders.
        magnificationGesture.isEnabled = false
        addGestureRecognizer(magnificationGesture)
        addSubview(floatingWindow)
        floatingWindow.addSubview(imageView)
        outgoingImageView.wantsLayer = true
        outgoingImageView.layer?.cornerRadius = 8
        outgoingImageView.layer?.masksToBounds = true
        outgoingImageView.imageScaling = .scaleProportionallyUpOrDown
        outgoingImageView.isHidden = true
        outgoingImageView.setAccessibilityElement(false)
        addSubview(outgoingImageView)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    /// Retain only pixels during the transition. All interaction reads `image`,
    /// which is cleared immediately when the selected target changes.
    func retireImage() {
        let outgoing = image
        let frame = displayedFrame
        clearTransition()
        image = nil
        guard let outgoing, !reducesMotion(), window?.isVisible == true else { return }
        outgoingImageView.image = outgoing
        // Mark retired pixels immediately without another screenshot read.
        // Hold the blur briefly before the faster fade; replacements never wait.
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.0]) {
            outgoingImageView.contentFilters = [blur]
        }
        outgoingImageView.frame = frame
        outgoingImageView.isHidden = false
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.beginTime = (outgoingImageView.layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()) + 0.05
        animation.fillMode = .backwards
        animation.duration = 0.04
        outgoingImageView.layer?.opacity = 0
        outgoingImageView.layer?.add(animation, forKey: "selectionFade")
        let token = fadeGeneration
        fadeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            guard let self, self.fadeGeneration == token else { return }
            self.clearTransition()
        }
    }

    func clearTransition() {
        fadeGeneration += 1
        fadeTask?.cancel(); fadeTask = nil
        outgoingImageView.layer?.removeAnimation(forKey: "selectionFade")
        outgoingImageView.contentFilters = []
        outgoingImageView.image = nil
        outgoingImageView.isHidden = true
    }

    override func refreshAppearance() {
        super.refreshAppearance()
        if reducesMotion() { clearTransition() }
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

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard image != nil else { return }
        let change = gesture.magnification
        // The recognizer accumulates magnification. Consume each increment
        // once so a long gesture does not repeatedly compound its whole delta.
        gesture.magnification = 0
        guard gesture.state != .cancelled, change.isFinite, change != 0 else { return }
        window?.makeFirstResponder(self)
        zoom(by: 1 + change, at: gesture.location(in: self))
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
