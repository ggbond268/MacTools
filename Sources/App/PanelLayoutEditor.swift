import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

/// Temporary presentation state only; completed moves go through the same host path as Settings.
struct PanelLayoutEditor: View {
    @ObservedObject var pluginHost: PluginHost
    let surface: PluginDisplaySurface
    @StateObject private var session = PanelLayoutEditingSession()
    @StateObject private var scroller = PanelLayoutDragScroller()
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ids: [String] {
        surface == .dashboard ? pluginHost.componentItems.map(\.id) : pluginHost.panelItems.map(\.id)
    }

    private var placements: [ComponentGridPlacement] {
        ComponentGridPlacementEngine.placements(for: pluginHost.componentItems)
    }

    private var previewPlacements: [ComponentGridPlacement] {
        let lookup = Dictionary(uniqueKeysWithValues: pluginHost.componentItems.map { ($0.id, $0) })
        return ComponentGridPlacementEngine.placements(
            for: session.previewIDs(currentIDs: ids).compactMap { lookup[$0] }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if surface == .dashboard {
                        dashboard
                    } else {
                        featureList
                    }
                    Color.clear.frame(height: 24)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(PanelLayoutScrollAnchor(scroller: scroller))
                .onDrop(of: [PanelLayoutDropDelegate.type], delegate: PanelLayoutDropDelegate(
                    session: session,
                    ids: { ids },
                    update: updateDestination,
                    stopScrolling: scroller.stop,
                    commit: commit
                ))
            }
            .onChange(of: ids) {
                session.cancel()
                scroller.stop()
            }
            .onChange(of: placements) {
                // A span change also invalidates the drag's geometry snapshot.
                session.cancel()
                scroller.stop()
            }
            .onDisappear {
                scroller.stop()
                session.cancel()
            }
            .environment(\.panelLayoutScrollToItem, { id in
                if reduceMotion { proxy.scrollTo(id) }
                else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            })
        }
    }

    private var featureList: some View {
        VStack(spacing: PanelLayoutDestination.rowSpacing) {
            ForEach(Array(pluginHost.panelItems.enumerated()), id: \.element.id) { index, item in
                reorderItem(id: item.id, title: item.title, icon: item.iconName, index: index) {
                    HStack(spacing: 10) {
                        Image(systemName: PluginSystemImage.resolvedName(item.iconName))
                            .foregroundStyle(item.iconTint)
                            .frame(width: 20)
                        Text(item.title).font(.body).lineLimit(1)
                        Spacer(minLength: 64)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: PanelLayoutDestination.rowHeight)
                    .background(theme.surfaces.card, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .overlay(alignment: .top) {
            if let destination = session.destination {
                Rectangle()
                    .fill(theme.accent)
                    .frame(height: 3)
                    .offset(y: max(0, CGFloat(destination) * (PanelLayoutDestination.rowHeight + PanelLayoutDestination.rowSpacing) - 5))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var dashboard: some View {
        let lookup = Dictionary(uniqueKeysWithValues: pluginHost.componentItems.map { ($0.id, $0) })
        return ZStack(alignment: .topLeading) {
            ForEach(previewPlacements) { placement in
                if let item = lookup[placement.id], let index = ids.firstIndex(of: item.id) {
                    reorderItem(id: item.id, title: item.title, icon: item.iconName, index: index) {
                        pluginHost.componentViewItem(for: item.id, dismiss: {}).content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .frame(width: ComponentPanelLayout.itemWidth(for: placement.span),
                           height: ComponentPanelLayout.itemHeight(for: placement.span))
                    .environment(\.layoutDirection, layoutDirection)
                    .offset(x: layoutDirection == .rightToLeft
                            ? ComponentPanelLayout.gridWidth - PanelLayoutDestination.frame(placement).maxX
                            : ComponentPanelLayout.xOffset(for: placement),
                            y: placement.yOffset)
                }
            }
        }
        // Keep canvas coordinates physical; mirror card positions explicitly for RTL.
        .frame(width: ComponentPanelLayout.gridWidth,
               height: max(ComponentPanelLayout.gridContentHeight(for: placements),
                           ComponentPanelLayout.gridContentHeight(for: previewPlacements)), alignment: .topLeading)
        .environment(\.layoutDirection, .leftToRight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: previewPlacements)
    }

    private func reorderItem<Content: View>(id: String, title: String, icon: String, index: Int,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        PanelLayoutReorderItem(id: id, title: title, index: index, count: ids.count,
                               isDragTarget: session.sourceID == id && session.destination != nil,
                               move: { offset in commit(.init(id: id, offset: offset)) }) {
            content()
        } dragProvider: {
            scroller.stop()
            let provider = NSItemProvider()
            if let token = session.begin(id: id, ids: ids) {
                provider.suggestedName = token
                provider.registerDataRepresentation(forTypeIdentifier: PanelLayoutDropDelegate.type.identifier,
                                                    visibility: .ownProcess) { completion in
                    completion(Data(token.utf8), nil)
                    return nil
                }
            }
            return provider
        } dragPreview: {
            Label(title, systemImage: PluginSystemImage.resolvedName(icon))
                .padding(12)
                .background(theme.surfaces.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func updateDestination(_ point: CGPoint) {
        guard session.validate(ids: ids) else { scroller.stop(); return }
        preview(at: point)
        scroller.start(onScroll: preview, onCancel: session.cancel)
    }

    private func preview(at point: CGPoint) {
        let offset = surface == .dashboard
            ? PanelLayoutDestination.gridOffset(at: point, placements: placements, rightToLeft: layoutDirection == .rightToLeft)
            : PanelLayoutDestination.listOffset(at: point, count: ids.count)
        let previous = session.destination
        session.preview(offset: offset, ids: ids)
        if previous != session.destination, let sourceID = session.sourceID,
           let index = session.previewIDs(currentIDs: ids).firstIndex(of: sourceID) {
            announce(id: sourceID, index: index)
        }
    }

    private func commit(_ move: PanelLayoutEditingSession.Move) {
        scroller.stop()
        session.cancel()
        guard ids.contains(move.id) else { return }
        let result = PanelLayoutDestination.moving(move.id, toOffset: move.offset, in: ids)
        guard result != ids, let index = result.firstIndex(of: move.id) else { return }
        pluginHost.movePlugin(id: move.id, toOffset: move.offset, on: surface)
        announce(id: move.id, index: index)
    }

    private func announce(id: String, index: Int) {
        let title = surface == .dashboard
            ? pluginHost.componentItems.first { $0.id == id }?.title
            : pluginHost.panelItems.first { $0.id == id }?.title
        guard let title else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: PanelLayoutCopy.position(title, index: index, count: ids.count),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
}

private struct PanelLayoutScrollToItemKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (String) -> Void = { _ in }
}

private extension EnvironmentValues {
    var panelLayoutScrollToItem: @MainActor @Sendable (String) -> Void {
        get { self[PanelLayoutScrollToItemKey.self] }
        set { self[PanelLayoutScrollToItemKey.self] = newValue }
    }
}

private struct PanelLayoutReorderItem<Content: View, Preview: View>: View {
    let id: String
    let title: String
    let index: Int
    let count: Int
    let isDragTarget: Bool
    let move: (Int) -> Void
    @ViewBuilder let content: () -> Content
    let dragProvider: () -> NSItemProvider
    @ViewBuilder let dragPreview: () -> Preview
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.panelLayoutScrollToItem) private var scrollToItem
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                    .onDrag(dragProvider, preview: dragPreview)
                    .accessibilityHidden(true)
                Menu {
                    Button(PanelLayoutCopy.earlier) { perform(index - 1) }.disabled(index == 0)
                    Button(PanelLayoutCopy.later) { perform(index + 2) }.disabled(index == count - 1)
                    Button(PanelLayoutCopy.beginning) { perform(0) }.disabled(index == 0)
                    Button(PanelLayoutCopy.end) { perform(count) }.disabled(index == count - 1)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 28)
                        .background(theme.surfaces.control, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if focused { scrollToItem(id) }
                }
                .accessibilityLabel(PanelLayoutCopy.position(title, index: index, count: count))
                .accessibilityHint(PanelLayoutCopy.hint)
                .accessibilityAction(named: PanelLayoutCopy.earlier) { if index > 0 { perform(index - 1) } }
                .accessibilityAction(named: PanelLayoutCopy.later) { if index < count - 1 { perform(index + 2) } }
                .accessibilityAction(named: PanelLayoutCopy.beginning) { perform(0) }
                .accessibilityAction(named: PanelLayoutCopy.end) { perform(count) }
            }
            .padding(6)
            .background(theme.surfaces.control, in: RoundedRectangle(cornerRadius: 6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDragTarget || isFocused ? theme.accent : theme.text.secondary,
                              style: StrokeStyle(lineWidth: isDragTarget || isFocused ? 2 : 1, dash: [4, 3]))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .id(id)
    }

    private func perform(_ offset: Int) {
        move(offset)
        scrollToItem(id)
    }
}

private struct PanelLayoutDropDelegate: DropDelegate {
    static let type = UTType(exportedAs: "com.mactools.panel-layout-item")
    let session: PanelLayoutEditingSession
    let ids: () -> [String]
    let update: (CGPoint) -> Void
    let stopScrolling: () -> Void
    let commit: (PanelLayoutEditingSession.Move) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let token = session.token, session.validate(ids: ids()) else { return false }
        return info.itemProviders(for: [Self.type]).contains { $0.suggestedName == token }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        update(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        stopScrolling()
        session.leave()
    }

    func performDrop(info: DropInfo) -> Bool {
        stopScrolling()
        guard validateDrop(info: info) else { session.cancel(); return false }
        update(info.location)
        stopScrolling()
        guard let move = session.finish(ids: ids()) else { return true }
        commit(move)
        return true
    }
}
