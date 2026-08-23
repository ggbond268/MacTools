import AppKit
import ImageIO
import MacToolsPluginKit
import QuickLookThumbnailing
import SwiftUI

enum ClipboardHistoryContentFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case pdf
    case files
    case link
    case color
    case media

    var id: String { rawValue }

    var shortcutNumber: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1
    }

    func matches(_ item: ClipboardHistoryItem) -> Bool {
        if self == .all {
            return true
        }
        return matches(kinds: item.filterContentKinds)
    }

    func matches(_ payload: ClipboardHistoryPayload) -> Bool {
        matches(kinds: payload.filterContentKinds)
    }

    private func matches(kinds: Set<ClipboardHistoryContentKind>) -> Bool {
        return switch self {
        case .all:
            true
        case .text:
            kinds.contains(.plainText) || kinds.contains(.richText)
        case .image:
            kinds.contains(.image)
        case .pdf:
            kinds.contains(.pdf)
        case .files:
            kinds.contains(.files)
        case .link:
            kinds.contains(.link)
        case .color:
            kinds.contains(.color)
        case .media:
            kinds.contains(.media)
        }
    }
}

enum ClipboardImageTextAvailability: Equatable {
    case pending
    case available
    case unavailable

    init(item: ClipboardHistoryItem) {
        guard item.kind == .image else {
            self = .unavailable
            return
        }
        guard item.hasCompletedImageTextIndexing else {
            self = .pending
            return
        }
        self = item.imageSearchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? .available
            : .unavailable
    }
}

enum ClipboardImagePreviewLayout {
    static func aspectFitSize(
        contentSize: CGSize,
        containerSize: CGSize,
        padding: CGFloat = 16
    ) -> CGSize {
        guard contentSize.width.isFinite,
              contentSize.height.isFinite,
              containerSize.width.isFinite,
              containerSize.height.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return .zero
        }
        let availableWidth = max(0, containerSize.width - padding * 2)
        let availableHeight = max(0, containerSize.height - padding * 2)
        guard availableWidth > 0, availableHeight > 0 else { return .zero }
        let scale = min(availableWidth / contentSize.width, availableHeight / contentSize.height)
        return CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }
}

private struct ClipboardEmbeddedPreviewResult: @unchecked Sendable {
    let image: NSImage?
}

enum ClipboardEmbeddedPreviewPolicy {
    static let maximumThumbnailDimension = 1_600
    static let maximumPDFPageCount = 1_000

    static func allowsImageSourceDimensions(width: Int, height: Int) -> Bool {
        VisionClipboardImageTextRecognizer.allowsSourceDimensions(width: width, height: height)
    }

    static func allowsPDF(pageCount: Int, mediaBox: CGRect) -> Bool {
        guard pageCount > 0, pageCount <= maximumPDFPageCount,
              mediaBox.width.isFinite, mediaBox.height.isFinite,
              mediaBox.width <= CGFloat(VisionClipboardImageTextRecognizer.maximumSourceDimension),
              mediaBox.height <= CGFloat(VisionClipboardImageTextRecognizer.maximumSourceDimension) else {
            return false
        }
        return VisionClipboardImageTextRecognizer.allowsSourceDimensions(
            width: Int(mediaBox.width.rounded(.up)),
            height: Int(mediaBox.height.rounded(.up))
        )
    }

