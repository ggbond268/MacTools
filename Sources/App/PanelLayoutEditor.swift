import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

/// Drag previews stay local; only completed operations change the host's layout.
struct PanelLayoutEditor: View {
    @ObservedObject var pluginHost: PluginHost
    let panelID: String
    let onDismiss: () -> Void
    let revealBottomRequest: UUID?
    @StateObject private var session: PanelLayoutEditingSession
    @StateObject private var scroller = PanelLayoutDragScroller()
    @State private var hover = PanelLayoutHoverState()
    @State private var entryToRemove: MenuBarPanelLayoutEntry?
    @State private var removalSourceRect = CGRect.zero
    @Namespace private var popoverCoordinateSpace
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(pluginHost: PluginHost, panelID: String, onDismiss: @escaping () -> Void,
         session: @autoclosure @escaping () -> PanelLayoutEditingSession = PanelLayoutEditingSession(),
         revealBottomRequest: UUID? = nil) {
        self.pluginHost = pluginHost
        self.panelID = panelID
        self.onDismiss = onDismiss
        self.revealBottomRequest = revealBottomRequest
        self._session = StateObject(wrappedValue: session())
    }

    init(pluginHost: PluginHost, surface: PluginDisplaySurface, onDismiss: @escaping () -> Void,
         session: @autoclosure @escaping () -> PanelLayoutEditingSession = PanelLayoutEditingSession(),
         revealBottomRequest: UUID? = nil) {
        self.init(pluginHost: pluginHost, panelID: surface.defaultPanelID, onDismiss: onDismiss, session: session(), revealBottomRequest: revealBottomRequest)
    }

    private var entries: [MenuBarPanelEntry] { pluginHost.panelEntries(in: panelID) }
    private var ids: [String] { entries.map(\.id) }

