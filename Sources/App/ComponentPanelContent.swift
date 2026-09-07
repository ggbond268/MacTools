import AppKit
import SwiftUI
import MacToolsPluginKit

struct ComponentGridPlacement: Identifiable, Equatable {
    let id: String
    let row: Int
    let column: Int
    let span: PluginComponentSpan
    let yOffset: CGFloat
}

enum ComponentPanelLayout {
    static let metrics = PluginComponentPanelLayoutMetrics.default
    static let columns = metrics.columns
    static let cellWidth = metrics.cellWidth
    static let horizontalSpacing = metrics.horizontalSpacing
    static let originalCellHeight = metrics.originalCellHeight
    static let cellHeight = metrics.cellHeight
    static let spacing = horizontalSpacing
    static let horizontalPadding = MenuBarPanelLayout.outerPadding
    static let topPadding = MenuBarPanelLayout.contentTopPadding
    static let bottomPadding = MenuBarPanelLayout.contentBottomPadding
    static let verticalPadding = MenuBarPanelLayout.outerPadding
    static let verticalSpacing = horizontalPadding
    static let emptyContentHeight: CGFloat = 164
    static let maximumPanelHeight = MenuBarPanelLayout.maximumPanelHeight
    static let minimumPanelHeight = MenuBarPanelLayout.minimumPanelHeight

    static var gridWidth: CGFloat {
        metrics.gridWidth
    }

    static var panelWidth: CGFloat {
        gridWidth + horizontalPadding * 2
    }

    static var contentVerticalPadding: CGFloat {
        topPadding + bottomPadding
    }

    static var scrollClipCornerRadius: CGFloat {
        MenuBarPanelLayout.cornerRadius
    }

    static func itemWidth(for span: PluginComponentSpan) -> CGFloat {
        metrics.itemWidth(forSpanWidth: span.width)
    }

    static func itemHeight(for span: PluginComponentSpan) -> CGFloat {
        metrics.itemHeight(forSpanHeight: span.height)
    }

    static func xOffset(for placement: ComponentGridPlacement) -> CGFloat {
        metrics.offsetX(forColumn: placement.column)
    }

    static func yOffset(for placement: ComponentGridPlacement) -> CGFloat {
        placement.yOffset
    }

    static func gridContentHeight(for placements: [ComponentGridPlacement]) -> CGFloat {
        guard let maximumBottom = placements.map({
            $0.yOffset + itemHeight(for: $0.span)
        }).max() else {
            return emptyContentHeight
        }

        return maximumBottom
    }

    static func preferredContentHeight(for items: [PluginComponentItem], screen: NSScreen?) -> CGFloat {
        let rawContentHeight: CGFloat

        if items.isEmpty {
            rawContentHeight = emptyContentHeight
        } else {
            let placements = ComponentGridPlacementEngine.placements(for: items, columns: columns)
            rawContentHeight = gridContentHeight(for: placements)
        }

        let contentHeight = rawContentHeight + contentVerticalPadding
        let minimumHeight = items.isEmpty ? MenuBarPanelLayout.minimumContentHeight : contentHeight
        return min(
            max(contentHeight, minimumHeight),
            MenuBarPanelLayout.maximumContentHeight(for: screen)
        )
    }

    static func preferredPanelHeight(for items: [PluginComponentItem], screen: NSScreen?) -> CGFloat {
        MenuBarPanelLayout.panelHeight(
            forContentHeight: preferredContentHeight(for: items, screen: screen)
        )
    }
}

