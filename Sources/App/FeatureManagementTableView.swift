import AppKit
import SwiftUI

struct FeatureManagementTableView: NSViewRepresentable {
    static let rowHeight: CGFloat = 62
    static let rowSpacing: CGFloat = 6
    static let verticalContentInset: CGFloat = 6
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.feature-management-item")

    let items: [PluginFeatureManagementItem]
    let onVisibilityChange: (String, Bool) -> Void
    let onMove: (String, Int) -> Void

    static func preferredHeight(for itemCount: Int) -> CGFloat {
        let visibleItemCount = max(itemCount, 1)
        let spacing = CGFloat(max(itemCount - 1, 0)) * rowSpacing
        return CGFloat(visibleItemCount) * rowHeight + spacing + verticalContentInset * 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NonScrollingTableScrollView()
        scrollView.contentView = LockedClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.verticalContentInset,
            left: 0,
            bottom: Self.verticalContentInset,
            right: 0
        )

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.verticalMotionCanBeginDrag = true
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([Self.dragType])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feature"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        syncLayout(in: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        syncLayout(in: scrollView, coordinator: context.coordinator)
    }

    private func syncLayout(in scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = coordinator.tableView else {
            return
        }

        tableView.reloadData()
        tableView.noteNumberOfRowsChanged()

        let contentHeight = Self.preferredHeight(for: items.count)
        let contentWidth = max(scrollView.contentSize.width, 1)

        tableView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FeatureManagementTableView
        weak var tableView: NSTableView?

        init(parent: FeatureManagementTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            FeatureManagementTableView.rowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("FeatureManagementCell")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FeatureManagementTableCellView)
                ?? FeatureManagementTableCellView(frame: .zero)
            view.identifier = identifier

            let item = parent.items[row]
            view.configure(
                item: item,
                onVisibilityChange: { [weak self] isVisible in
                    self?.parent.onVisibilityChange(item.id, isVisible)
                }
            )
            return view
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(parent.items[row].id, forType: FeatureManagementTableView.dragType)
            return pasteboardItem
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
        }

        func tableView(
            _ tableView: NSTableView,
            draggingImageForRowsWith rowIndexes: IndexSet,
            event: NSEvent,
            offset dragImageOffset: NSPointPointer
        ) -> NSImage {
            guard let row = rowIndexes.first, parent.items.indices.contains(row) else {
                return NSImage(size: NSSize(width: 1, height: 1))
            }

            dragImageOffset.pointee = .init(x: 0, y: 0)
            return FeatureManagementDragPreview.image(for: parent.items[row])
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard info.draggingPasteboard.availableType(from: [FeatureManagementTableView.dragType]) != nil else {
                return []
            }

            let targetRow = min(max(row, 0), parent.items.count)
            tableView.setDropRow(targetRow, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard
                let draggedID = info.draggingPasteboard.string(forType: FeatureManagementTableView.dragType)
            else {
                return false
            }

            let targetRow = min(max(row, 0), parent.items.count)
            parent.onMove(draggedID, targetRow)
            return true
        }
    }
}

private final class NonScrollingTableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class LockedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin = .zero
        return bounds
    }
}

@MainActor
private enum FeatureManagementDragPreview {
    static func image(for item: PluginFeatureManagementItem) -> NSImage {
        let previewView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 12
        previewView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        previewView.layer?.borderWidth = 1
        previewView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        previewView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        previewView.layer?.shadowOpacity = 1
        previewView.layer?.shadowRadius = 10
        previewView.layer?.shadowOffset = NSSize(width: 0, height: -2)

        let iconBackgroundView = NSView()
        iconBackgroundView.wantsLayer = true
        iconBackgroundView.layer?.cornerRadius = 9
        iconBackgroundView.layer?.backgroundColor = NSColor(item.iconTint.opacity(0.14)).cgColor

        let iconImageView = NSImageView()
        iconImageView.image = NSImage(
            systemSymbolName: item.iconName,
            accessibilityDescription: item.title
        )
        iconImageView.contentTintColor = NSColor(item.iconTint)

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        [iconBackgroundView, iconImageView, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        previewView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        previewView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconBackgroundView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 10),
            iconBackgroundView.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 28),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 28),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: previewView.centerYAnchor)
        ])

        previewView.layoutSubtreeIfNeeded()
        return previewView.snapshotImage()
    }
}

