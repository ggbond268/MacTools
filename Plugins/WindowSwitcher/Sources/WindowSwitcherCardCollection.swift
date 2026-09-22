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
    override func scrollWheel(with event: NSEvent) {
        // NSCollectionView can consume trackpad phases before its enclosing
        // scroll view sees them, especially in a nonactivating panel. Route the
        // complete gesture to the viewport so card grids always remain scrollable.
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
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
    private let badge = WindowSwitcherShortcutBadge(title: "", target: nil, action: nil)
    var onEditShortcut: (() -> Void)?
    var assignedShortcut: String? { didSet { updateBadge() } }
    var isRecordingShortcut = false { didSet { badge.isRecording = isRecordingShortcut } }
    var shortcutHelp: String? { didSet { badge.toolTip = shortcutHelp } }
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
