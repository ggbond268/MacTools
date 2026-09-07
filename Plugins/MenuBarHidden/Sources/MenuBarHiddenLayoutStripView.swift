// SPDX-License-Identifier: GPL-3.0-only
// Restored and adapted for MacTools on 2026-09-07.

import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

// MARK: - SwiftUI wrapper

private enum MenuBarHiddenLayoutStripMetrics {
    static let minItemWidth: CGFloat = 14
    static let maxItemWidth: CGFloat = 240
    static let minItemHeight: CGFloat = 18
    static let spacing: CGFloat = 4
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 4
    static let rowSpacing: CGFloat = 4
    static let singleRowHeight: CGFloat = 48
    static let heightEpsilon: CGFloat = 0.5
}

struct MenuBarHiddenLayoutStrip: NSViewRepresentable {
    let section: MenuBarHiddenSection
    let items: [MenuBarItem]
    let iconCache: MenuBarHiddenIconCache
    let controller: MenuBarHiddenController
    @Binding var measuredHeight: CGFloat

    func makeNSView(context _: Context) -> MenuBarHiddenStripPaddingNSView {
        let view = MenuBarHiddenStripPaddingNSView(
            section: section,
            items: items,
            iconCache: iconCache,
            controller: controller
        )
        view.onHeightChange = updateMeasuredHeight(_:)
        return view
    }

    func updateNSView(_ view: MenuBarHiddenStripPaddingNSView, context _: Context) {
        view.onHeightChange = updateMeasuredHeight(_:)
        view.update(items: items, iconCache: iconCache)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MenuBarHiddenStripPaddingNSView,
        context _: Context
    ) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        let height = nsView.fittingHeight(forWidth: width)
        DispatchQueue.main.async {
            updateMeasuredHeight(height)
        }
        if let proposedWidth = proposal.width {
            return CGSize(width: proposedWidth, height: height)
        }
        return CGSize(width: nsView.bounds.width, height: height)
    }

    private func updateMeasuredHeight(_ height: CGFloat) {
        guard abs(measuredHeight - height) > MenuBarHiddenLayoutStripMetrics.heightEpsilon else { return }
        measuredHeight = height
    }
}

// MARK: - Drag receiving padding view

final class MenuBarHiddenStripPaddingNSView: NSView {
    private let container: MenuBarHiddenStripContainerNSView
    private var isStabilizing = false
    private var lastPublishedHeight: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)?

    init(
        section: MenuBarHiddenSection,
        items: [MenuBarItem],
        iconCache: MenuBarHiddenIconCache,
        controller: MenuBarHiddenController
    ) {
        self.container = MenuBarHiddenStripContainerNSView(
            section: section,
            items: items,
            iconCache: iconCache,
            controller: controller
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        registerForDraggedTypes([.menuBarHiddenItem])

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func update(items: [MenuBarItem], iconCache: MenuBarHiddenIconCache) {
        container.update(items: items, iconCache: iconCache)
        publishFittingHeight()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        super.setFrameSize(newSize)
        if oldWidth != newSize.width {
            invalidateIntrinsicContentSize()
            publishFittingHeight()
        }
    }

    fileprivate func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        container.fittingHeight(forWidth: width)
    }

    fileprivate func containerContentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        publishFittingHeight()
    }

    private func publishFittingHeight() {
        let height = fittingHeight(forWidth: bounds.width)
        guard abs(lastPublishedHeight - height) > MenuBarHiddenLayoutStripMetrics.heightEpsilon else { return }
        lastPublishedHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(height)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        return container.updateItemViewsForDrag(with: sender, phase: .entered)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !isStabilizing, let sender else { return }
        container.updateItemViewsForDrag(with: sender, phase: .exited)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isStabilizing else { return [] }
        return container.updateItemViewsForDrag(with: sender, phase: .updated)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard !isStabilizing else { return }
        container.updateItemViewsForDrag(with: sender, phase: .ended)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let draggingSource = sender.draggingSource as? MenuBarHiddenItemNSView else {
            container.canSetItemViews = true
            return false
        }
        let sourceContainer = draggingSource.oldContainerInfo?.container

        guard container.canAccept(draggingSource) else {
            if container.section != .visible, draggingSource.item.isHostApplicationIcon {
                PluginPresentationSafety.prepareForWindowOrdering()
                provideAlertForVisibleOnlyAppIcon().runModal()
            }
            container.updateItemViewsForDrag(with: sender, phase: .exited)
            draggingSource.hasContainer = false
            container.canSetItemViews = true
            return false
        }

        var willMove = false
        if let index = container.itemViews.firstIndex(of: draggingSource) {
            if sourceContainer === container,
               draggingSource.oldContainerInfo?.index == index
            {
                container.canSetItemViews = true
                sourceContainer?.canSetItemViews = true
                return false
            }

            let item = draggingSource.item
            if let rightItem = container.nearestItem(toRightOf: index) {
                willMove = true
                draggingSource.hasPendingMove = true
                move(item: item, to: .before(rightItem.tag), sourceContainer: sourceContainer)
            } else if let leftItem = container.nearestItem(toLeftOf: index) {
                willMove = true
                draggingSource.hasPendingMove = true
                move(item: item, to: .after(leftItem.tag), sourceContainer: sourceContainer)
            } else {
                willMove = true
                draggingSource.hasPendingMove = true
                move(item: item, to: .end, sourceContainer: sourceContainer)
            }
        }

        if !willMove {
            container.canSetItemViews = true
        }
        return true
    }

    private func provideAlertForVisibleOnlyAppIcon() -> NSAlert {
        let localization = container.controller?.localization ?? PluginLocalization(bundle: .main)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localization.string(
            "alert.hostIconCannotHide.title",
            defaultValue: "MacTools 图标不能隐藏"
        )
        alert.informativeText = localization.string(
            "alert.hostIconCannotHide.message",
            defaultValue: "应用本身的菜单栏图标必须保留在显示区域。"
        )
        return alert
    }

    private func move(
        item: MenuBarItem,
        to placement: MenuBarHiddenMovePlacement,
        sourceContainer: MenuBarHiddenStripContainerNSView?
    ) {
        guard !isStabilizing else { return }
        isStabilizing = true
        container.alphaValue = 0.6
        container.controller?.moveItem(id: item.tag, to: container.section, placement: placement)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            self.isStabilizing = false
            self.container.alphaValue = 1
            self.container.canSetItemViews = true
            sourceContainer?.canSetItemViews = true
        }
    }

    override func accessibilityChildren() -> [Any]? {
        container.itemViews
    }
}