enum ComponentGridPlacementEngine {
    static func placements(
        for items: [PluginComponentItem],
        columns: Int = ComponentPanelLayout.columns
    ) -> [ComponentGridPlacement] {
        var occupiedCells: Set<GridCell> = []
        var placements: [ComponentGridPlacement] = []
        var columnBottoms = Array(repeating: CGFloat(0), count: columns)

        for item in items {
            let span = item.span
            var row = 0

            while true {
                var didPlace = false

                for column in 0..<columns where canPlace(
                    span: span,
                    row: row,
                    column: column,
                    columns: columns,
                    occupiedCells: occupiedCells
                ) {
                    placements.append(
                        ComponentGridPlacement(
                            id: item.id,
                            row: row,
                            column: column,
                            span: span,
                            yOffset: yOffset(
                                column: column,
                                span: span,
                                columnBottoms: columnBottoms
                            )
                        )
                    )
                    markOccupied(
                        span: span,
                        row: row,
                        column: column,
                        occupiedCells: &occupiedCells
                    )
                    updateColumnBottoms(
                        span: span,
                        column: column,
                        yOffset: placements[placements.count - 1].yOffset,
                        columnBottoms: &columnBottoms
                    )
                    didPlace = true
                    break
                }

                if didPlace {
                    break
                }

                row += 1
            }
        }

        return placements
    }

    private static func yOffset(
        column: Int,
        span: PluginComponentSpan,
        columnBottoms: [CGFloat]
    ) -> CGFloat {
        let coveredColumns = column..<(column + span.width)
        let previousBottom = coveredColumns
            .map { columnBottoms[$0] }
            .max() ?? 0

        return previousBottom == 0
            ? 0
            : previousBottom + ComponentPanelLayout.verticalSpacing
    }

    private static func updateColumnBottoms(
        span: PluginComponentSpan,
        column: Int,
        yOffset: CGFloat,
        columnBottoms: inout [CGFloat]
    ) {
        let bottom = yOffset + ComponentPanelLayout.itemHeight(for: span)
        for occupiedColumn in column..<(column + span.width) {
            columnBottoms[occupiedColumn] = bottom
        }
    }

    private static func canPlace(
        span: PluginComponentSpan,
        row: Int,
        column: Int,
        columns: Int,
        occupiedCells: Set<GridCell>
    ) -> Bool {
        guard column + span.width <= columns else {
            return false
        }

        for occupiedRow in row..<(row + span.height) {
            for occupiedColumn in column..<(column + span.width) {
                if occupiedCells.contains(GridCell(row: occupiedRow, column: occupiedColumn)) {
                    return false
                }
            }
        }

        return true
    }

    private static func markOccupied(
        span: PluginComponentSpan,
        row: Int,
        column: Int,
        occupiedCells: inout Set<GridCell>
    ) {
        for occupiedRow in row..<(row + span.height) {
            for occupiedColumn in column..<(column + span.width) {
                occupiedCells.insert(GridCell(row: occupiedRow, column: occupiedColumn))
            }
        }
    }

    private struct GridCell: Hashable {
        let row: Int
        let column: Int
    }
}

struct ComponentPanelContent: View {
    private enum DetailLayout {
        static let width: CGFloat = 360
        static let minimumHeight: CGFloat = 300
    }

    @StateObject private var detailCoordinator = ComponentDetailCoordinator()
    @StateObject private var layoutCache = ComponentGridLayoutCache()
    @StateObject private var secondaryPanelController = SecondaryPanelController()
    @ObservedObject var pluginHost: PluginHost
    let contentBodyHeight: CGFloat
    let isPanelVisible: Bool
    var isEditingLayout: Bool = false
    let onDismiss: () -> Void
    @Environment(\.menuBarPanelTheme) private var theme