    static func imageThumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
        allowsImageSourceDimensions(width: width.intValue, height: height.intValue),
        !Task.isCancelled,
        let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
            ] as CFDictionary
        ) else {
            return nil
        }
        return NSImage(cgImage: image, size: .zero)
    }

    static func pdfThumbnail(from data: Data) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else {
            return nil
        }
        let mediaBox = page.getBoxRect(.mediaBox).standardized
        guard allowsPDF(pageCount: document.numberOfPages, mediaBox: mediaBox) else {
            return nil
        }
        let scale = min(
            1,
            CGFloat(maximumThumbnailDimension) / max(mediaBox.width, mediaBox.height)
        )
        let width = max(1, Int((mediaBox.width * scale).rounded(.up)))
        let height = max(1, Int((mediaBox.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(
            .mediaBox,
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        guard !Task.isCancelled, let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

private actor ClipboardEmbeddedPreviewDecodeGate {
    static let shared = ClipboardEmbeddedPreviewDecodeGate()

    func load(for item: ClipboardHistoryItem) -> ClipboardEmbeddedPreviewResult {
        defer { item.discardCachedPayloadIfReloadable() }
        guard !Task.isCancelled,
              let payload = try? item.loadPayload(),
              !Task.isCancelled,
              let representation = payload.representations.first(where: {
                  ClipboardRepresentationType.isImage($0.typeIdentifier)
                      || $0.typeIdentifier == ClipboardRepresentationType.pdf
              }) else {
            return ClipboardEmbeddedPreviewResult(image: nil)
        }
        let image: NSImage?
        if representation.typeIdentifier == ClipboardRepresentationType.pdf {
            image = ClipboardEmbeddedPreviewPolicy.pdfThumbnail(from: representation.data)
        } else {
            image = ClipboardEmbeddedPreviewPolicy.imageThumbnail(from: representation.data)
        }
        return ClipboardEmbeddedPreviewResult(image: Task.isCancelled ? nil : image)
    }
}

enum ClipboardEmbeddedPreviewLoader {
    static func load(for item: ClipboardHistoryItem) async -> NSImage? {
        let result = await ClipboardEmbeddedPreviewDecodeGate.shared.load(for: item)
        return result.image
    }
}

enum ClipboardHistoryTimestampFormatting {
    static func exactString(for date: Date, locale: Locale) -> String {
        date.formatted(
            Date.FormatStyle(date: .long, time: .standard)
                .locale(locale)
        )
    }

    static func relativeString(
        for date: Date,
        relativeTo referenceDate: Date,
        locale: Locale
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }
}

struct ClipboardHistoryPreviousApplicationState<Application> {
    private(set) var application: Application?

    mutating func beginPresentation(
        frontmostApplication: Application?,
        isExternal: (Application) -> Bool
    ) {
        application = frontmostApplication.flatMap { isExternal($0) ? $0 : nil }
    }

    mutating func consume() -> Application? {
        defer { application = nil }
        return application
    }
}

@MainActor
final class ClipboardHistoryPanelModel: ObservableObject {
    nonisolated static let resultPageSize = 50
    nonisolated static let searchDebounceNanoseconds: UInt64 = 120_000_000

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            visibleResultLimit = Self.resultPageSize
            scheduleSearch(debounced: true)
        }
    }
    @Published var contentFilter: ClipboardHistoryContentFilter = .all {
        didSet {
            guard contentFilter != oldValue else { return }
            visibleResultLimit = Self.resultPageSize
            scheduleSearch(debounced: false)
        }
    }
    @Published var selectedItemID: UUID?
    @Published private(set) var visibleItems: [ClipboardHistoryItem] = []
    @Published private(set) var hasMoreResults = false
    @Published private(set) var isSearching = false
    @Published private(set) var focusRequestID: UInt = 0

    private var allItems: [ClipboardHistoryItem] = []
    private var visibleResultLimit = ClipboardHistoryPanelModel.resultPageSize
    private var searchGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?

    func updateItems(_ items: [ClipboardHistoryItem]) {
        guard items != allItems else { return }
        let updatedByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let existingIDs = Set(allItems.map(\.id))
        let newItems = items.filter { !existingIDs.contains($0.id) }
        allItems = newItems + allItems.compactMap { updatedByID[$0.id] }
        scheduleSearch(debounced: false)
    }

    func prepareForPresentation(items: [ClipboardHistoryItem]) {
        searchTask?.cancel()
        query = ""
        contentFilter = .all
        allItems = items.sorted(by: Self.activityOrder)
        visibleResultLimit = Self.resultPageSize
        visibleItems = []
        hasMoreResults = false
        selectedItemID = nil
        focusRequestID &+= 1
        scheduleSearch(debounced: false)
    }

    func loadMoreResults() {
        guard hasMoreResults, !isSearching else { return }
        visibleResultLimit += Self.resultPageSize
        scheduleSearch(debounced: false)
    }

    func waitForSearchForTesting() async {
        await searchTask?.value
    }

    func moveSelection(by offset: Int) {
        guard !visibleItems.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap { selectedID in
            visibleItems.firstIndex { $0.id == selectedID }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), visibleItems.count - 1)
        selectedItemID = visibleItems[nextIndex].id
    }

    @discardableResult
    func selectNeighborBeforeRemoving(itemID: UUID) -> UUID? {
        guard selectedItemID == itemID,
              let index = visibleItems.firstIndex(where: { $0.id == itemID }) else {
            return selectedItemID
        }
        if visibleItems.indices.contains(index + 1) {
            selectedItemID = visibleItems[index + 1].id
        } else if index > 0 {
            selectedItemID = visibleItems[index - 1].id
        } else {
            selectedItemID = nil
        }
        return selectedItemID
    }

    private func scheduleSearch(debounced: Bool) {
        searchGeneration &+= 1
        let generation = searchGeneration
        let items = allItems
        let query = query
        let contentFilter = contentFilter
        let limit = visibleResultLimit
        searchTask?.cancel()
        isSearching = true

        searchTask = Task { [weak self] in
            if debounced {
                do {
                    try await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .userInitiated) {
                let typeMatches = items.filter { contentFilter.matches($0) }
                guard !Task.isCancelled else {
                    return ClipboardHistorySearch.Result(items: [], hasMore: false)
                }
                let orderedItems = typeMatches.filter(\.isPinned)
                    + typeMatches.filter { !$0.isPinned }
                return ClipboardHistorySearch.result(
                    orderedItems,
                    query: query,
                    limit: limit
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, generation == self.searchGeneration else { return }
            visibleItems = result.items
            hasMoreResults = result.hasMore
            isSearching = false
            if selectedItemID == nil || !visibleItems.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = visibleItems.first?.id
            }
        }
    }

    private static func activityOrder(_ lhs: ClipboardHistoryItem, _ rhs: ClipboardHistoryItem) -> Bool {
        let lhsActivity = lhs.lastUsedAt ?? lhs.capturedAt
        let rhsActivity = rhs.lastUsedAt ?? rhs.capturedAt
        if lhsActivity != rhsActivity {
            return lhsActivity > rhsActivity
        }
        return lhs.capturedAt > rhs.capturedAt
    }
}

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    enum KeyboardCommand: Equatable {
        case close
        case pasteSelection(asPlainText: Bool)
        case togglePin
        case deleteSelection
        case moveSelection(offset: Int)
        case pasteVisibleItem(index: Int)
        case selectFilter(ClipboardHistoryContentFilter)
    }

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let historyController: ClipboardHistoryController
    private let localization: PluginLocalization
    private let onIgnoreNextCopy: () -> Void
    private let pasteCommandSender: any ClipboardPasteCommandSending
    private let model = ClipboardHistoryPanelModel()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var previousApplicationState = ClipboardHistoryPreviousApplicationState<NSRunningApplication>()

    init(
        historyController: ClipboardHistoryController,
        localization: PluginLocalization,
        onIgnoreNextCopy: @escaping () -> Void,
        pasteCommandSender: any ClipboardPasteCommandSending = SystemClipboardPasteCommandSender()
    ) {
        self.historyController = historyController
        self.localization = localization
        self.onIgnoreNextCopy = onIgnoreNextCopy
        self.pasteCommandSender = pasteCommandSender
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    static func shouldDismissForGlobalShortcut(
        isVisible: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        // A global shortcut is a visibility toggle. The panel may have yielded key status to
        // another application while remaining visible, but invoking the shortcut again should
        // still dismiss it.
        _ = isKeyWindow
        return isVisible
    }

    func handleGlobalShortcut() {
        if Self.shouldDismissForGlobalShortcut(
            isVisible: panel?.isVisible == true,
            isKeyWindow: panel?.isKeyWindow == true
        ) {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        previousApplicationState.beginPresentation(
            frontmostApplication: NSWorkspace.shared.frontmostApplication,
            isExternal: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        )
        model.prepareForPresentation(items: historyController.items)
        installKeyMonitor()
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close(restorePreviousApplication: Bool = true) {
        let previousApplication = previousApplicationState.consume()
        historyController.releasePayloadIfReloadable(id: model.selectedItemID)
        panel?.orderOut(nil)
        removeKeyMonitor()
        if restorePreviousApplication {
            previousApplication?.activate(options: [])
        }
    }

    func windowWillClose(_ notification: Notification) {
        historyController.releasePayloadIfReloadable(id: model.selectedItemID)
        removeKeyMonitor()
        previousApplicationState.consume()?.activate(options: [])
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = localization.string("metadata.title", defaultValue: "剪贴板历史")
        panel.setAccessibilityTitle(localization.string("metadata.title", defaultValue: "剪贴板历史"))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 680, height: 440)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: ClipboardHistoryPanelView(
                controller: historyController,
                model: model,
                localization: localization,
                onCopyAndClose: { [weak self] itemID in
                    Task { @MainActor [weak self] in
                        guard let self,
                              await self.historyController.preparePayloadForUse(id: itemID),
                              await self.historyController.copyItem(id: itemID) else { return }
                        self.close()
                    }
                },
                onPasteAndClose: { [weak self] itemID, asPlainText in
                    self?.pasteItem(id: itemID, asPlainText: asPlainText)
                },
                onIgnoreNextCopy: { [weak self] in
                    self?.onIgnoreNextCopy()
                    self?.close()
                },
                onDelete: { [weak self] itemID in
                    guard let self else { return }
                    await self.deleteItem(id: itemID)
                },
                onClose: { [weak self] in self?.close() }
            )
            .environment(\.locale, PluginRuntimeLocalization.locale)
            .environment(
                \.layoutDirection,
                PluginRuntimeLocalization.locale.language.characterDirection == .rightToLeft
                    ? .rightToLeft
                    : .leftToRight
            )
        )
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            let textEditor = panel.firstResponder as? NSTextView
            guard let command = Self.keyboardCommand(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isPanelEvent: event.window === panel,
                isPanelKeyWindow: panel.isKeyWindow,
                hasAttachedSheet: panel.attachedSheet != nil,
                isEditingText: textEditor?.isFieldEditor == true,
                hasMarkedText: textEditor?.hasMarkedText() == true
            ) else {
                return event
            }

            switch command {
            case .close:
                self.close()
                return nil
            case let .pasteSelection(asPlainText):
                guard !self.historyController.isClearingHistory else { return event }
                guard let selectedItemID = self.model.selectedItemID else { return event }
                self.pasteItem(id: selectedItemID, asPlainText: asPlainText)
                return nil
            case .togglePin:
                guard !self.historyController.isClearingHistory else { return event }
                guard let selectedItemID = self.model.selectedItemID else { return event }
                self.historyController.togglePin(id: selectedItemID)
                return nil
            case .deleteSelection:
                guard !self.historyController.isClearingHistory else { return event }
                guard let selectedItemID = self.model.selectedItemID else { return event }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.deleteItem(id: selectedItemID)
                }
                return nil
            case let .moveSelection(offset):
                self.moveSelection(by: offset)
                return nil
            case let .pasteVisibleItem(index):
                self.pasteVisibleItem(at: index)
                return nil
            case let .selectFilter(filter):
                self.model.contentFilter = filter
                self.selectFirstVisibleItemIfNeeded()
                return nil
            }
        }
    }

    static func keyboardCommand(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isPanelEvent: Bool,
        isPanelKeyWindow: Bool,
        hasAttachedSheet: Bool,
        isEditingText: Bool,
        hasMarkedText: Bool
    ) -> KeyboardCommand? {
        guard isPanelEvent, isPanelKeyWindow, !hasAttachedSheet, !hasMarkedText else {
            return nil
        }
        let flags = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        switch keyCode {
        case 53:
            return .close
        case 36 where flags.isEmpty:
            return .pasteSelection(asPlainText: false)
        case 36 where flags == .shift:
            return .pasteSelection(asPlainText: true)
        case 35 where flags.contains(.command) && flags.isDisjoint(with: [.control, .option, .shift]):
            return .togglePin
        case 35 where flags == .control:
            return .moveSelection(offset: -1)
        case 45 where flags == .control:
            return .moveSelection(offset: 1)
        case 51 where flags == .command:
            return .deleteSelection
        case 125 where flags.isEmpty:
            return .moveSelection(offset: 1)
        case 126 where flags.isEmpty:
            return .moveSelection(offset: -1)
        case 18 where flags == .command:
            return .pasteVisibleItem(index: 0)
        case 19 where flags == .command:
            return .pasteVisibleItem(index: 1)
        case 20 where flags == .command:
            return .pasteVisibleItem(index: 2)
        case 21 where flags == .command:
            return .pasteVisibleItem(index: 3)
        case 23 where flags == .command:
            return .pasteVisibleItem(index: 4)
        case 22 where flags == .command:
            return .pasteVisibleItem(index: 5)
        case 26 where flags == .command:
            return .pasteVisibleItem(index: 6)
        case 28 where flags == .command:
            return .pasteVisibleItem(index: 7)
        case 25 where flags == .command:
            return .pasteVisibleItem(index: 8)
        case 18 where flags == .control:
            return .selectFilter(.all)
        case 19 where flags == .control:
            return .selectFilter(.text)
        case 20 where flags == .control:
            return .selectFilter(.image)
        case 21 where flags == .control:
            return .selectFilter(.pdf)
        case 23 where flags == .control:
            return .selectFilter(.files)
        case 22 where flags == .control:
            return .selectFilter(.link)
        case 26 where flags == .control:
            return .selectFilter(.color)
        case 28 where flags == .control:
            return .selectFilter(.media)
        default:
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func selectFirstVisibleItemIfNeeded() {
        let visibleIDs = model.visibleItems.map(\.id)
        if let selectedItemID = model.selectedItemID, visibleIDs.contains(selectedItemID) {
            return
        }
        model.selectedItemID = visibleIDs.first
    }

    private func moveSelection(by offset: Int) {
        model.moveSelection(by: offset)
    }

    private func pasteVisibleItem(at index: Int) {
        guard model.visibleItems.indices.contains(index) else { return }
        pasteItem(id: model.visibleItems[index].id, asPlainText: false)
    }

    private func deleteItem(id: UUID) async {
        let previousSelection = model.selectedItemID
        model.selectNeighborBeforeRemoving(itemID: id)
        guard await historyController.deleteItem(id: id) else {
            model.selectedItemID = previousSelection
            return
        }
        selectFirstVisibleItemIfNeeded()
    }

    private func pasteItem(id: UUID, asPlainText: Bool) {
        Task { @MainActor in
            guard await historyController.preparePayloadForUse(id: id) else {
                NSSound.beep()
                return
            }
            let copied: Bool
            if asPlainText {
                copied = historyController.copyItemAsPlainText(id: id)
            } else {
                copied = await historyController.copyItem(id: id)
            }
            guard copied else {
                NSSound.beep()
                return
            }

            let previousApplication = previousApplicationState.consume()
            panel?.orderOut(nil)
            removeKeyMonitor()
            guard let previousApplication else { return }
            previousApplication.activate(options: [])
            let pasteCommandSender = pasteCommandSender
            let activationDeadline = ProcessInfo.processInfo.systemUptime + 0.4
            while !previousApplication.isActive,
                  ProcessInfo.processInfo.systemUptime < activationDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if !(await pasteCommandSender.sendPasteCommand()) {
                NSSound.beep()
            }
        }
    }
}

private enum ClipboardHistoryClearRequest: String, Identifiable {
    case unpinned
    case all

    var id: String { rawValue }
}

struct ClipboardHistoryPanelPresentation: Equatable {
    let showsErrorOnly: Bool
    let showsEmptyState: Bool
    let showsSearchEmptyState: Bool
    let showsHistory: Bool
    let showsInlineStorageError: Bool

    static func resolve(
        itemCount: Int,
        visibleItemCount: Int,
        hasStorageError: Bool
    ) -> Self {
        if itemCount == 0 {
            return Self(
                showsErrorOnly: hasStorageError,
                showsEmptyState: !hasStorageError,
                showsSearchEmptyState: false,
                showsHistory: false,
                showsInlineStorageError: false
            )
        }
        return Self(
            showsErrorOnly: false,
            showsEmptyState: false,
            showsSearchEmptyState: visibleItemCount == 0,
            showsHistory: visibleItemCount > 0,
            showsInlineStorageError: hasStorageError
        )
    }
}

@MainActor
private struct ClipboardRichTextPreviewView: View {
    let item: ClipboardHistoryItem
    let localization: PluginLocalization

    @State private var preview: ClipboardRichTextPreviewResult?
    @State private var usesDarkCanvas = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    localization.string("content.kind.richText", defaultValue: "富文本"),
                    systemImage: "doc.richtext.fill"
                )
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    usesDarkCanvas.toggle()
                } label: {
                    Image(systemName: usesDarkCanvas ? "sun.max.fill" : "moon.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(canvasToggleTitle)
                .accessibilityLabel(canvasToggleTitle)
            }

            Group {
                switch preview {
                case let .some(.formatted(attributedString)):
                    Text(attributedString)
                        .textSelection(.enabled)
                case let .some(.plainText(text, isSimplified)):
                    VStack(alignment: .leading, spacing: 10) {
                        if isSimplified {
                            Label(
                                localization.string(
                                    "panel.richText.previewSimplified",
                                    defaultValue: "为保持流畅，大型富文本以纯文本预览。"
                                ),
                                systemImage: "speedometer"
                            )
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                        }
                        Text(text)
                            .textSelection(.enabled)
                    }
                case .some(.unavailable):
                    Label(
                        localization.string("content.kind.richText", defaultValue: "富文本"),
                        systemImage: "doc.richtext.fill"
                    )
                    .foregroundStyle(.secondary)
                case .none:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14)
            .background(usesDarkCanvas ? Color.black : Color.white)
            .foregroundStyle(usesDarkCanvas ? Color.white : Color.black)
            .environment(\.colorScheme, usesDarkCanvas ? .dark : .light)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
        }
        .task(id: item.id) {
            preview = nil
            let fallbackText = item.text
            let loadedPreview = await ClipboardRichTextPreviewLoader.load(
                for: item,
                fallbackText: fallbackText
            )
            guard !Task.isCancelled else { return }
            preview = loadedPreview
        }
    }

    private var canvasToggleTitle: String {
        if usesDarkCanvas {
            return localization.string(
                "panel.richText.useLightCanvas",
                defaultValue: "使用浅色预览背景"
            )
        }
        return localization.string(
            "panel.richText.useDarkCanvas",
            defaultValue: "使用深色预览背景"
        )
    }
}

@MainActor
private struct ClipboardWindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            NSCursor.closedHand.push()
            defer { NSCursor.pop() }
            window.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView {
        DragView(frame: .zero)
    }

    func updateNSView(_ nsView: DragView, context: Context) {}
}