// MARK: - Strip container

final class MenuBarHiddenStripContainerNSView: NSView {
    enum DraggingPhase {
        case entered
        case exited
        case updated
        case ended
    }

    let section: MenuBarHiddenSection
    weak var controller: MenuBarHiddenController?
    private var iconCache: MenuBarHiddenIconCache
    fileprivate var itemViews: [MenuBarHiddenItemNSView] = [] {
        didSet { layoutItemViews(oldViews: oldValue) }
    }
    private var items: [MenuBarItem] = []
    var canSetItemViews = true {
        didSet {
            guard canSetItemViews, !oldValue else { return }
            rebuildItemViews()
        }
    }

    private struct LayoutRow {
        let range: Range<Int>
        let height: CGFloat
    }

    init(
        section: MenuBarHiddenSection,
        items: [MenuBarItem],
        iconCache: MenuBarHiddenIconCache,
        controller: MenuBarHiddenController
    ) {
        self.section = section
        self.controller = controller
        self.iconCache = iconCache
        super.init(frame: .zero)
        unregisterDraggedTypes()
        translatesAutoresizingMaskIntoConstraints = false
        update(items: items, iconCache: iconCache)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func update(items: [MenuBarItem], iconCache: MenuBarHiddenIconCache) {
        self.items = items
        self.iconCache = iconCache
        guard canSetItemViews else { return }
        rebuildItemViews()
    }

    private func rebuildItemViews() {
        let newViews = items.map { item in
            itemViews.first(where: { $0.item == item }) ?? MenuBarHiddenItemNSView(item: item, iconCache: iconCache)
        }
        itemViews = newViews
    }

    private func layoutItemViews(oldViews: [MenuBarHiddenItemNSView]? = nil) {
        let oldViews = oldViews ?? itemViews
        for view in oldViews where !itemViews.contains(view) {
            view.removeFromSuperview()
            view.hasContainer = false
        }

        for view in itemViews where view.superview !== self {
            addSubview(view)
            view.stripView = self
            view.hasContainer = true
        }

        invalidateIntrinsicContentSize()
        (superview as? MenuBarHiddenStripPaddingNSView)?.containerContentDidChange()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rows = layoutRows(forWidth: bounds.width)
        guard !rows.isEmpty else { return }

        let contentHeight = contentHeight(for: rows)
        var rowTop = ((bounds.height + contentHeight) / 2) - MenuBarHiddenLayoutStripMetrics.verticalInset

        for row in rows {
            var x = MenuBarHiddenLayoutStripMetrics.horizontalInset
            for index in row.range {
                let view = itemViews[index]
                let preferredSize = view.preferredSize.integralCeil
                let y = rowTop - row.height + ((row.height - preferredSize.height) / 2)
                view.frame = CGRect(
                    x: x.rounded(.down),
                    y: y.rounded(.down),
                    width: preferredSize.width,
                    height: preferredSize.height
                )
                x += preferredSize.width + MenuBarHiddenLayoutStripMetrics.spacing
            }
            rowTop -= row.height + MenuBarHiddenLayoutStripMetrics.rowSpacing
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        super.setFrameSize(newSize)
        if oldWidth != newSize.width {
            invalidateIntrinsicContentSize()
            (superview as? MenuBarHiddenStripPaddingNSView)?.containerContentDidChange()
        }
    }

    fileprivate func itemPreferredSizeDidChange(_ itemView: MenuBarHiddenItemNSView) {
        guard itemViews.contains(itemView) else { return }
        invalidateIntrinsicContentSize()
        (superview as? MenuBarHiddenStripPaddingNSView)?.containerContentDidChange()
        needsLayout = true
    }

    fileprivate func canAccept(_ source: MenuBarHiddenItemNSView) -> Bool {
        guard controller?.permissions.canManageItems ?? false else { return false }
        guard source.isEnabled else { return false }
        return !MenuBarHiddenLayoutPolicy.shouldRejectMoveToSection(item: source.item, section: section)
    }

    fileprivate func reinsert(_ view: MenuBarHiddenItemNSView, at index: Int) {
        var next = itemViews
        next.removeAll { $0 === view }
        next.insert(view, at: min(index, next.count))
        itemViews = next
    }

    @discardableResult
    func updateItemViewsForDrag(with draggingInfo: NSDraggingInfo, phase: DraggingPhase) -> NSDragOperation {
        guard let sourceView = draggingInfo.draggingSource as? MenuBarHiddenItemNSView else {
            return []
        }

        switch phase {
        case .entered:
            guard canAccept(sourceView) else { return [] }
            return updateItemViewsForDrag(with: draggingInfo, phase: .updated)
        case .exited:
            if let sourceIndex = itemViews.firstIndex(of: sourceView) {
                itemViews.remove(at: sourceIndex)
            }
            return .move
        case .updated:
            guard canAccept(sourceView) else { return [] }
            if sourceView.oldContainerInfo == nil,
               let sourceIndex = itemViews.firstIndex(of: sourceView)
            {
                sourceView.oldContainerInfo = (self, sourceIndex)
            }

            guard itemViews.contains(where: { $0 !== sourceView && $0.isEnabled }) else {
                if !itemViews.contains(sourceView) {
                    itemViews.insert(sourceView, at: 0)
                }
                return .move
            }

            let draggingLocation = convert(draggingInfo.draggingLocation, from: nil)
            guard
                let destinationView = itemView(nearestTo: draggingLocation, excluding: sourceView),
                destinationView !== sourceView,
                destinationView.isEnabled,
                destinationView.layer?.animationKeys() == nil,
                let destinationIndex = itemViews.firstIndex(of: destinationView)
            else {
                return .move
            }

            if !isNear(destinationView, draggingLocation: draggingLocation),
               sourceView.oldContainerInfo?.container === self
            {
                return .move
            }

            if let sourceIndex = itemViews.firstIndex(of: sourceView) {
                var targetIndex = destinationIndex
                if destinationIndex > sourceIndex {
                    targetIndex += 1
                }
                itemViews.move(fromOffsets: [sourceIndex], toOffset: targetIndex)
            } else {
                itemViews.insert(sourceView, at: destinationIndex)
            }
            return .move
        case .ended:
            return .move
        }
    }

    fileprivate func nearestItem(toRightOf index: Int) -> MenuBarItem? {
        guard itemViews.indices.contains(index + 1) else { return nil }
        for candidateIndex in (index + 1) ..< itemViews.count {
            let candidate = itemViews[candidateIndex]
            if candidate.isEnabled {
                return candidate.item
            }
        }
        return nil
    }

    fileprivate func nearestItem(toLeftOf index: Int) -> MenuBarItem? {
        guard itemViews.indices.contains(index - 1) else { return nil }
        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let candidate = itemViews[candidateIndex]
            if candidate.isEnabled {
                return candidate.item
            }
        }
        return nil
    }

    private func itemView(
        nearestTo point: CGPoint,
        excluding source: MenuBarHiddenItemNSView
    ) -> MenuBarHiddenItemNSView? {
        let candidates = itemViews.filter { $0 !== source }
        guard !candidates.isEmpty else { return nil }
        let rowCandidates = candidates.filter {
            point.y >= $0.frame.minY - MenuBarHiddenLayoutStripMetrics.rowSpacing / 2
                && point.y <= $0.frame.maxY + MenuBarHiddenLayoutStripMetrics.rowSpacing / 2
        }
        let effectiveCandidates = rowCandidates.isEmpty ? candidates : rowCandidates
        return effectiveCandidates.min { lhs, rhs in
            let lhsDistance = hypot(lhs.frame.midX - point.x, lhs.frame.midY - point.y)
            let rhsDistance = hypot(rhs.frame.midX - point.x, rhs.frame.midY - point.y)
            return lhsDistance < rhsDistance
        }
    }

    private func isNear(_ view: MenuBarHiddenItemNSView, draggingLocation: CGPoint) -> Bool {
        let horizontalRange = (view.frame.midX - view.frame.width / 2) ... (view.frame.midX + view.frame.width / 2)
        let verticalRange = (view.frame.midY - view.frame.height / 2 - MenuBarHiddenLayoutStripMetrics.rowSpacing)
            ... (view.frame.midY + view.frame.height / 2 + MenuBarHiddenLayoutStripMetrics.rowSpacing)
        return horizontalRange.contains(draggingLocation.x) && verticalRange.contains(draggingLocation.y)
    }

    fileprivate func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let rows = layoutRows(forWidth: width)
        guard !rows.isEmpty else { return MenuBarHiddenLayoutStripMetrics.singleRowHeight }
        guard width > 0 else { return MenuBarHiddenLayoutStripMetrics.singleRowHeight }
        return max(MenuBarHiddenLayoutStripMetrics.singleRowHeight, contentHeight(for: rows)).rounded(.up)
    }

