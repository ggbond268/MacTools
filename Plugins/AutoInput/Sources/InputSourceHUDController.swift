import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

@MainActor
protocol InputSourceHUDPresenting: AnyObject {
    func show(
        label: InputSourceHUDLabel,
        near focusedFrame: CGRect,
        avoiding editableFrame: CGRect,
        configuration: AutoInputHUDConfiguration,
        presentationID: AutoInputHUDPresentationID,
        onActivate: (() -> Void)?
    )
    func dismiss()
}

protocol InputSourceHUDLabelResolving: Sendable {
    func displayLabel(for source: AutoInputSource) -> InputSourceHUDLabel
}

struct StandardInputSourceHUDLabelResolver: InputSourceHUDLabelResolving {
    func displayLabel(for source: AutoInputSource) -> InputSourceHUDLabel {
        InputSourceHUDLabel(
            title: source.name,
            modeIndicator: nil
        )
    }
}

struct InputSourceHUDLabel: Equatable, Sendable {
    let title: String
    let modeIndicator: String?
}

struct InputSourceHUDPresentationGate {
    private let duplicateInterval: TimeInterval
    private var lastLabel: InputSourceHUDLabel?
    private var lastFocusedFrame: CGRect?
    private var lastEditableFrame: CGRect?
    private var lastConfiguration: AutoInputHUDConfiguration?
    private var lastPresentationID: AutoInputHUDPresentationID?
    private var lastPresentationTime: TimeInterval?

    init(duplicateInterval: TimeInterval) {
        self.duplicateInterval = duplicateInterval
    }

    mutating func shouldPresent(
        label: InputSourceHUDLabel,
        focusedFrame: CGRect,
        editableFrame: CGRect,
        configuration: AutoInputHUDConfiguration,
        presentationID: AutoInputHUDPresentationID,
        at presentationTime: TimeInterval
    ) -> Bool {
        if presentationID == lastPresentationID,
           label == lastLabel,
           focusedFrame == lastFocusedFrame,
           editableFrame == lastEditableFrame,
           configuration == lastConfiguration,
           let lastPresentationTime,
           presentationTime - lastPresentationTime < duplicateInterval {
            return false
        }
        lastLabel = label
        lastFocusedFrame = focusedFrame
        lastEditableFrame = editableFrame
        lastConfiguration = configuration
        lastPresentationID = presentationID
        lastPresentationTime = presentationTime
        return true
    }

    mutating func reset() {
        lastLabel = nil
        lastFocusedFrame = nil
        lastEditableFrame = nil
        lastConfiguration = nil
        lastPresentationID = nil
        lastPresentationTime = nil
    }
}

@MainActor
final class InputSourceHUDController: InputSourceHUDPresenting {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.auto-input.hud")

    private let dismissDelay: Duration
    private let now: () -> TimeInterval
    private let visibleFrames: () -> [CGRect]
    private let displayFrames: () -> [CGRect]
    private let pointerLocation: () -> CGPoint

    private var panel: InputSourceHUDPanel?
    private var hostingView: InputSourceHUDHostingView?
    private var dismissTask: Task<Void, Never>?
    private var isPointerHovering = false
    private var presentationGate: InputSourceHUDPresentationGate