private struct ClipboardRelativeTimestamp: View {
    let date: Date

    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(ClipboardHistoryTimestampFormatting.relativeString(
                for: date,
                relativeTo: context.date,
                locale: locale
            ))
        }
    }
}

@MainActor
private struct ClipboardFileReferenceRow: View {
    let url: URL
    let unavailableTitle: String

    @State private var isAvailable: Bool?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.body)
                    .lineLimit(2)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isAvailable == false {
                    Label(unavailableTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .task(id: url) {
            isAvailable = await ClipboardFileAvailabilityCache.shared.isAvailable(url)
        }
    }

    private var systemImage: String {
        switch ClipboardFileContentKind(url: url) {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "play.rectangle"
        case nil: "doc"
        }
    }
}

@MainActor
private struct ClipboardFilePreviewView: View {
    let url: URL
    let kind: ClipboardFileContentKind
    let unavailableTitle: String

    @State private var thumbnail: NSImage?
    @State private var isAvailable: Bool?
    @State private var didFinishLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(14)
                } else if didFinishLoading {
                    Image(systemName: systemImage)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isAvailable == false {
                    Label(unavailableTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.orange)
                }
            }
        }
        .task(id: url) {
            thumbnail = nil
            isAvailable = nil
            didFinishLoading = false

            async let loadedAvailability = Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: url.path)
            }.value
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 900, height: 650),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            thumbnail = representation?.nsImage
            isAvailable = await loadedAvailability
            didFinishLoading = true
        }
    }

    private var systemImage: String {
        switch kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "play.rectangle"
        }
    }

}