    private func contentHeight(for rows: [LayoutRow]) -> CGFloat {
        guard !rows.isEmpty else { return MenuBarHiddenLayoutStripMetrics.singleRowHeight }
        let rowsHeight = rows.reduce(CGFloat(0)) { $0 + $1.height }
        let spacing = CGFloat(max(0, rows.count - 1)) * MenuBarHiddenLayoutStripMetrics.rowSpacing
        return (MenuBarHiddenLayoutStripMetrics.verticalInset * 2) + rowsHeight + spacing
    }

    private func layoutRows(forWidth width: CGFloat) -> [LayoutRow] {
        guard !itemViews.isEmpty else { return [] }
        let availableWidth = max(
            MenuBarHiddenLayoutStripMetrics.minItemWidth,
            width - (MenuBarHiddenLayoutStripMetrics.horizontalInset * 2)
        )

        var rows: [LayoutRow] = []
        var rowStart = itemViews.startIndex
        var rowWidth: CGFloat = 0
        var rowHeight = MenuBarHiddenLayoutStripMetrics.minItemHeight

        for index in itemViews.indices {
            let itemSize = itemViews[index].preferredSize.integralCeil
            let widthWithSpacing = rowWidth == 0
                ? itemSize.width
                : rowWidth + MenuBarHiddenLayoutStripMetrics.spacing + itemSize.width

            if rowWidth > 0, widthWithSpacing > availableWidth {
                rows.append(LayoutRow(range: rowStart ..< index, height: rowHeight))
                rowStart = index
                rowWidth = 0
                rowHeight = 0
            }

            if rowWidth > 0 {
                rowWidth += MenuBarHiddenLayoutStripMetrics.spacing
            }
            rowWidth += itemSize.width
            rowHeight = max(rowHeight, itemSize.height)
        }

        rows.append(LayoutRow(range: rowStart ..< itemViews.endIndex, height: rowHeight))
        return rows
    }
}

