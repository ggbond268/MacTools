import AppKit
import MacToolsPluginKit
import SwiftUI

private enum WindowSwitcherOverlayPresentation {
    case direct
    case keyWindow
}

enum WindowSwitcherOverlayMetrics {
    static let cornerRadius: CGFloat = 22
    static let iconSize: CGFloat = 60
    static let iconLayoutSize: CGFloat = 80
    static let iconHighlightPadding: CGFloat = 2
    static let iconHighlightSize = iconSize + iconHighlightPadding * 2
    static let iconHighlightCornerRadius: CGFloat = 14
    static let quitButtonSize: CGFloat = 18
    static let quitButtonGap: CGFloat = 1
    static let horizontalSpacing: CGFloat = 14
    static let verticalSpacing: CGFloat = 12
    static let panelHorizontalPadding: CGFloat = 20
    static let panelVerticalPadding: CGFloat = 18
    static let directTopSpacing: CGFloat = 14
    static let shortcutHeight: CGFloat = 22
    static let shortcutContentSpacing: CGFloat = 7
    static let iconLabelSpacing: CGFloat = 6
    static let labelAreaHeight: CGFloat = 27
    static let tileContentHeight = iconLayoutSize + iconLabelSpacing + labelAreaHeight
    static let directTileWidth: CGFloat = 106
    static let keyWindowTileWidth: CGFloat = 112
    static let directTileHeight = directTopSpacing + tileContentHeight
    static let keyWindowTileHeight = shortcutHeight + shortcutContentSpacing + tileContentHeight

    static func quitButtonCenter(tileWidth: CGFloat, contentTopOffset: CGFloat) -> CGPoint {
        let highlightTopInset = (iconLayoutSize - iconHighlightSize) / 2
        let cornerCenter = CGPoint(
            x: tileWidth / 2 + iconHighlightSize / 2 - iconHighlightCornerRadius,
            y: contentTopOffset + highlightTopInset + iconHighlightCornerRadius
        )
        let diagonalOffset = (
            iconHighlightCornerRadius + quitButtonSize / 2 + quitButtonGap
        ) / sqrt(2)
        return CGPoint(
            x: cornerCenter.x + diagonalOffset,
            y: cornerCenter.y - diagonalOffset
        )
    }

    static func roundedMaskImage(
        cornerRadius: CGFloat = WindowSwitcherOverlayMetrics.cornerRadius
    ) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            ).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
private final class WindowSwitcherOverlayModel: ObservableObject {
    @Published var entries: [WindowSwitcherAppEntry] = []
    @Published var selectedID: String?
    @Published var recordingEntryID: String?
    @Published var recordingCandidate: String?
    @Published var recordingHasConflict: Bool = false
    @Published var presentation: WindowSwitcherOverlayPresentation = .keyWindow
    @Published var columnCount: Int = 1
    @Published var shortcutText: String = ""
}

@MainActor
final class WindowSwitcherOverlayController: NSObject, NSWindowDelegate {
    var onSelect: ((WindowSwitcherAppEntry) -> Void)?
    var onQuit: ((WindowSwitcherAppEntry) -> Void)?
    var onShortcutChange: ((WindowSwitcherAppEntry, String?) -> WindowSwitcherShortcutCustomizationResult)?
    var onCancel: (() -> Void)?

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private let model = WindowSwitcherOverlayModel()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var hostingView: NSView?
    private var isClosing = false

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func showDirect(
        entries: [WindowSwitcherAppEntry],
        selectedID: String?,
        shortcutText: String
    ) {
        show(
            entries: entries,
            selectedID: selectedID,
            presentation: .direct,
            shortcutText: shortcutText
        )
    }

    func showKeyWindow(
        entries: [WindowSwitcherAppEntry],
        shortcutText: String
    ) {
        show(
            entries: entries,
            selectedID: nil,
            presentation: .keyWindow,
            shortcutText: shortcutText
        )
    }