@MainActor
private struct ClipboardHistoryPanelView: View {
    private enum Layout {
        static let listMinimumWidth: CGFloat = 240
        static let listMaximumWidth: CGFloat = 310
    }

    @ObservedObject var controller: ClipboardHistoryController
    @ObservedObject var model: ClipboardHistoryPanelModel
    let onCopyAndClose: (UUID) -> Void
    let onPasteAndClose: (UUID, Bool) -> Void
    let onIgnoreNextCopy: () -> Void
    let onDelete: (UUID) async -> Void
    let onClose: () -> Void
    let localization: PluginLocalization

    @ObservedObject private var settings: ClipboardHistorySettingsStore
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.locale) private var locale
    @State private var clearRequest: ClipboardHistoryClearRequest?
    @State private var detailMetadataByItemID: [UUID: ClipboardHistoryDetailMetadata] = [:]
    @State private var embeddedPreviewItemID: UUID?
    @State private var embeddedPreviewImage: NSImage?
    @State private var isEmbeddedPreviewLoading = false

    init(
        controller: ClipboardHistoryController,
        model: ClipboardHistoryPanelModel,
        localization: PluginLocalization,
        onCopyAndClose: @escaping (UUID) -> Void,
        onPasteAndClose: @escaping (UUID, Bool) -> Void,
        onIgnoreNextCopy: @escaping () -> Void,
        onDelete: @escaping (UUID) async -> Void,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.model = model
        self.localization = localization
        self.onCopyAndClose = onCopyAndClose
        self.onPasteAndClose = onPasteAndClose
        self.onIgnoreNextCopy = onIgnoreNextCopy
        self.onDelete = onDelete
        self.onClose = onClose
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    private var visibleItems: [ClipboardHistoryItem] {
        model.visibleItems
    }

    private var selectedItem: ClipboardHistoryItem? {
        guard let selectedItemID = model.selectedItemID else { return nil }
        return controller.items.first { $0.id == selectedItemID }
    }

    private var presentation: ClipboardHistoryPanelPresentation {
        .resolve(
            itemCount: controller.items.count,
            visibleItemCount: visibleItems.count,
            hasStorageError: controller.errorMessage != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginPaletteMetrics.contentSpacing) {
            panelToolbar
            if presentation.showsInlineStorageError,
               let errorMessage = controller.errorMessage {
                storageErrorBanner(errorMessage)
            }
            panelContent
            footer
        }
        .padding(PluginPaletteMetrics.contentPadding)
        .background {
            panelSurface
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: PluginPaletteMetrics.surfaceCornerRadius,
                style: .continuous
            )
                .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            ClipboardWindowDragRegion()
                .frame(width: 72, height: 15)
                .overlay {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 28, height: 3)
                        .allowsHitTesting(false)
                }
                .help(localization.string("panel.drag.help", defaultValue: "拖动以移动窗口"))
                .accessibilityLabel(
                    localization.string("panel.drag.help", defaultValue: "拖动以移动窗口")
                )
        }
        .onAppear {
            model.updateItems(controller.items)
            repairSelection()
        }
        .onChange(of: controller.items) { _, items in model.updateItems(items) }
        .onChange(of: visibleItems.map(\.id)) { _, _ in repairSelection() }
        .task(id: selectedItem?.id) {
            await loadEmbeddedPreview()
        }
        .alert(item: $clearRequest) { request in
            switch request {
            case .unpinned:
                Alert(
                    title: Text(localization.string("clear.unpinned.title", defaultValue: "清除未固定的历史记录？")),
                    message: Text(localization.string("clear.unpinned.message", defaultValue: "固定片段会保留。此操作无法撤销。")),
                    primaryButton: .destructive(Text(localization.string("common.clear", defaultValue: "清除"))) {
                        Task { await controller.clearUnpinnedHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .all:
                Alert(
                    title: Text(localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？")),
                    message: Text(localization.string("clear.all.message", defaultValue: "所有历史记录和固定片段都会被永久删除。")),
                    primaryButton: .destructive(Text(localization.string("common.clearAll", defaultValue: "全部清除"))) {
                        Task { await controller.clearAllHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if presentation.showsErrorOnly, let errorMessage = controller.errorMessage {
            ContentUnavailableView {
                Label(
                    localization.string("panel.error.title", defaultValue: "无法读取剪贴板历史"),
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                    controller.retryStorageAccess()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation.showsEmptyState {
            ContentUnavailableView(
                settings.isPaused
                    ? localization.string("panel.empty.paused.title", defaultValue: "收集已暂停")
                    : localization.string("panel.empty.title", defaultValue: "尚无剪贴板历史"),
                systemImage: settings.isPaused ? "pause.circle" : "clipboard",
                description: Text(
                    settings.isPaused
                        ? localization.string(
                            "panel.empty.paused.description",
                            defaultValue: "恢复后，新复制的剪贴板项目会保存在本机。"
                        )
                        : localization.string(
                            "panel.empty.description",
                            defaultValue: "复制内容后，可在这里搜索并再次使用。"
                        )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isSearching, visibleItems.isEmpty {
            ProgressView(
                localization.string("panel.search.searching", defaultValue: "正在搜索…")
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation.showsSearchEmptyState {
            if model.query.isEmpty, model.contentFilter != .all {
                ContentUnavailableView(
                    localization.string("panel.filter.empty", defaultValue: "此类型没有记录"),
                    systemImage: filterSystemImage(model.contentFilter)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: model.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if presentation.showsHistory {
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    historyList
                        .frame(width: min(
                            Layout.listMaximumWidth,
                            max(Layout.listMinimumWidth, geometry.size.width * 0.34)
                        ))
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(controller.isClearingHistory)
        }
    }

    private func storageErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string("panel.error.storage.title", defaultValue: "存储问题"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                controller.retryStorageAccess()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private var panelToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            PluginPaletteSearchToolbar(
                text: $model.query,
                placeholder: localization.string(
                    "panel.search.placeholder",
                    defaultValue: "搜索剪贴板历史或来源应用"
                ),
                accessibilityLabel: localization.string(
                    "panel.search.placeholder",
                    defaultValue: "搜索剪贴板历史或来源应用"
                ),
                accessibilityIdentifier: "mactools.clipboard-history.search",
                clearAccessibilityLabel: localization.string(
                    "common.clear",
                    defaultValue: "清除"
                ),
                focusRequestID: model.focusRequestID,
                alternateSubmitModifier: .shift,
                onCommand: handleSearchFieldCommand
            ) {
                if settings.isPaused {
                    Label(
                        localization.string("panel.badge.paused", defaultValue: "已暂停"),
                        systemImage: "pause.fill"
                    )
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.orange)
                }
                if controller.isIgnoringNextCopy {
                    Button {
                        controller.cancelNextCaptureSuppression()
                    } label: {
                        Label(
                            localization.string("panel.status.ignoreNext", defaultValue: "下次复制不会保存"),
                            systemImage: "eye.slash.fill"
                        )
                    }
                    .buttonStyle(.plain)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                    .help(
                        localization.string(
                            "panel.action.cancelIgnore",
                            defaultValue: "取消忽略下一次复制"
                        )
                    )
                }

                Button {
                    settings.setPaused(!settings.isPaused)
                } label: {
                    Image(systemName: settings.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PluginPaletteToolbarControlStyle())
                .disabled(!controller.isCollectionOperational)
                .help(
                    settings.isPaused
                        ? localization.string("common.resume", defaultValue: "恢复")
                        : localization.string("common.pause", defaultValue: "暂停")
                )

                Menu {
                    if controller.isIgnoringNextCopy {
                        Button(
                            localization.string(
                                "panel.action.cancelIgnore",
                                defaultValue: "取消忽略下一次复制"
                            )
                        ) {
                            controller.cancelNextCaptureSuppression()
                        }
                    } else {
                        Button(localization.string("shortcut.ignoreNext.title", defaultValue: "忽略下一次复制")) {
                            onIgnoreNextCopy()
                        }
                        .disabled(!controller.canSuppressNextCapture)
                    }
                    Divider()
                    Button(localization.string("clear.unpinned.menu", defaultValue: "清除未固定的历史记录"), role: .destructive) {
                        clearRequest = .unpinned
                    }
                    .disabled(controller.recentItems.isEmpty || controller.isClearingHistory)
                    Button(localization.string("clear.all.menu", defaultValue: "清除全部历史记录"), role: .destructive) {
                        clearRequest = .all
                    }
                    .disabled(
                        (controller.items.isEmpty && controller.errorMessage == nil)
                            || controller.isClearingHistory
                    )
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .buttonStyle(PluginPaletteToolbarControlStyle())
                .accessibilityLabel(localization.string("common.moreActions", defaultValue: "更多操作"))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PluginPaletteToolbarControlStyle())
                .help(localization.string("panel.close.help", defaultValue: "关闭（Esc）"))
                .accessibilityLabel(localization.string("panel.close.help", defaultValue: "关闭（Esc）"))
            }

            filterStrip
        }
    }

    private var filterStrip: some View {
        ViewThatFits(in: .horizontal) {
            filterButtons(showsLabels: true)
            filterButtons(showsLabels: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.string("panel.filter.title", defaultValue: "按类型筛选"))
    }

    private func filterButtons(showsLabels: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(ClipboardHistoryContentFilter.allCases) { filter in
                Button {
                    model.contentFilter = filter
                    repairSelection()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: filterSystemImage(filter))
                        if showsLabels {
                            Text(filterTitle(filter))
                        }
                    }
                    .padding(.horizontal, showsLabels ? 8 : 7)
                    .frame(minHeight: 26)
                    .foregroundStyle(
                        model.contentFilter == filter ? Color.accentColor : Color.primary
                    )
                    .background(
                        model.contentFilter == filter
                            ? PluginSettingsTheme.Palette.activeControlBackground
                            : Color.clear,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(filterTitle(filter)) (⌃\(filter.shortcutNumber))")
                .accessibilityLabel("\(filterTitle(filter)) (⌃\(filter.shortcutNumber))")
                .accessibilityAddTraits(
                    model.contentFilter == filter ? .isSelected : []
                )
            }
        }
    }

    private var historyList: some View {
        let quickPasteNumbers = Dictionary(
            uniqueKeysWithValues: visibleItems.prefix(9).enumerated().map { index, item in
                (item.id, index + 1)
            }
        )
        let sectionStartingItemIDs = Set([
            visibleItems.first(where: \.isPinned)?.id,
            visibleItems.first(where: { !$0.isPinned })?.id,
        ].compactMap { $0 })

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if sectionStartingItemIDs.contains(item.id) {
                                sectionTitle(
                                    item.isPinned
                                        ? localization.string("panel.section.pinned", defaultValue: "固定片段")
                                        : localization.string("panel.section.recent", defaultValue: "最近记录")
                                )
                            }
                            row(item, quickPasteNumber: quickPasteNumbers[item.id])
                        }
                        .id(item.id)
                    }
                    if model.hasMoreResults || model.isSearching {
                        VStack(spacing: 5) {
                            if model.hasMoreResults {
                                Text(localization.format(
                                    "panel.results.showingFirst",
                                    defaultValue: "正在显示前 %d 条结果",
                                    visibleItems.count
                                ))
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.loadMoreResults()
                                } label: {
                                    Label(
                                        localization.format(
                                            "panel.results.showMore",
                                            defaultValue: "再显示 %d 条",
                                            ClipboardHistoryPanelModel.resultPageSize
                                        ),
                                        systemImage: "chevron.down"
                                    )
                                }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.trailing, 6)
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedItemID, initial: true) { previousItemID, itemID in
                controller.releasePayloadIfReloadable(id: previousItemID)
                guard let itemID else { return }
                controller.requestImageTextIndexing(id: itemID)
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(PluginSettingsTheme.Typography.secondaryLabel)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private func row(
        _ item: ClipboardHistoryItem,
        quickPasteNumber: Int?
    ) -> some View {
        let isSelected = item.id == model.selectedItemID
        return HStack(alignment: .top, spacing: PluginPaletteMetrics.rowContentSpacing) {
            Image(systemName: itemSystemImage(item))
                .font(.body)
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: PluginPaletteMetrics.rowIconWidth, height: 20)
                .help(detailKindTitle(item))
                .accessibilityLabel(detailKindTitle(item))
            VStack(
                alignment: .leading,
                spacing: PluginPaletteMetrics.rowTitleDescriptionSpacing
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTitle(item).replacingOccurrences(of: "\n", with: " "))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let quickPasteNumber {
                        Text("⌘\(quickPasteNumber)")
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                            .fixedSize()
                    }
                }
                HStack(spacing: 5) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                    }
                    Text(item.sourceApplication?.name ?? localization.string("common.unknownSource", defaultValue: "未知来源"))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ClipboardRelativeTimestamp(date: item.capturedAt)
                        .fixedSize()
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginPaletteSelectableRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .help(ClipboardHistoryTimestampFormatting.exactString(for: item.capturedAt, locale: locale))
        .onTapGesture { model.selectedItemID = item.id }
        .onTapGesture(count: 2) { onPasteAndClose(item.id, false) }
        .contextMenu {
            Button(localization.string("panel.footer.paste", defaultValue: "粘贴")) {
                onPasteAndClose(item.id, false)
            }
            Button(plainTextPasteTitle(for: item)) {
                onPasteAndClose(item.id, true)
            }
            .disabled(!ClipboardPlainTextConversion.isAvailable(for: item))
            Button(localization.string("common.copy", defaultValue: "复制")) { onCopyAndClose(item.id) }
            Button(
                item.isPinned
                    ? localization.string("common.unpin", defaultValue: "取消固定")
                    : localization.string("common.pin", defaultValue: "固定")
            ) {
                controller.togglePin(id: item.id)
            }
            Divider()
            Button(localization.string("common.delete", defaultValue: "删除"), role: .destructive) {
                Task { await onDelete(item.id) }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.sourceApplication?.name ?? localization.string("common.unknownSource", defaultValue: "未知来源"))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        HStack(spacing: 5) {
                            Text(ClipboardHistoryTimestampFormatting.exactString(
                                for: item.capturedAt,
                                locale: locale
                            ))
                            Text("·")
                            ClipboardRelativeTimestamp(date: item.capturedAt)
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        detailMetadataLine(item)
                        if item.kind == .image {
                            imageTextStatus(item)
                        }
                    }
                    Spacer()
                    Button {
                        controller.togglePin(id: item.id)
                    } label: {
                        Image(systemName: item.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.plain)
                    .help(
                        item.isPinned
                            ? localization.string("common.unpin", defaultValue: "取消固定")
                            : localization.string("common.pin", defaultValue: "固定")
                    )
                    Button(localization.string("panel.footer.paste", defaultValue: "粘贴")) {
                        onPasteAndClose(item.id, false)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("mactools.clipboard-history.paste")
                    Menu {
                        Button(plainTextPasteTitle(for: item)) {
                            onPasteAndClose(item.id, true)
                        }
                        .disabled(!ClipboardPlainTextConversion.isAvailable(for: item))
                        Button(localization.string("common.copy", defaultValue: "复制")) {
                            onCopyAndClose(item.id)
                        }
                        Divider()
                        Button(localization.string("common.delete", defaultValue: "删除"), role: .destructive) {
                            Task { await onDelete(item.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(
                        localization.string("common.moreActions", defaultValue: "更多操作")
                    )
                }
                detailPreviewSurface(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                localization.string("panel.detail.selectItem", defaultValue: "选择一条记录"),
                systemImage: "cursorarrow.click"
            )
        }
    }

    private var footer: some View {
        PluginPaletteFooter {
            EmptyView()
        } trailing: {
            ViewThatFits(in: .horizontal) {
                shortcutHints(includeSecondaryActions: true)
                shortcutHints(includeSecondaryActions: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localization.string(
            "panel.detail.keyboardHint",
            defaultValue: "↑↓ 浏览 · Return 粘贴 · ⇧Return 粘贴为纯文本 · ⌘1–9 粘贴 · ⌃1–8 筛选 · ⌘P 固定 · ⌘⌫ 删除 · Esc 关闭"
        ))
    }

    private func shortcutHints(includeSecondaryActions: Bool) -> some View {
        HStack(spacing: 12) {
            PluginPaletteKeyboardHint(
                key: "↑↓",
                action: localization.string("panel.footer.navigate", defaultValue: "浏览")
            )
            PluginPaletteKeyboardHint(
                key: "Return",
                action: localization.string("panel.footer.paste", defaultValue: "粘贴")
            )
            if includeSecondaryActions {
                PluginPaletteKeyboardHint(
                    key: "⇧Return",
                    action: localization.string("panel.pastePlain", defaultValue: "粘贴为纯文本")
                )
            }
            PluginPaletteKeyboardHint(
                key: "⌘1–9",
                action: localization.string("panel.footer.paste", defaultValue: "粘贴")
            )
            PluginPaletteKeyboardHint(
                key: "⌃1–8",
                action: localization.string("panel.footer.filter", defaultValue: "筛选")
            )
            if includeSecondaryActions {
                PluginPaletteKeyboardHint(
                    key: "⌘P",
                    action: localization.string("common.pin", defaultValue: "固定")
                )
                PluginPaletteKeyboardHint(
                    key: "⌘⌫",
                    action: localization.string("common.delete", defaultValue: "删除")
                )
            }
            PluginPaletteKeyboardHint(
                key: "Esc",
                action: localization.string("common.close", defaultValue: "关闭")
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func handleSearchFieldCommand(_ command: PluginPaletteSearchCommand) {
        switch command {
        case let .moveSelection(offset):
            model.moveSelection(by: offset)
        case .submit:
            guard let selectedItemID = model.selectedItemID else { return }
            onPasteAndClose(selectedItemID, false)
        case .alternateSubmit:
            guard let selectedItemID = model.selectedItemID else { return }
            onPasteAndClose(selectedItemID, true)
        case .cancel:
            onClose()
        }
    }

    private func repairSelection() {
        let visibleIDs = visibleItems.map(\.id)
        if let selectedItemID = model.selectedItemID, visibleIDs.contains(selectedItemID) {
            return
        }
        model.selectedItemID = visibleIDs.first
    }

    @ViewBuilder
    private func imageTextStatus(_ item: ClipboardHistoryItem) -> some View {
        switch ClipboardImageTextAvailability(item: item) {
        case .pending:
            Label(
                localization.string("panel.imageText.pending", defaultValue: "正在识别文字…"),
                systemImage: "text.viewfinder"
            )
            .foregroundStyle(.secondary)
        case .available:
            Label(
                localization.string("panel.imageText.available", defaultValue: "可粘贴识别文字"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .unavailable:
            Label(
                localization.string("panel.imageText.unavailable", defaultValue: "未识别到文字"),
                systemImage: "xmark.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func plainTextPasteTitle(for item: ClipboardHistoryItem) -> String {
        if item.kind == .image {
            return localization.string(
                "panel.imageText.paste",
                defaultValue: "粘贴识别文字"
            )
        }
        return localization.string("panel.pastePlain", defaultValue: "粘贴为纯文本")
    }

    @ViewBuilder
    private func detailPreviewSurface(_ item: ClipboardHistoryItem) -> some View {
        switch item.kind {
        case .image, .pdf:
            if embeddedPreviewItemID == item.id, let image = embeddedPreviewImage {
                imagePreviewCanvas(image, showsTransparencyGrid: item.kind == .image)
            } else if embeddedPreviewItemID == item.id, isEmbeddedPreviewLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                unavailablePreview(item)
            }
        case .files:
            if let previewFile = previewableFile(item) {
                ClipboardFilePreviewView(
                    url: previewFile.url,
                    kind: previewFile.kind,
                    unavailableTitle: localization.string(
                        "content.file.unavailable",
                        defaultValue: "文件不可用"
                    )
                )
            } else {
                ScrollView {
                    detailPreview(item)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
        default:
            ScrollView {
                detailPreview(item)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }

    private func imagePreviewCanvas(_ image: NSImage, showsTransparencyGrid: Bool) -> some View {
        GeometryReader { geometry in
            let previewSize = ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: image.size,
                containerSize: geometry.size,
                padding: 18
            )
            ZStack {
                if showsTransparencyGrid {
                    ClipboardTransparencyGrid()
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func detailPreview(_ item: ClipboardHistoryItem) -> some View {
        switch item.kind {
        case .image, .pdf:
            if embeddedPreviewItemID == item.id, let image = embeddedPreviewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailablePreview(item)
            }
        case .files:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(
                    Array(ClipboardFileReferencePresentation.visibleURLs(from: item.fileURLs).enumerated()),
                    id: \.offset
                ) { _, url in
                    ClipboardFileReferenceRow(
                        url: url,
                        unavailableTitle: localization.string(
                            "content.file.unavailable",
                            defaultValue: "文件不可用"
                        )
                    )
                }
                let remainingCount = ClipboardFileReferencePresentation.remainingCount(
                    totalCount: item.fileReferenceCount,
                    visibleCount: item.fileURLs.count
                )
                if remainingCount > 0 {
                    Label("+\(remainingCount)", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .richText:
            ClipboardRichTextPreviewView(item: item, localization: localization)
        case .plainText, .link:
            Text(item.text.isEmpty ? kindTitle(item.kind) : item.text)
                .font(item.kind == .plainText ? .body.monospaced() : .body)
                .textSelection(.enabled)
        case .color, .media:
            unavailablePreview(item)
        }
    }

    private func unavailablePreview(_ item: ClipboardHistoryItem) -> some View {
        Label(kindTitle(item.kind), systemImage: kindSystemImage(item.kind))
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func loadEmbeddedPreview() async {
        embeddedPreviewImage = nil
        guard let item = selectedItem, item.kind == .image || item.kind == .pdf else {
            embeddedPreviewItemID = nil
            isEmbeddedPreviewLoading = false
            return
        }
        embeddedPreviewItemID = item.id
        isEmbeddedPreviewLoading = true
        let image = await ClipboardEmbeddedPreviewLoader.load(for: item)
        guard !Task.isCancelled, model.selectedItemID == item.id else { return }
        embeddedPreviewImage = image
        isEmbeddedPreviewLoading = false
    }

    private func displayTitle(_ item: ClipboardHistoryItem) -> String {
        item.text.isEmpty ? kindTitle(item.kind) : item.text
    }

    private func previewableFile(
        _ item: ClipboardHistoryItem
    ) -> (url: URL, kind: ClipboardFileContentKind)? {
        guard item.kind == .files,
              item.fileReferenceCount == 1,
              let url = item.fileURLs.first,
              let kind = ClipboardFileContentKind(url: url) else {
            return nil
        }
        return (url, kind)
    }

    private func fileSubtypeTitles(_ item: ClipboardHistoryItem) -> [String] {
        guard item.kind == .files else { return [] }
        return ClipboardFileContentKind.allCases.compactMap { kind in
            item.fileContentKinds.contains(kind) ? fileKindTitle(kind) : nil
        }
    }

    private func detailKindTitle(_ item: ClipboardHistoryItem) -> String {
        let subtypes = fileSubtypeTitles(item)
        guard !subtypes.isEmpty else {
            return kindTitle(item.kind)
        }
        return ([kindTitle(.files)] + subtypes).joined(separator: " · ")
    }

    private func detailMetadataLine(_ item: ClipboardHistoryItem) -> some View {
        let title = detailMetadataTitle(
            item,
            metadata: detailMetadataByItemID[item.id]
        )
        return Text(title)
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(title)
            .task(id: item.id) {
                guard detailMetadataByItemID[item.id] == nil else { return }
                let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item)
                guard !Task.isCancelled, model.selectedItemID == item.id else { return }
                detailMetadataByItemID[item.id] = metadata
            }
    }

    private func detailMetadataTitle(
        _ item: ClipboardHistoryItem,
        metadata: ClipboardHistoryDetailMetadata?
    ) -> String {
        let values = metadata?.values.map(metadataValueTitle) ?? []
        return ([detailMetadataBaseTitle(item)] + values).joined(separator: " · ")
    }

    private func detailMetadataBaseTitle(_ item: ClipboardHistoryItem) -> String {
        let subtypes = fileSubtypeTitles(item)
        if item.fileReferenceCount == 1, subtypes.count == 1, let subtype = subtypes.first {
            return subtype
        }
        return kindTitle(item.kind)
    }

    private func metadataValueTitle(_ value: ClipboardHistoryDetailMetadataValue) -> String {
        switch value {
        case let .format(format):
            format
        case let .characterCount(count):
            localization.format(
                "panel.metadata.characters.format",
                defaultValue: "%d 个字符",
                count
            )
        case let .lineCount(count):
            localization.format(
                "panel.metadata.lines.format",
                defaultValue: "%d 行",
                count
            )
        case let .dimensions(width, height):
            "\(width.formatted(.number.locale(locale))) × \(height.formatted(.number.locale(locale)))"
        case let .pageCount(count):
            localization.format(
                "panel.metadata.pages.format",
                defaultValue: "%d 页",
                count
            )
        case let .fileCount(count):
            localization.format(
                "panel.metadata.files.format",
                defaultValue: "%d 个文件",
                count
            )
        case let .byteCount(byteCount):
            byteCount.formatted(.byteCount(style: .file).locale(locale))
        case let .durationSeconds(seconds):
            Self.durationText(seconds)
        case let .host(host):
            host
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let roundedSeconds = max(0, Int(seconds.rounded()))
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds % 3_600) / 60
        let remainingSeconds = roundedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func itemSystemImage(_ item: ClipboardHistoryItem) -> String {
        guard item.kind == .files,
              item.fileContentKinds.count == 1,
              let fileKind = item.fileContentKinds.first else {
            return kindSystemImage(item.kind)
        }
        return switch fileKind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "play.rectangle"
        }
    }

    private func fileKindTitle(_ kind: ClipboardFileContentKind) -> String {
        switch kind {
        case .pdf:
            localization.string("content.kind.pdf", defaultValue: "PDF")
        case .image:
            localization.string("content.kind.image", defaultValue: "图片")
        case .audio:
            localization.string("content.kind.audio", defaultValue: "音频")
        case .video:
            localization.string("content.kind.video", defaultValue: "视频")
        }
    }

    private func kindTitle(_ kind: ClipboardHistoryContentKind) -> String {
        switch kind {
        case .plainText:
            localization.string("content.kind.text", defaultValue: "文本")
        case .richText:
            localization.string("content.kind.richText", defaultValue: "富文本")
        case .image:
            localization.string("content.kind.image", defaultValue: "图片")
        case .pdf:
            localization.string("content.kind.pdf", defaultValue: "PDF")
        case .files:
            localization.string("content.kind.files", defaultValue: "文件")
        case .link:
            localization.string("content.kind.link", defaultValue: "链接")
        case .color:
            localization.string("content.kind.color", defaultValue: "颜色")
        case .media:
            localization.string("content.kind.media", defaultValue: "音频与视频")
        }
    }

    private func filterTitle(_ filter: ClipboardHistoryContentFilter) -> String {
        switch filter {
        case .all:
            localization.string("panel.filter.all", defaultValue: "所有类型")
        case .text:
            localization.string("content.kind.text", defaultValue: "文本")
        case .image:
            localization.string("content.kind.image", defaultValue: "图片")
        case .pdf:
            localization.string("content.kind.pdf", defaultValue: "PDF")
        case .files:
            localization.string("content.kind.files", defaultValue: "文件")
        case .link:
            localization.string("content.kind.link", defaultValue: "链接")
        case .color:
            localization.string("content.kind.color", defaultValue: "颜色")
        case .media:
            localization.string("content.kind.media", defaultValue: "音频与视频")
        }
    }

    private func filterSystemImage(_ filter: ClipboardHistoryContentFilter) -> String {
        switch filter {
        case .all: "square.grid.2x2"
        case .text: "text.alignleft"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .files: "doc.on.doc"
        case .link: "link"
        case .color: "paintpalette"
        case .media: "play.rectangle"
        }
    }

    private func kindSystemImage(_ kind: ClipboardHistoryContentKind) -> String {
        switch kind {
        case .plainText: "text.alignleft"
        case .richText: "doc.richtext.fill"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .files: "doc.on.doc"
        case .link: "link"
        case .color: "paintpalette"
        case .media: "play.rectangle"
        }
    }

    private var panelSurface: some View {
        PluginPaletteSurface(reducesTransparency: accessibilityReduceTransparency)
    }
}

private struct ClipboardTransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let squareSize: CGFloat = 12
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .underPageBackgroundColor))
            )
            var alternateSquares = Path()
            let columnCount = Int(ceil(size.width / squareSize))
            let rowCount = Int(ceil(size.height / squareSize))
            for row in 0..<rowCount {
                for column in 0..<columnCount where (row + column).isMultiple(of: 2) {
                    alternateSquares.addRect(CGRect(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    ))
                }
            }
            context.fill(alternateSquares, with: .color(Color.primary.opacity(0.035)))
        }
        .allowsHitTesting(false)
    }
}