// MARK: - Individual item tile

final class MenuBarHiddenItemNSView: NSView, NSDraggingSource {
    let item: MenuBarItem
    private var iconCache: MenuBarHiddenIconCache
    weak var stripView: MenuBarHiddenStripContainerNSView?
    var oldContainerInfo: (container: MenuBarHiddenStripContainerNSView, index: Int)?
    var hasContainer = false
    var isDraggingPlaceholder = false {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }
    var hasPendingMove = false

    private var cachedImage: MenuBarHiddenIconCache.CapturedImage? {
        didSet {
            let oldSize = preferredSize(for: oldValue)
            let newSize = preferredSize(for: cachedImage)
            guard !MenuBarHiddenIconCache.CapturedImage.isVisuallyEqual(oldValue, cachedImage) else { return }
            setFrameSize(newSize)
            if oldSize != newSize {
                stripView?.itemPreferredSizeDidChange(self)
            }
            needsDisplay = true
        }
    }
    private var cancellables = Set<AnyCancellable>()

    init(item: MenuBarItem, iconCache: MenuBarHiddenIconCache) {
        self.item = item
        self.iconCache = iconCache
        self.cachedImage = iconCache.image(for: item.tag)
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize(for: item, image: iconCache.image(for: item.tag))))
        unregisterDraggedTypes()
        toolTip = item.displayName
        setAccessibilityLabel(item.displayName)
        isEnabled = item.isMovable
        configureCancellables()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func configureCancellables() {
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

    override func draw(_: NSRect) {
        guard !isDraggingPlaceholder else { return }
        if let image = cachedImage?.nsImage {
            image.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: isEnabled ? 1.0 : 0.67
            )
        }
    }

    var preferredSize: CGSize {
        preferredSize(for: cachedImage)
    }

    override func mouseDragged(with event: NSEvent) {
        guard stripView?.controller?.permissions.canManageItems ?? false else { return }
        guard isEnabled else {
            PluginPresentationSafety.prepareForWindowOrdering()
            provideAlertForDisabledItem().runModal()
            return
        }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(Data(), forType: .menuBarHiddenItem)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: draggingImage())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor _: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt _: NSPoint) {
        if let container = superview as? MenuBarHiddenStripContainerNSView {
            if oldContainerInfo == nil,
               let sourceIndex = container.itemViews.firstIndex(of: self)
            {
                oldContainerInfo = (container, sourceIndex)
            }
            container.canSetItemViews = false
        }
        session.animatesToStartingPositionsOnCancelOrFail = false
        Task { @MainActor in
            self.isDraggingPlaceholder = true
        }
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        let sourceContainer = oldContainerInfo?.container
        defer {
            oldContainerInfo = nil
            hasPendingMove = false
        }

        isDraggingPlaceholder = false

        if !hasContainer {
            guard let (container, index) = oldContainerInfo else { return }
            container.reinsert(self, at: index)
        }

        if !hasPendingMove {
            sourceContainer?.canSetItemViews = true
            if sourceContainer == nil,
               let container = superview as? MenuBarHiddenStripContainerNSView
            {
                container.canSetItemViews = true
            }
        }
    }

    private func provideAlertForDisabledItem() -> NSAlert {
        let localization = stripView?.controller?.localization ?? PluginLocalization(bundle: .main)
        let alert = NSAlert()
        alert.messageText = localization.string(
            "alert.itemCannotMove.title",
            defaultValue: "菜单栏图标不可移动"
        )
        alert.informativeText = localization.format(
            "alert.itemCannotMove.message",
            defaultValue: "macOS 不允许移动“%@”。",
            item.displayName
        )
        return alert
    }

    private func draggingImage() -> NSImage? {
        cachedImage?.nsImage ?? bitmapImage()
    }

    private func bitmapImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func preferredSize(for image: MenuBarHiddenIconCache.CapturedImage?) -> CGSize {
        Self.preferredSize(for: item, image: image)
    }

    private static func preferredSize(
        for item: MenuBarItem,
        image: MenuBarHiddenIconCache.CapturedImage?
    ) -> CGSize {
        if let image {
            return image.scaledSize
        }
        let width = min(
            MenuBarHiddenLayoutStripMetrics.maxItemWidth,
            max(MenuBarHiddenLayoutStripMetrics.minItemWidth, item.bounds.width)
        )
        let height = max(item.bounds.height, MenuBarHiddenLayoutStripMetrics.minItemHeight)
        return CGSize(width: width, height: height)
    }
}

// MARK: - Pasteboard type

extension NSPasteboard.PasteboardType {
    static let menuBarHiddenItem = NSPasteboard.PasteboardType(MenuBarHiddenConstants.itemPasteboardType)
}

private extension CGSize {
    var integralCeil: CGSize {
        CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }
}