    private var placements: [ComponentGridPlacement] {
        layoutCache.placements(for: pluginHost.componentItems)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dashboardContent
                .opacity(secondaryPanelController.isPresentingInline ? 0 : 1)
                .allowsHitTesting(!secondaryPanelController.isPresentingInline)

            if secondaryPanelController.isPresentingInline, let detailContent {
                ComponentDetailPanelView(
                    title: detailContent.title,
                    content: detailContent.content,
                    onDismiss: dismissDetail
                )
                .frame(
                    width: ComponentPanelLayout.gridWidth,
                    height: contentBodyHeight,
                    alignment: .topLeading
                )
            }
        }
        .frame(
            width: ComponentPanelLayout.gridWidth,
            height: contentBodyHeight,
            alignment: .topLeading
        )
        .background(
            MenuWindowAccessor { window in
                let didChangeHostWindow = secondaryPanelController.setHostWindow(
                    isPanelVisible ? window : nil
                )
                if didChangeHostWindow, isPanelVisible, detailCoordinator.state.selection != nil {
                    syncDetailPanel()
                }
            }
        )
        .onAppear { [detailCoordinator] in
            pluginHost.componentDetailPresentationHandler = { [weak detailCoordinator] pluginID, detailID in
                detailCoordinator?.toggle(pluginID: pluginID, detailID: detailID)
            }
            secondaryPanelController.onHostWindowDismissRequest = { [weak detailCoordinator] in
                detailCoordinator?.dismiss()
            }
        }
        .onChange(of: detailCoordinator.state) {
            syncDetailPanel()
        }
        .onChange(of: isPanelVisible) { _, visible in
            if visible {
                if detailCoordinator.state.selection != nil {
                    syncDetailPanel()
                }
            } else {
                dismissDetail()
                secondaryPanelController.setHostWindow(nil)
            }
        }
        .onChange(of: isEditingLayout) { _, isEditing in
            if isEditing {
                dismissDetail()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppAppearancePreference.didChangeNotification)) { _ in
            secondaryPanelController.applyCurrentAppearance()
        }
        .onDisappear {
            pluginHost.componentDetailPresentationHandler = nil
            secondaryPanelController.onHostWindowDismissRequest = nil
            dismissDetail()
            secondaryPanelController.setHostWindow(nil)
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if pluginHost.componentItems.isEmpty && (!isEditingLayout || pluginHost.dashboardHiddenLayoutItems.isEmpty) {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ComponentGridView(
                        pluginHost: pluginHost,
                        items: pluginHost.componentItems,
                        placements: placements,
                        detailAnchorPluginID: detailCoordinator.state.selection?.pluginID,
                        isEditingLayout: isEditingLayout,
                        onDismiss: onDismiss,
                        onCardFrameChange: detailCoordinator.updateCardFrame
                    )

                    if isEditingLayout && !pluginHost.dashboardHiddenLayoutItems.isEmpty {
                        hiddenComponentsSection
                    }
                }
            }
            .background(ScrollViewScrollerVisibilityConfigurator())
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ComponentPanelLayout.scrollClipCornerRadius,
                    style: .continuous
                )
            )
        }
    }

    private var hiddenComponentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: PluginSystemImage.resolvedName("eye.slash"))
                    .font(.system(size: 10, weight: .medium))
                Text(AppL10n.settings("plugins.layout.hiddenSection", defaultValue: "已隐藏"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.text.secondary)
            .padding(.top, 8)
            .padding(.horizontal, 4)

            ForEach(pluginHost.dashboardHiddenLayoutItems) { hiddenItem in
                ComponentPanelHiddenEditRowView(
                    item: hiddenItem,
                    onToggleVisible: {
                        pluginHost.setPluginVisible(true, id: hiddenItem.id, on: .dashboard)
                    }
                )
            }
        }
    }

    private var detailContent: PluginComponentDetailContent? {
        guard let selection = detailCoordinator.state.selection else {
            return nil
        }
        return pluginHost.componentDetailContent(
            pluginID: selection.pluginID,
            detailID: selection.detailID,
            dismiss: dismissDetail
        )
    }

    private func syncDetailPanel() {
        guard
            isPanelVisible,
            detailCoordinator.state.selection != nil,
            let anchorRect = detailCoordinator.state.selectedCardFrame,
            let detailContent
        else {
            secondaryPanelController.hide()
            return
        }

        let rootView = AnyView(
            ComponentDetailPanelView(
                title: detailContent.title,
                content: detailContent.content,
                onDismiss: dismissDetail
            )
            .frame(width: DetailLayout.width)
            .foregroundStyle(theme.text.primary)
            .tint(theme.accent)
            .environment(\.menuBarPanelTheme, theme)
            .environment(\.pluginComponentTheme, theme.componentTheme)
        )
        secondaryPanelController.show(
            content: rootView,
            width: DetailLayout.width,
            minimumHeight: DetailLayout.minimumHeight,
            anchorRect: anchorRect
        )
    }

    private func dismissDetail() {
        detailCoordinator.dismiss()
        secondaryPanelController.hide()
    }

    private var emptyState: some View {
        PanelPluginEmptyState(
            tab: .components,
            onInstall: {
                pluginHost.presentPluginMarketplace()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComponentGridView: View {
    @ObservedObject var pluginHost: PluginHost
    let items: [PluginComponentItem]
    let placements: [ComponentGridPlacement]
    let detailAnchorPluginID: String?
    let isEditingLayout: Bool
    let onDismiss: () -> Void
    let onCardFrameChange: (String, CGRect?) -> Void

    private var itemsByID: [String: PluginComponentItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    }

    var body: some View {
        let itemLookup = itemsByID

        ZStack(alignment: .topLeading) {
            ForEach(Array(placements.enumerated()), id: \.element.id) { index, placement in
                if let item = itemLookup[placement.id] {
                    let itemSize = CGSize(
                        width: ComponentPanelLayout.itemWidth(for: placement.span),
                        height: ComponentPanelLayout.itemHeight(for: placement.span)
                    )
                    ZStack(alignment: .topLeading) {
                        ComponentCardContainer(
                            item: item,
                            componentViewItem: pluginHost.componentViewItem(
                                for: item.id,
                                dismiss: onDismiss
                            ),
                            measuresDetailAnchor: !isEditingLayout && item.id == detailAnchorPluginID,
                            onFrameChange: { onCardFrameChange(item.id, $0) }
                        )
                        .allowsHitTesting(!isEditingLayout)

                        if isEditingLayout {
                            ComponentCardEditOverlay(
                                item: item,
                                isFirst: index == 0,
                                isLast: index == placements.count - 1,
                                onMoveEarlier: {
                                    pluginHost.movePlugin(id: item.id, by: -1, on: .dashboard)
                                },
                                onMoveLater: {
                                    pluginHost.movePlugin(id: item.id, by: 1, on: .dashboard)
                                },
                                onMoveToTop: {
                                    pluginHost.movePlugin(id: item.id, toOffset: 0, on: .dashboard)
                                },
                                onMoveToBottom: {
                                    pluginHost.movePlugin(id: item.id, toOffset: placements.count, on: .dashboard)
                                },
                                onToggleVisible: {
                                    pluginHost.setPluginVisible(false, id: item.id, on: .dashboard)
                                },
                                onDropTarget: { draggedID in
                                    guard draggedID != item.id,
                                          let sourceIndex = items.firstIndex(where: { $0.id == draggedID }) else {
                                        return
                                    }
                                    let targetOffset = index > sourceIndex ? index + 1 : index
                                    pluginHost.movePlugin(id: draggedID, toOffset: targetOffset, on: .dashboard)
                                }
                            )
                        }
                    }
                    .frame(
                        width: itemSize.width,
                        height: itemSize.height
                    )
                    .offset(
                        x: ComponentPanelLayout.xOffset(for: placement),
                        y: ComponentPanelLayout.yOffset(for: placement)
                    )
                }
            }
        }
        .frame(
            width: ComponentPanelLayout.gridWidth,
            height: ComponentPanelLayout.gridContentHeight(for: placements),
            alignment: .topLeading
        )
    }
}

private struct ComponentCardEditOverlay: View {
    let item: PluginComponentItem
    let isFirst: Bool
    let isLast: Bool
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onMoveToTop: () -> Void
    let onMoveToBottom: () -> Void
    let onToggleVisible: () -> Void
    let onDropTarget: (String) -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @State private var isTargetedForDrop = false
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isTargetedForDrop ? theme.accent : theme.accent.opacity(0.6),
                    lineWidth: isTargetedForDrop ? 2.5 : 1.5
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.surfaces.panel.opacity(0.12))
                )

            Button(action: onToggleVisible) {
                Image(systemName: PluginSystemImage.resolvedName("eye"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text.primary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(theme.surfaces.panel.opacity(0.85))
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(AppL10n.settings("plugins.layout.hide", defaultValue: "隐藏"))
            .accessibilityLabel(AppL10n.settings("plugins.layout.hide", defaultValue: "隐藏"))

            VStack {
                Spacer()
                HStack(spacing: 2) {
                    Button(action: onMoveEarlier) {
                        Image(systemName: PluginSystemImage.resolvedName("chevron.backward"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isFirst ? theme.text.disabled : theme.text.primary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isFirst)
                    .help(AppL10n.settings("plugins.layout.moveEarlier", defaultValue: "向前移动"))
                    .accessibilityLabel(AppL10n.settings("plugins.layout.moveEarlier", defaultValue: "向前移动"))

                    Image(systemName: PluginSystemImage.resolvedName("line.3.horizontal"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.text.secondary)
                        .frame(width: 14, height: 20)
                        .accessibilityLabel(AppL10n.settings("plugins.layout.reorderHandle", defaultValue: "重新排序"))

                    Button(action: onMoveLater) {
                        Image(systemName: PluginSystemImage.resolvedName("chevron.forward"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isLast ? theme.text.disabled : theme.text.primary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                    .help(AppL10n.settings("plugins.layout.moveLater", defaultValue: "向后移动"))
                    .accessibilityLabel(AppL10n.settings("plugins.layout.moveLater", defaultValue: "向后移动"))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background {
                    Capsule()
                        .fill(theme.surfaces.panel.opacity(0.92))
                        .shadow(color: Color.black.opacity(0.18), radius: 3, y: 1)
                }
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .draggable(item.id)
        .dropDestination(for: String.self) { items, _ in
            guard let draggedID = items.first else { return false }
            onDropTarget(draggedID)
            return true
        } isTargeted: { isTargeted in
            isTargetedForDrop = isTargeted
        }
        .contextMenu {
            Button(AppL10n.settings("plugins.layout.moveToTop", defaultValue: "移至顶部")) {
                onMoveToTop()
            }
            .disabled(isFirst)

            Button(AppL10n.settings("plugins.layout.moveEarlier", defaultValue: "向前移动")) {
                onMoveEarlier()
            }
            .disabled(isFirst)

            Button(AppL10n.settings("plugins.layout.moveLater", defaultValue: "向后移动")) {
                onMoveLater()
            }
            .disabled(isLast)

            Button(AppL10n.settings("plugins.layout.moveToBottom", defaultValue: "移至底部")) {
                onMoveToBottom()
            }
            .disabled(isLast)

            Divider()

            Button(AppL10n.settings("plugins.layout.hide", defaultValue: "隐藏")) {
                onToggleVisible()
            }
        }
        .accessibilityAction(named: Text(AppL10n.settings("plugins.layout.moveEarlier", defaultValue: "向前移动"))) {
            if !isFirst { onMoveEarlier() }
        }
        .accessibilityAction(named: Text(AppL10n.settings("plugins.layout.moveLater", defaultValue: "向后移动"))) {
            if !isLast { onMoveLater() }
        }
        .accessibilityAction(named: Text(AppL10n.settings("plugins.layout.moveToTop", defaultValue: "移至顶部"))) {
            if !isFirst { onMoveToTop() }
        }
        .accessibilityAction(named: Text(AppL10n.settings("plugins.layout.moveToBottom", defaultValue: "移至底部"))) {
            if !isLast { onMoveToBottom() }
        }
        .accessibilityAction(named: Text(AppL10n.settings("plugins.layout.hide", defaultValue: "隐藏"))) {
            onToggleVisible()
        }
    }
}

private struct ComponentPanelHiddenEditRowView: View {
    let item: PluginSurfaceLayoutItem
    let onToggleVisible: () -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaces.control.opacity(0.6))

                Image(systemName: PluginSystemImage.resolvedName(item.iconName))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text.disabled)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)

                Text(item.description)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.text.disabled)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggleVisible) {
                Image(systemName: PluginSystemImage.resolvedName("eye.slash"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(isHovered ? theme.surfaces.control : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help(AppL10n.settings("plugins.layout.show", defaultValue: "显示"))
            .accessibilityLabel(AppL10n.settings("plugins.layout.show", defaultValue: "显示"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaces.card.opacity(0.5))
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(AppL10n.settings("plugins.layout.show", defaultValue: "显示")) {
                onToggleVisible()
            }
        }
        .accessibilityAction(named: Text(AppL10n.settings("plugins.layout.show", defaultValue: "显示"))) {
            onToggleVisible()
        }
    }
}

private struct ComponentCardContainer: View {
    let item: PluginComponentItem
    let componentViewItem: PluginComponentViewItem?
    let measuresDetailAnchor: Bool
    let onFrameChange: (CGRect?) -> Void

    var body: some View {
        Group {
            if let componentViewItem {
                componentViewItem.content
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.55)
        .background {
            if measuresDetailAnchor {
                ComponentCardFrameReader(onFrameChange: onFrameChange)
            }
        }
        .onDisappear {
            if measuresDetailAnchor {
                onFrameChange(nil)
            }
        }
    }
}

@MainActor
final class ComponentDetailCoordinator: ObservableObject {
    struct Selection: Equatable {
        let pluginID: String
        let detailID: String
    }

    struct State: Equatable {
        var selection: Selection?
        var selectedCardFrame: CGRect?
    }

    @Published private(set) var state = State()

    func toggle(pluginID: String, detailID: String) {
        let requested = Selection(pluginID: pluginID, detailID: detailID)

        if state.selection == requested {
            state = State()
            return
        }

        let selectedCardFrame = state.selection?.pluginID == pluginID
            ? state.selectedCardFrame
            : nil
        state = State(
            selection: requested,
            selectedCardFrame: selectedCardFrame
        )
    }

    func dismiss() {
        guard state.selection != nil || state.selectedCardFrame != nil else {
            return
        }
        state = State()
    }

    func updateCardFrame(pluginID: String, frame: CGRect?) {
        guard state.selection?.pluginID == pluginID, state.selectedCardFrame != frame else {
            return
        }
        state.selectedCardFrame = frame
    }
}

@MainActor
private final class ComponentGridLayoutCache: ObservableObject {
    private struct LayoutItem: Equatable {
        let id: String
        let span: PluginComponentSpan
    }

    private var layoutItems: [LayoutItem] = []
    private var cachedPlacements: [ComponentGridPlacement] = []

    func placements(for items: [PluginComponentItem]) -> [ComponentGridPlacement] {
        let nextLayoutItems = items.map { LayoutItem(id: $0.id, span: $0.span) }
        guard nextLayoutItems != layoutItems else {
            return cachedPlacements
        }

        let placements = ComponentGridPlacementEngine.placements(for: items)
        layoutItems = nextLayoutItems
        cachedPlacements = placements
        return placements
    }
}

private struct ComponentCardFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { updateFrame(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { updateFrame(for: nsView) }
    }

    private func updateFrame(for view: NSView) {
        guard let window = view.window else {
            onFrameChange(nil)
            return
        }
        let rectInWindow = view.convert(view.bounds, to: nil)
        onFrameChange(window.convertToScreen(rectInWindow))
    }
}

private struct ComponentDetailPanelView: View {
    let title: String
    let content: AnyView
    let onDismiss: () -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered ? theme.text.primary : theme.text.secondary
                        )
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(isCloseHovered ? theme.surfaces.hover : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { isCloseHovered = $0 }
                .keyboardShortcut(.cancelAction)
                .help(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
                .accessibilityLabel(AppL10n.settings("panelTheme.close", defaultValue: "关闭"))
            }

            content
        }
        .padding(MenuBarPanelLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { MenuBarPanelBackground() }
        .clipShape(
            RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius, style: .continuous)
        )
    }
}
