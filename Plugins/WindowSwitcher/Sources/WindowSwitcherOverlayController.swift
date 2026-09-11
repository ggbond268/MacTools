import AppKit
import Carbon.HIToolbox
import MacToolsPluginKit

@MainActor
final class WindowSwitcherOverlayController: NSObject, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((WindowSwitcherAppEntry) -> Void)?
    var onClose: ((WindowSwitcherAppEntry) -> Void)?
    var onQuit: ((WindowSwitcherAppEntry) -> Void)?
    var onCancel: (() -> Void)?
    var onSessionChange: ((WindowSwitcherSession) -> Void)?
    var onPreviewChange: ((Bool) -> Void)?
    private(set) var session: WindowSwitcherSession?

    private final class Panel: NSPanel {
        var shortcutHandler: ((NSEvent) -> Bool)?
        var searchEventFilter: ((NSEvent) -> NSEvent)?
        var searchTransitionHandler: ((NSEvent) -> Bool)?
        override func sendEvent(_ event: NSEvent) {
            let filtered = searchEventFilter?(event) ?? event
            if filtered.type == .keyDown {
                if shortcutHandler?(filtered) == true || searchTransitionHandler?(filtered) == true { return }
            }
            super.sendEvent(filtered)
        }
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let filtered = searchEventFilter?(event) ?? event
            if filtered.modifierFlags != event.modifierFlags {
                // Consume the original chord so AppKit cannot retry menus with
                // the held Command modifier after native text input handles it.
                firstResponder?.keyDown(with: filtered)
                return true
            }
            return shortcutHandler?(event) == true || searchTransitionHandler?(event) == true || super.performKeyEquivalent(with: event)
        }
    }
    private final class Table: NSTableView {
        var keyHandler: ((NSEvent) -> Bool)?
        override func keyDown(with event: NSEvent) {
            if keyHandler?(event) != true { super.keyDown(with: event) }
        }
    }
    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let table = Table()
    private let search = NSSearchField()
    private let scope = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let display = NSPopUpButton()
    private let count = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let previewImage = NSImageView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let previewPane = NSStackView()
    private let preview: WindowSwitcherPreview
    private let localization: PluginLocalization
    private let closeButton = NSButton(title: "", target: nil, action: nil)
    private let quitButton = NSButton(title: "", target: nil, action: nil)
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private let previewButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private var rows: [WindowSwitcherAppEntry] = []
    private var currentPID: pid_t?
    private var updating = false
    private var closing = false
    private var previewedEntry: WindowSwitcherAppEntry?
    private var previewedPermission: Bool?
    private var showsPreview = false
    private var screenObserver: NSObjectProtocol?
    private var actionMessage: String?
    private var renderedSession: WindowSwitcherSession?
    private var searchHeldModifiers: NSEvent.ModifierFlags = []

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.preview = WindowSwitcherPreview(localization: localization)
        super.init()
        buildPanel()
        preview.onChange = { [weak self] image, message in
            guard let self else { return }
            self.previewImage.image = image
            self.previewLabel.stringValue = message ?? (image == nil ? localization.string("preview.loading", defaultValue: "正在加载预览…") : "")
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.layoutPanel() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ session: WindowSwitcherSession, currentPID: pid_t?, showsPreview: Bool) {
        self.session = session
        self.currentPID = currentPID
        self.showsPreview = showsPreview
        renderedSession = nil
        searchHeldModifiers = []
        previewButton.state = showsPreview ? .on : .off
        search.stringValue = session.query
        actionMessage = nil
        previewedEntry = nil; previewedPermission = nil
        render()
        layoutPanel()
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        // The nonactivating panel takes keyboard input without activating the
        // MacTools application or changing the user's current Space.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(table)
    }

    func update(_ value: WindowSwitcherSession) {
        session = value
        render()
    }

    func hide() {
        closing = true
        panel.orderOut(nil)
        closing = false
        session = nil
        renderedSession = nil
        searchHeldModifiers = []
        previewedEntry = nil; previewedPermission = nil
        preview.cancel()
    }

    func showMessage(_ message: String) { actionMessage = message; footer.stringValue = message }

    private func layoutPanel() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let usePreview = showsPreview && screen.visibleFrame.width >= 760
        previewPane.isHidden = !usePreview
        panel.setFrame(WindowSwitcherSession.panelFrame(visibleFrame: screen.visibleFrame, preview: usePreview), display: true)
    }

    private func buildPanel() {
        panel.identifier = NSUserInterfaceItemIdentifier("WindowSwitcherChooser")
        panel.searchEventFilter = { [weak self] event in self?.filterSearchEvent(event) ?? event }
        panel.searchTransitionHandler = { [weak self] event in
            guard let self, let session, !session.isPersistent,
                  !session.invocationModifiers.intersection(event.modifierFlags).isEmpty,
                  let text = event.charactersIgnoringModifiers, !text.isEmpty,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            // Keep explicit close/quit shortcuts available before search begins.
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               ["w", "q"].contains(text.lowercased()) { return false }
            return handleKey(event)
        }
        panel.shortcutHandler = { [weak self] event in self?.handleChooserShortcut(event) ?? false }
        panel.level = .popUpMenu
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.delegate = self
        let effect = WindowSwitcherPaletteSurface()
        panel.contentView = effect
        let title = NSTextField(labelWithString: localization.string("chooser.title", defaultValue: "窗口切换"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        search.placeholderString = localization.string("chooser.search", defaultValue: "搜索窗口标题或应用")
        search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(localization.string("chooser.search", defaultValue: "搜索窗口标题或应用"))
        search.font = .systemFont(ofSize: 15)
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.selectedSegment = 0
        display.target = self; display.action = #selector(displayChanged)
        display.setAccessibilityLabel(localization.string("chooser.displayFilter", defaultValue: "显示器筛选"))
        count.font = .systemFont(ofSize: 12); count.textColor = .secondaryLabelColor
        previewButton.target = self; previewButton.action = #selector(previewChanged)
        cancelButton.target = self; cancelButton.action = #selector(cancelSelection); cancelButton.bezelStyle = .rounded
        let header = NSStackView(views: [title, NSView(), previewButton, cancelButton])
        let filters = NSStackView(views: [scope, display, NSView(), count])
        header.orientation = .horizontal; filters.orientation = .horizontal
        filters.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("window")))
        table.headerView = nil; table.rowHeight = 54; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel(localization.string("chooser.list", defaultValue: "窗口列表"))
        table.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        scroll.documentView = table
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewLabel.font = .systemFont(ofSize: 12); previewLabel.textColor = .secondaryLabelColor
        previewPane.orientation = .vertical; previewPane.alignment = .leading
        previewPane.spacing = 12; previewPane.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        previewPane.addArrangedSubview(previewImage); previewPane.addArrangedSubview(previewLabel)
        let body = NSStackView(views: [scroll, previewPane])
        body.orientation = .horizontal; body.spacing = 8; body.alignment = .top
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
        openButton.target = self; openButton.action = #selector(openSelected); openButton.bezelStyle = .rounded
        closeButton.target = self; closeButton.action = #selector(closeSelected); closeButton.bezelStyle = .rounded
        quitButton.target = self; quitButton.action = #selector(quitSelected); quitButton.bezelStyle = .rounded
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        let actions = NSStackView(views: [openButton, closeButton, quitButton, NSView()])
        actions.orientation = .horizontal
        let stack = NSStackView(views: [header, search, filters, body, empty, actions, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            previewPane.widthAnchor.constraint(equalToConstant: 250),
            previewImage.heightAnchor.constraint(equalToConstant: 190),
            previewImage.widthAnchor.constraint(equalTo: previewPane.widthAnchor, constant: -24),
            previewLabel.widthAnchor.constraint(equalTo: previewPane.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(equalTo: body.heightAnchor),
        ])
        for view in [header, search, filters, body, empty, actions, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        display.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func localizeControls() {
        scope.setLabel(localization.string("chooser.all", defaultValue: "全部窗口"), forSegment: 0)
        scope.setLabel(localization.string("chooser.current", defaultValue: "当前应用"), forSegment: 1)
        closeButton.title = localization.string("chooser.close", defaultValue: "关闭窗口")
        quitButton.title = localization.string("chooser.quit", defaultValue: "退出应用")
        openButton.title = localization.string("chooser.open", defaultValue: "打开窗口")
        previewButton.title = localization.string("chooser.preview", defaultValue: "预览")
        cancelButton.title = localization.string("chooser.cancel", defaultValue: "取消")
        scope.setToolTip("\(scope.label(forSegment: 0) ?? "") · ⌘1", forSegment: 0)
        scope.setToolTip("\(scope.label(forSegment: 1) ?? "") · ⌘2", forSegment: 1)
        display.toolTip = "\(localization.string("chooser.displayFilter", defaultValue: "显示器筛选")) · ⌘D"
        previewButton.title += " ⌘P"
        search.toolTip = "\(localization.string("chooser.search", defaultValue: "搜索窗口标题或应用")) · ⌘F"
    }

    private func render() {
        guard var session else { return }
        localizeControls()
        session.normalizeSelection(); self.session = session
        let revealSelection = renderedSession == nil || renderedSession?.selectedID != session.selectedID
            || renderedSession?.query != session.query || renderedSession?.scope != session.scope
            || renderedSession?.display != session.display
        let viewport = table.enclosingScrollView?.contentView.bounds.origin
        updating = true
        rows = session.results
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == session.selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if revealSelection { table.scrollRowToVisible(index) }
        } else { table.deselectAll(nil) }
        if !revealSelection, let viewport, let scroll = table.enclosingScrollView {
            scroll.contentView.scroll(to: viewport)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        renderedSession = session
        count.stringValue = localization.format("chooser.count", defaultValue: "%d 个窗口", rows.count)
        scope.selectedSegment = session.scope == .all ? 0 : 1
        scope.setEnabled(currentPID != nil, forSegment: 1)
        display.removeAllItems(); display.addItem(withTitle: localization.string("chooser.allDisplays", defaultValue: "所有显示器"))
        for screen in session.displays {
            display.addItem(withTitle: screen.name)
            display.lastItem?.representedObject = NSNumber(value: screen.id)
            if session.display == screen.id { display.select(display.lastItem) }
        }
        if let selectedDisplay = session.display, !session.displays.contains(where: { $0.id == selectedDisplay }) {
            // Keep the visible control honest if the selected display has lost
            // its last window or disconnected while this session is open.
            display.addItem(withTitle: localization.string("chooser.emptyDisplay", defaultValue: "所选显示器暂无窗口"))
            display.lastItem?.representedObject = NSNumber(value: selectedDisplay)
            display.select(display.lastItem)
        }
        let selected = session.selected
        closeButton.isEnabled = selected?.isWindowEntry == true && selected?.metadataUnavailable == false
        quitButton.isEnabled = selected != nil; openButton.isEnabled = selected != nil
        empty.stringValue = rows.isEmpty ? localization.string("chooser.empty", defaultValue: "没有匹配的窗口。窗口信息可能仍在更新。") : ""
        empty.isHidden = !rows.isEmpty
        footer.stringValue = actionMessage ?? (session.isPersistent
            ? localization.string("chooser.keyboardHelp", defaultValue: "↑↓ 选择 · 回车打开 · ⌘1/2 范围 · ⌘D 显示器 · Esc 取消")
            : localization.string("chooser.cycleHelp", defaultValue: "按住快捷键循环 · 松开切换 · 输入文字搜索 · Esc 取消"))
        updating = false
        if showsPreview, selected != previewedEntry || preview.isPermissionGranted != previewedPermission {
            previewedEntry = selected
            previewedPermission = preview.isPermissionGranted
            preview.select(selected?.isWindowEntry == true ? selected : nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let icon = NSImageView(image: entry.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let displayName = entry.localizedDisplayName(using: localization)
        let title = NSTextField(labelWithString: displayName)
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        title.attributedStringValue = highlighted(displayName, query: session?.query ?? "")
        let parts = [entry.appName, entry.displayNameContext,
                     entry.isMinimized ? localization.string("window.minimized", defaultValue: "已最小化") : nil, entry.isHidden ? localization.string("window.hidden", defaultValue: "已隐藏") : nil,
                     entry.metadataUnavailable ? localization.string("window.unavailable", defaultValue: "暂时无法更新") : nil, entry.isWindowEntry ? nil : localization.string("window.none", defaultValue: "无可用窗口")]
        let subtitle = NSTextField(labelWithString: parts.compactMap { $0 }.joined(separator: " · "))
        subtitle.attributedStringValue = highlighted(subtitle.stringValue, query: session?.query ?? "")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let cell = NSStackView(views: [icon, labels])
        cell.orientation = .horizontal; cell.spacing = 10
        cell.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        return cell
    }

    static func matchRanges(in text: String, query: String) -> [NSRange] {
        query.split(whereSeparator: \.isWhitespace).flatMap { term in
            var ranges: [NSRange] = []
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: String(term),
                options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                ranges.append(NSRange(range, in: text)); start = range.upperBound
            }
            return ranges
        }
    }

    private func highlighted(_ text: String, query: String) -> NSAttributedString {
        let value = NSMutableAttributedString(string: text)
        for range in Self.matchRanges(in: text, query: query) {
            value.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range)
        }
        return value
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, rows.indices.contains(table.selectedRow), var session else { return }
        session.selectedID = rows[table.selectedRow].id
        self.session = session
        actionMessage = nil
        onSessionChange?(session)
        render()
    }

    private func beginSearch() {
        guard var session else { return }
        session.beginSearch(); self.session = session
        onSessionChange?(session)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { beginSearch() }
    func controlTextDidChange(_ obj: Notification) {
        guard var session else { return }
        session.beginSearch(); session.query = search.stringValue; session.normalizeSelection()
        self.session = session; actionMessage = nil
        onSessionChange?(session); render()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
        default: return false
        }
        return true
    }

    @discardableResult
    func handleChooserShortcut(_ event: NSEvent) -> Bool {
        guard session != nil,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              ["1", "2", "d", "p", "f", "w", "q"].contains(key) else { return false }
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return true }
        // Invocation modifiers still being held belong to search input, not a
        // newly pressed chooser command. Close/quit retain their explicit chord.
        if session?.isPersistent == false, session?.invocationModifiers.contains(.command) == true,
           !["w", "q"].contains(key) { return false }
        switch key {
        case "1": scope.selectedSegment = 0; scopeChanged()
        case "2":
            if currentPID != nil { scope.selectedSegment = 1; scopeChanged() }
        case "d":
            beginSearch()
            display.performClick(nil)
        case "p": previewButton.state = showsPreview ? .off : .on; previewChanged()
        case "f": beginSearch(); panel.makeFirstResponder(search)
        case "w": closeSelected()
        case "q": quitSelected()
        default: return false
        }
        return true
    }

    private func handleKey(_ original: NSEvent) -> Bool {
        var event = original
        switch Int(event.keyCode) {
        case kVK_Escape: onCancel?()
        case kVK_DownArrow: move(1)
        case kVK_UpArrow: move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter: openSelected()
        default:
            if session?.isPersistent == false, let modifiers = session?.invocationModifiers {
                // The held invocation chord is navigation state, not an editing
                // modifier. Continue suppressing it until its physical release.
                searchHeldModifiers = modifiers.intersection(event.modifierFlags)
                event = filterSearchEvent(event)
            }
            let command = event.modifierFlags.contains(.command)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if command && key != "f" && key != "v" { return false }
            guard let text = event.charactersIgnoringModifiers, !text.isEmpty,
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            beginSearch()
            panel.makeFirstResponder(search)
            if command && key == "v" {
                (search.currentEditor() as? NSTextView)?.paste(nil)
            } else if !command {
                search.currentEditor()?.interpretKeyEvents([event])
            }
        }
        return true
    }

    func filterSearchEvent(_ event: NSEvent) -> NSEvent {
        if event.type == .flagsChanged {
            searchHeldModifiers.formIntersection(event.modifierFlags)
            return event
        }
        guard event.type == .keyDown, !searchHeldModifiers.isEmpty else { return event }
        searchHeldModifiers.formIntersection(event.modifierFlags)
        guard !searchHeldModifiers.isEmpty else { return event }
        let flags = event.modifierFlags.subtracting(searchHeldModifiers)
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.charactersIgnoringModifiers ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private func move(_ delta: Int) {
        guard var session else { return }
        session.advance(delta); self.session = session; actionMessage = nil
        onSessionChange?(session); render()
    }
    @objc private func openSelected() { if let entry = session?.selected { onSelect?(entry) } }
    @objc private func cancelSelection() { onCancel?() }
    @objc private func closeSelected() { if let entry = session?.selected { beginSearch(); onClose?(entry) } }
    @objc private func quitSelected() { if let entry = session?.selected { beginSearch(); onQuit?(entry) } }
    @objc private func scopeChanged() {
        guard var session else { return }
        session.scope = scope.selectedSegment == 1 ? currentPID.map(WindowSwitcherSession.Scope.currentApplication) ?? .all : .all
        session.beginSearch(); session.normalizeSelection(); self.session = session
        actionMessage = nil; onSessionChange?(session); render()
    }
    @objc private func displayChanged() {
        guard var session else { return }
        session.display = (display.selectedItem?.representedObject as? NSNumber)?.uint32Value
        session.beginSearch(); session.normalizeSelection(); self.session = session
        actionMessage = nil; onSessionChange?(session); render()
    }
    @objc private func previewChanged() {
        beginSearch()
        showsPreview = previewButton.state == .on
        onPreviewChange?(showsPreview)
        previewedEntry = nil; previewedPermission = nil
        if !showsPreview { preview.cancel() }
        layoutPanel(); render()
    }
    func windowDidResignKey(_ notification: Notification) {
        if !closing, session != nil { onCancel?() }
    }
}
