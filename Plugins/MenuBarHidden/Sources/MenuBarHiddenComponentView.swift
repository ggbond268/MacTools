// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

struct MenuBarHiddenComponentView: View {
    @ObservedObject var controller: MenuBarHiddenController
    let context: PluginComponentContext

    @Environment(\.pluginComponentTheme) private var theme

    private var canShowIcons: Bool { controller.permissions.canManageItems }

    var body: some View {
        iconPanel
    }

    private var iconPanel: some View {
        Group {
            if canShowIcons {
                MenuBarHiddenComponentIconFlowLayout(
                    horizontalSpacing: MenuBarHiddenComponentIconLayout.horizontalItemSpacing,
                    minimumVerticalSpacing: MenuBarHiddenComponentIconLayout.minimumVerticalSpacing
                ) {
                    ForEach(displayItems) { item in
                        MenuBarHiddenComponentIconButton(
                            item: item,
                            iconCache: controller.manager.iconCache,
                            restingFill: theme.surfaces.control,
                            hoverFill: theme.surfaces.controlHover,
                            onLeftClick: { click(item, button: .left) },
                            onRightClick: { click(item, button: .right) }
                        )
                    }
                }
                .padding(.horizontal, MenuBarHiddenComponentIconLayout.horizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(
                    PluginComponentCardBackground(
                        cornerRadius: MenuBarHiddenComponentIconLayout.cardCornerRadius
                    )
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MenuBarHiddenComponentIconLayout.cardCornerRadius,
                        style: .continuous
                    )
                )
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var displayItems: [MenuBarItem] {
        controller.snapshot.hiddenItems + controller.snapshot.alwaysHiddenItems
    }

    private func click(_ item: MenuBarItem, button: CGMouseButton) {
        context.dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            controller.clickItem(item, button: button)
        }
    }
}

enum MenuBarHiddenComponentIconLayout {
    /// Fixed row height for all icon cells.
    static let rowHeight: CGFloat = 26
    /// Inset applied inside each icon cell for the background padding and image bounds.
    static let iconInset: CGFloat = 3
    /// Minimum and maximum cell widths (including insets).
    static let minItemWidth: CGFloat = 20
    static let maxItemWidth: CGFloat = 104
    static let horizontalItemSpacing: CGFloat = 4
    static let minimumVerticalSpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 7
    static let cardCornerRadius: CGFloat = PluginComponentPanelLayoutMetrics.cardCornerRadius
    static let itemCornerRadius: CGFloat = 7

    static func naturalContentHeight(forRowHeights rowHeights: [CGFloat]) -> CGFloat {
        guard !rowHeights.isEmpty else {
            return 0
        }

        return rowHeights.reduce(0, +)
            + CGFloat(rowHeights.count + 1) * minimumVerticalSpacing
    }

    static func balancedVerticalGap(
        forRowHeights rowHeights: [CGFloat],
        availableHeight: CGFloat
    ) -> CGFloat {
        guard !rowHeights.isEmpty, availableHeight.isFinite else {
            return minimumVerticalSpacing
        }

        let totalRowHeight = rowHeights.reduce(0, +)
        let gapCount = CGFloat(rowHeights.count + 1)
        let distributedGap = (availableHeight - totalRowHeight) / gapCount
        return max(minimumVerticalSpacing, distributedGap)
    }

    @MainActor
    static func iconCellWidth(for item: MenuBarItem, image: MenuBarHiddenIconCache.CapturedImage?) -> CGFloat {
        MenuBarHiddenComponentIconNSView.naturalSize(for: item, image: image).width
    }

    @MainActor
    static func rowCount(
        forItems items: [MenuBarItem],
        iconCache: MenuBarHiddenIconCache,
        availableWidth: CGFloat = PluginComponentPanelLayoutMetrics.default.gridWidth
    ) -> Int {
        let contentWidth = max(0, availableWidth - horizontalPadding * 2)
        guard !items.isEmpty, contentWidth > 0 else {
            return 1
        }

        var rows = 1
        var currentWidth: CGFloat = 0

        for item in items {
            let itemWidth = iconCellWidth(for: item, image: iconCache.image(for: item.tag))
            let candidateWidth = currentWidth == 0
                ? itemWidth
                : currentWidth + horizontalItemSpacing + itemWidth

            if currentWidth > 0, candidateWidth > contentWidth {
                rows += 1
                currentWidth = itemWidth
            } else {
                currentWidth = candidateWidth
            }
        }

        return rows
    }

    @MainActor
    static func spanHeight(
        forItems items: [MenuBarItem],
        iconCache: MenuBarHiddenIconCache,
        metrics: PluginComponentPanelLayoutMetrics = .default
    ) -> Int {
        let rows = rowCount(
            forItems: items,
            iconCache: iconCache,
            availableWidth: metrics.itemWidth(forSpanWidth: PluginComponentSpan.maximumWidth)
        )
        return rows * 4 + 1
    }
}

private struct MenuBarHiddenComponentIconFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let minimumVerticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let layout = makeLayout(
            subviews: subviews,
            maxWidth: proposedWidth(proposal.width, subviews: subviews),
            proposedHeight: proposal.height
        )
        return layout.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let layout = makeLayout(
            subviews: subviews,
            maxWidth: bounds.width,
            proposedHeight: bounds.height
        )
        for (index, placement) in layout.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func proposedWidth(_ width: CGFloat?, subviews: Subviews) -> CGFloat {
        if let width, width > 0 {
            return width
        }
        let naturalWidth = subviews.reduce(CGFloat(0)) { partial, subview in
            let size = subview.sizeThatFits(.unspecified)
            return partial + size.width + (partial == 0 ? 0 : horizontalSpacing)
        }
        return max(naturalWidth, MenuBarHiddenComponentIconLayout.rowHeight)
    }

    private func makeLayout(
        subviews: Subviews,
        maxWidth: CGFloat,
        proposedHeight: CGFloat?
    ) -> (size: CGSize, placements: [(origin: CGPoint, size: CGSize)]) {
        guard !subviews.isEmpty else {
            return (.zero, [])
        }

        let effectiveMaxWidth = max(maxWidth, MenuBarHiddenComponentIconLayout.rowHeight)
        let rows = makeRows(subviews: subviews, maxWidth: effectiveMaxWidth)
        let rowHeights = rows.map(\.height)
        let naturalHeight = MenuBarHiddenComponentIconLayout.naturalContentHeight(forRowHeights: rowHeights)
        let layoutHeight = proposedHeight.flatMap { height in
            height.isFinite ? max(height, naturalHeight) : nil
        } ?? naturalHeight
        let verticalGap = max(
            minimumVerticalSpacing,
            MenuBarHiddenComponentIconLayout.balancedVerticalGap(
                forRowHeights: rowHeights,
                availableHeight: layoutHeight
            )
        )
        var placements: [(origin: CGPoint, size: CGSize)] = Array(
            repeating: (origin: .zero, size: .zero),
            count: subviews.count
        )
        var y = verticalGap

        for row in rows {
            for item in row.items {
                placements[item.index] = (
                    CGPoint(x: item.x, y: y),
                    item.size
                )
            }
            y += row.height + verticalGap
        }

        return (
            CGSize(width: effectiveMaxWidth, height: layoutHeight),
            placements
        )
    }

    private func makeRows(
        subviews: Subviews,
        maxWidth: CGFloat
    ) -> [Row] {
        var rows: [Row] = []
        var items: [RowItem] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                rows.append(Row(items: items, height: rowHeight))
                items = []
                x = 0
                rowHeight = 0
            }

            items.append(RowItem(index: index, x: x, size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        if !items.isEmpty {
            rows.append(Row(items: items, height: rowHeight))
        }

        return rows
    }

    private struct Row {
        let items: [RowItem]
        let height: CGFloat
    }

    private struct RowItem {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }
}

private struct MenuBarHiddenComponentIconButton: NSViewRepresentable {
    let item: MenuBarItem
    let iconCache: MenuBarHiddenIconCache
    let restingFill: Color
    let hoverFill: Color
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context _: Context) -> MenuBarHiddenComponentIconNSView {
        MenuBarHiddenComponentIconNSView(
            item: item,
            iconCache: iconCache,
            restingFill: NSColor(restingFill),
            hoverFill: NSColor(hoverFill),
            onLeftClick: onLeftClick,
            onRightClick: onRightClick
        )
    }

    func updateNSView(_ nsView: MenuBarHiddenComponentIconNSView, context _: Context) {
        nsView.update(
            item: item,
            iconCache: iconCache,
            restingFill: NSColor(restingFill),
            hoverFill: NSColor(hoverFill),
            onLeftClick: onLeftClick,
            onRightClick: onRightClick
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarHiddenComponentIconNSView, context _: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

private final class MenuBarHiddenComponentIconNSView: NSView {
    private var item: MenuBarItem
    private var iconCache: MenuBarHiddenIconCache
    private var restingFill: NSColor
    private var hoverFill: NSColor
    private var onLeftClick: () -> Void
    private var onRightClick: () -> Void
    private var cachedImage: MenuBarHiddenIconCache.CapturedImage? {
        didSet {
            guard !MenuBarHiddenIconCache.CapturedImage.isVisuallyEqual(oldValue, cachedImage) else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()
    private var lastLeftMouseDownDate: Date?
    private var lastRightMouseDownDate: Date?
    private var lastLeftMouseDownLocation = CGPoint.zero
    private var lastRightMouseDownLocation = CGPoint.zero

    init(
        item: MenuBarItem,
        iconCache: MenuBarHiddenIconCache,
        restingFill: NSColor,
        hoverFill: NSColor,
        onLeftClick: @escaping () -> Void,
        onRightClick: @escaping () -> Void
    ) {
        self.item = item
        self.iconCache = iconCache
        self.restingFill = restingFill
        self.hoverFill = hoverFill
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
        let image = iconCache.image(for: item.tag)
        self.cachedImage = image
        super.init(
            frame: NSRect(
                origin: .zero,
                size: Self.naturalSize(for: item, image: image)
            )
        )
        wantsLayer = true
        updateAccessibilityAndTooltip()
        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        Self.naturalSize(for: item, image: cachedImage)
    }

    /// Computes cell size so the icon fills the cell height minus insets,
    /// with width proportional to the actual icon aspect ratio.
    fileprivate static func naturalSize(
        for item: MenuBarItem,
        image: MenuBarHiddenIconCache.CapturedImage?
    ) -> NSSize {
        let rowH = MenuBarHiddenComponentIconLayout.rowHeight
        let inset = MenuBarHiddenComponentIconLayout.iconInset
        let iconH = rowH - inset * 2

        let sourceSize: CGSize
        if let nsImage = image?.nsImage, nsImage.size.height > 0 {
            sourceSize = nsImage.size
        } else if item.bounds.height > 0 {
            sourceSize = item.bounds.size
        } else {
            return NSSize(width: rowH, height: rowH)
        }

        let scale = iconH / sourceSize.height
        let iconW = sourceSize.width * scale
        let naturalCellWidth = iconW + inset * 2
        let cellW = min(
            max(naturalCellWidth, MenuBarHiddenComponentIconLayout.minItemWidth),
            MenuBarHiddenComponentIconLayout.maxItemWidth
        )
        return NSSize(width: ceil(cellW), height: rowH)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    func update(
        item: MenuBarItem,
        iconCache: MenuBarHiddenIconCache,
        restingFill: NSColor,
        hoverFill: NSColor,
        onLeftClick: @escaping () -> Void,
        onRightClick: @escaping () -> Void
    ) {
        let didChangeItem = self.item.tag != item.tag
        let didChangeCache = self.iconCache !== iconCache
        self.item = item
        self.iconCache = iconCache
        self.restingFill = restingFill
        self.hoverFill = hoverFill
        self.onLeftClick = onLeftClick
        self.onRightClick = onRightClick
        cachedImage = iconCache.image(for: item.tag)
        updateAccessibilityAndTooltip()
        if didChangeItem || didChangeCache {
            configureCancellables()
        }
        needsDisplay = true
    }

    private func updateAccessibilityAndTooltip() {
        toolTip = item.displayName
        setAccessibilityLabel(item.displayName)
    }

    private func configureCancellables() {
        cancellables.removeAll()
        let tag = item.tag
        iconCache.$images
            .map { [weak iconCache] _ in iconCache?.image(for: tag) }
            .removeDuplicates(by: MenuBarHiddenIconCache.CapturedImage.isVisuallyEqual)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] image in
                self?.cachedImage = image
            }
            .store(in: &cancellables)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        lastLeftMouseDownDate = .now
        lastLeftMouseDownLocation = NSEvent.mouseLocation
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        lastRightMouseDownDate = .now
        lastRightMouseDownLocation = NSEvent.mouseLocation
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard
            let lastLeftMouseDownDate,
            Date.now.timeIntervalSince(lastLeftMouseDownDate) < 0.5,
            Self.distance(lastLeftMouseDownLocation, NSEvent.mouseLocation) < 5
        else {
            return
        }
        onLeftClick()
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        guard
            let lastRightMouseDownDate,
            Date.now.timeIntervalSince(lastRightMouseDownDate) < 0.5,
            Self.distance(lastRightMouseDownLocation, NSEvent.mouseLocation) < 5
        else {
            return
        }
        onRightClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        drawItemBackground()
        guard let image = cachedImage?.nsImage else { return }

        let inset = MenuBarHiddenComponentIconLayout.iconInset
        let iconRect = bounds.insetBy(dx: inset, dy: inset)
        let targetRect = aspectFitRect(imageSize: image.size, in: iconRect)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: targetRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawItemBackground() {
        let r = min(MenuBarHiddenComponentIconLayout.itemCornerRadius, bounds.height / 2)
        (isHovered ? hoverFill : restingFill).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: r,
            yRadius: r
        ).fill()
    }

    private func aspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
