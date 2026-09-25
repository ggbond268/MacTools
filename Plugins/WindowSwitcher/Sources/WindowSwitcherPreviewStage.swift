import AppKit
import CoreImage

/// A viewport, rather than an image-sized view: captures never participate in
/// the panel's minimum size. Only the fitted window receives a border/shadow.
@MainActor
final class WindowSwitcherPreviewStage: WindowSwitcherAppearanceView {
    private let floatingWindow = NSView()
    private let imageView = NSImageView()
    private let outgoingImageView = NSImageView()
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var hasOutgoingImage: Bool { outgoingImageView.image != nil }
    var onRequestDetail: (() -> Void)?
    var onRequestFocus: (() -> Void)?
    var prefersGestureFocus = false
    var contextMenu: (() -> NSMenu?)?
    var keyHandler: ((NSEvent) -> Bool)?
    private(set) var zoomScale: CGFloat = 1
    private(set) var panOffset = CGPoint.zero
    private var dragPoint: CGPoint?
    private var selectionGeneration: UInt = 0
    private var gestureGeneration: UInt?
    private var pendingMagnification: CGFloat = 1
    private var pendingMagnificationAnchor: CGPoint?
    private var isAwaitingSelectedImage = false
    private lazy var magnificationGesture = NSMagnificationGestureRecognizer(
        target: self, action: #selector(handleMagnification(_:)))

    var image: NSImage? {
        didSet {
            WindowSwitcherPinchDiagnostics.record("image ready=\(image != nil) outgoing=\(hasOutgoingImage) zoom=\(zoomScale)")
            if image != nil {
                clearTransition()
                isAwaitingSelectedImage = false
            }
            if image == nil { fit() }
            imageView.image = image
            floatingWindow.isHidden = image == nil
            needsLayout = true
            if image != nil {
                let magnification = pendingMagnification
                let anchor = pendingMagnificationAnchor
                clearPendingMagnification()
                zoom(by: magnification, at: anchor)
                focusIfPointerInside()
            }
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
        // empty margins. Keep it enabled while images load: missing a gesture's
        // beginning makes AppKit ignore its remaining magnification updates.
        addGestureRecognizer(magnificationGesture)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
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
        let continuesActiveGesture = gestureGeneration != nil
        selectionGeneration &+= 1
        // Tab can change the selected app while the same physical pinch is
        // still in progress. Rebind only that live gesture to the new target.
        gestureGeneration = continuesActiveGesture ? selectionGeneration : nil
        clearPendingMagnification()
        isAwaitingSelectedImage = true
        // Rapid navigation keeps the last real preview, rather than clearing
        // it again for intermediate selections that have not captured an image.
        let outgoing = image ?? outgoingImageView.image
        WindowSwitcherPinchDiagnostics.record("retire image ready=\(image != nil) outgoing=\(outgoing != nil)")
        let frame = image != nil ? displayedFrame : outgoingImageView.frame
        clearTransition()
        image = nil
        guard let outgoing, !reducesMotion(), window?.isVisible == true else { return }
        outgoingImageView.image = outgoing
        outgoingImageView.frame = frame
        outgoingImageView.isHidden = false
        // Reuse the captured pixels. Blur marks them stale while the latest
        // request settles; a ready replacement never waits for an animation.
        outgoingImageView.contentFilters = CIFilter(name: "CIGaussianBlur",
            parameters: [kCIInputRadiusKey: 3.0]).map { [$0] } ?? []
    }

    func clearTransition() {
        outgoingImageView.contentFilters = []
        outgoingImageView.image = nil
        outgoingImageView.isHidden = true
    }

    func cancelPendingMagnification() {
        isAwaitingSelectedImage = false
        gestureGeneration = nil
        clearPendingMagnification()
    }

    private func clearPendingMagnification() {
        pendingMagnification = 1
        pendingMagnificationAnchor = nil
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

    // Keep the viewport eligible while a new screenshot loads. Otherwise a
    // selection change can evict the responder between two pinch events.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }

    override func mouseEntered(with event: NSEvent) {
        requestGestureFocusIfNeeded()
        super.mouseEntered(with: event)
    }

    /// A nonactivating chooser can appear beneath an already stationary pointer,
    /// without producing a mouse-enter event. Prepare focus before any pinch.
    func focusIfPointerInside() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        WindowSwitcherPinchDiagnostics.record("pointer inside=\(bounds.contains(point)) key=\(window.isKeyWindow) active=\(NSApp.isActive) previewResponder=\(window.firstResponder === self)")
        if bounds.contains(point) { requestGestureFocusIfNeeded() }
    }

    private func requestGestureFocusIfNeeded() {
        // A nonactivating panel may be key while its host app is inactive.
        // Magnification is delivered to the key window's view, so the host
        // needs foreground ownership before the gesture begins.
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor,
              (!NSApp.isActive || !window.isKeyWindow ||
               (prefersGestureFocus && window.firstResponder !== self)),
              magnificationGesture.state != .began, magnificationGesture.state != .changed else { return }
        WindowSwitcherPinchDiagnostics.record("focus request key=\(window.isKeyWindow) active=\(NSApp.isActive) previewResponder=\(window.firstResponder === self)")
        onRequestFocus?()
    }

    var displayedFrame: CGRect {
        let fitted = Self.fittedFrame(imageSize: image?.size ?? .zero, in: bounds)
        let size = CGSize(width: fitted.width * zoomScale, height: fitted.height * zoomScale)
        return CGRect(x: fitted.midX - size.width / 2 + panOffset.x,
                      y: fitted.midY - size.height / 2 + panOffset.y, width: size.width, height: size.height)
    }

    func fit() {
        WindowSwitcherPinchDiagnostics.record("fit zoom=\(zoomScale) image=\(image != nil)")
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
        WindowSwitcherPinchDiagnostics.record("zoom factor=\(factor) before=\(zoomScale) after=\(next) image=\(image != nil)")
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
        // Changing foreground ownership after recognition begins can cancel
        // the same pinch. Hover and initial pointer checks prepare focus first.
        let change = gesture.magnification
        WindowSwitcherPinchDiagnostics.record("recognizer state=\(gesture.state.rawValue) change=\(change) image=\(image != nil) outgoing=\(hasOutgoingImage) key=\(window?.isKeyWindow == true) active=\(NSApp.isActive) zoom=\(zoomScale)")
        // Consume increments even while a screenshot is unavailable. A pinch
        // that begins during capture belongs only to the selected generation.
        gesture.magnification = 0
        consumeMagnification(change: change, state: gesture.state, anchor: gesture.location(in: self))
    }

    func consumeMagnification(change: CGFloat, state: NSGestureRecognizer.State, anchor: CGPoint) {
        if state == .began { gestureGeneration = selectionGeneration }
        if state == .cancelled || state == .failed {
            gestureGeneration = nil
            clearPendingMagnification()
            return
        }
        defer { if state == .ended { gestureGeneration = nil } }
        guard gestureGeneration == selectionGeneration, change.isFinite, change != 0,
              1 + change > 0, anchor.x.isFinite, anchor.y.isFinite else { return }
        if image == nil {
            guard isAwaitingSelectedImage else { return }
            pendingMagnification = min(4, max(1, pendingMagnification * (1 + change)))
            pendingMagnificationAnchor = anchor
            WindowSwitcherPinchDiagnostics.record("pinch pending factor=\(pendingMagnification) generation=\(selectionGeneration)")
            return
        }
        window?.makeFirstResponder(self)
        zoom(by: 1 + change, at: anchor)
    }

    override func mouseDown(with event: NSEvent) {
        onRequestFocus?()
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