    var body: some View {
        let layout = PanelLayoutEditorSnapshot(pluginHost: pluginHost, panelID: panelID)
        GeometryReader { geometry in
            Group {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        visibleContent(layout)
                            .frame(minHeight: geometry.size.height, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .onDrop(of: [PanelLayoutDragTransfer.type], delegate: PanelLayoutDropDelegate(
                                session: session, ids: { ids }, validate: { session.validate(in: pluginHost, panelID: panelID) },
                                update: { updateDestination($0, layout: layout) },
                                stopScrolling: scroller.stop, commit: commit
                            ))
                    }
                    .frame(maxWidth: .infinity)
                    .background(PanelLayoutScrollAnchor(scroller: scroller, hover: hover, bottomRequest: revealBottomRequest))
                }
                .overlay {
                    if layout.ids.isEmpty {
                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                    }
                }
                .onChange(of: layout.ids) {
                    session.reconcile(ids: layout.ids, panelID: panelID)
                    scroller.stop()
                }
                .onChange(of: layout.frames) {
                    if session.destinationPanelID == nil || session.destinationPanelID == panelID { session.invalidate() }
                    scroller.stop()
                }
                .onChange(of: session.token) { _, token in
                    hover.setDragging(token != nil)
                    if token == nil { scroller.stop() }
                }
                .onAppear { hover.setDragging(session.token != nil) }
                .onDisappear { scroller.stop() }
                .environment(\.panelLayoutScrollToItem, { id in
                    DispatchQueue.main.async {
                        let updated = PanelLayoutEditorSnapshot(pluginHost: pluginHost, panelID: panelID)
                        if let frame = updated.frames.first(where: { $0.id == id })?.frame {
                            scroller.reveal(frame)
                        }
                    }
                })
            }
            .coordinateSpace(name: popoverCoordinateSpace)
            .popover(item: $entryToRemove, attachmentAnchor: removalAttachment(in: geometry.size),
                     arrowEdge: .trailing) { item in
                MenuBarPanelRemovalConfirmation(
                    title: FeatureL10n.string("移除组件？"),
                    message: FeatureL10n.format("将从此面板移除“%@”。你可以从添加组件中重新添加。", item.item.title),
                    systemImage: item.item.iconName, actionTitle: FeatureL10n.string("移除"),
                    errorLabel: FeatureL10n.string("无法移除组件"), identifier: "panel.layout.remove",
                    onCancel: { entryToRemove = nil }, onConfirm: {
                        scroller.stop()
                        session.reset()
                        entryToRemove = nil
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            _ = pluginHost.removePanelEntry(item.entry, from: panelID)
                        }
                        return nil
                    }
                )
                .onExitCommand { entryToRemove = nil }
            }
            .onChange(of: session.feedback) { _, feedback in
                guard feedback != .guidance else { return }
                announce(feedback.message)
            }
        }
    }

    private func removalAttachment(in size: CGSize) -> PopoverAttachmentAnchor {
        guard removalSourceRect.height > 0, size.width > 0, size.height > 0 else { return .rect(.bounds) }
        // Keep the popover beside the viewport, at the clicked control's height.
        // AppKit handles screen-edge avoidance; no window coordinates are needed.
        let height = min(removalSourceRect.height, size.height)
        let y = min(max(removalSourceRect.minY, 0), size.height - height)
        return .rect(.rect(CGRect(x: 0, y: y, width: size.width, height: height)))
    }

    private func visibleContent(_ layout: PanelLayoutEditorSnapshot) -> some View {
        let positions = layout.frames
        let indices = Dictionary(uniqueKeysWithValues: layout.ids.enumerated().map { ($0.element, $0.offset) })
        return PanelViewportStack(frames: layout.itemFrames(rightToLeft: layoutDirection == .rightToLeft),
                              width: ComponentPanelLayout.gridWidth,
                              height: PanelLayoutDestination.visibleContentHeight(itemHeight: layout.height),
                              retainedIDs: Set([session.sourceID, hover.focusedItemID].compactMap { $0 })) { id in
            if let item = layout.items[id], let index = indices[id] {
                reorderItem(item, feature: layout.features[item.entry.pluginID], index: index, count: layout.ids.count)
                    .environment(\.layoutDirection, layoutDirection)
            }
        }
        .overlay(alignment: .topLeading) {
            PanelLayoutInsertionMarker(preview: session.dragPreview, frames: positions,
                                       rightToLeft: layoutDirection == .rightToLeft)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: positions)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var emptyState: some View {
        Text(FeatureL10n.string("点击添加组件，为此面板添加内容"))
            .font(.subheadline)
            .foregroundStyle(theme.text.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("panel.layout.empty")
    }

    private func reorderItem(_ item: MenuBarPanelLayoutEntry, feature: PluginPanelItem?, index: Int, count: Int) -> some View {
        PanelLayoutReorderItem(
            id: item.id, title: item.item.title, icon: item.item.iconName, index: index, count: count,
            isDragging: session.sourceID == item.id, panels: pluginHost.menuBarPanels, panelID: panelID,
            hover: hover, hoverState: hover.state(for: item.id),
            nativeSource: session.nativeDragSource,
            popoverCoordinateSpace: popoverCoordinateSpace,
            move: { commit(.init(id: item.id, offset: $0)) },
            remove: { sourceRect in
                removalSourceRect = sourceRect
                entryToRemove = item
            },
            moveToPanel: { move(item.entry, to: $0) }
        ) {
            if item.surface == .dashboard {
                pluginHost.componentViewItem(for: item.item.id, dismiss: onDismiss).content
            } else if let feature {
                FeatureRowView(
                    item: feature,
                    indicator: pluginHost.primaryPanelIndicatorsByID[feature.id],
                    compactIndicator: pluginHost.primaryPanelCompactIndicatorsByID[feature.id],
                    onDisclosureToggle: { _ in }, onSelectionChange: { _, _ in },
                    onNavigationSelectionChange: { _, _ in }, onNavigationHoverChange: { _, _, _ in },
                    onNavigationRowFrameChange: { _, _, _ in }, onDateChange: { _, _ in },
                    onSwitchChange: { _ in false }, onSliderChange: { _, _, _ in },
                    onActionInvoke: { _, _ in }
                )
            }
        } beginDrag: {
            scroller.stop()
            return session.begin(entry: item.entry, panelID: panelID, ids: ids)
        } endDrag: { [weak session, weak scroller] token in
            guard let session, session.token == token else { return }
            scroller?.stop()
            session.sourceEnded(token: token)
        }
    }

    private func move(_ entry: MenuBarPanelEntry, to destination: String) {
        scroller.stop(); session.reset()
        _ = pluginHost.transferPanelEntry(entry, from: panelID, to: destination, at: pluginHost.panelEntries(in: destination).count)
    }

    private func updateDestination(_ point: CGPoint, layout: PanelLayoutEditorSnapshot) {
        guard session.validate(in: pluginHost, panelID: panelID) else { scroller.stop(); return }
        preview(at: point, layout: layout)
        scroller.start { preview(at: $0, layout: layout) }
    }

    private func preview(at point: CGPoint, layout: PanelLayoutEditorSnapshot) {
        let offset = PanelLayoutEntryFrame.destination(at: point, frames: layout.frames,
                                                      rightToLeft: layoutDirection == .rightToLeft)
        session.preview(offset: offset, ids: layout.ids)
    }

    private func commit(_ move: PanelLayoutEditingSession.Move) {
        scroller.stop()
        session.commit(move, in: pluginHost, panelID: panelID)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }
}

/// Resolve the host's ordering and packing once per content update, then reuse the
/// same geometry for rendering, pointer movement, and drag autoscrolling.
@MainActor
private struct PanelLayoutEditorSnapshot {
    let ids: [String]
    let items: [String: MenuBarPanelLayoutEntry]
    let features: [String: PluginPanelItem]
    let frames: [PanelLayoutEntryFrame]
    let height: CGFloat

    func itemFrames(rightToLeft: Bool) -> [PanelItemFrame] {
        frames.map { position in
            var frame = position.frame
            if rightToLeft { frame.origin.x = ComponentPanelLayout.gridWidth - frame.maxX }
            return PanelItemFrame(id: position.id, frame: frame)
        }
    }

    init(pluginHost: PluginHost, panelID: String) {
        let entries = pluginHost.panelEntries(in: panelID)
        let features = pluginHost.panelItems(in: panelID)
        let placement = ConfiguredMenuBarPanelLayout.placement(
            entries: entries, components: pluginHost.componentItems(in: panelID), features: features
        )
        ids = entries.map(\.id)
        items = Dictionary(uniqueKeysWithValues: pluginHost.panelLayoutEntries(in: panelID).map { ($0.id, $0) })
        self.features = Dictionary(uniqueKeysWithValues: features.map { ($0.id, $0) })
        frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
        height = placement.height
    }
}

private struct PanelLayoutInsertionMarker: View {
    @ObservedObject var preview: PanelLayoutDragPreview
    let frames: [PanelLayoutEntryFrame]
    let rightToLeft: Bool
    @Environment(\.menuBarPanelTheme) private var theme

    var body: some View {
        if let destination = preview.destination,
           let marker = PanelLayoutEntryFrame.insertionFrame(offset: destination, frames: frames, rightToLeft: rightToLeft) {
            RoundedRectangle(cornerRadius: 1).fill(theme.accent)
                .frame(width: marker.width, height: marker.height)
                .offset(x: marker.minX, y: marker.minY)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// The committed geometry remains the drag hit map even while the insertion marker moves.
struct PanelLayoutEntryFrame: Equatable, Identifiable {
    let entry: MenuBarPanelEntry
    let frame: CGRect
    var id: String { entry.id }

    static func frames(entries: [MenuBarPanelEntry], placement: ConfiguredMenuBarPanelLayout.Placement) -> [Self] {
        let components = Dictionary(uniqueKeysWithValues: placement.components.map { ($0.id, $0) })
        return entries.compactMap { entry in
            switch entry.surface {
            case .dashboard:
                guard let item = components[entry.presentationID] else { return nil }
                return Self(entry: entry, frame: PanelLayoutDestination.frame(item))
            case .featurePanel:
                guard let y = placement.featureOffsets[entry.presentationID],
                      let height = placement.featureHeights[entry.presentationID] else { return nil }
                return Self(entry: entry, frame: CGRect(x: 0, y: y, width: ComponentPanelLayout.gridWidth,
                                                       height: height))
            }
        }
    }

    static func destination(at point: CGPoint, frames: [Self], rightToLeft: Bool) -> Int {
        guard !frames.isEmpty else { return 0 }
        if point.y < 0 { return 0 }
        if point.y >= frames.map(\.frame.maxY).max()! { return frames.count }
        let point = CGPoint(x: rightToLeft ? ComponentPanelLayout.gridWidth - point.x : point.x, y: point.y)
        func distance(_ rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        let nearest = frames.enumerated().min { distance($0.element.frame) < distance($1.element.frame) }!
        let after = nearest.element.entry.surface == .featurePanel
            ? point.y >= nearest.element.frame.midY : point.x >= nearest.element.frame.midX
        return nearest.offset + (after ? 1 : 0)
    }

    static func insertionFrame(offset: Int, frames: [Self], rightToLeft: Bool) -> CGRect? {
        guard !frames.isEmpty else { return CGRect(x: 0, y: 0, width: ComponentPanelLayout.gridWidth, height: 3) }
        let index = min(max(offset, 0), frames.count)
        let item = frames[min(index, frames.count - 1)]
        if item.entry.surface == .featurePanel {
            return CGRect(x: 0, y: index == frames.count ? item.frame.maxY : item.frame.minY,
                          width: item.frame.width, height: 3)
        }
        let x = index == frames.count ? item.frame.maxX - 3 : item.frame.minX
        return CGRect(x: rightToLeft ? ComponentPanelLayout.gridWidth - x - 3 : x,
                      y: item.frame.minY, width: 3, height: item.frame.height)
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
    let panels: [MenuBarPanelDefinition]
    let panelID: String
    let hover: PanelLayoutHoverState
    @ObservedObject var hoverState: PanelLayoutItemHoverState
    let nativeSource: PanelLayoutNativeDragSource
    let popoverCoordinateSpace: Namespace.ID
    let move: (Int) -> Void
    let remove: (CGRect) -> Void
    let moveToPanel: (String) -> Void
    @ViewBuilder let content: Content
    let beginDrag: () -> String?
    let endDrag: (String) -> Void
    @Environment(\.menuBarPanelTheme) private var theme
    @Environment(\.panelLayoutScrollToItem) private var scrollToItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Control: Hashable { case remove, moveTo, more }
    @FocusState private var focusedControl: Control?

    private var showsControls: Bool { hoverState.isActive }

    var body: some View {
        ZStack {
            // Preserve the plugin's enabled appearance while excluding its content
            // from pointer input, keyboard focus, and accessibility actions.
            content
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .compositingGroup()
                .blur(radius: showsControls ? 2 : 0)
                .overlay { theme.surfaces.panel.opacity(showsControls ? 0.22 : 0) }
                .clipShape(RoundedRectangle(cornerRadius: MenuBarPanelLayout.cornerRadius))
                .opacity(isDragging ? 0.32 : 1)
                .scaleEffect(isDragging ? 0.985 : 1)
                .allowsHitTesting(false)
                .focusable(false)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                let metrics = PanelLayoutItemControlsLayout(size: proxy.size)
                let layout = metrics.isVertical
                    ? AnyLayout(VStackLayout(spacing: metrics.spacing))
                    : AnyLayout(HStackLayout(spacing: metrics.spacing))
                layout {
                    Button {
                        // Read geometry only when invoked, including keyboard activation.
                        let controls = PanelLayoutItemControlsLayout.frame(in: proxy.frame(in: .named(popoverCoordinateSpace)))
                        remove(CGRect(x: controls.minX, y: controls.minY,
                                      width: metrics.buttonSide, height: metrics.buttonSide))
                    } label: {
                        controlIcon("trash", side: metrics.buttonSide)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .remove)
                    .help(FeatureL10n.string("移除组件"))
                    .accessibilityLabel(FeatureL10n.string("移除组件"))
                    .accessibilityIdentifier("panel.layout.remove.\(id)")

                    Menu {
                        Text(FeatureL10n.string("移动到"))
                        Divider()
                        ForEach(panels.filter { $0.id != panelID }) { panel in
                            Button { moveToPanel(panel.id) } label: {
                                Label(panel.title, systemImage: PluginSystemImage.resolvedName(panel.systemImage))
                                    .labelStyle(.iconOnly)
                            }
                        }
                    } label: {
                        controlIcon("arrow.right.square", side: metrics.buttonSide)
                    }
                    .focused($focusedControl, equals: .moveTo)
                    .help(FeatureL10n.string("移动到"))
                    .accessibilityLabel(FeatureL10n.string("移动到"))
                    .accessibilityIdentifier("panel.layout.moveTo.\(id)")

                    Menu {
                        Button(PanelLayoutCopy.earlier) { perform(index - 1) }.disabled(index == 0)
                        Button(PanelLayoutCopy.later) { perform(index + 2) }.disabled(index == count - 1)
                        Button(PanelLayoutCopy.beginning) { perform(0) }.disabled(index == 0)
                        Button(PanelLayoutCopy.end) { perform(count) }.disabled(index == count - 1)
                    } label: {
                        controlIcon("ellipsis.circle", side: metrics.buttonSide)
                    }
                    .focused($focusedControl, equals: .more)
                    .accessibilityLabel(PanelLayoutCopy.position(title, index: index, count: count))
                    .accessibilityHint(PanelLayoutCopy.hint)
                    .accessibilityAction(named: PanelLayoutCopy.earlier) { if index > 0 { perform(index - 1) } }
                    .accessibilityAction(named: PanelLayoutCopy.later) { if index < count - 1 { perform(index + 2) } }
                    .accessibilityAction(named: PanelLayoutCopy.beginning) { perform(0) }
                    .accessibilityAction(named: PanelLayoutCopy.end) { perform(count) }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .tint(theme.text.primary)
                .foregroundStyle(theme.text.primary)
                .fixedSize()
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
        }
        // Retire the previous owner immediately, so fast scrolling never stacks
        // fading toolbars. Only the new owner's entrance is animated.
        .animation(showsControls && !reduceMotion ? .easeOut(duration: 0.12) : nil, value: showsControls)
        .overlay {
            PanelLayoutDragSource(id: id, title: title, icon: icon, showsControls: showsControls,
                                  isDraggable: true, hover: hover, nativeSource: nativeSource, begin: beginDrag, end: endDrag)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDragging || (showsControls && focusedControl != nil) ? theme.accent : .clear, lineWidth: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: focusedControl) { _, control in
            hover.focusChanged(id: id, isFocused: control != nil)
            if control != nil { scrollToItem(id) }
        }
        .id(id)
    }

    private func controlIcon(_ symbol: String, side: CGFloat, preferredIconSide: CGFloat = 16) -> some View {
        let iconSide = max(1, min(preferredIconSide, side - 4))
        return Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .font(.system(size: iconSide, weight: .semibold))
            .frame(width: iconSide, height: iconSide)
            .frame(width: side, height: side)
            .contentShape(Rectangle())
    }

    private func perform(_ offset: Int) {
        move(offset)
        scrollToItem(id)
    }
}

/// Share the toolbar geometry with native pointer hit testing, including narrow cards.
struct PanelLayoutItemControlsLayout {
    let isVertical: Bool
    let buttonSide: CGFloat
    let spacing: CGFloat = 8

    init(size: CGSize) {
        isVertical = size.width < 120 && size.height > size.width
        let main = isVertical ? size.height : size.width
        let cross = isVertical ? size.width : size.height
        buttonSide = max(0, min(32, floor((main - 8 - spacing * 2) / 3), cross - 4))
    }

    static func frame(in bounds: CGRect) -> CGRect {
        let layout = Self(size: bounds.size)
        let length = layout.buttonSide * 3 + layout.spacing * 2
        let size = layout.isVertical
            ? CGSize(width: layout.buttonSide, height: length)
            : CGSize(width: length, height: layout.buttonSide)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
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
        accepts(
            hasRegisteredPayload: providers.contains {
                $0.hasItemConformingToTypeIdentifier(type.identifier)
            },
            hasActiveSession: hasActiveSession,
            sessionIsValid: sessionIsValid
        )
    }

    static func accepts(
        hasRegisteredPayload: Bool,
        hasActiveSession: Bool,
        sessionIsValid: Bool
    ) -> Bool {
        guard hasActiveSession, sessionIsValid else { return false }
        return hasRegisteredPayload
    }
}

private struct PanelLayoutDropDelegate: DropDelegate {
    let session: PanelLayoutEditingSession
    let ids: () -> [String]
    let validate: () -> Bool
    let update: (CGPoint) -> Void
    let stopScrolling: () -> Void
    let commit: (PanelLayoutEditingSession.Move) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        PanelLayoutDragTransfer.accepts(
            hasRegisteredPayload: info.hasItemsConforming(
                to: [PanelLayoutDragTransfer.type]
            ),
            hasActiveSession: session.token != nil,
            sessionIsValid: validate()
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