private final class FeatureManagementTableCellView: NSTableCellView {
    private let containerView = NSView()
    private let iconBackgroundView = NSView()
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let activeDotView = NSView()
    private let visibilityButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let handleImageView = NSImageView()
    private var visibilityHandler: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
        configureStyles()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: PluginFeatureManagementItem,
        onVisibilityChange: @escaping (Bool) -> Void
    ) {
        textField = titleLabel
        visibilityHandler = onVisibilityChange

        titleLabel.stringValue = item.title
        descriptionLabel.stringValue = "\(item.description) · \(presentationText(for: item.presentation))"
        iconImageView.image = NSImage(
            systemSymbolName: item.iconName,
            accessibilityDescription: item.title
        )
        iconImageView.contentTintColor = NSColor(item.iconTint)
        iconBackgroundView.layer?.backgroundColor = NSColor(item.iconTint.opacity(0.14)).cgColor
        activeDotView.isHidden = !item.isActive
        visibilityButton.state = item.isVisible ? .on : .off
        toolTip = item.title
        visibilityButton.toolTip = item.title
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        containerView.wantsLayer = true
        iconBackgroundView.wantsLayer = true
        activeDotView.wantsLayer = true

        addSubview(containerView)
        containerView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(descriptionLabel)
        containerView.addSubview(activeDotView)
        containerView.addSubview(visibilityButton)
        containerView.addSubview(handleImageView)
    }

    private func configureStyles() {
        containerView.layer?.cornerRadius = 12
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        iconBackgroundView.layer?.cornerRadius = 10

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.usesSingleLineMode = false

        activeDotView.layer?.cornerRadius = 4
        activeDotView.layer?.backgroundColor = NSColor.systemGreen.cgColor

        visibilityButton.setButtonType(.switch)
        visibilityButton.title = ""
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityToggle(_:))

        handleImageView.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: "拖拽调整顺序"
        )
        handleImageView.contentTintColor = .secondaryLabelColor
        handleImageView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    }

    private func configureLayout() {
        [
            containerView,
            iconBackgroundView,
            iconImageView,
            titleLabel,
            descriptionLabel,
            activeDotView,
            visibilityButton,
            handleImageView
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBackgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            iconBackgroundView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 30),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 30),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: activeDotView.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            activeDotView.widthAnchor.constraint(equalToConstant: 8),
            activeDotView.heightAnchor.constraint(equalToConstant: 8),
            activeDotView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            activeDotView.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -14),

            visibilityButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            visibilityButton.trailingAnchor.constraint(equalTo: handleImageView.leadingAnchor, constant: -12),

            handleImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            handleImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            handleImageView.widthAnchor.constraint(equalToConstant: 16),
            handleImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @objc
    private func handleVisibilityToggle(_ sender: NSButton) {
        visibilityHandler?(sender.state == .on)
    }

    private func presentationText(for presentation: PluginFeaturePresentation) -> String {
        switch presentation {
        case .featurePanel:
            return "操作面板"
        case .componentPanel:
            return "组件"
        case .featureAndComponentPanel:
            return "操作面板与组件"
        }
    }
}

@MainActor
private extension NSView {
    func snapshotImage() -> NSImage {
        guard
            let bitmap = bitmapImageRepForCachingDisplay(in: bounds)
                ?? NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(bounds.width),
                    pixelsHigh: Int(bounds.height),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
        else {
            return NSImage(size: bounds.size)
        }

        cacheDisplay(in: bounds, to: bitmap)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}
