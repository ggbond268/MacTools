import AppKit

@MainActor
final class WindowSwitcherCardCollection: NSCollectionView {
    var contextMenuForItem: ((IndexPath) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return contextMenuForItem?(path)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else { super.mouseDown(with: event) }
    }
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class WindowSwitcherCardItem: NSCollectionViewItem {
    private final class Card: WindowSwitcherAppearanceView {
        var onAppearanceChange: (() -> Void)?
        override func refreshAppearance() {
            super.refreshAppearance()
            onAppearanceChange?()
        }
        var onOpen: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { onOpen?() }
        }
    }
    var onOpen: (() -> Void)?
    private let selectionMark = NSImageView()
    private final class Badge: NSButton {
        var editable = false
        override func hitTest(_ point: NSPoint) -> NSView? { editable ? super.hitTest(point) : nil }
    }
    private let badge = Badge(title: "", target: nil, action: nil)
    var onEditShortcut: (() -> Void)?
    var assignedShortcut: String? { didSet { updateBadge() } }
    var shortcutNumber: Int? {
        didSet { updateBadge() }
    }
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    private func updateBadge() {
        badge.title = assignedShortcut ?? shortcutNumber.map { "⌘\($0)" } ?? ""
        badge.editable = assignedShortcut != nil
        badge.isEnabled = true
        badge.refusesFirstResponder = assignedShortcut == nil
        badge.isBordered = assignedShortcut != nil
        badge.isHidden = badge.title.isEmpty
    }

    @objc private func editShortcut() { onEditShortcut?() }

    override func loadView() {
        let card = Card(frame: NSRect(x: 0, y: 0, width: 132, height: 88))
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.onOpen = { [weak self] in self?.onOpen?() }
        view = card
        card.onAppearanceChange = { [weak self] in self?.updateSelection() }
        selectionMark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        selectionMark.contentTintColor = .labelColor
        selectionMark.frame = NSRect(x: 7, y: 67, width: 14, height: 14)
        selectionMark.setAccessibilityElement(false)
        card.addSubview(selectionMark)
        icon.identifier = NSUserInterfaceItemIdentifier("window-card-icon")
        titleLabel.identifier = NSUserInterfaceItemIdentifier("window-card-title")
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.alignment = .center; titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.cell?.wraps = true
        titleLabel.cell?.isScrollable = false
        for child in [icon, titleLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(child)
        }
        badge.identifier = NSUserInterfaceItemIdentifier("window-assigned-key")
        badge.bezelStyle = .texturedRounded
        badge.controlSize = .small
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        badge.isBordered = false
        badge.contentTintColor = .labelColor
        badge.target = self
        badge.action = #selector(editShortcut)
        badge.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            badge.heightAnchor.constraint(equalToConstant: 24),
            badge.topAnchor.constraint(equalTo: card.topAnchor, constant: 3),
            badge.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8)
        ])
        // Fixed tracks keep every icon and label on the same baseline, including
        // entries with short or missing window titles.
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 45),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            titleLabel.heightAnchor.constraint(equalToConstant: 30),
        ])
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = (isSelected
                ? WindowSwitcherAppearance.selectionColor(view.effectiveAppearance)
                : NSColor.clear).cgColor
            selectionMark.isHidden = !isSelected || !WindowSwitcherAppearance.increasedContrast(view.effectiveAppearance)
            view.layer?.borderWidth = 0
            view.layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor
        }
    }

    func configure(icon: NSImage?, title: NSAttributedString, appName: String) {
        self.icon.image = icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        let alignedTitle = NSMutableAttributedString(attributedString: title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        alignedTitle.addAttributes([.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 12, weight: .medium)],
                                   range: NSRange(location: 0, length: alignedTitle.length))
        self.titleLabel.attributedStringValue = alignedTitle
        view.toolTip = "\(title.string) — \(appName)"
        view.setAccessibilityLabel("\(title.string), \(appName)")
        updateSelection()
    }
}

/// Directional buttons reveal overflow even when macOS hides scrollbars.
@MainActor
final class WindowSwitcherCardScrollView: NSScrollView {
    private let topIndicator = NSButton(title: "", target: nil, action: nil)
    private let bottomIndicator = NSButton(title: "", target: nil, action: nil)
    private(set) var hasContentAbove = false
    private(set) var hasContentBelow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (button, symbol, action) in [(topIndicator, "chevron.up", #selector(scrollUp)), (bottomIndicator, "chevron.down", #selector(scrollDown))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.contentTintColor = .labelColor
            button.target = self; button.action = action
            button.identifier = NSUserInterfaceItemIdentifier(symbol == "chevron.up" ? "window-grid-more-above" : "window-grid-more-below")
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setOverflowLabels(above: String, below: String) {
        for (button, label) in [(topIndicator, above), (bottomIndicator, below)] {
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
    }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        updateOverflow()
    }
    override func layout() { super.layout(); updateOverflow() }
    @objc private func scrollUp() { scrollPage(-1) }
    @objc private func scrollDown() { scrollPage(1) }
    private func scrollPage(_ direction: CGFloat) {
        guard let documentView else { return }
        let visible = documentVisibleRect
        let delta = max(88, visible.height * 0.75) * direction * (documentView.isFlipped ? 1 : -1)
        let y = min(max(documentView.bounds.minY, visible.minY + delta), max(documentView.bounds.minY, documentView.bounds.maxY - visible.height))
        contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        reflectScrolledClipView(contentView)
    }
    func updateOverflow() {
        guard let documentView else { return }
        let visible = documentVisibleRect
        let before = visible.minY > documentView.bounds.minY + 1
        let after = visible.maxY < documentView.bounds.maxY - 1
        hasContentAbove = documentView.isFlipped ? before : after
        hasContentBelow = documentView.isFlipped ? after : before
        topIndicator.isHidden = !hasContentAbove
        topIndicator.setAccessibilityHidden(!hasContentAbove)
        topIndicator.isEnabled = hasContentAbove
        bottomIndicator.isHidden = !hasContentBelow
        bottomIndicator.setAccessibilityHidden(!hasContentBelow)
        bottomIndicator.isEnabled = hasContentBelow
        let rect = convert(contentView.bounds, from: contentView)
        let height = min(18, rect.height)
        topIndicator.frame = NSRect(x: rect.midX - 32, y: isFlipped ? rect.minY : rect.maxY - height, width: 64, height: height)
        bottomIndicator.frame = NSRect(x: rect.midX - 32, y: isFlipped ? rect.maxY - height : rect.minY, width: 64, height: height)
    }
}
