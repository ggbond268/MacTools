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
        placements(for: items.map { (id: $0.id, span: $0.span) }, columns: columns)
    }

    static func placements(for items: [(id: String, span: PluginComponentSpan)],
                           columns: Int = ComponentPanelLayout.columns) -> [ComponentGridPlacement] {
        var occupiedCells: Set<GridCell> = []
        var placements: [ComponentGridPlacement] = []
        var columnBottoms = Array(repeating: CGFloat(0), count: columns)
        var firstCandidateRows: [PluginComponentSpan: Int] = [:]

        for item in items {
            let span = item.span
            // Occupancy only grows. Rows rejected for this span cannot become free.
            // Keep first-fit packing without scanning those rows for every copy.
            var row = firstCandidateRows[span, default: 0]

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
                    firstCandidateRows[span] = row
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
    @State private var detailAnchors = ComponentDetailAnchorRegistry()
    @StateObject private var layoutCache = ComponentGridLayoutCache()
    @StateObject private var secondaryPanelController = SecondaryPanelController()
    @ObservedObject var pluginHost: PluginHost
    let contentBodyHeight: CGFloat
    let isPanelVisible: Bool
    let onDismiss: () -> Void
    var panelID: String? = nil
    var suppliedItems: [PluginComponentItem]? = nil
    var suppliedEntries: [MenuBarPanelEntry]? = nil
    var embedded = false
    var suppliedPlacements: [ComponentGridPlacement]? = nil
    var suppliedGridHeight: CGFloat? = nil
    var onInlinePresentationChange: (Bool) -> Void = { _ in }

    private var items: [PluginComponentItem] { suppliedItems ?? pluginHost.componentItems }
    @Environment(\.menuBarPanelTheme) private var theme

    private var placements: [ComponentGridPlacement] {
        suppliedPlacements ?? layoutCache.placements(for: items)
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
            .allowsHitTesting(false)
        )
        .onAppear { [detailCoordinator] in
            let handler: (String, String) -> Void = { [weak detailCoordinator, weak detailAnchors] pluginID, detailID in
                detailCoordinator?.toggle(pluginID: pluginID, detailID: detailID,
                    presentationID: detailAnchors?.presentationID(for: pluginID))
            }
            if let panelID { pluginHost.componentDetailHandlersByPanelID[panelID] = handler }
            else { pluginHost.componentDetailPresentationHandler = handler }
            secondaryPanelController.onHostWindowDismissRequest = { [weak detailCoordinator] in
                detailCoordinator?.dismiss()
            }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedID = detailCoordinator.state.selection?.pluginID, !ids.contains(selectedID) { dismissDetail() }
        }
        .onChange(of: secondaryPanelController.isPresentingInline) { _, inline in
            onInlinePresentationChange(inline)
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
        .onReceive(NotificationCenter.default.publisher(for: AppAppearancePreference.didChangeNotification)) { _ in
            secondaryPanelController.applyCurrentAppearance()
        }
        .onDisappear {
            onInlinePresentationChange(false)
            if let panelID { pluginHost.componentDetailHandlersByPanelID.removeValue(forKey: panelID) }
            else { pluginHost.componentDetailPresentationHandler = nil }
            secondaryPanelController.onHostWindowDismissRequest = nil
            dismissDetail()
            secondaryPanelController.setHostWindow(nil)
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if embedded {
                grid
            } else {
                ScrollView(.vertical, showsIndicators: false) { grid }
                    .background(ScrollViewScrollerVisibilityConfigurator())
                    .clipShape(RoundedRectangle(cornerRadius: ComponentPanelLayout.scrollClipCornerRadius, style: .continuous))
            }
        }
    }

    private var grid: some View {
        ComponentGridView(
            pluginHost: pluginHost, items: items, entries: suppliedEntries, placements: placements, contentHeight: suppliedGridHeight,
            detailAnchorID: detailCoordinator.state.selection.map { $0.presentationID ?? $0.pluginID },
            detailAnchors: detailAnchors,
            onDismiss: onDismiss, onCardFrameChange: { id, frame in
                detailCoordinator.updatePresentationFrame(id: id, frame: frame)
            }
        )
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
    let entries: [MenuBarPanelEntry]?
    let placements: [ComponentGridPlacement]
    var contentHeight: CGFloat? = nil
    let detailAnchorID: String?
    let detailAnchors: ComponentDetailAnchorRegistry
    let onDismiss: () -> Void
    let onCardFrameChange: (String, CGRect?) -> Void

    private var itemsByID: [String: PluginComponentItem] {
        let templates = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard let entries else { return templates }
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            templates[entry.pluginID].map { (entry.presentationID, $0) }
        })
    }

    var body: some View {
        let itemLookup = itemsByID

        let frames = placements.map { placement in
            PanelItemFrame(id: placement.id, frame: CGRect(
                x: ComponentPanelLayout.xOffset(for: placement), y: placement.yOffset,
                width: ComponentPanelLayout.itemWidth(for: placement.span),
                height: ComponentPanelLayout.itemHeight(for: placement.span)))
        }
        PanelViewportStack(frames: frames, width: ComponentPanelLayout.gridWidth,
                           height: contentHeight ?? ComponentPanelLayout.gridContentHeight(for: placements),
                           retainedIDs: Set([detailAnchorID].compactMap { $0 })) { id in
            if let item = itemLookup[id] {
                ComponentCardContainer(
                    item: item,
                    componentViewItem: pluginHost.componentViewItem(for: item.id, dismiss: onDismiss),
                    measuresDetailAnchor: id == detailAnchorID,
                    onFrameChange: { onCardFrameChange(id, $0) }
                )
                .background(ComponentDetailAnchor(registry: detailAnchors, pluginID: item.id,
                                                   presentationID: id).allowsHitTesting(false))
            }
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
        var presentationID: String? = nil
    }

    struct State: Equatable {
        var selection: Selection?
        var selectedCardFrame: CGRect?
    }

    @Published private(set) var state = State()

    func toggle(pluginID: String, detailID: String, presentationID: String? = nil) {
        let requested = Selection(pluginID: pluginID, detailID: detailID, presentationID: presentationID)

        if state.selection == requested {
            state = State()
            return
        }

        let selectedCardFrame = state.selection?.pluginID == pluginID && state.selection?.presentationID == presentationID
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

    func updatePresentationFrame(id: String, frame: CGRect?) {
        guard let selection = state.selection, (selection.presentationID ?? selection.pluginID) == id,
              state.selectedCardFrame != frame else { return }
        state.selectedCardFrame = frame
    }

    func updateCardFrame(pluginID: String, frame: CGRect?) {
        guard state.selection?.pluginID == pluginID, state.selectedCardFrame != frame else {
            return
        }
        state.selectedCardFrame = frame
    }
}

@MainActor
final class ComponentGridLayoutCache: ObservableObject {
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

/// Resolve the initiating copy only when a detail is requested; no per-card geometry polling.
@MainActor
private final class ComponentDetailAnchorRegistry {
    final class Entry: NSObject {
        let pluginID: String
        let presentationID: String
        init(pluginID: String, presentationID: String) {
            self.pluginID = pluginID
            self.presentationID = presentationID
        }
    }
    let views = NSMapTable<NSView, Entry>.weakToStrongObjects()

    func presentationID(for pluginID: String) -> String? {
        let candidates = views.keyEnumerator().allObjects.compactMap { $0 as? NSView }.filter {
            views.object(forKey: $0)?.pluginID == pluginID && $0.window != nil
        }
        let source = candidates.first { view in
            guard let window = view.window else { return false }
            let point: CGPoint
            if NSApp.currentEvent?.type == .keyDown, let focused = window.firstResponder as? NSView {
                point = view.convert(CGPoint(x: focused.bounds.midX, y: focused.bounds.midY), from: focused)
            } else {
                point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            }
            return view.bounds.contains(point)
        } ?? candidates.first
        return source.flatMap { views.object(forKey: $0)?.presentationID }
    }
}

private struct ComponentDetailAnchor: NSViewRepresentable {
    let registry: ComponentDetailAnchorRegistry
    let pluginID: String
    let presentationID: String

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        registry.views.setObject(.init(pluginID: pluginID, presentationID: presentationID), forKey: view)
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
