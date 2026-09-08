import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

/// Temporary presentation state only; the host persists completed moves in the rendered order.
struct PanelLayoutEditor: View {
    @ObservedObject var pluginHost: PluginHost
    let surface: PluginDisplaySurface
    let onDismiss: () -> Void
    @StateObject private var session = PanelLayoutEditingSession()
    @StateObject private var scroller = PanelLayoutDragScroller()
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(pluginHost: PluginHost, surface: PluginDisplaySurface, onDismiss: @escaping () -> Void,
         session: @autoclosure @escaping () -> PanelLayoutEditingSession = PanelLayoutEditingSession()) {
        self.pluginHost = pluginHost
        self.surface = surface
        self.onDismiss = onDismiss
        self._session = StateObject(wrappedValue: session())
    }

    private var ids: [String] {
        surface == .dashboard ? pluginHost.componentItems.map(\.id) : pluginHost.panelItems.map(\.id)
    }

    private var placements: [ComponentGridPlacement] {
        surface == .dashboard ? ComponentGridPlacementEngine.placements(for: pluginHost.componentItems) : []
    }

    private var previewIDs: [String] {
        session.previewIDs(currentIDs: ids)
    }

    private var previewPlacements: [ComponentGridPlacement] {
        guard surface == .dashboard else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: pluginHost.componentItems.map { ($0.id, $0) })
        return ComponentGridPlacementEngine.placements(for: previewIDs.compactMap { lookup[$0] })
    }

    var body: some View {
        VStack(spacing: PanelLayoutDestination.footerSpacing) {
            editor
            HStack(spacing: 8) {
                Text(destinationDescription ?? session.feedback.message)
                    .font(.caption)
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(PanelLayoutCopy.undo, action: undo)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!session.canUndo(ids: ids))
                    .accessibilityIdentifier("panel.layout.undo")
            }
            .padding(.horizontal, 4)
            .frame(height: PanelLayoutDestination.footerHeight)
        }
        .onChange(of: session.feedback) { _, feedback in
            guard feedback != .guidance else { return }
            announce(feedback.message)
        }
    }

    private var editor: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if surface == .dashboard {
                        dashboard
                    } else {
                        featureList
                    }
                    Color.clear.frame(height: PanelLayoutDestination.dropTailHeight)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .background(PanelLayoutScrollAnchor(scroller: scroller))
                .onDrop(of: [PanelLayoutDragTransfer.type], delegate: PanelLayoutDropDelegate(
                    session: session,
                    ids: { ids },
                    update: updateDestination,
                    stopScrolling: scroller.stop,
                    commit: commit
                ))
            }
            .onChange(of: ids) {
                session.reconcile(ids: ids)
                scroller.stop()
            }
            .onChange(of: placements) {
                // A span change also invalidates the drag's geometry snapshot.
                session.invalidate()
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
        let lookup = Dictionary(uniqueKeysWithValues: pluginHost.panelItems.map { ($0.id, $0) })
        return VStack(spacing: PanelLayoutDestination.rowSpacing) {
            ForEach(Array(previewIDs.enumerated()), id: \.element) { index, id in
                if let item = lookup[id] {
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
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: previewIDs)
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
                if let item = lookup[placement.id], let index = previewIDs.firstIndex(of: item.id) {
                    reorderItem(id: item.id, title: item.title, icon: item.iconName, index: index) {
                        pluginHost.componentViewItem(for: item.id, dismiss: onDismiss).content
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: previewPlacements)
        .frame(width: ComponentPanelLayout.gridWidth,
               height: ComponentPanelLayout.gridContentHeight(for: previewPlacements), alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if let destination = session.destination,
               let marker = PanelLayoutDestination.gridInsertionFrame(
                offset: destination, placements: placements, rightToLeft: layoutDirection == .rightToLeft
               ) {
                Rectangle().fill(theme.accent)
                    .frame(width: marker.width, height: marker.height)
                    .offset(x: marker.minX, y: marker.minY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func reorderItem<Content: View>(id: String, title: String, icon: String, index: Int,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        PanelLayoutReorderItem(id: id, title: title, icon: icon, index: index, count: ids.count,
                               isDragging: session.sourceID == id,
                               move: { offset in commit(.init(id: id, offset: offset)) }) {
            content()
        } beginDrag: {
            scroller.stop()
            return session.begin(id: id, ids: ids)
        } endDrag: { token in
            guard session.token == token else { return }
            scroller.stop()
            session.sourceEnded(token: token)
        }
    }

    private func updateDestination(_ point: CGPoint) {
        guard session.validate(ids: ids) else { scroller.stop(); return }
        preview(at: point)
        scroller.start(onScroll: preview)
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
        save(move, isUndo: false)
    }

    private func undo() {
        guard let move = session.takeUndo(ids: ids) else { return }
        save(move, isUndo: true)
    }

    private func save(_ move: PanelLayoutEditingSession.Move, isUndo: Bool) {
        scroller.stop()
        session.cancel()
        let before = ids
        guard before.contains(move.id) else { session.rejectMove(); return }
        let result = PanelLayoutDestination.moving(move.id, toOffset: move.offset, in: before)
        guard result != before else { return }
        pluginHost.moveRenderedPlugin(id: move.id, toOffset: move.offset, on: surface)
        guard ids == result else { session.rejectMove(); return }
        if isUndo { session.didUndo() }
        else { session.didSave(move, beforeIDs: before, afterIDs: result) }
    }

    private var destinationDescription: String? {
        guard let source = session.sourceID, session.destination != nil,
              let index = session.previewIDs(currentIDs: ids).firstIndex(of: source),
              let title = title(for: source) else { return nil }
        return PanelLayoutCopy.position(title, index: index, count: ids.count)
    }

    private func title(for id: String) -> String? {
        surface == .dashboard
            ? pluginHost.componentItems.first { $0.id == id }?.title
            : pluginHost.panelItems.first { $0.id == id }?.title
    }

    private func announce(id: String, index: Int) {
        guard let title = title(for: id) else { return }
        announce(PanelLayoutCopy.position(title, index: index, count: ids.count))
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message,
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

private struct PanelLayoutReorderItem<Content: View>: View {
    let id: String
    let title: String
    let icon: String
    let index: Int
    let count: Int
    let isDragging: Bool
    let move: (Int) -> Void
    @ViewBuilder let content: () -> Content
    let beginDrag: () -> String?
    let endDrag: (String) -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.panelLayoutScrollToItem) private var scrollToItem
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .opacity(isDragging ? 0.32 : 1)
                .scaleEffect(isDragging ? 0.985 : 1)
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
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
            PanelLayoutDragSource(id: id, title: title, icon: icon, begin: beginDrag, end: endDrag)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDragging || isFocused ? theme.accent : theme.text.secondary,
                              style: StrokeStyle(lineWidth: isDragging || isFocused ? 2 : 1, dash: [4, 3]))
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

enum PanelLayoutDragTransfer {
    static let type = UTType(exportedAs: "com.mactools.panel-layout-item")

    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)

    static func pasteboardItem(token: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(token, forType: pasteboardType)
        return item
    }

    static func accepts(
        providers: [NSItemProvider],
        hasActiveSession: Bool,
        sessionIsValid: Bool
    ) -> Bool {
        guard hasActiveSession, sessionIsValid else { return false }
        return providers.contains {
            $0.hasItemConformingToTypeIdentifier(type.identifier)
        }
    }
}

private struct PanelLayoutDropDelegate: DropDelegate {
    let session: PanelLayoutEditingSession
    let ids: () -> [String]
    let update: (CGPoint) -> Void
    let stopScrolling: () -> Void
    let commit: (PanelLayoutEditingSession.Move) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        PanelLayoutDragTransfer.accepts(
            providers: info.itemProviders(for: [PanelLayoutDragTransfer.type]),
            hasActiveSession: session.token != nil,
            sessionIsValid: session.validate(ids: ids())
        )
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