    func updateDirectSelection(selectedID: String?) {
        model.selectedID = selectedID
    }

    func updateEntries(entries: [WindowSwitcherAppEntry], selectedID: String?) {
        model.entries = entries
        model.selectedID = selectedID
        if let recordingEntryID = model.recordingEntryID,
           !entries.contains(where: { $0.id == recordingEntryID }) {
            cancelShortcutRecording()
        }
        model.columnCount = columnCount(
            for: entries.count,
            presentation: model.presentation,
            screen: targetScreen()
        )

        if entries.isEmpty {
            hide()
        } else if let panel {
            resize(panel)
            center(panel, on: targetScreen())
        }
    }

    func hide() {
        model.recordingEntryID = nil
        model.recordingCandidate = nil
        model.recordingHasConflict = false
        removeKeyMonitor()
        removeClickMonitor()
        isClosing = true
        panel?.orderOut(nil)
        isClosing = false
    }

    private func show(
        entries: [WindowSwitcherAppEntry],
        selectedID: String?,
        presentation: WindowSwitcherOverlayPresentation,
        shortcutText: String
    ) {
        let screen = targetScreen()
        model.entries = entries
        model.selectedID = selectedID
        model.recordingEntryID = nil
        model.recordingCandidate = nil
        model.recordingHasConflict = false
        model.presentation = presentation
        model.shortcutText = shortcutText
        model.columnCount = columnCount(for: entries.count, presentation: presentation, screen: screen)

        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel)
        center(panel, on: screen)

        switch presentation {
        case .direct:
            removeKeyMonitor()
            removeClickMonitor()
            PluginPresentationSafety.prepareForWindowOrdering(panel)
            panel.orderFrontRegardless()
        case .keyWindow:
            installKeyMonitor()
            installClickMonitor()
            NSApp.activate(ignoringOtherApps: true)
            PluginPresentationSafety.prepareForWindowOrdering(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self

        let hostingView = NSHostingView(
            rootView: WindowSwitcherOverlayView(model: model) { [weak self] entry in
                self?.select(entry)
            } onQuit: { [weak self] entry in
                self?.quit(entry)
            } onRecordShortcut: { [weak self] entry in
                self?.beginShortcutRecording(entry)
            } onCancelShortcutRecording: { [weak self] in
                self?.cancelShortcutRecording()
            }
        )
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = WindowSwitcherOverlayMetrics.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true

        self.hostingView = hostingView
        panel.contentView = makeGlassContentView(hostingView: hostingView)
        return panel
    }

    private func makeGlassContentView(hostingView: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = WindowSwitcherOverlayMetrics.cornerRadius
            glassView.contentView = hostingView
            glassView.wantsLayer = true
            glassView.layer?.cornerRadius = WindowSwitcherOverlayMetrics.cornerRadius
            glassView.layer?.cornerCurve = .continuous
            glassView.layer?.masksToBounds = true
            return glassView
        }

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = WindowSwitcherOverlayMetrics.roundedMaskImage()
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = WindowSwitcherOverlayMetrics.cornerRadius
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
        return effectView
    }

    private func resize(_ panel: NSPanel) {
        guard let hostingView else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        panel.setContentSize(hostingView.fittingSize)
        panel.invalidateShadow()
    }