    init(
        dismissDelay: Duration = .milliseconds(1200),
        duplicateInterval: TimeInterval = 0.2,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        visibleFrames: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
        displayFrames: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) },
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }
    ) {
        self.dismissDelay = dismissDelay
        self.now = now
        self.visibleFrames = visibleFrames
        self.displayFrames = displayFrames
        self.pointerLocation = pointerLocation
        self.presentationGate = InputSourceHUDPresentationGate(
            duplicateInterval: duplicateInterval
        )
    }

    func show(
        label: InputSourceHUDLabel,
        near focusedFrame: CGRect,
        avoiding editableFrame: CGRect,
        configuration: AutoInputHUDConfiguration,
        presentationID: AutoInputHUDPresentationID,
        onActivate: (() -> Void)? = nil
    ) {
        let normalizedName = label.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, !focusedFrame.isEmpty, !editableFrame.isEmpty else {
            dismiss()
            return
        }

        let integralFocusedFrame = focusedFrame.integral
        let integralEditableFrame = editableFrame.integral
        guard presentationGate.shouldPresent(
            label: InputSourceHUDLabel(
                title: normalizedName,
                modeIndicator: label.modeIndicator
            ),
            focusedFrame: integralFocusedFrame,
            editableFrame: integralEditableFrame,
            configuration: configuration,
            presentationID: presentationID,
            at: now()
        ) else {
            return
        }

        let effectivePosition = configuration.effectivePosition
        let capturedPointerLocation = effectivePosition == .atPointer
            ? pointerLocation()
            : nil
        let placementFrames = capturedPointerLocation == nil
            ? visibleFrames()
            : displayFrames()
        let placementReferenceFrame = capturedPointerLocation.map {
            CGRect(origin: $0, size: CGSize(width: 1, height: 1))
        } ?? focusedFrame
        let maximumPanelWidth = Self.matchingVisibleFrame(
            for: placementReferenceFrame,
            visibleFrames: placementFrames
        ).map { max($0.width - (Self.displayMargin * 2), 1) }

        let panel = panel ?? Self.makePanel()
        let wasVisible = panel.isVisible
        self.panel = panel
        panel.ignoresMouseEvents = !configuration.isInteractive
        let metrics = Self.metrics(for: configuration.size)
        let panelSize = Self.panelSize(
            for: normalizedName,
            size: configuration.size,
            maximumWidth: maximumPanelWidth
        )
        let frame = Self.panelFrame(
            focusedFrame: focusedFrame,
            avoiding: editableFrame,
            panelSize: panelSize,
            visibleFrames: placementFrames,
            position: effectivePosition,
            pointerLocation: capturedPointerLocation,
            pointerInset: Self.pointerHitInset(for: configuration.size)
        )
        panel.setFrame(frame, display: true)
        panel.setAccessibilityLabel(
            [label.modeIndicator, normalizedName].compactMap { $0 }.joined(separator: ", ")
        )
        let normalizedLabel = InputSourceHUDLabel(
            title: normalizedName,
            modeIndicator: label.modeIndicator
        )
        if let hostingView {
            hostingView.configure(
                label: normalizedLabel,
                metrics: metrics,
                isInteractive: configuration.isInteractive,
                onActivate: configuration.isInteractive ? onActivate : nil,
                onHoverChanged: configuration.isInteractive ? { [weak self] isHovering in
                    self?.setPointerHovering(isHovering)
                } : nil
            )
        } else {
            let hostingView = InputSourceHUDHostingView()
            hostingView.configure(
                label: normalizedLabel,
                metrics: metrics,
                isInteractive: configuration.isInteractive,
                onActivate: configuration.isInteractive ? onActivate : nil,
                onHoverChanged: configuration.isInteractive ? { [weak self] isHovering in
                    self?.setPointerHovering(isHovering)
                } : nil
            )
            hostingView.wantsLayer = true
            hostingView.layer?.borderWidth = 0
            hostingView.layer?.borderColor = NSColor.clear.cgColor
            self.hostingView = hostingView
            panel.contentView = hostingView
        }

        let textEditingRestoration = PluginPresentationSafety.prepareForWindowOrdering(
            panel,
            windows: NSApp.windows,
            restoringTextEditingIn: NSApp.isActive ? NSApp.keyWindow : nil
        )
        panel.orderFrontRegardless()
        textEditingRestoration?.restore()

        if !wasVisible {
            isPointerHovering = false
        }
        scheduleDismiss()
    }

    #if DEBUG
    var presentedPanelForTests: InputSourceHUDPanel? { panel }
    var hostingViewIdentityForTests: ObjectIdentifier? {
        hostingView.map(ObjectIdentifier.init)
    }

    @discardableResult
    func sendPointerClickForTests() -> Bool {
        guard let hostingView,
              let event = NSEvent.mouseEvent(
                  with: .leftMouseUp,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: panel?.windowNumber ?? 0,
                  context: nil,
                  eventNumber: 0,
                  clickCount: 1,
                  pressure: 0
              ) else {
            return false
        }
        hostingView.mouseUp(with: event)
        return true
    }

    @discardableResult
    func sendPointerHoverForTests(_ isHovering: Bool) -> Bool {
        guard let hostingView,
              let event = NSEvent.mouseEvent(
                  with: .mouseMoved,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: panel?.windowNumber ?? 0,
                  context: nil,
                  eventNumber: 0,
                  clickCount: 0,
                  pressure: 0
              ) else {
            return false
        }
        if isHovering {
            hostingView.mouseEntered(with: event)
        } else {
            hostingView.mouseExited(with: event)
        }
        return true
    }
    #endif

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        isPointerHovering = false
        hostingView?.resetHoverState()
        panel?.orderOut(nil)
        presentationGate.reset()
    }

    private func setPointerHovering(_ isHovering: Bool) {
        isPointerHovering = isHovering
        if isHovering {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard !isPointerHovering else { return }
        dismissTask = Task { @MainActor [weak self, dismissDelay] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    static func makePanel() -> InputSourceHUDPanel {
        let panel = InputSourceHUDPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.panelIdentifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        return panel
    }

    static func panelSize(
        for sourceName: String,
        size: AutoInputHUDSize = .standard,
        maximumWidth: CGFloat? = nil
    ) -> CGSize {
        let metrics = metrics(for: size)
        let font = NSFont.systemFont(ofSize: metrics.textSize, weight: .semibold)
        let textWidth = ceil((sourceName as NSString).size(withAttributes: [.font: font]).width)
        let naturalWidth = max(
            textWidth
                + metrics.modeBadgeSize
                + metrics.spacing
                + (metrics.horizontalPadding * 2),
            metrics.minimumWidth
        )
        let resolvedWidth = maximumWidth.map { min(naturalWidth, max($0, 1)) }
            ?? naturalWidth
        return CGSize(
            width: resolvedWidth,
            height: metrics.height
        )
    }

    static func panelFrame(
        focusedFrame: CGRect,
        avoiding editableFrame: CGRect? = nil,
        panelSize: CGSize,
        visibleFrames: [CGRect],
        position: AutoInputHUDPosition = .automatic,
        pointerLocation: CGPoint? = nil,
        pointerInset: CGFloat = 12
    ) -> CGRect {
        if position == .atPointer, let pointerLocation {
            return panelFrame(
                at: pointerLocation,
                panelSize: panelSize,
                displayFrames: visibleFrames,
                pointerInset: pointerInset
            )
        }

        guard let visibleFrame = matchingVisibleFrame(
            for: focusedFrame,
            visibleFrames: visibleFrames
        ) else {
            return CGRect(origin: focusedFrame.origin, size: panelSize)
        }

        if position == .screenCenter {
            return pixelAlignedPanelFrame(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.midY - panelSize.height / 2,
                size: panelSize
            )
        }

        let gap: CGFloat = 8
        let avoidanceFrame = editableFrame ?? focusedFrame
        let minX = visibleFrame.minX + displayMargin
        let maxX = visibleFrame.maxX - panelSize.width - displayMargin
        let preferredX = focusedFrame.midX - panelSize.width / 2
        let x = maxX >= minX
            ? min(max(preferredX, minX), maxX)
            : visibleFrame.midX - panelSize.width / 2

        let minY = visibleFrame.minY + displayMargin
        let maxY = visibleFrame.maxY - panelSize.height - displayMargin
        let belowY = avoidanceFrame.minY - panelSize.height - gap
        let aboveY = avoidanceFrame.maxY + gap
        let preferredVerticalY = preferredVerticalOrigin(
            position: position,
            belowY: belowY,
            aboveY: aboveY,
            belowFits: belowY >= minY,
            aboveFits: aboveY <= maxY,
            minY: minY,
            maxY: maxY
        )
        let clampedVerticalY = maxY >= minY
            ? min(max(preferredVerticalY, minY), maxY)
            : visibleFrame.midY - panelSize.height / 2
        let alternateVerticalY = preferredVerticalY == belowY ? aboveY : belowY
        let clampedAlternateY = maxY >= minY
            ? min(max(alternateVerticalY, minY), maxY)
            : clampedVerticalY

        let minPanelX = visibleFrame.minX + displayMargin
        let maxPanelX = visibleFrame.maxX - panelSize.width - displayMargin
        let lateralY = maxY >= minY
            ? min(max(focusedFrame.midY - panelSize.height / 2, minY), maxY)
            : visibleFrame.midY - panelSize.height / 2
        let rightX = maxPanelX >= minPanelX
            ? min(max(avoidanceFrame.maxX + gap, minPanelX), maxPanelX)
            : x
        let leftX = maxPanelX >= minPanelX
            ? min(max(avoidanceFrame.minX - panelSize.width - gap, minPanelX), maxPanelX)
            : x

        let preferredLateralFrames = avoidanceFrame.midX <= visibleFrame.midX
            ? [
                pixelAlignedPanelFrame(x: rightX, y: lateralY, size: panelSize),
                pixelAlignedPanelFrame(x: leftX, y: lateralY, size: panelSize),
            ]
            : [
                pixelAlignedPanelFrame(x: leftX, y: lateralY, size: panelSize),
                pixelAlignedPanelFrame(x: rightX, y: lateralY, size: panelSize),
            ]
        let candidates = [
            pixelAlignedPanelFrame(x: x, y: clampedVerticalY, size: panelSize),
            pixelAlignedPanelFrame(x: x, y: clampedAlternateY, size: panelSize),
        ] + preferredLateralFrames

        if let nonoverlapping = candidates.first(where: { !$0.intersects(avoidanceFrame) }) {
            return nonoverlapping
        }
        return candidates.min {
            intersectionArea($0, avoidanceFrame) < intersectionArea($1, avoidanceFrame)
        } ?? candidates[0]
    }

    private static func pixelAlignedPanelFrame(
        x: CGFloat,
        y: CGFloat,
        size: CGSize
    ) -> CGRect {
        CGRect(
            x: x.rounded(),
            y: y.rounded(),
            width: size.width.rounded(.up),
            height: size.height.rounded(.up)
        )
    }

    static func panelFrame(
        at pointerLocation: CGPoint,
        panelSize: CGSize,
        displayFrames: [CGRect],
        pointerInset: CGFloat = 12
    ) -> CGRect {
        guard let displayFrame = matchingVisibleFrame(
            for: CGRect(origin: pointerLocation, size: CGSize(width: 1, height: 1)),
            visibleFrames: displayFrames
        ) else {
            return CGRect(
                x: pointerLocation.x - panelSize.width + pointerInset,
                y: pointerLocation.y - pointerInset,
                width: panelSize.width,
                height: panelSize.height
            ).integral
        }

        let minX = displayFrame.minX
        let maxX = displayFrame.maxX - panelSize.width
        let preferredX = pointerLocation.x - panelSize.width + pointerInset
        let x = maxX >= minX
            ? min(max(preferredX, minX), maxX)
            : displayFrame.midX - panelSize.width / 2

        let minY = displayFrame.minY
        let maxY = displayFrame.maxY - panelSize.height
        let preferredY = pointerLocation.y - pointerInset
        let y = maxY >= minY
            ? min(max(preferredY, minY), maxY)
            : displayFrame.midY - panelSize.height / 2

        return CGRect(origin: CGPoint(x: x, y: y), size: panelSize).integral
    }

    private static func preferredVerticalOrigin(
        position: AutoInputHUDPosition,
        belowY: CGFloat,
        aboveY: CGFloat,
        belowFits: Bool,
        aboveFits: Bool,
        minY: CGFloat,
        maxY: CGFloat
    ) -> CGFloat {
        switch position {
        case .automatic:
            if belowFits && aboveFits {
                let spaceBelow = belowY - minY
                let spaceAbove = maxY - aboveY
                return spaceBelow >= spaceAbove ? belowY : aboveY
            }
            if belowFits { return belowY }
            if aboveFits { return aboveY }
            let spaceBelow = belowY - minY
            let spaceAbove = maxY - aboveY
            return spaceBelow >= spaceAbove ? belowY : aboveY
        case .below:
            if belowFits { return belowY }
            if aboveFits { return aboveY }
        case .above:
            if aboveFits { return aboveY }
            if belowFits { return belowY }
        case .screenCenter:
            return min(max(belowY, minY), maxY)
        case .atPointer:
            return min(max(belowY, minY), maxY)
        }
        return min(max(position == .above ? aboveY : belowY, minY), maxY)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    fileprivate static func metrics(for size: AutoInputHUDSize) -> InputSourceHUDMetrics {
        switch size {
        case .compact:
            InputSourceHUDMetrics(
                textSize: 14,
                modeTextSize: 13,
                modeBadgeSize: 26,
                spacing: 7,
                horizontalPadding: 13,
                minimumWidth: 136,
                height: 44,
                cornerRadius: 11
            )
        case .standard:
            InputSourceHUDMetrics(
                textSize: 16,
                modeTextSize: 15,
                modeBadgeSize: 30,
                spacing: 9,
                horizontalPadding: 16,
                minimumWidth: 160,
                height: 52,
                cornerRadius: 13
            )
        case .large:
            InputSourceHUDMetrics(
                textSize: 19,
                modeTextSize: 18,
                modeBadgeSize: 36,
                spacing: 11,
                horizontalPadding: 20,
                minimumWidth: 188,
                height: 64,
                cornerRadius: 16
            )
        }
    }

    private static let displayMargin: CGFloat = 10

    private static func pointerHitInset(for size: AutoInputHUDSize) -> CGFloat {
        switch size {
        case .compact:
            10
        case .standard, .large:
            12
        }
    }

    private static func matchingVisibleFrame(
        for focusedFrame: CGRect,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        if let containing = visibleFrames.first(where: { $0.contains(focusedFrame.center) }) {
            return containing
        }

        let intersecting = visibleFrames.max { lhs, rhs in
            lhs.intersection(focusedFrame).area < rhs.intersection(focusedFrame).area
        }
        if let intersecting, intersecting.intersects(focusedFrame) {
            return intersecting
        }

        return visibleFrames.min { lhs, rhs in
            lhs.center.squaredDistance(to: focusedFrame.center)
                < rhs.center.squaredDistance(to: focusedFrame.center)
        }
    }
}

@MainActor
final class InputSourceHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class InputSourceHUDHostingView: NSHostingView<InputSourceHUDView> {
    private var label = InputSourceHUDLabel(title: "", modeIndicator: nil)
    private var metrics = InputSourceHUDController.metrics(for: .standard)
    private var isInteractive = false
    private var isHovering = false
    private var onActivate: (() -> Void)?
    private var onHoverChanged: ((Bool) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    convenience init() {
        let initialLabel = InputSourceHUDLabel(title: "", modeIndicator: nil)
        let initialMetrics = InputSourceHUDController.metrics(for: .standard)
        self.init(rootView: InputSourceHUDView(
            label: initialLabel,
            metrics: initialMetrics
        ))
    }

    required init(rootView: InputSourceHUDView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        label: InputSourceHUDLabel,
        metrics: InputSourceHUDMetrics,
        isInteractive: Bool,
        onActivate: (() -> Void)?,
        onHoverChanged: ((Bool) -> Void)?
    ) {
        if !isInteractive {
            setHovering(false)
        }
        self.label = label
        self.metrics = metrics
        self.isInteractive = isInteractive
        self.onActivate = onActivate
        self.onHoverChanged = onHoverChanged
        refreshRootView()
        updateTrackingAreas()
    }

    func resetHoverState() {
        guard isHovering else { return }
        isHovering = false
        refreshRootView()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let pointerTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(pointerTrackingArea)
        self.pointerTrackingArea = pointerTrackingArea
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isInteractive
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else {
            super.mouseUp(with: event)
            return
        }
        onActivate?()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractive else { return }
        setHovering(false)
    }

    private func setHovering(_ isHovering: Bool) {
        guard self.isHovering != isHovering else { return }
        self.isHovering = isHovering
        refreshRootView()
        onHoverChanged?(isHovering)
    }

    private func refreshRootView() {
        rootView = InputSourceHUDView(
            label: label,
            metrics: metrics,
            isInteractive: isInteractive,
            isHovering: isHovering,
            onActivate: onActivate
        )
    }
}

private struct InputSourceHUDView: View {
    let label: InputSourceHUDLabel
    let metrics: InputSourceHUDMetrics
    var isInteractive = false
    var isHovering = false
    var onActivate: (() -> Void)?

    var body: some View {
        HStack(spacing: metrics.spacing) {
            if let modeIndicator = label.modeIndicator {
                Text(modeIndicator)
                    .font(.system(size: metrics.modeTextSize, weight: .semibold, design: .rounded))
                    .frame(width: metrics.modeBadgeSize, height: metrics.modeBadgeSize)
                    .background(
                        Color.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: metrics.modeBadgeSize * 0.3, style: .continuous)
                    )
            } else {
                Image(systemName: "keyboard")
                    .font(.system(size: metrics.modeTextSize, weight: .medium))
                    .frame(width: metrics.modeBadgeSize, height: metrics.modeBadgeSize)
            }
            Text(label.title)
                .font(.system(size: metrics.textSize, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            InputSourceHUDMaterial(cornerRadius: metrics.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityAction {
            guard isInteractive else { return }
            onActivate?()
        }
    }
}

struct InputSourceHUDPreview: View {
    let title: String
    let size: AutoInputHUDSize
    let maximumWidth: CGFloat

    var body: some View {
        let metrics = InputSourceHUDController.metrics(for: size)
        let panelSize = InputSourceHUDController.panelSize(
            for: title,
            size: size,
            maximumWidth: maximumWidth
        )

        InputSourceHUDView(
            label: InputSourceHUDLabel(title: title, modeIndicator: nil),
            metrics: metrics,
            isInteractive: false
        )
        .frame(width: panelSize.width, height: panelSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct InputSourceHUDMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        configureLayer(of: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        configureLayer(of: view)
    }

    private func configureLayer(of view: NSVisualEffectView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 0
        view.layer?.borderColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
    }
}

private struct InputSourceHUDMetrics {
    let textSize: CGFloat
    let modeTextSize: CGFloat
    let modeBadgeSize: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat
    let minimumWidth: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        isNull || isInfinite ? 0 : max(width, 0) * max(height, 0)
    }
}

private extension CGPoint {
    func squaredDistance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}