    private func center(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func columnCount(
        for entryCount: Int,
        presentation: WindowSwitcherOverlayPresentation,
        screen: NSScreen?
    ) -> Int {
        guard entryCount > 0 else {
            return 1
        }

        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let tileWidth = presentation == .direct
            ? WindowSwitcherOverlayMetrics.directTileWidth
            : WindowSwitcherOverlayMetrics.keyWindowTileWidth
        let horizontalPadding = WindowSwitcherOverlayMetrics.panelHorizontalPadding * 2
        let spacing = WindowSwitcherOverlayMetrics.horizontalSpacing
        let maxWidth = min(frame.width - 96, presentation == .direct ? 980 : 1040)
        let capacity = Int((maxWidth - horizontalPadding + spacing) / (tileWidth + spacing))
        return max(1, min(entryCount, capacity))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard model.presentation == .keyWindow else {
            return false
        }

        if model.recordingEntryID != nil {
            return handleRecordingKeyDown(event)
        }

        if event.keyCode == 53 {
            cancel()
            return true
        }

        guard let shortcut = selectionShortcut(from: event) else {
            return false
        }

        resolveShortcutToken(shortcut.storageValue)
        return true
    }

    private func handleRecordingKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            cancelShortcutRecording()
            return true
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            commitRecordedShortcut(nil)
            return true
        }

        guard let shortcut = selectionShortcut(from: event) else {
            NSSound.beep()
            return true
        }

        commitRecordedShortcut(shortcut.storageValue)
        return true
    }

    private func selectionShortcut(from event: NSEvent) -> WindowSwitcherSelectionShortcut? {
        guard event.modifierFlags.intersection([.control, .option]).isEmpty,
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              let character = chars.first
        else {
            return nil
        }

        return WindowSwitcherSelectionShortcut(
            key: String(character),
            usesCommand: event.modifierFlags.contains(.command)
        )
    }

    private func resolveShortcutToken(_ token: String) {
        guard let entry = model.entries.first(where: { $0.shortcutToken == token }) else {
            NSSound.beep()
            return
        }

        select(entry)
    }

    private func select(_ entry: WindowSwitcherAppEntry) {
        cancelShortcutRecording()
        hide()
        onSelect?(entry)
    }

    private func beginShortcutRecording(_ entry: WindowSwitcherAppEntry) {
        guard model.presentation == .keyWindow else {
            return
        }

        cancelShortcutRecording()
        model.recordingEntryID = entry.id
        model.recordingCandidate = nil
        model.recordingHasConflict = false
    }

    private func commitRecordedShortcut(_ token: String?) {
        guard let entryID = model.recordingEntryID,
              let entry = model.entries.first(where: { $0.id == entryID }),
              let onShortcutChange
        else {
            cancelShortcutRecording()
            return
        }

        model.recordingCandidate = token
        switch onShortcutChange(entry, token) {
        case let .updated(entries):
            model.entries = entries
            cancelShortcutRecording()
        case .conflict:
            model.recordingHasConflict = true
            NSSound.beep()
        case .unavailable:
            cancelShortcutRecording()
            NSSound.beep()
        }
    }

    private func cancelShortcutRecording() {
        model.recordingEntryID = nil
        model.recordingCandidate = nil
        model.recordingHasConflict = false
    }

    private func quit(_ entry: WindowSwitcherAppEntry) {
        cancelShortcutRecording()
        onQuit?(entry)
    }

    private func cancel() {
        cancelShortcutRecording()
        hide()
        onCancel?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, model.presentation == .keyWindow else {
            return
        }

        cancel()
    }
}

@MainActor
private struct WindowSwitcherOverlayView: View {
    @ObservedObject var model: WindowSwitcherOverlayModel
    let onSelect: (WindowSwitcherAppEntry) -> Void
    let onQuit: (WindowSwitcherAppEntry) -> Void
    let onRecordShortcut: (WindowSwitcherAppEntry) -> Void
    let onCancelShortcutRecording: () -> Void

    private var tileWidth: CGFloat {
        model.presentation == .direct
            ? WindowSwitcherOverlayMetrics.directTileWidth
            : WindowSwitcherOverlayMetrics.keyWindowTileWidth
    }

    private var tileHeight: CGFloat {
        model.presentation == .direct
            ? WindowSwitcherOverlayMetrics.directTileHeight
            : WindowSwitcherOverlayMetrics.keyWindowTileHeight
    }

    private var spacing: CGFloat {
        WindowSwitcherOverlayMetrics.horizontalSpacing
    }

    private var contentWidth: CGFloat {
        let columns = max(1, model.columnCount)
        let gridWidth = CGFloat(columns) * tileWidth + CGFloat(max(0, columns - 1)) * spacing
        return max(220, gridWidth)
    }

    var body: some View {
        VStack(spacing: WindowSwitcherOverlayMetrics.verticalSpacing) {
            if model.entries.isEmpty {
                emptyState
            } else {
                appGrid
            }
        }
        .frame(width: contentWidth)
        .padding(.horizontal, WindowSwitcherOverlayMetrics.panelHorizontalPadding)
        .padding(.vertical, WindowSwitcherOverlayMetrics.panelVerticalPadding)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard model.recordingEntryID != nil else {
                        return
                    }
                    onCancelShortcutRecording()
                }
        }
        .fixedSize()
    }

    private var appGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(tileWidth), spacing: spacing),
                count: max(1, model.columnCount)
            ),
            spacing: WindowSwitcherOverlayMetrics.verticalSpacing
        ) {
            ForEach(model.entries) { entry in
                WindowSwitcherAppTile(
                    entry: entry,
                    isSelected: entry.id == model.selectedID,
                    isRecording: entry.id == model.recordingEntryID,
                    recordingCandidate: entry.id == model.recordingEntryID
                        ? model.recordingCandidate
                        : nil,
                    recordingHasConflict: entry.id == model.recordingEntryID
                        && model.recordingHasConflict,
                    showsShortcut: model.presentation == .keyWindow,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    onSelect: { onSelect(entry) },
                    onQuit: { onQuit(entry) },
                    onRecordShortcut: { onRecordShortcut(entry) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("没有可切换的窗口")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
    }

}

private struct WindowSwitcherAppTile: View {
    let entry: WindowSwitcherAppEntry
    let isSelected: Bool
    let isRecording: Bool
    let recordingCandidate: String?
    let recordingHasConflict: Bool
    let showsShortcut: Bool
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let onSelect: () -> Void
    let onQuit: () -> Void
    let onRecordShortcut: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isIconHovered = false
    @State private var isQuitHovered = false
    @State private var isShortcutHovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: showsShortcut ? WindowSwitcherOverlayMetrics.shortcutContentSpacing : 0) {
                if showsShortcut {
                    Button(action: onRecordShortcut) {
                        shortcutBadge
                            .frame(height: WindowSwitcherOverlayMetrics.shortcutHeight)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { isShortcutHovered = $0 }
                    .help("修改 \(entry.appName)快捷键")
                } else {
                    Color.clear
                        .frame(height: WindowSwitcherOverlayMetrics.directTopSpacing)
                }

                Button(action: onSelect) {
                    tileContent
                }
                .buttonStyle(.plain)
            }
            .frame(width: tileWidth, height: tileHeight, alignment: .top)

            quitButton
                .position(quitButtonCenter)
        }
        .frame(width: tileWidth, height: tileHeight)
    }

    private var shortcutBadge: some View {
        Group {
            if isRecording, recordingCandidate == nil {
                Image(systemName: "keyboard")
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Text(recordingDisplay ?? entry.shortcutDisplay ?? "")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
        }
            .foregroundStyle(shortcutForegroundColor)
            .frame(minWidth: 22)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(shortcutBackgroundColor)
            )
            .contentShape(Capsule(style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isRecording)
            .animation(.easeOut(duration: 0.12), value: recordingHasConflict)
            .animation(.easeOut(duration: 0.12), value: isShortcutHovered)
    }

    private var shortcutForegroundColor: Color {
        if recordingHasConflict {
            return Color(nsColor: .systemRed)
        }
        if isRecording {
            return Color.accentColor
        }
        return .secondary
    }

    private var shortcutBackgroundColor: Color {
        if recordingHasConflict {
            return Color(nsColor: .systemRed).opacity(0.16)
        }
        if isRecording {
            return Color.accentColor.opacity(0.16)
        }
        if isShortcutHovered {
            return Color.primary.opacity(0.12)
        }
        return Color.primary.opacity(0.07)
    }

    private var recordingDisplay: String? {
        guard isRecording, let recordingCandidate else {
            return nil
        }

        return WindowSwitcherSelectionShortcut(storageValue: recordingCandidate)?.displayValue
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(quitForegroundColor)
                .frame(
                    width: WindowSwitcherOverlayMetrics.quitButtonSize,
                    height: WindowSwitcherOverlayMetrics.quitButtonSize
                )
                .background(
                    Circle()
                        .fill(quitBackgroundColor)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(showsQuitButton ? 1 : 0)
        .allowsHitTesting(showsQuitButton)
        .onHover { isQuitHovered = $0 }
        .help("退出 \(entry.appName)")
        .animation(.easeOut(duration: 0.12), value: showsQuitButton)
        .animation(.easeOut(duration: 0.12), value: isQuitHovered)
    }

    private var tileContent: some View {
        VStack(spacing: WindowSwitcherOverlayMetrics.iconLabelSpacing) {
            highlightedIcon

            VStack(spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .frame(height: 14)

                if let subtitle = entry.displaySubtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .frame(height: 12)
                } else {
                    Color.clear
                        .frame(height: 12)
                }
            }
            .frame(
                width: tileWidth - 12,
                height: WindowSwitcherOverlayMetrics.labelAreaHeight,
                alignment: .top
            )
        }
        .frame(width: tileWidth, height: highlightedContentHeight, alignment: .top)
        .help(accessibilityTitle)
    }

    private var highlightedIcon: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: WindowSwitcherOverlayMetrics.iconHighlightCornerRadius,
                style: .continuous
            )
                .fill(iconBackgroundColor)

            iconView
        }
        .frame(
            width: WindowSwitcherOverlayMetrics.iconHighlightSize,
            height: WindowSwitcherOverlayMetrics.iconHighlightSize
        )
        .frame(
            width: WindowSwitcherOverlayMetrics.iconLayoutSize,
            height: WindowSwitcherOverlayMetrics.iconLayoutSize
        )
        .contentShape(Rectangle())
        .onHover { isIconHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isIconHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var iconBackgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if showsShortcut && (isIconHovered || isQuitHovered) {
            return Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08)
        }
        return .clear
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = entry.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(
                    width: WindowSwitcherOverlayMetrics.iconSize,
                    height: WindowSwitcherOverlayMetrics.iconSize
                )
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .frame(
                    width: WindowSwitcherOverlayMetrics.iconSize,
                    height: WindowSwitcherOverlayMetrics.iconSize
                )
        }
    }

    private var highlightedContentTopOffset: CGFloat {
        showsShortcut
            ? WindowSwitcherOverlayMetrics.shortcutHeight
                + WindowSwitcherOverlayMetrics.shortcutContentSpacing
            : WindowSwitcherOverlayMetrics.directTopSpacing
    }

    private var quitButtonCenter: CGPoint {
        WindowSwitcherOverlayMetrics.quitButtonCenter(
            tileWidth: tileWidth,
            contentTopOffset: highlightedContentTopOffset
        )
    }

    private var highlightedContentHeight: CGFloat {
        WindowSwitcherOverlayMetrics.tileContentHeight
    }

    private var showsQuitButton: Bool {
        isIconHovered || isQuitHovered
    }

    private var quitForegroundColor: Color {
        isQuitHovered ? Color(nsColor: .systemRed) : .secondary
    }

    private var quitBackgroundColor: Color {
        isQuitHovered ? Color(nsColor: .systemRed).opacity(0.16) : Color.primary.opacity(0.08)
    }

    private var accessibilityTitle: String {
        if let subtitle = entry.displaySubtitle {
            return "\(entry.displayName)，\(subtitle)"
        }

        return entry.displayName
    }
}
