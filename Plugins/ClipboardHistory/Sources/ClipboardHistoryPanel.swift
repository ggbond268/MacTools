import AppKit
import ImageIO
import MacToolsPluginKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
private var selectedRowTextColor: Color {
    // This is the list/table foreground paired with selectedContentBackgroundColor.
    Color(nsColor: .alternateSelectedControlTextColor)
}

enum ClipboardHistoryContentFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case pdf
    case files
    case color
    case media

    var id: String { rawValue }

    func matches(_ item: ClipboardHistoryItem) -> Bool {
        if self == .all {
            return true
        }
        if self == .color,
           item.kind == .plainText || item.kind == .richText,
           item.semanticTraits.contains(.color) {
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
        case .color:
            kinds.contains(.color)
        case .media:
            kinds.contains(.media)
        }
    }
}

enum ClipboardHistorySemanticFilter: String, CaseIterable, Identifiable, Sendable {
    case any
    case link
    case email
    case recognizedText

    var id: String { rawValue }

    func matches(_ item: ClipboardHistoryItem) -> Bool {
        switch self {
        case .any:
            true
        case .link:
            item.semanticTraits.contains(.link)
        case .email:
            item.semanticTraits.contains(.email)
        case .recognizedText:
            item.semanticTraits.contains(.recognizedText)
        }
    }
}

enum ClipboardPanelMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case history
    case saved
    case snippets

    var id: String { rawValue }
}

enum ClipboardHistoryFilterFamily: String, CaseIterable, Identifiable, Sendable {
    case scope
    case type
    case content

    var id: String { rawValue }

    static func available(
        totalItemCount: Int,
        scopeCounts: [Int],
        typeCounts: [Int],
        contentCounts: [Int]
    ) -> [Self] {
        guard totalItemCount > 1 else { return [] }
        func canNarrow(_ counts: [Int]) -> Bool {
            counts.contains { $0 > 0 && $0 < totalItemCount }
        }
        var result: [Self] = []
        if canNarrow(scopeCounts) { result.append(.scope) }
        if canNarrow(typeCounts) { result.append(.type) }
        if canNarrow(contentCounts) { result.append(.content) }
        return result
    }

    static func resolvedSelection(current: Self, available: [Self]) -> Self? {
        guard !available.isEmpty else { return nil }
        if available.contains(current) { return current }
        return available.first
    }
}

struct ClipboardPanelSearchCandidate: Sendable {
    let item: ClipboardHistoryItem
    let isSnippet: Bool
    let sortDate: Date
}

/// The action companion must never retarget an operation when live results change.
struct ClipboardHistoryPanelActionContext: Equatable {
    let itemIDs: [UUID]
    let snippetIDs: Set<UUID>
    let savedClipIDs: Set<UUID>
    let focusedItemID: UUID?
    let isMultiSelectionEnabled: Bool

    var canStartSequentialQueue: Bool {
        isMultiSelectionEnabled && !itemIDs.isEmpty
    }
}

enum ClipboardHistoryPanelClipboardWrite {
    static func targetsAreAvailable(_ ids: [UUID], availableIDs: Set<UUID>) -> Bool {
        !ids.isEmpty && ids.allSatisfy(availableIDs.contains)
    }

    /// Keep cancellation validation and the synchronous write in the same actor turn.
    static func perform(
        isCancelled: Bool,
        isCurrent: Bool,
        write: () -> Bool,
        didWrite: () -> Void
    ) -> Bool {
        guard !isCancelled, isCurrent, write() else { return false }
        didWrite()
        return true
    }
}

struct ClipboardPanelBoundedSearchResult: Sendable {
    let candidates: [ClipboardPanelSearchCandidate]
    let matchingCount: Int

    var hasMore: Bool { matchingCount > candidates.count }
}

enum ClipboardPanelBoundedSearch {
    static func collect(
        limit: Int,
        _ body: (inout Collector) -> Void
    ) -> ClipboardPanelBoundedSearchResult {
        var collector = Collector(limit: max(0, limit))
        body(&collector)
        return ClipboardPanelBoundedSearchResult(
            candidates: collector.candidates,
            matchingCount: collector.matchingCount
        )
    }

    struct Collector {
        fileprivate let limit: Int
        fileprivate(set) var candidates: [ClipboardPanelSearchCandidate] = []
        fileprivate(set) var matchingCount = 0

        mutating func consider(_ candidate: ClipboardPanelSearchCandidate) {
            matchingCount += 1
            guard limit > 0 else { return }

            let insertionIndex = candidates.partitioningIndex { existing in
                isOrderedBefore(candidate, existing)
            }
            if candidates.count == limit, insertionIndex == candidates.endIndex {
                return
            }
            candidates.insert(candidate, at: insertionIndex)
            if candidates.count > limit {
                candidates.removeLast()
            }
        }

        private func isOrderedBefore(
            _ lhs: ClipboardPanelSearchCandidate,
            _ rhs: ClipboardPanelSearchCandidate
        ) -> Bool {
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
            return lhs.item.id.uuidString < rhs.item.id.uuidString
        }
    }
}

private extension Array {
    func partitioningIndex(where belongsBefore: (Element) -> Bool) -> Int {
        var lowerBound = startIndex
        var upperBound = endIndex
        while lowerBound < upperBound {
            let distance = self.distance(from: lowerBound, to: upperBound)
            let middle = index(lowerBound, offsetBy: distance / 2)
            if belongsBefore(self[middle]) {
                upperBound = middle
            } else {
                lowerBound = index(after: middle)
            }
        }
        return lowerBound
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

enum ClipboardHistoryRowHitTesting {
    static let multiSelectionLeadingControlWidth = PluginPaletteMetrics.rowHorizontalPadding
        + 36
        + PluginPaletteMetrics.rowContentSpacing

    static func targetsFocus(atX x: CGFloat, isMultiSelectionEnabled: Bool) -> Bool {
        !isMultiSelectionEnabled || x >= multiSelectionLeadingControlWidth
    }
}

struct ClipboardEmbeddedPreviewResult: @unchecked Sendable {
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
        return previewImage(from: image)
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
        return previewImage(from: image)
    }

    private static func previewImage(from image: CGImage) -> NSImage {
        // Keep decoded pixels explicit. NSCGImageSnapshotRep can report a Retina-
        // scaled representation, overstating the thumbnail's cache cost fourfold.
        let preview = NSImage(size: NSSize(width: image.width, height: image.height))
        preview.addRepresentation(NSBitmapImageRep(cgImage: image))
        return preview
    }
}

private final class ClipboardBoundedImagePreviewOperation: Operation, @unchecked Sendable {
    private let dataProvider: @Sendable () -> Data?
    private let lock = NSLock()
    private var storedImage: NSImage?

    init(data: Data) {
        dataProvider = { data }
    }

    init(savedItem item: ClipboardSavedItem) {
        dataProvider = {
            defer { item.discardCachedPayloadIfReloadable() }
            guard let payload = try? item.loadPayload(),
                  let representation = payload.representations.first(where: {
                      ClipboardRepresentationType.isImage($0.typeIdentifier)
                  }) else { return nil }
            return representation.data
        }
    }

    override func main() {
        guard !isCancelled, let data = dataProvider(), !isCancelled else { return }
        let image = ClipboardEmbeddedPreviewPolicy.imageThumbnail(from: data)
        guard !isCancelled else { return }
        lock.withLock { storedImage = image }
    }

    func result() -> NSImage? {
        lock.withLock { storedImage }
    }
}

enum ClipboardBoundedImagePreviewWork {
    private struct SendableImage: @unchecked Sendable {
        let value: NSImage?
    }

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mactools.clipboard-history.image-preview"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    static func image(from data: Data) async -> NSImage? {
        let operation = ClipboardBoundedImagePreviewOperation(data: data)
        return await image(using: operation)
    }

    static func image(for savedItem: ClipboardSavedItem) async -> NSImage? {
        let operation = ClipboardBoundedImagePreviewOperation(savedItem: savedItem)
        return await image(using: operation)
    }

    private static func image(using operation: ClipboardBoundedImagePreviewOperation) async -> NSImage? {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.completionBlock = { [weak operation] in
                    continuation.resume(returning: SendableImage(value: operation?.result()))
                }
                queue.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        return result.value
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
    struct RuntimeStatus: Equatable {
        var historyErrorMessage: String?
        var isHistoryLoaded: Bool
        var isClearingHistory: Bool
        var savedErrorMessage: String?
        var savedFatalErrorMessage: String?
        var isSavedLibraryLoaded: Bool

        static let loading = RuntimeStatus(
            historyErrorMessage: nil,
            isHistoryLoaded: false,
            isClearingHistory: false,
            savedErrorMessage: nil,
            savedFatalErrorMessage: nil,
            isSavedLibraryLoaded: false
        )
    }

    nonisolated static let resultPageSize = 50
    nonisolated static let searchDebounceNanoseconds: UInt64 = 120_000_000
    nonisolated static let maximumMultiSelectionItemCount = ClipboardSequentialPasteSession.maximumItemCount

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            requestedScrollItemID = nil
            visibleResultLimit = Self.resultPageSize
            scheduleSearch(debounced: true)
        }
    }
    @Published var mode: ClipboardPanelMode = .all {
        didSet {
            guard mode != oldValue else { return }
            requestedScrollItemID = nil
            visibleResultLimit = Self.resultPageSize
            scheduleSearch(debounced: false)
        }
    }
    @Published var selectedSavedItemID: UUID?
    @Published var contentFilter: ClipboardHistoryContentFilter = .all {
        didSet {
            guard contentFilter != oldValue else { return }
            requestedScrollItemID = nil
            visibleResultLimit = Self.resultPageSize
            scheduleSearch(debounced: false)
        }
    }
    @Published var semanticFilter: ClipboardHistorySemanticFilter = .any {
        didSet {
            guard semanticFilter != oldValue else { return }
            requestedScrollItemID = nil
            visibleResultLimit = Self.resultPageSize
            scheduleSearch(debounced: false)
        }
    }
    @Published var selectedItemID: UUID?
    @Published var isMultiSelectionEnabled = false
    @Published private(set) var selectedItemIDs: [UUID] = []
    @Published private(set) var selectionLimitReachedRevision: UInt = 0
    @Published var isActionPalettePresented = false
    @Published private(set) var visibleItems: [ClipboardHistoryItem] = []
    @Published private(set) var visibleSavedPresentationItemIDs: Set<UUID> = []
    @Published private(set) var visibleSavedItemIDs: [UUID] = []
    @Published private(set) var hasMoreResults = false
    @Published private(set) var isSearching = false
    @Published private(set) var showsSearchProgress = false
    @Published private(set) var isPreparingPresentation = false
    @Published private(set) var focusRequestID: UInt = 0
    @Published private(set) var exportMenuRequestID: UInt = 0
    @Published private(set) var actionMenuRequestID: UInt = 0
    @Published private(set) var deleteConfirmationRequestID: UInt = 0
    @Published private(set) var requestedScrollItemID: UUID?
    @Published private(set) var savedEditRequestID: UInt = 0
    @Published private(set) var availableScopeModes: [ClipboardPanelMode] = [.history]
    @Published private(set) var availableContentFilters: [ClipboardHistoryContentFilter] = []
    @Published private(set) var availableSemanticFilters: [ClipboardHistorySemanticFilter] = []
    @Published private(set) var availableFilterFamilies: [ClipboardHistoryFilterFamily] = []
    @Published private(set) var selectedFilterFamily: ClipboardHistoryFilterFamily = .scope
    @Published private(set) var pendingSavedItemIDs: Set<UUID> = []
    @Published private(set) var previewResetRevision: UInt = 0
    @Published private(set) var isPreviewPresentationActive = false
    @Published private(set) var runtimeStatus = RuntimeStatus.loading

    var filterOptionCount: Int {
        guard availableFilterFamilies.contains(selectedFilterFamily) else { return 0 }
        switch selectedFilterFamily {
        case .scope: return availableScopeModes.count
        case .type: return availableContentFilters.count + 1
        case .content: return availableSemanticFilters.count + 1
        }
    }

    private var allItems: [ClipboardHistoryItem] = []
    private var allSavedItems: [ClipboardSavedItem] = []
    private var itemIndexByID: [UUID: Int] = [:]
    private var savedItemByID: [UUID: ClipboardSavedItem] = [:]
    private var optimisticSavedStateByID: [UUID: Bool] = [:]
    private var historyItemCount = 0
    private var availableClipItemIDs: Set<UUID> = []
    private var availableSnippetIDs: Set<UUID> = []
    private var savedClipIDs: Set<UUID> = []
    private var selectedItemIDSet: Set<UUID> = []
    private var selectionNumberByItemID: [UUID: Int] = [:]
    private var visibleResultLimit = ClipboardHistoryPanelModel.resultPageSize
    private var deleteConfirmationContext: ClipboardHistoryPanelActionContext?
    private var searchGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var searchProgressTask: Task<Void, Never>?
    private var presentationPreparationTask: Task<Void, Never>?
    private var presentationPreparationGeneration: UInt64 = 0
    private var filterRefreshTask: Task<Void, Never>?
    private var filterRefreshGeneration: UInt64 = 0
    private let searchProgressDelayNanoseconds: UInt64
    private var initialPage: InitialPage?
    private var currentHistoryRevision: UInt64 = 0
    private var currentSavedRevision: UInt64 = 0
    private let presentationPreparationCheckpointForTesting: (@Sendable () -> Void)?

    private struct InitialPage {
        let historyRevision: UInt64
        let savedRevision: UInt64
        let mode: ClipboardPanelMode
        let items: [ClipboardHistoryItem]
        let snippetIDs: Set<UUID>
        let hasMore: Bool
        let selectedItemID: UUID?
        let scopeModes: [ClipboardPanelMode]
        let contentFilters: [ClipboardHistoryContentFilter]
        let semanticFilters: [ClipboardHistorySemanticFilter]
        let filterFamilies: [ClipboardHistoryFilterFamily]
    }

    private struct PresentationPreparationSnapshot: Sendable {
        let itemIndexByID: [UUID: Int]
        let historyItemCount: Int
        let availableClipItemIDs: Set<UUID>
        let availableSnippetIDs: Set<UUID>
        let savedClipIDs: Set<UUID>
        let newestHistoryItemID: UUID?
        let scopeModes: [ClipboardPanelMode]
        let contentFilters: [ClipboardHistoryContentFilter]
        let semanticFilters: [ClipboardHistorySemanticFilter]
        let filterFamilies: [ClipboardHistoryFilterFamily]
    }

    init(
        searchProgressDelayNanoseconds: UInt64 = 180_000_000,
        presentationPreparationCheckpointForTesting: (@Sendable () -> Void)? = nil
    ) {
        self.searchProgressDelayNanoseconds = searchProgressDelayNanoseconds
        self.presentationPreparationCheckpointForTesting = presentationPreparationCheckpointForTesting
    }

    // Count the collection, not the current query results: users can select
    // across searches. Always retain a way out of an existing selection.
    var canEnterMultiSelection: Bool {
        Self.logicalItemCount(historyItems: allItems, savedItems: allSavedItems) > 1
    }

    var showsMultiSelectionControl: Bool { isMultiSelectionEnabled || canEnterMultiSelection }

    /// Known IDs avoid rescanning the collection for ordinary metadata acknowledgements.
    /// Snapshot reconciliation remains available for loading, retention and error recovery.
    func updateItems(
        _ items: [ClipboardHistoryItem],
        revision: UInt64? = nil,
        changedIDs: Set<UUID>? = nil
    ) {
        if let revision {
            guard revision != currentHistoryRevision else { return }
            invalidatePresentationPreparationForSourceMutation()
        } else {
            guard items != allItems else { return }
            invalidatePresentationPreparationForSourceMutation()
        }
        let changes: [ClipboardHistoryMutation.Change]
        let hasKnownPositions = items.count == allItems.count && changedIDs?.allSatisfy({ id in
               itemIndexByID[id].map { items.indices.contains($0) && items[$0].id == id } == true
           }) == true
        if let changedIDs, hasKnownPositions {
            changes = changedIDs.compactMap { id in
                guard let index = itemIndexByID[id], allItems[index] != items[index] else { return nil }
                return .init(id: id, before: allItems[index], after: items[index])
            }
        } else {
            changes = ClipboardHistoryMutation.between(allItems, items).changes
        }
        // Keep the canonical source order. Search owns presentation ordering; retaining a
        // separately sorted source made identical snapshots look different on every reopen.
        guard !changes.isEmpty else {
            allItems = items
            if let revision { currentHistoryRevision = revision }
            if !hasKnownPositions {
                itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            }
            return
        }
        initialPage = nil
        currentHistoryRevision = revision ?? (currentHistoryRevision &+ 1)
        let structural = changes.contains { $0.before == nil || $0.after == nil || $0.before?.capturedAt != $0.after?.capturedAt }
            || (!hasKnownPositions && !zip(allItems, items).allSatisfy { $0.0.id == $0.1.id })
        for change in changes {
            historyItemCount += (change.after?.isInHistory == true ? 1 : 0) - (change.before?.isInHistory == true ? 1 : 0)
            if let after = change.after {
                availableClipItemIDs.insert(change.id)
                if after.isSaved { savedClipIDs.insert(change.id) } else { savedClipIDs.remove(change.id) }
            } else {
                availableClipItemIDs.remove(change.id)
                savedClipIDs.remove(change.id)
            }
        }
        allItems = items
        appendAvailableFilterOptions(for: changes.compactMap(\.after))
        if structural {
            itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            let retainedSelection = selectedItemIDs.filter {
                availableClipItemIDs.contains($0) || availableSnippetIDs.contains($0)
            }
            if retainedSelection != selectedItemIDs {
                selectedItemIDs = retainedSelection
                rebuildSelectionIndex()
            }
        }
        let removedIDs = Set(changes.lazy.filter { $0.after == nil }.map(\.id))
        let changedByID = Dictionary(uniqueKeysWithValues: changes.compactMap { change in
            change.after.map { (change.id, $0) }
        })
        let immediatelyReconciled = visibleItems.compactMap { item in
            removedIDs.contains(item.id) ? nil : (changedByID[item.id] ?? item)
        }
        if immediatelyReconciled != visibleItems { visibleItems = immediatelyReconciled }
        guard mode != .snippets else { return }
        let preparedQuery = ClipboardHistorySearch.PreparedQuery(query)
        let changesResults = structural || changes.contains {
            matchesCurrentSearch($0.before, query: preparedQuery) != matchesCurrentSearch($0.after, query: preparedQuery)
        }
        if isSearching || changesResults {
            scheduleSearch(debounced: false)
        } else {
            let updated = visibleItems.map { changedByID[$0.id] ?? $0 }
            if updated != visibleItems { visibleItems = updated }
        }
    }

    private func matchesCurrentSearch(_ item: ClipboardHistoryItem?, query: ClipboardHistorySearch.PreparedQuery) -> Bool {
        guard let item else { return false }
        let included = switch mode {
        case .all: item.isInHistory || item.isSaved
        case .history: item.isInHistory
        case .saved: item.isSaved
        case .snippets: false
        }
        return included && contentFilter.matches(item) && semanticFilter.matches(item)
            && ClipboardHistorySearch.matches(index: item.searchIndex, query: query)
    }

    var scopedItemCount: Int {
        switch mode {
        case .all: allItems.count + availableSnippetIDs.count
        case .history: historyItemCount
        case .saved: savedClipIDs.count
        case .snippets: availableSnippetIDs.count
        }
    }

    func containsPreview(_ key: ClipboardEmbeddedPreviewKey) -> Bool {
        guard let index = itemIndexByID[key.itemID], allItems.indices.contains(index) else { return false }
        return allItems[index].id == key.itemID && allItems[index].payloadDigest == key.payloadDigest
    }

    func updateSavedItems(_ items: [ClipboardSavedItem], revision: UInt64? = nil) {
        if let revision {
            guard revision != currentSavedRevision else { return }
            invalidatePresentationPreparationForSourceMutation()
        } else {
            guard items != allSavedItems else { return }
            invalidatePresentationPreparationForSourceMutation()
        }
        guard items != allSavedItems else {
            currentSavedRevision = revision ?? currentSavedRevision
            return
        }
        initialPage = nil
        currentSavedRevision = revision ?? (currentSavedRevision &+ 1)
        let previousByID = Dictionary(uniqueKeysWithValues: allSavedItems.map { ($0.id, $0) })
        let changedItems = items.filter { previousByID[$0.id] != $0 }
        allSavedItems = items
        savedItemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        availableSnippetIDs = Set(items.lazy.filter(\.isSnippet).map(\.id))
        appendAvailableFilterOptions(for: changedItems.lazy.filter(\.isSnippet).map {
            $0.historyPresentationItem()
        })
        let availableIDs = Set(allItems.map(\.id)).union(items.map(\.id))
        selectedItemIDs = selectedItemIDs.filter { availableIDs.contains($0) }
        rebuildSelectionIndex()
        if !visibleSavedPresentationItemIDs.isSubset(of: availableSnippetIDs) {
            visibleSavedPresentationItemIDs.formIntersection(availableSnippetIDs)
            visibleItems.removeAll { !availableIDs.contains($0.id) }
        }
        if mode == .all || mode == .snippets {
            scheduleSearch(debounced: false)
        }
    }

    func prepareForPresentation(
        items: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem] = [],
        historyRevision: UInt64? = nil,
        savedRevision: UInt64? = nil
    ) {
        presentationPreparationTask?.cancel()
        presentationPreparationTask = nil
        filterRefreshGeneration &+= 1
        filterRefreshTask?.cancel()
        filterRefreshTask = nil
        presentationPreparationGeneration &+= 1
        searchTask?.cancel()
        searchProgressTask?.cancel()
        searchGeneration &+= 1
        isPreparingPresentation = true
        if let historyRevision, let savedRevision, let page = initialPage,
           page.historyRevision == historyRevision,
           page.savedRevision == savedRevision {
            query = ""
            mode = page.mode
            contentFilter = .all
            semanticFilter = .any
            availableScopeModes = page.scopeModes
            availableContentFilters = page.contentFilters
            availableSemanticFilters = page.semanticFilters
            availableFilterFamilies = page.filterFamilies
            selectedFilterFamily = ClipboardHistoryFilterFamily.resolvedSelection(current: .scope, available: page.filterFamilies) ?? .scope
            visibleResultLimit = Self.resultPageSize
            visibleItems = page.items
            visibleSavedPresentationItemIDs = page.snippetIDs
            hasMoreResults = page.hasMore
            selectedItemID = page.selectedItemID
            requestedScrollItemID = selectedItemID
            isMultiSelectionEnabled = false
            selectedItemIDs = []
            rebuildSelectionIndex()
            isActionPalettePresented = false
            focusRequestID &+= 1
            isSearching = false
            showsSearchProgress = false
            isPreparingPresentation = false
            return
        }
        query = ""
        guard let preparation = Self.preparePresentationSnapshot(
            items: items,
            savedItems: savedItems
        ) else { return }
        applyFilterAvailability(preparation)
        mode = availableScopeModes.first ?? .history
        contentFilter = .all
        semanticFilter = .any
        allItems = items
        allSavedItems = savedItems
        savedItemByID = Dictionary(uniqueKeysWithValues: savedItems.map { ($0.id, $0) })
        currentHistoryRevision = historyRevision ?? (currentHistoryRevision &+ 1)
        currentSavedRevision = savedRevision ?? (currentSavedRevision &+ 1)
        itemIndexByID = preparation.itemIndexByID
        historyItemCount = preparation.historyItemCount
        availableClipItemIDs = preparation.availableClipItemIDs
        availableSnippetIDs = preparation.availableSnippetIDs
        savedClipIDs = preparation.savedClipIDs
        visibleResultLimit = Self.resultPageSize
        visibleItems = []
        visibleSavedPresentationItemIDs = []
        hasMoreResults = false
        selectedItemID = preparation.newestHistoryItemID
        requestedScrollItemID = selectedItemID
        isMultiSelectionEnabled = false
        selectedItemIDs = []
        rebuildSelectionIndex()
        isActionPalettePresented = false
        focusRequestID &+= 1
        isPreparingPresentation = false
        scheduleSearch(debounced: false, cachesInitialPage: true)
    }

    func cancelPresentationPreparation() {
        presentationPreparationGeneration &+= 1
        presentationPreparationTask?.cancel()
        presentationPreparationTask = nil
        filterRefreshGeneration &+= 1
        filterRefreshTask?.cancel()
        filterRefreshTask = nil
        searchProgressTask?.cancel()
        showsSearchProgress = false
        isPreparingPresentation = false
    }

    private func invalidatePresentationPreparationForSourceMutation() {
        if presentationPreparationTask != nil || isPreparingPresentation {
            presentationPreparationGeneration &+= 1
            presentationPreparationTask?.cancel()
            presentationPreparationTask = nil
            searchProgressTask?.cancel()
            searchProgressTask = nil
            showsSearchProgress = false
            isPreparingPresentation = false
        }
        if filterRefreshTask != nil {
            filterRefreshGeneration &+= 1
            filterRefreshTask?.cancel()
            filterRefreshTask = nil
        }
    }

    func prepareForPresentationAsynchronously(
        items: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem] = [],
        historyRevision: UInt64? = nil,
        savedRevision: UInt64? = nil
    ) {
        presentationPreparationTask?.cancel()
        filterRefreshGeneration &+= 1
        filterRefreshTask?.cancel()
        filterRefreshTask = nil
        presentationPreparationGeneration &+= 1
        let generation = presentationPreparationGeneration

        if let historyRevision, let savedRevision, let page = initialPage,
           page.historyRevision == historyRevision,
           page.savedRevision == savedRevision {
            prepareForPresentation(
                items: items,
                savedItems: savedItems,
                historyRevision: historyRevision,
                savedRevision: savedRevision
            )
            return
        }

        searchTask?.cancel()
        searchProgressTask?.cancel()
        searchGeneration &+= 1
        isPreparingPresentation = true
        isSearching = true
        showsSearchProgress = false
        query = ""
        visibleResultLimit = Self.resultPageSize
        isMultiSelectionEnabled = false
        selectedItemIDs = []
        rebuildSelectionIndex()
        isActionPalettePresented = false
        focusRequestID &+= 1
        currentHistoryRevision = historyRevision ?? (currentHistoryRevision &+ 1)
        currentSavedRevision = savedRevision ?? (currentSavedRevision &+ 1)
        let preparedHistoryRevision = currentHistoryRevision
        let preparedSavedRevision = currentSavedRevision

        let progressDelay = searchProgressDelayNanoseconds
        searchProgressTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: progressDelay) } catch { return }
            guard let self, !Task.isCancelled,
                  generation == self.presentationPreparationGeneration,
                  self.isPreparingPresentation else { return }
            self.showsSearchProgress = true
        }

        let preparationCheckpoint = presentationPreparationCheckpointForTesting
        presentationPreparationTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.preparePresentationSnapshot(
                    items: items,
                    savedItems: savedItems,
                    cancelsWhenTaskIsCancelled: true,
                    checkpoint: preparationCheckpoint
                )
            }
            let preparation = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, let preparation, !Task.isCancelled,
                  generation == self.presentationPreparationGeneration,
                  preparedHistoryRevision == self.currentHistoryRevision,
                  preparedSavedRevision == self.currentSavedRevision else { return }
            self.searchProgressTask?.cancel()
            self.showsSearchProgress = false
            self.applyPreparedPresentation(
                preparation,
                items: items,
                savedItems: savedItems
            )
            self.isPreparingPresentation = false
            self.scheduleSearch(debounced: false, cachesInitialPage: true)
        }
    }

    func refreshFiltersForReactivation(
        items: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem] = [],
        historyRevision: UInt64? = nil,
        savedRevision: UInt64? = nil
    ) {
        if let historyRevision, let savedRevision,
           historyRevision == currentHistoryRevision,
           savedRevision == currentSavedRevision {
            return
        }
        let previousFamily = selectedFilterFamily
        updateItems(items, revision: historyRevision)
        updateSavedItems(savedItems, revision: savedRevision)
        filterRefreshTask?.cancel()
        filterRefreshGeneration &+= 1
        let generation = filterRefreshGeneration
        let preparedHistoryRevision = currentHistoryRevision
        let preparedSavedRevision = currentSavedRevision
        let preparationCheckpoint = presentationPreparationCheckpointForTesting
        filterRefreshTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.preparePresentationSnapshot(
                    items: items,
                    savedItems: savedItems,
                    cancelsWhenTaskIsCancelled: true,
                    checkpoint: preparationCheckpoint
                )
            }
            let preparation = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, let preparation, !Task.isCancelled,
                  generation == self.filterRefreshGeneration,
                  preparedHistoryRevision == self.currentHistoryRevision,
                  preparedSavedRevision == self.currentSavedRevision else { return }
            self.applyReactivatedFilterAvailability(
                preparation,
                previousFamily: previousFamily
            )
            self.filterRefreshTask = nil
            self.scheduleSearch(debounced: false)
        }
    }

    private func applyReactivatedFilterAvailability(
        _ preparation: PresentationPreparationSnapshot,
        previousFamily: ClipboardHistoryFilterFamily
    ) {
        applyFilterAvailability(preparation)
        // Keep active filters available even if their last matching item disappeared,
        // so the user can see and clear them instead of silently broadening the query.
        if mode != .all, !availableScopeModes.contains(mode) {
            availableScopeModes = ClipboardPanelMode.allCases.filter {
                $0 == .all || $0 == mode || availableScopeModes.contains($0)
            }
            if !availableFilterFamilies.contains(.scope) { availableFilterFamilies.append(.scope) }
        }
        if contentFilter != .all {
            availableContentFilters = ClipboardHistoryContentFilter.allCases.filter {
                $0 != .all && ($0 == contentFilter || availableContentFilters.contains($0))
            }
            if !availableFilterFamilies.contains(.type) { availableFilterFamilies.append(.type) }
        }
        if semanticFilter != .any {
            availableSemanticFilters = ClipboardHistorySemanticFilter.allCases.filter {
                $0 != .any && ($0 == semanticFilter || availableSemanticFilters.contains($0))
            }
            if !availableFilterFamilies.contains(.content) { availableFilterFamilies.append(.content) }
        }
        availableFilterFamilies = ClipboardHistoryFilterFamily.allCases.filter(availableFilterFamilies.contains)
        selectedFilterFamily = ClipboardHistoryFilterFamily.resolvedSelection(
            current: previousFamily, available: availableFilterFamilies
        ) ?? .scope
    }

    func savedItem(forPresentationID itemID: UUID) -> ClipboardSavedItem? {
        guard visibleSavedPresentationItemIDs.contains(itemID) else { return nil }
        return savedItemByID[itemID]
    }

    func item(forPresentationID itemID: UUID) -> ClipboardHistoryItem? {
        if let index = itemIndexByID[itemID], allItems.indices.contains(index) {
            return allItems[index]
        }
        return savedItemByID[itemID]?.historyPresentationItem()
    }

    func effectiveSavedState(for item: ClipboardHistoryItem) -> Bool {
        optimisticSavedStateByID[item.id] ?? item.isSaved
    }

    func beginSavedMutation(for itemID: UUID) -> Bool {
        guard !pendingSavedItemIDs.contains(itemID),
              let item = item(forPresentationID: itemID),
              !isSavedPresentation(itemID) else { return false }
        pendingSavedItemIDs.insert(itemID)
        optimisticSavedStateByID[itemID] = !item.isSaved
        return true
    }

    func finishSavedMutation(for itemID: UUID) {
        pendingSavedItemIDs.remove(itemID)
        optimisticSavedStateByID.removeValue(forKey: itemID)
    }

    func activatePreviewPresentation() {
        isPreviewPresentationActive = true
        previewResetRevision &+= 1
    }

    func resetPreviewPresentation() {
        isPreviewPresentationActive = false
        previewResetRevision &+= 1
    }

    func updateRuntimeStatus(
        historyController: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController
    ) {
        let status = RuntimeStatus(
            historyErrorMessage: historyController.errorMessage,
            isHistoryLoaded: historyController.isLoaded,
            isClearingHistory: historyController.isClearingHistory,
            savedErrorMessage: savedLibraryController.errorMessage,
            savedFatalErrorMessage: savedLibraryController.fatalErrorMessage,
            isSavedLibraryLoaded: savedLibraryController.isLoaded
        )
        if runtimeStatus != status { runtimeStatus = status }
    }

    func isSavedPresentation(_ itemID: UUID) -> Bool {
        visibleSavedPresentationItemIDs.contains(itemID)
    }

    func updateVisibleSavedItemIDs(_ itemIDs: [UUID]) {
        visibleSavedItemIDs = itemIDs
        guard let selectedSavedItemID,
              itemIDs.contains(selectedSavedItemID) else {
            selectedSavedItemID = itemIDs.first
            return
        }
    }

    func moveSavedSelection(by offset: Int) {
        guard !visibleSavedItemIDs.isEmpty else { return }
        let currentIndex = selectedSavedItemID.flatMap { selectedID in
            visibleSavedItemIDs.firstIndex(of: selectedID)
        } ?? 0
        let nextIndex = Self.wrappedIndex(
            currentIndex + offset,
            count: visibleSavedItemIDs.count
        )
        selectedSavedItemID = visibleSavedItemIDs[nextIndex]
    }

    func loadMoreResults() {
        guard hasMoreResults, !isSearching else { return }
        visibleResultLimit += Self.resultPageSize
        scheduleSearch(debounced: false)
    }

    func requestExportMenu() {
        exportMenuRequestID &+= 1
    }

    func requestSearchFocus() {
        focusRequestID &+= 1
    }

    func showSnippetScope() {
        mode = .snippets
        if !availableScopeModes.contains(.snippets) {
            availableScopeModes.append(.snippets)
        }
        if !availableFilterFamilies.contains(.scope) {
            availableFilterFamilies.insert(.scope, at: 0)
        }
        selectedFilterFamily = .scope
    }

    /// Reveal a committed creation even when the editor was opened from a filtered clip.
    /// Batch these changes so no intermediate search can replace the new selection.
    func revealCreatedSnippet(id: UUID, savedItems: [ClipboardSavedItem]) {
        guard savedItems.contains(where: { $0.id == id && $0.isSnippet }) else { return }
        isPreparingPresentation = true
        updateSavedItems(savedItems)
        query = ""
        contentFilter = .all
        semanticFilter = .any
        showSnippetScope()
        if availableScopeModes.count > 1, !availableScopeModes.contains(.all) {
            availableScopeModes.insert(.all, at: 0)
        }
        visibleResultLimit = Self.resultPageSize
        setMultiSelectionEnabled(false)
        selectedItemID = id
        requestedScrollItemID = id
        isPreparingPresentation = false
        scheduleSearch(debounced: false)
    }

    func selectFilterFamily(_ family: ClipboardHistoryFilterFamily) {
        guard availableFilterFamilies.contains(family) else { return }
        selectedFilterFamily = family
    }

    func cycleFilterFamily(offset: Int = 1) {
        let families = availableFilterFamilies
        guard families.count > 1 else { return }
        let index = families.firstIndex(of: selectedFilterFamily) ?? 0
        selectedFilterFamily = families[Self.wrappedIndex(index + offset, count: families.count)]
    }

    @discardableResult
    func selectFilterOption(at index: Int) -> Bool {
        guard (0..<filterOptionCount).contains(index) else { return false }
        switch selectedFilterFamily {
        case .scope:
            mode = availableScopeModes[index]
        case .type:
            contentFilter = ([.all] + availableContentFilters)[index]
        case .content:
            semanticFilter = ([.any] + availableSemanticFilters)[index]
        }
        isActionPalettePresented = false
        requestSearchFocus()
        return true
    }

    func requestActionMenu() {
        actionMenuRequestID &+= 1
        isActionPalettePresented = true
    }

    func requestDeleteConfirmation(for context: ClipboardHistoryPanelActionContext? = nil) {
        guard let context = context ?? actionContext,
              context.isMultiSelectionEnabled,
              !context.itemIDs.isEmpty,
              canPerformAction(in: context) else { return }
        deleteConfirmationContext = context
        deleteConfirmationRequestID &+= 1
    }

    func consumeDeleteConfirmationContext() -> ClipboardHistoryPanelActionContext? {
        defer { deleteConfirmationContext = nil }
        return deleteConfirmationContext
    }

    func requestSavedItemEdit() {
        guard let id = selectedItemID, actionItemIDs == [id],
              savedItem(forPresentationID: id)?.isSnippet == true else { return }
        savedEditRequestID &+= 1
    }

    func dismissActionMenu() {
        isActionPalettePresented = false
    }

    func toggleMultiSelection(for itemID: UUID) {
        if let index = selectionNumberByItemID[itemID].map({ $0 - 1 }) {
            removeSelectedItem(at: index)
        } else {
            appendSelectedItem(itemID)
        }
    }

    func toggleFocusedSelection() {
        guard isMultiSelectionEnabled, let selectedItemID else { return }
        toggleMultiSelection(for: selectedItemID)
    }

    func setMultiSelectionEnabled(_ isEnabled: Bool) {
        guard !isEnabled || showsMultiSelectionControl else { return }
        isMultiSelectionEnabled = isEnabled
        if isEnabled, let selectedItemID {
            appendSelectedItem(selectedItemID)
        } else if !isEnabled {
            selectedItemIDs = []
            selectedItemIDSet.removeAll(keepingCapacity: true)
            selectionNumberByItemID.removeAll(keepingCapacity: true)
        }
    }

    func selectionNumber(for itemID: UUID) -> Int? {
        selectionNumberByItemID[itemID]
    }

    func rowNumber(for itemID: UUID, quickPasteNumber: Int?) -> Int? {
        isMultiSelectionEnabled ? selectionNumber(for: itemID) : quickPasteNumber
    }

    var areAllVisibleItemsSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selectedItemIDSet.contains($0.id) }
    }

    func clearMultiSelection() {
        selectedItemIDs = []
        rebuildSelectionIndex()
    }

    func selectAllVisibleItems() {
        guard showsMultiSelectionControl else { return }
        isMultiSelectionEnabled = true
        for item in visibleItems { appendSelectedItem(item.id) }
    }

    func extendSelection(by offset: Int) {
        guard !visibleItems.isEmpty, showsMultiSelectionControl else { return }
        if !isMultiSelectionEnabled {
            isMultiSelectionEnabled = true
        }
        if let selectedItemID, !selectedItemIDSet.contains(selectedItemID) {
            appendSelectedItem(selectedItemID)
        }
        moveSelection(by: offset, wraps: false)
        if let selectedItemID, !selectedItemIDSet.contains(selectedItemID) {
            appendSelectedItem(selectedItemID)
        }
    }

    func requestScroll(to itemID: UUID) {
        requestedScrollItemID = itemID
    }

    func consumeRequestedScrollItemID() -> UUID? {
        defer { requestedScrollItemID = nil }
        return requestedScrollItemID
    }

    @discardableResult
    private func appendSelectedItem(_ itemID: UUID) -> Bool {
        guard !selectedItemIDSet.contains(itemID) else { return false }
        guard selectedItemIDs.count < Self.maximumMultiSelectionItemCount else {
            selectionLimitReachedRevision &+= 1
            return false
        }
        selectedItemIDSet.insert(itemID)
        selectedItemIDs.append(itemID)
        selectionNumberByItemID[itemID] = selectedItemIDs.count
        return true
    }

    private func removeSelectedItem(at index: Int) {
        guard selectedItemIDs.indices.contains(index) else { return }
        let removedID = selectedItemIDs.remove(at: index)
        selectedItemIDSet.remove(removedID)
        selectionNumberByItemID.removeValue(forKey: removedID)
        for shiftedIndex in index..<selectedItemIDs.count {
            selectionNumberByItemID[selectedItemIDs[shiftedIndex]] = shiftedIndex + 1
        }
    }

    private func rebuildSelectionIndex() {
        selectedItemIDSet = Set(selectedItemIDs)
        selectionNumberByItemID = Dictionary(
            uniqueKeysWithValues: selectedItemIDs.enumerated().map { index, itemID in
                (itemID, index + 1)
            }
        )
    }

    var actionItemIDs: [UUID] {
        if isMultiSelectionEnabled {
            return selectedItemIDs
        }
        return selectedItemID.map { [$0] } ?? []
    }

    var canStartSequentialQueue: Bool {
        isMultiSelectionEnabled
            && !selectedItemIDs.isEmpty
            && selectedItemIDs.allSatisfy {
                availableClipItemIDs.contains($0) || availableSnippetIDs.contains($0)
            }
    }

    var actionContext: ClipboardHistoryPanelActionContext? {
        let ids = actionItemIDs
        guard ids.allSatisfy({ availableClipItemIDs.contains($0) || availableSnippetIDs.contains($0) }),
              selectedItemID.map({ availableClipItemIDs.contains($0) || availableSnippetIDs.contains($0) }) ?? true
        else { return nil }
        return ClipboardHistoryPanelActionContext(
            itemIDs: ids,
            snippetIDs: Set(ids.filter(availableSnippetIDs.contains)),
            savedClipIDs: Set(ids.filter(savedClipIDs.contains)),
            focusedItemID: selectedItemID,
            isMultiSelectionEnabled: isMultiSelectionEnabled
        )
    }

    func canPerformAction(in context: ClipboardHistoryPanelActionContext) -> Bool {
        actionContext == context
    }

    func actionContextTitle(localization: PluginLocalization) -> String {
        if isMultiSelectionEnabled {
            return localization.format("panel.selection.orderedCount", defaultValue: "%lld selected · Selection order",
                actionItemIDs.count)
        }
        guard let id = actionItemIDs.first else { return "" }
        if let snippet = savedItem(forPresentationID: id) { return snippet.title }
        guard let item = visibleItems.first(where: { $0.id == id }) else { return "" }
        let title = item.savedMetadata?.title ?? item.text
        return title.isEmpty ? (item.sourceApplication?.name ?? "")
            : String(title.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    }

    func waitForSearchForTesting() async {
        await searchTask?.value
    }

    func waitForPresentationPreparationForTesting() async {
        await presentationPreparationTask?.value
    }

    func waitForFilterRefreshForTesting() async {
        await filterRefreshTask?.value
    }

    func moveSelection(by offset: Int, wraps: Bool = true) {
        guard !visibleItems.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap { selectedID in
            visibleItems.firstIndex { $0.id == selectedID }
        } ?? 0
        let proposedIndex = currentIndex + offset
        let nextIndex = wraps
            ? Self.wrappedIndex(proposedIndex, count: visibleItems.count)
            : min(max(proposedIndex, 0), visibleItems.count - 1)
        selectedItemID = visibleItems[nextIndex].id
    }

    nonisolated static func wrappedIndex(_ proposedIndex: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (proposedIndex % count + count) % count
    }

    private func lockAvailableFilters(
        items: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem]
    ) {
        // Snapshot per active interaction. Background changes must not move the toolbar;
        // opening or returning from another app refreshes these choices.
        guard let preparation = Self.preparePresentationSnapshot(
            items: items,
            savedItems: savedItems
        ) else { return }
        applyFilterAvailability(preparation)
    }

    private func applyFilterAvailability(_ snapshot: PresentationPreparationSnapshot) {
        availableScopeModes = snapshot.scopeModes
        availableContentFilters = snapshot.contentFilters
        availableSemanticFilters = snapshot.semanticFilters
        availableFilterFamilies = snapshot.filterFamilies
        selectedFilterFamily = ClipboardHistoryFilterFamily.resolvedSelection(
            current: .scope,
            available: availableFilterFamilies
        ) ?? .scope
    }

    private func appendAvailableFilterOptions<S: Sequence>(
        for items: S
    ) where S.Element == ClipboardHistoryItem {
        let candidates = Array(items)
        guard !candidates.isEmpty else { return }

        if availableFilterFamilies.contains(.scope) {
            for item in candidates {
                if item.isInHistory, !availableScopeModes.contains(.history) {
                    availableScopeModes.append(.history)
                }
                if item.isSaved, !availableScopeModes.contains(.saved) {
                    availableScopeModes.append(.saved)
                }
            }
            if candidates.contains(where: { availableSnippetIDs.contains($0.id) }),
               !availableScopeModes.contains(.snippets) {
                availableScopeModes.append(.snippets)
            }
        }
        if availableFilterFamilies.contains(.type) {
            for filter in ClipboardHistoryContentFilter.allCases
            where filter != .all && !availableContentFilters.contains(filter) {
                if candidates.contains(where: filter.matches) {
                    availableContentFilters.append(filter)
                }
            }
        }
        if availableFilterFamilies.contains(.content) {
            for filter in ClipboardHistorySemanticFilter.allCases
            where filter != .any && !availableSemanticFilters.contains(filter) {
                if candidates.contains(where: filter.matches) {
                    availableSemanticFilters.append(filter)
                }
            }
        }
    }

    private func applyPreparedPresentation(
        _ preparation: PresentationPreparationSnapshot,
        items: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem]
    ) {
        applyFilterAvailability(preparation)
        mode = availableScopeModes.first ?? .history
        contentFilter = .all
        semanticFilter = .any
        allItems = items
        allSavedItems = savedItems
        savedItemByID = Dictionary(uniqueKeysWithValues: savedItems.map { ($0.id, $0) })
        itemIndexByID = preparation.itemIndexByID
        historyItemCount = preparation.historyItemCount
        availableClipItemIDs = preparation.availableClipItemIDs
        availableSnippetIDs = preparation.availableSnippetIDs
        savedClipIDs = preparation.savedClipIDs
        visibleResultLimit = Self.resultPageSize
        if items.isEmpty && savedItems.isEmpty {
            visibleItems = []
            visibleSavedPresentationItemIDs = []
            hasMoreResults = false
        }
        selectedItemID = visibleItems.first?.id ?? preparation.newestHistoryItemID
        requestedScrollItemID = selectedItemID
        isMultiSelectionEnabled = false
        selectedItemIDs = []
        rebuildSelectionIndex()
        isActionPalettePresented = false
    }

    private nonisolated static func preparePresentationSnapshot(
        items: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem],
        cancelsWhenTaskIsCancelled: Bool = false,
        checkpoint: (@Sendable () -> Void)? = nil
    ) -> PresentationPreparationSnapshot? {
        var itemIndexByID: [UUID: Int] = [:]
        itemIndexByID.reserveCapacity(items.count)
        var historyItemCount = 0
        var availableClipItemIDs = Set<UUID>()
        availableClipItemIDs.reserveCapacity(items.count)
        var savedClipIDs = Set<UUID>()
        var newestHistoryItemID: UUID?
        var newestHistoryCaptureDate: Date?
        var seenPresentationIDs = Set<UUID>()
        var presentationCount = 0
        var typeCounts = Dictionary(
            uniqueKeysWithValues: ClipboardHistoryContentFilter.allCases
                .filter { $0 != .all }
                .map { ($0, 0) }
        )
        var contentCounts = Dictionary(
            uniqueKeysWithValues: ClipboardHistorySemanticFilter.allCases
                .filter { $0 != .any }
                .map { ($0, 0) }
        )

        func recordPresentation(_ item: ClipboardHistoryItem) {
            guard seenPresentationIDs.insert(item.id).inserted else { return }
            presentationCount += 1
            for filter in ClipboardHistoryContentFilter.allCases where filter != .all {
                if filter.matches(item) { typeCounts[filter, default: 0] += 1 }
            }
            for filter in ClipboardHistorySemanticFilter.allCases where filter != .any {
                if filter.matches(item) { contentCounts[filter, default: 0] += 1 }
            }
        }

        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) {
                checkpoint?()
                if cancelsWhenTaskIsCancelled, Task.isCancelled { return nil }
            }
            itemIndexByID[item.id] = index
            availableClipItemIDs.insert(item.id)
            if item.isInHistory {
                historyItemCount += 1
                if newestHistoryCaptureDate.map({ item.capturedAt > $0 }) ?? true {
                    newestHistoryCaptureDate = item.capturedAt
                    newestHistoryItemID = item.id
                }
            }
            if item.isSaved { savedClipIDs.insert(item.id) }
            recordPresentation(item)
        }

        var availableSnippetIDs = Set<UUID>()
        for (index, item) in savedItems.enumerated() {
            if index.isMultiple(of: 64) {
                checkpoint?()
                if cancelsWhenTaskIsCancelled, Task.isCancelled { return nil }
            }
            guard item.isSnippet else { continue }
            availableSnippetIDs.insert(item.id)
            recordPresentation(item.historyPresentationItem())
        }

        let scopeCounts = [historyItemCount, savedClipIDs.count, availableSnippetIDs.count]
        var populatedScopes = zip(
            [ClipboardPanelMode.history, .saved, .snippets], scopeCounts
        ).filter { $0.1 > 0 }.map(\.0)
        if populatedScopes.isEmpty { populatedScopes = [.history] }
        let scopeModes = populatedScopes.count > 1 ? [.all] + populatedScopes : populatedScopes
        let orderedTypeCounts = ClipboardHistoryContentFilter.allCases.filter { $0 != .all }.map {
            ($0, typeCounts[$0, default: 0])
        }
        let orderedContentCounts = ClipboardHistorySemanticFilter.allCases.filter { $0 != .any }.map {
            ($0, contentCounts[$0, default: 0])
        }
        let contentFilters = orderedTypeCounts.filter { $0.1 > 0 }.map(\.0)
        let semanticFilters = orderedContentCounts.filter { $0.1 > 0 }.map(\.0)
        let filterFamilies = ClipboardHistoryFilterFamily.available(
            totalItemCount: presentationCount,
            scopeCounts: scopeCounts,
            typeCounts: orderedTypeCounts.map(\.1),
            contentCounts: orderedContentCounts.map(\.1)
        )
        guard !cancelsWhenTaskIsCancelled || !Task.isCancelled else { return nil }
        return PresentationPreparationSnapshot(
            itemIndexByID: itemIndexByID,
            historyItemCount: historyItemCount,
            availableClipItemIDs: availableClipItemIDs,
            availableSnippetIDs: availableSnippetIDs,
            savedClipIDs: savedClipIDs,
            newestHistoryItemID: newestHistoryItemID,
            scopeModes: scopeModes,
            contentFilters: contentFilters,
            semanticFilters: semanticFilters,
            filterFamilies: filterFamilies
        )
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

    private func scheduleSearch(debounced: Bool, cachesInitialPage: Bool = false) {
        guard !isPreparingPresentation else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        let items = allItems
        let savedItems = allSavedItems
        let query = query
        let mode = mode
        let contentFilter = contentFilter
        let semanticFilter = semanticFilter
        let limit = visibleResultLimit
        let presentationAnchorItemID = requestedScrollItemID
        searchTask?.cancel()
        isSearching = true
        searchProgressTask?.cancel()
        showsSearchProgress = false
        let progressDelay = searchProgressDelayNanoseconds
        searchProgressTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: progressDelay) } catch { return }
            guard let self, !Task.isCancelled,
                  generation == self.searchGeneration, self.isSearching else { return }
            self.showsSearchProgress = true
        }

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
                let preparedQuery = ClipboardHistorySearch.PreparedQuery(query)
                let result = ClipboardPanelBoundedSearch.collect(limit: limit) { collector in
                    for item in items {
                        guard !Task.isCancelled else { return }
                    let isIncluded = switch mode {
                    case .all: item.isInHistory || item.isSaved
                    case .history: item.isInHistory
                    case .saved: item.isSaved
                    case .snippets: false
                    }
                        guard isIncluded,
                              contentFilter.matches(item),
                              semanticFilter.matches(item),
                              ClipboardHistorySearch.matches(index: item.searchIndex, query: preparedQuery) else {
                            continue
                        }
                        collector.consider(ClipboardPanelSearchCandidate(
                            item: item,
                            isSnippet: false,
                            sortDate: item.capturedAt
                        ))
                    }
                    guard mode == .all || mode == .snippets else { return }
                    for savedItem in savedItems where savedItem.isSnippet {
                        guard !Task.isCancelled else { return }
                        guard ClipboardHistorySearch.matches(index: savedItem.searchIndex, query: preparedQuery) else {
                            continue
                        }
                        let presentation = savedItem.historyPresentationItem()
                        guard contentFilter.matches(presentation),
                              semanticFilter.matches(presentation) else {
                            continue
                        }
                        collector.consider(ClipboardPanelSearchCandidate(
                            item: presentation,
                            isSnippet: true,
                            sortDate: savedItem.updatedAt
                        ))
                    }
                }
                guard !Task.isCancelled else {
                    return (items: [ClipboardHistoryItem](), snippetIDs: Set<UUID>(), hasMore: false)
                }
                let visible = result.candidates
                return (
                    items: visible.map(\.item),
                    snippetIDs: Set(visible.lazy.filter(\.isSnippet).map { $0.item.id }),
                    hasMore: result.hasMore
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, generation == self.searchGeneration else { return }
            var displayedItems = result.items
            if query.isEmpty,
               contentFilter == .all,
               semanticFilter == .any,
               let presentationAnchorItemID,
               !displayedItems.contains(where: { $0.id == presentationAnchorItemID }),
               let anchorItem = items.first(where: { $0.id == presentationAnchorItemID }),
               ((mode == .history && anchorItem.isInHistory)
                    || (mode == .saved && anchorItem.isSaved)
                    || mode == .snippets
                    || (mode == .all && (anchorItem.isInHistory || anchorItem.isSaved))) {
                displayedItems.append(anchorItem)
            }
            if visibleItems != displayedItems { visibleItems = displayedItems }
            if visibleSavedPresentationItemIDs != result.snippetIDs { visibleSavedPresentationItemIDs = result.snippetIDs }
            if hasMoreResults != result.hasMore { hasMoreResults = result.hasMore }
            isSearching = false
            searchProgressTask?.cancel()
            showsSearchProgress = false
            if cachesInitialPage, query.isEmpty, contentFilter == .all, semanticFilter == .any,
               limit == Self.resultPageSize {
                initialPage = InitialPage(
                    historyRevision: currentHistoryRevision,
                    savedRevision: currentSavedRevision,
                    mode: mode,
                    items: displayedItems, snippetIDs: result.snippetIDs, hasMore: result.hasMore,
                    selectedItemID: displayedItems.contains(where: { $0.id == selectedItemID }) ? selectedItemID : displayedItems.first?.id,
                    scopeModes: availableScopeModes, contentFilters: availableContentFilters,
                    semanticFilters: availableSemanticFilters, filterFamilies: availableFilterFamilies
                )
            }
            if selectedItemID == nil || !visibleItems.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = visibleItems.first?.id
            }
        }
    }

    nonisolated static func logicalItemCount(
        historyItems: [ClipboardHistoryItem],
        savedItems: [ClipboardSavedItem]
    ) -> Int {
        let snippetCount = savedItems.lazy.filter(\.isSnippet).count
        return historyItems.count + snippetCount
    }
}

struct ClipboardHistoryPanelActionState {
    struct Token: Equatable {
        let presentation: UInt64
        let action: UInt64
    }

    private(set) var presentation: UInt64 = 0
    private var nextAction: UInt64 = 0
    private(set) var activeToken: Token?

    mutating func beginPresentation() {
        presentation &+= 1
        activeToken = nil
    }

    mutating func invalidatePresentation() {
        presentation &+= 1
        activeToken = nil
    }

    mutating func beginAction() -> Token? {
        guard activeToken == nil else { return nil }
        nextAction &+= 1
        let token = Token(presentation: presentation, action: nextAction)
        activeToken = token
        return token
    }

    func isCurrent(_ token: Token, panelIsVisible: Bool) -> Bool {
        panelIsVisible && activeToken == token && token.presentation == presentation
    }

    mutating func finish(_ token: Token) {
        if activeToken == token {
            activeToken = nil
        }
    }

    mutating func commit(_ token: Token) -> Bool {
        guard activeToken == token, token.presentation == presentation else { return false }
        presentation &+= 1
        activeToken = nil
        return true
    }
}

@MainActor
enum ClipboardHistoryFixedShortcut {
    static let close = ShortcutBinding(keyCode: 53, modifiers: [])
    static let paste = ShortcutBinding(keyCode: 36, modifiers: [])
    static let pastePlainText = ShortcutBinding(keyCode: 36, modifiers: [.shift])
    static let copy = ShortcutBinding(keyCode: 8, modifiers: [.command])
    static let previous = ShortcutBinding(keyCode: 126, modifiers: [])
    static let next = ShortcutBinding(keyCode: 125, modifiers: [])
    static let previousAlternate = ShortcutBinding(keyCode: 35, modifiers: [.control])
    static let nextAlternate = ShortcutBinding(keyCode: 45, modifiers: [.control])
    static let extendPrevious = ShortcutBinding(keyCode: 126, modifiers: [.shift])
    static let extendNext = ShortcutBinding(keyCode: 125, modifiers: [.shift])

    static let numberKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static func display(_ binding: ShortcutBinding) -> String {
        ShortcutFormatter.compactDisplayString(for: binding)
    }

    static var navigationDisplay: String {
        [
            display(previous),
            display(next),
            display(previousAlternate),
            display(nextAlternate),
        ].joined(separator: " / ")
    }

    static func numberedDisplay(modifiers: ShortcutModifiers, count: Int) -> String {
        guard count > 0 else { return "—" }
        let first = ShortcutBinding(keyCode: numberKeyCodes[0], modifiers: modifiers)
        return "\(display(first))–\(min(count, numberKeyCodes.count))"
    }
}

@MainActor
final class ClipboardHistoryPanelController: NSObject, NSWindowDelegate {
    static let panelStyleMask: NSWindow.StyleMask = [
        .titled,
        .resizable,
        .fullSizeContentView,
    ]
    static func restrictMovementToExplicitDragRegions(_ window: NSWindow) {
        window.isMovableByWindowBackground = false
    }

    enum KeyboardCommand: Equatable {
        case close
        case pasteSelection(asPlainText: Bool)
        case copySelection
        case saveSelection
        case deleteSelection
        case showExportMenu
        case editSnippet
        case toggleActionMenu
        case toggleMultiSelection
        case toggleFocusedSelection
        case selectAllVisible
        case extendSelection(offset: Int)
        case copyCombinedSelection
        case pasteCombinedSelection
        case shareSelection
        case moveSelection(offset: Int)
        case pasteVisibleItem(index: Int)
        case selectFilterOption(index: Int)
        case cycleFilterFamily(offset: Int)
    }

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let historyController: ClipboardHistoryController
    private let savedLibraryController: ClipboardSavedLibraryController
    private let previewPasteboard: any ClipboardPasteboardAccess
    private let localization: PluginLocalization
    private let onIgnoreNextCopy: () -> Void
    private let onManualClipboardWrite: () -> Void
    private let pasteCommandSender: any ClipboardPasteCommandSending
    private let exportCoordinator: ClipboardHistoryExportCoordinator
    private let shareCoordinator: ClipboardHistoryShareCoordinator
    private let combinedExportCoordinator: ClipboardCombinedExportCoordinator
    private let onStartSequentialQueue: ([UUID]) async -> Bool
    private let onPrepareForPermanentDeletion: ([UUID]) async -> Bool
    private let shortcutBindingProvider: (String) -> ShortcutBinding?
    private let shortcutSettingsContextProvider: () -> PluginSettingsContext?
    private let model = ClipboardHistoryPanelModel()
    private var panel: KeyablePanel?
    private let previewCache = ClipboardEmbeddedPreviewCache()
    private var keyMonitor: Any?
    private var needsFilterRefreshOnActivation = false
    private var previousApplicationState = ClipboardHistoryPreviousApplicationState<NSRunningApplication>()
    private var actionState = ClipboardHistoryPanelActionState()
    private var itemActionTask: Task<Void, Never>?
    private lazy var actionPaletteController = ClipboardHistoryActionPaletteController(
        localization: localization
    )

    init(
        historyController: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController,
        previewPasteboard: any ClipboardPasteboardAccess,
        localization: PluginLocalization,
        onIgnoreNextCopy: @escaping () -> Void,
        onManualClipboardWrite: @escaping () -> Void = {},
        onStartSequentialQueue: @escaping ([UUID]) async -> Bool = { _ in false },
        onPrepareForPermanentDeletion: @escaping ([UUID]) async -> Bool = { _ in true },
        hudPresenter: any ClipboardPrivacyHUDPresenting,
        pasteCommandSender: any ClipboardPasteCommandSending = SystemClipboardPasteCommandSender(),
        shortcutBindingProvider: @escaping (String) -> ShortcutBinding? = {
            ClipboardHistoryPlugin.defaultPanelShortcutBinding($0)
        },
        shortcutSettingsContextProvider: @escaping () -> PluginSettingsContext? = { nil }
    ) {
        self.historyController = historyController
        self.savedLibraryController = savedLibraryController
        self.previewPasteboard = previewPasteboard
        self.localization = localization
        self.onIgnoreNextCopy = onIgnoreNextCopy
        self.onManualClipboardWrite = onManualClipboardWrite
        self.onStartSequentialQueue = onStartSequentialQueue
        self.onPrepareForPermanentDeletion = onPrepareForPermanentDeletion
        self.pasteCommandSender = pasteCommandSender
        self.shortcutBindingProvider = shortcutBindingProvider
        self.shortcutSettingsContextProvider = shortcutSettingsContextProvider
        self.exportCoordinator = ClipboardHistoryExportCoordinator(
            historyController: historyController,
            localization: localization,
            hudPresenter: hudPresenter
        )
        self.shareCoordinator = ClipboardHistoryShareCoordinator(
            historyController: historyController,
            localization: localization,
            hudPresenter: hudPresenter
        )
        self.combinedExportCoordinator = ClipboardCombinedExportCoordinator(
            historyController: historyController,
            localization: localization,
            hudPresenter: hudPresenter
        )
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    var isVisible: Bool { panel?.isVisible == true }

    var focusedWindowLayoutTarget: NSWindow? {
        guard let panel,
              Self.isEligibleWindowLayoutTarget(
                  isVisible: panel.isVisible,
                  isKeyWindow: panel.isKeyWindow,
                  isActionPaletteKeyWindow: actionPaletteController.isKeyWindow
              )
        else {
            return nil
        }
        return panel
    }

    static func isEligibleWindowLayoutTarget(
        isVisible: Bool,
        isKeyWindow: Bool,
        isActionPaletteKeyWindow: Bool = false
    ) -> Bool {
        isVisible && (isKeyWindow || isActionPaletteKeyWindow)
    }

    static func shouldDismissForGlobalShortcut(
        isVisible: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        isVisible && isKeyWindow
    }

    static func shouldCenterPanel(hasExistingPanel: Bool) -> Bool {
        !hasExistingPanel
    }

    func handleGlobalShortcut() {
        if actionPaletteController.isVisible {
            close()
            return
        }
        if Self.shouldDismissForGlobalShortcut(
            isVisible: panel?.isVisible == true,
            isKeyWindow: panel?.isKeyWindow == true
        ) {
            close()
        } else if let panel, panel.isVisible {
            refreshFiltersAfterExternalInteraction()
            previousApplicationState.beginPresentation(
                frontmostApplication: NSWorkspace.shared.frontmostApplication,
                isExternal: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            )
            PluginPresentationSafety.prepareForWindowOrdering(panel)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            model.requestSearchFocus()
        } else {
            show()
        }
    }

    func show() {
        invalidatePendingItemAction()
        actionState.beginPresentation()
        let shouldCenterPanel = Self.shouldCenterPanel(hasExistingPanel: panel != nil)
        let panel = panel ?? makePanel()
        self.panel = panel
        model.activatePreviewPresentation()
        previousApplicationState.beginPresentation(
            frontmostApplication: NSWorkspace.shared.frontmostApplication,
            isExternal: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        )
        model.prepareForPresentationAsynchronously(
            items: historyController.items,
            savedItems: savedLibraryController.items,
            historyRevision: historyController.presentationRevision,
            savedRevision: savedLibraryController.presentationRevision
        )
        needsFilterRefreshOnActivation = false
        installKeyMonitor()
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        NSApp.activate(ignoringOtherApps: true)
        if shouldCenterPanel {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func showSnippets() {
        show()
        model.showSnippetScope()
    }

    func close(restorePreviousApplication: Bool = true) {
        model.cancelPresentationPreparation()
        model.resetPreviewPresentation()
        previewCache.removeAll()
        exportCoordinator.cancel()
        shareCoordinator.cancel()
        combinedExportCoordinator.cancel()
        invalidatePendingItemAction()
        actionState.invalidatePresentation()
        let previousApplication = previousApplicationState.consume()
        historyController.releasePayloadIfReloadable(id: model.selectedItemID)
        actionPaletteController.dismiss(notify: false)
        model.dismissActionMenu()
        panel?.orderOut(nil)
        removeKeyMonitor()
        if restorePreviousApplication {
            previousApplication?.activate(options: [])
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.resetPreviewPresentation()
        previewCache.removeAll()
        exportCoordinator.cancel()
        shareCoordinator.cancel()
        combinedExportCoordinator.cancel()
        invalidatePendingItemAction()
        actionState.invalidatePresentation()
        historyController.releasePayloadIfReloadable(id: model.selectedItemID)
        actionPaletteController.dismiss(notify: false)
        model.dismissActionMenu()
        removeKeyMonitor()
        previousApplicationState.consume()?.activate(options: [])
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        actionPaletteController.reposition(relativeTo: panel)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        actionPaletteController.reposition(relativeTo: panel)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        actionPaletteController.reposition(relativeTo: panel)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel,
              notification.object as? NSWindow === panel else { return }
        if needsFilterRefreshOnActivation { refreshFiltersAfterExternalInteraction() }
        guard actionPaletteController.isVisible else { return }
        actionPaletteController.dismiss(notify: false)
        model.dismissActionMenu()
        model.requestSearchFocus()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        if panel?.isVisible == true { needsFilterRefreshOnActivation = true }
    }

    private func refreshFiltersAfterExternalInteraction() {
        model.refreshFiltersForReactivation(
            items: historyController.items,
            savedItems: savedLibraryController.items,
            historyRevision: historyController.presentationRevision,
            savedRevision: savedLibraryController.presentationRevision
        )
        needsFilterRefreshOnActivation = false
    }

    private func toggleSavedOptimistically(_ itemID: UUID) {
        guard model.beginSavedMutation(for: itemID) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await historyController.toggleSaved(id: itemID)
            model.finishSavedMutation(for: itemID)
        }
    }

    private func presentActionPalette(
        entries: [ClipboardHistoryExportMenuEntry],
        performAction: @escaping (ClipboardHistoryExportMenuEntry.Action) -> Void
    ) {
        guard let panel, panel.isVisible else {
            model.dismissActionMenu()
            return
        }
        actionPaletteController.show(
            entries: entries,
            contextTitle: model.actionContextTitle(localization: localization),
            relativeTo: panel,
            shortcutSettingsContextProvider: shortcutSettingsContextProvider,
            shortcutBindingsProvider: { [weak self] in self?.panelShortcutBindings() ?? [:] },
            onSelect: { [weak self] action in
                guard let self else { return }
                self.actionPaletteController.dismiss(notify: false)
                self.model.dismissActionMenu()
                PluginPresentationSafety.prepareForWindowOrdering(panel)
                panel.makeKeyAndOrderFront(nil)
                performAction(action)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.model.dismissActionMenu()
                PluginPresentationSafety.prepareForWindowOrdering(panel)
                panel.makeKeyAndOrderFront(nil)
                self.model.requestSearchFocus()
            }
        )
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: Self.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = localization.string("metadata.title", defaultValue: "剪贴板历史")
        panel.setAccessibilityTitle(localization.string("metadata.title", defaultValue: "剪贴板历史"))
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        Self.restrictMovementToExplicitDragRegions(panel)
        panel.animationBehavior = .utilityWindow
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 860, height: 540)
        panel.delegate = self
        panel.contentView = ClipboardHistoryWindowContent.makeHostingView(
            rootView: ClipboardHistoryPanelView(
                controller: historyController,
                savedLibraryController: savedLibraryController,
                model: model,
                localization: localization,
                previewPasteboard: previewPasteboard,
                previewCache: previewCache,
                onCopyAndClose: { [weak self] itemID in
                    self?.copyItemAndClose(id: itemID)
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
                    await self.deletePresentationItem(id: itemID)
                },
                onDeleteSelection: { [weak self] historyIDs, snippetIDs in
                    guard let self else { return false }
                    return await self.deleteSelection(
                        historyIDs: historyIDs,
                        snippetIDs: snippetIDs
                    )
                },
                onExport: { [weak self] itemID, format in
                    guard let self else { return }
                    self.exportCoordinator.export(
                        itemID: itemID,
                        format: format,
                        parentWindow: self.panel
                    )
                },
                onShowReferencedFiles: { [weak self] itemID in
                    self?.exportCoordinator.showReferencedFiles(itemID: itemID)
                },
                onCopyReferencedFiles: { [weak self] itemID in
                    guard let self else { return }
                    self.exportCoordinator.copyReferencedFiles(
                        itemID: itemID,
                        parentWindow: self.panel
                    )
                },
                onCopyCombined: { [weak self] itemIDs in
                    self?.copyCombinedItemsAndClose(ids: itemIDs)
                },
                onPasteCombined: { [weak self] itemIDs in
                    self?.pasteCombinedItems(ids: itemIDs)
                },
                onShare: { [weak self] itemIDs in
                    self?.shareItems(ids: itemIDs)
                },
                onExportCombined: { [weak self] itemIDs, format in
                    self?.exportCombinedItems(ids: itemIDs, format: format)
                },
                onStartSequentialQueue: { [weak self] itemIDs in
                    guard let self, await self.onStartSequentialQueue(itemIDs) else { return false }
                    self.close()
                    return true
                },
                onPasteSavedItem: { [weak self] itemID, asPlainText in
                    self?.pasteSavedItem(id: itemID, asPlainText: asPlainText)
                },
                onCopySavedItem: { [weak self] itemID in
                    self?.copySavedItemAndClose(id: itemID)
                },
                onPresentActionPalette: { [weak self] entries, performAction in
                    self?.presentActionPalette(
                        entries: entries,
                        performAction: performAction
                    )
                },
                onDismissActionPalette: { [weak self] in self?.actionPaletteController.dismiss() },
                shortcutTextProvider: { [weak self] shortcutID in
                    guard let binding = self?.shortcutBindingProvider(shortcutID) else {
                        return nil
                    }
                    return ShortcutFormatter.compactDisplayString(for: binding)
                },
                shortcutSettingsContextProvider: { [weak self] in
                    self?.shortcutSettingsContextProvider()
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

    private func copyCombinedItemsAndClose(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        guard let token = actionState.beginAction() else { return }
        let previousApplication = previousApplicationState.application
        itemActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishItemAction(token) }
            guard let resolved = await self.resolveCombinedPlainText(ids: ids),
                  ClipboardHistoryPanelClipboardWrite.perform(
                      isCancelled: Task.isCancelled,
                      isCurrent: self.actionState.isCurrent(token, panelIsVisible: self.isVisible)
                        && self.combinedActionTargetsAreAvailable(ids),
                      write: {
                          self.historyController.writeCombinedPlainText(
                              resolved.text, historyItemIDs: resolved.historyItemIDs
                          )
                      },
                      didWrite: {
                          self.onManualClipboardWrite()
                          self.savedLibraryController.recordSuccessfulUse(
                              ids: resolved.snippetItemIDs
                          )
                      }
                  ),
                  self.commitItemAction(token) else {
                return
            }
            previousApplication?.activate(options: [])
        }
    }

    private func pasteCombinedItems(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        guard let token = actionState.beginAction() else { return }
        let previousApplication = previousApplicationState.application
        itemActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishItemAction(token) }
            guard let resolved = await self.resolveCombinedPlainText(ids: ids),
                  ClipboardHistoryPanelClipboardWrite.perform(
                      isCancelled: Task.isCancelled,
                      isCurrent: self.actionState.isCurrent(token, panelIsVisible: self.isVisible)
                        && self.combinedActionTargetsAreAvailable(ids),
                      write: {
                          self.historyController.writeCombinedPlainText(
                              resolved.text, historyItemIDs: resolved.historyItemIDs
                          )
                      },
                      didWrite: self.onManualClipboardWrite
                  ),
                  self.commitItemAction(token),
                  let previousApplication else {
                NSSound.beep()
                return
            }
            let preparedClipboardVersion = self.historyController.currentPasteboardVersion
            previousApplication.activate(options: [])
            let activationDeadline = ProcessInfo.processInfo.systemUptime + 0.4
            while !previousApplication.isActive,
                  ProcessInfo.processInfo.systemUptime < activationDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == previousApplication.processIdentifier,
                  await self.pasteCommandSender.sendPasteCommand(
                      to: previousApplication.processIdentifier,
                      expectedPasteboardVersion: preparedClipboardVersion,
                      currentPasteboardVersion: { self.historyController.currentPasteboardVersion }
                  ) else {
                NSSound.beep()
                return
            }
            self.savedLibraryController.recordSuccessfulUse(ids: resolved.snippetItemIDs)
        }
    }

    private func combinedActionTargetsAreAvailable(_ ids: [UUID]) -> Bool {
        let availableIDs = Set(historyController.items.map(\.id)).union(
            savedLibraryController.items.lazy.filter(\.isSnippet).map(\.id)
        )
        return ClipboardHistoryPanelClipboardWrite.targetsAreAvailable(ids, availableIDs: availableIDs)
    }

    private func resolveCombinedPlainText(
        ids: [UUID],
        expandsSnippets: Bool = true
    ) async -> (text: String, historyItemIDs: [UUID], snippetItemIDs: [UUID])? {
        let historyItemsByID = Dictionary(
            uniqueKeysWithValues: historyController.items.map { ($0.id, $0) }
        )
        let snippetIDs = Set(savedLibraryController.items.filter(\.isSnippet).map(\.id))
        var parts: [String] = []
        var historyItemIDs: [UUID] = []
        var snippetItemIDs: [UUID] = []
        parts.reserveCapacity(ids.count)
        for id in ids {
            guard !Task.isCancelled else { return nil }
            if let item = historyItemsByID[id] {
                do {
                    _ = try await item.loadPayloadAsync()
                } catch {
                    return nil
                }
                guard let text = ClipboardPlainTextConversion.text(for: item),
                      !text.isEmpty else { return nil }
                item.discardCachedPayloadIfReloadable()
                parts.append(text)
                historyItemIDs.append(id)
            } else if snippetIDs.contains(id),
                      let text = await savedLibraryController.resolvedPlainText(
                          id: id,
                          expandsSnippet: expandsSnippets
                      ),
                      !text.isEmpty {
                parts.append(text)
                snippetItemIDs.append(id)
            } else {
                return nil
            }
        }
        guard parts.count == ids.count else { return nil }
        return (parts.joined(separator: "\n\n"), historyItemIDs, snippetItemIDs)
    }

    private func shareItems(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if ids.count == 1,
           let id = ids.first,
           let savedItem = model.savedItem(forPresentationID: id)
            ?? savedLibraryController.items.first(where: { $0.id == id }) {
            shareCoordinator.share(savedItem: savedItem, from: panel?.contentView)
            return
        }
        let containsSnippet = ids.contains { id in
            savedLibraryController.items.contains { $0.id == id && $0.isSnippet }
        }
        guard containsSnippet else {
            shareCoordinator.share(itemIDs: ids, from: panel?.contentView)
            return
        }
        itemActionTask = Task { @MainActor [weak self] in
            guard let self,
                  let resolved = await self.resolveCombinedPlainText(
                      ids: ids,
                      expandsSnippets: false
                  ),
                  !Task.isCancelled else { return }
            self.shareCoordinator.share(text: resolved.text, from: self.panel?.contentView)
        }
    }

    private func exportCombinedItems(ids: [UUID], format: ClipboardExportFormat) {
        guard !ids.isEmpty else { return }
        let containsSnippet = ids.contains { id in
            savedLibraryController.items.contains { $0.id == id && $0.isSnippet }
        }
        guard containsSnippet else {
            combinedExportCoordinator.export(itemIDs: ids, format: format, parentWindow: panel)
            return
        }
        itemActionTask = Task { @MainActor [weak self] in
            guard let self,
                  let resolved = await self.resolveCombinedPlainText(
                      ids: ids,
                      expandsSnippets: false
                  ),
                  !Task.isCancelled else { return }
            self.combinedExportCoordinator.export(
                text: resolved.text,
                itemIDs: ids,
                historyItemIDs: resolved.historyItemIDs,
                format: format,
                parentWindow: self.panel
            )
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            guard !self.actionPaletteController.hasActiveShortcutRecorder else { return event }
            let isActionPaletteEvent = self.actionPaletteController.ownsKeyEvent(event)
            if isActionPaletteEvent, self.actionPaletteController.handleShortcut(event) {
                return nil
            }
            let textEditor = event.window?.firstResponder as? NSTextView
            guard let command = Self.keyboardCommand(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isPanelEvent: event.window === panel || isActionPaletteEvent,
                isPanelKeyWindow: panel.isKeyWindow || isActionPaletteEvent,
                hasAttachedSheet: panel.attachedSheet != nil || event.window?.attachedSheet != nil,
                isEditingText: textEditor?.isFieldEditor == true,
                hasSelectedText: (textEditor?.selectedRange().length ?? 0) > 0,
                hasMarkedText: textEditor?.hasMarkedText() == true,
                isMultiSelectionEnabled: self.model.isMultiSelectionEnabled,
                isActionPalettePresented: self.model.isActionPalettePresented,
                panelShortcutBindings: self.panelShortcutBindings()
            ) else {
                return event
            }

            if self.model.isPreparingPresentation {
                if case .close = command {
                    // Closing remains available while preparation is in flight.
                } else {
                    return nil
                }
            }

            switch command {
            case .close:
                self.close()
                return nil
            case let .pasteSelection(asPlainText):
                guard !self.historyController.isClearingHistory else { return event }
                if self.model.isMultiSelectionEnabled {
                    let ids = self.model.actionItemIDs
                    if !ids.isEmpty { self.pasteCombinedItems(ids: ids) }
                    return nil
                }
                guard let selectedItemID = self.model.selectedItemID else { return event }
                if self.model.isSavedPresentation(selectedItemID) {
                    self.pasteSavedItem(id: selectedItemID, asPlainText: asPlainText)
                } else {
                    self.pasteItem(id: selectedItemID, asPlainText: asPlainText)
                }
                return nil
            case .copySelection:
                if self.model.isMultiSelectionEnabled {
                    let ids = self.model.actionItemIDs
                    if !ids.isEmpty { self.copyCombinedItemsAndClose(ids: ids) }
                    return nil
                }
                guard !self.historyController.isClearingHistory,
                      let selectedItemID = self.model.selectedItemID else { return event }
                if self.model.isSavedPresentation(selectedItemID) {
                    self.copySavedItemAndClose(id: selectedItemID)
                } else {
                    self.copyItemAndClose(id: selectedItemID)
                }
                return nil
            case .saveSelection:
                guard !self.model.isMultiSelectionEnabled else { return nil }
                guard !self.historyController.isClearingHistory else { return event }
                guard let selectedItemID = self.model.selectedItemID else { return event }
                guard !self.model.isSavedPresentation(selectedItemID) else { return nil }
                self.toggleSavedOptimistically(selectedItemID)
                return nil
            case .deleteSelection:
                guard !self.historyController.isClearingHistory else { return event }
                if self.model.isMultiSelectionEnabled {
                    self.model.requestDeleteConfirmation()
                    return nil
                }
                guard let selectedItemID = self.model.selectedItemID else { return event }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.deletePresentationItem(id: selectedItemID)
                }
                return nil
            case .showExportMenu:
                guard !self.historyController.isClearingHistory else { return event }
                guard !self.model.actionItemIDs.isEmpty else { return event }
                self.model.requestExportMenu()
                return nil
            case .editSnippet:
                guard !self.model.isMultiSelectionEnabled else { return nil }
                guard !self.historyController.isClearingHistory,
                      self.model.actionItemIDs.count == 1,
                      let id = self.model.selectedItemID,
                      self.model.savedItem(forPresentationID: id)?.isSnippet == true else { return event }
                self.model.requestSavedItemEdit()
                return nil
            case .toggleActionMenu:
                guard !event.isARepeat else { return nil }
                if self.model.isActionPalettePresented {
                    self.actionPaletteController.dismiss()
                    return nil
                }
                guard !self.model.actionItemIDs.isEmpty || self.model.isMultiSelectionEnabled else { return event }
                self.model.requestActionMenu()
                return nil
            case .toggleMultiSelection:
                self.model.setMultiSelectionEnabled(!self.model.isMultiSelectionEnabled)
                return nil
            case .toggleFocusedSelection:
                guard !event.isARepeat else { return nil }
                self.model.toggleFocusedSelection()
                return nil
            case .selectAllVisible:
                self.model.selectAllVisibleItems()
                return nil
            case let .extendSelection(offset):
                self.model.extendSelection(by: offset)
                return nil
            case .copyCombinedSelection:
                let ids = self.model.actionItemIDs
                guard !ids.isEmpty else { return event }
                self.copyCombinedItemsAndClose(ids: ids)
                return nil
            case .pasteCombinedSelection:
                let ids = self.model.actionItemIDs
                guard !ids.isEmpty else { return event }
                self.pasteCombinedItems(ids: ids)
                return nil
            case .shareSelection:
                let ids = self.model.actionItemIDs
                guard !ids.isEmpty else { return event }
                self.shareItems(ids: ids)
                return nil
            case let .moveSelection(offset):
                self.moveSelection(by: offset)
                return nil
            case let .pasteVisibleItem(index):
                guard !self.model.isMultiSelectionEnabled else { return nil }
                self.pasteVisibleItem(at: index)
                return nil
            case let .selectFilterOption(index):
                guard self.model.selectFilterOption(at: index) else { return nil }
                self.selectFirstVisibleItemIfNeeded()
                return nil
            case let .cycleFilterFamily(offset):
                self.model.cycleFilterFamily(offset: offset)
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
        hasSelectedText: Bool = false,
        hasMarkedText: Bool,
        isMultiSelectionEnabled: Bool = false,
        isActionPalettePresented: Bool = false,
        panelShortcutBindings: [String: ShortcutBinding] = ClipboardHistoryPanelController.defaultPanelShortcutBindings
    ) -> KeyboardCommand? {
        guard isPanelEvent, isPanelKeyWindow, !hasAttachedSheet, !hasMarkedText else {
            return nil
        }
        let flags = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let candidate = ShortcutBinding(
            keyCode: keyCode,
            modifiers: ShortcutModifiers.from(flags)
        )
        let commandsByBinding = effectiveKeyboardCommands(
            isEditingText: isEditingText,
            hasSelectedText: hasSelectedText,
            isMultiSelectionEnabled: isMultiSelectionEnabled,
            panelShortcutBindings: panelShortcutBindings
        )
        if panelShortcutBindings[ClipboardHistoryPlugin.ShortcutID.panelActions] == candidate {
            return commandsByBinding[candidate]
        }
        // The companion owns its search, navigation and submission. Only the shared
        // Actions toggle is routed back to the history window while it is presented.
        guard !isActionPalettePresented else { return nil }
        return commandsByBinding[candidate]
    }

    private static func effectiveKeyboardCommands(
        isEditingText: Bool,
        hasSelectedText: Bool,
        isMultiSelectionEnabled: Bool,
        panelShortcutBindings: [String: ShortcutBinding]
    ) -> [ShortcutBinding: KeyboardCommand] {
        var commands: [ShortcutBinding: KeyboardCommand] = [:]

        func register(_ binding: ShortcutBinding?, _ command: KeyboardCommand) {
            guard let binding, commands[binding] == nil else { return }
            commands[binding] = command
        }

        let configuredCommands: [(String, KeyboardCommand?)] = [
            (ClipboardHistoryPlugin.ShortcutID.panelActions, .toggleActionMenu),
            (ClipboardHistoryPlugin.ShortcutID.panelCycleScope, .cycleFilterFamily(offset: 1)),
            (ClipboardHistoryPlugin.ShortcutID.panelExport, .showExportMenu),
            (ClipboardHistoryPlugin.ShortcutID.panelEditSnippet, .editSnippet),
            (ClipboardHistoryPlugin.ShortcutID.panelShare, .shareSelection),
            (ClipboardHistoryPlugin.ShortcutID.panelSave, .saveSelection),
            (ClipboardHistoryPlugin.ShortcutID.panelDelete, .deleteSelection),
            (ClipboardHistoryPlugin.ShortcutID.panelMultiSelect, .toggleMultiSelection),
            (
                ClipboardHistoryPlugin.ShortcutID.panelToggleSelection,
                isMultiSelectionEnabled ? .toggleFocusedSelection : nil
            ),
            (
                ClipboardHistoryPlugin.ShortcutID.panelSelectAll,
                isMultiSelectionEnabled ? .selectAllVisible : nil
            ),
            (ClipboardHistoryPlugin.ShortcutID.panelCopyCombined, .copyCombinedSelection),
            (ClipboardHistoryPlugin.ShortcutID.panelPasteCombined, .pasteCombinedSelection),
        ]
        for (shortcutID, command) in configuredCommands {
            guard let command else { continue }
            register(panelShortcutBindings[shortcutID], command)
        }

        if let forward = panelShortcutBindings[ClipboardHistoryPlugin.ShortcutID.panelCycleScope],
           !forward.modifiers.contains(.shift) {
            register(
                ShortcutBinding(
                    keyCode: forward.keyCode,
                    modifiers: forward.modifiers.union(.shift)
                ),
                .cycleFilterFamily(offset: -1)
            )
        }

        register(ClipboardHistoryFixedShortcut.close, .close)
        register(
            ClipboardHistoryFixedShortcut.paste,
            isMultiSelectionEnabled
                ? .pasteCombinedSelection
                : .pasteSelection(asPlainText: false)
        )
        register(
            ClipboardHistoryFixedShortcut.pastePlainText,
            isMultiSelectionEnabled
                ? .pasteCombinedSelection
                : .pasteSelection(asPlainText: true)
        )
        if !isEditingText || !hasSelectedText {
            register(
                ClipboardHistoryFixedShortcut.copy,
                isMultiSelectionEnabled ? .copyCombinedSelection : .copySelection
            )
        }
        register(ClipboardHistoryFixedShortcut.previous, .moveSelection(offset: -1))
        register(ClipboardHistoryFixedShortcut.next, .moveSelection(offset: 1))
        register(ClipboardHistoryFixedShortcut.previousAlternate, .moveSelection(offset: -1))
        register(ClipboardHistoryFixedShortcut.nextAlternate, .moveSelection(offset: 1))
        if isMultiSelectionEnabled {
            register(ClipboardHistoryFixedShortcut.extendPrevious, .extendSelection(offset: -1))
            register(ClipboardHistoryFixedShortcut.extendNext, .extendSelection(offset: 1))
        }

        for (index, keyCode) in ClipboardHistoryFixedShortcut.numberKeyCodes.enumerated() {
            register(
                ShortcutBinding(keyCode: keyCode, modifiers: [.command]),
                .pasteVisibleItem(index: index)
            )
            register(
                ShortcutBinding(keyCode: keyCode, modifiers: [.control]),
                .selectFilterOption(index: index)
            )
        }
        return commands
    }

    private static var defaultPanelShortcutBindings: [String: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: panelShortcutIDs.compactMap { id in
            ClipboardHistoryPlugin.defaultPanelShortcutBinding(id).map { (id, $0) }
        })
    }

    private static let panelShortcutIDs = [
        ClipboardHistoryPlugin.ShortcutID.panelActions,
        ClipboardHistoryPlugin.ShortcutID.panelCycleScope,
        ClipboardHistoryPlugin.ShortcutID.panelExport,
        ClipboardHistoryPlugin.ShortcutID.panelEditSnippet,
        ClipboardHistoryPlugin.ShortcutID.panelShare,
        ClipboardHistoryPlugin.ShortcutID.panelSave,
        ClipboardHistoryPlugin.ShortcutID.panelDelete,
        ClipboardHistoryPlugin.ShortcutID.panelMultiSelect,
        ClipboardHistoryPlugin.ShortcutID.panelToggleSelection,
        ClipboardHistoryPlugin.ShortcutID.panelSelectAll,
        ClipboardHistoryPlugin.ShortcutID.panelCopyCombined,
        ClipboardHistoryPlugin.ShortcutID.panelPasteCombined,
    ]

    private func panelShortcutBindings() -> [String: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: Self.panelShortcutIDs.compactMap { id in
            shortcutBindingProvider(id).map { (id, $0) }
        })
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
        let itemID = model.visibleItems[index].id
        if model.isSavedPresentation(itemID) {
            pasteSavedItem(id: itemID, asPlainText: false)
        } else {
            pasteItem(id: itemID, asPlainText: false)
        }
    }

    private func deleteItem(id: UUID) async {
        let previousSelection = model.selectedItemID
        model.selectNeighborBeforeRemoving(itemID: id)
        guard await historyController.deletePermanently(id: id) else {
            model.selectedItemID = previousSelection
            return
        }
        selectFirstVisibleItemIfNeeded()
    }

    private func deletePresentationItem(id: UUID) async {
        guard await onPrepareForPermanentDeletion([id]) else {
            NSSound.beep()
            return
        }
        if savedLibraryController.items.contains(where: { $0.id == id && $0.isSnippet }) {
            guard await savedLibraryController.delete(id: id) else { NSSound.beep(); return }
            selectFirstVisibleItemIfNeeded()
        } else {
            await deleteItem(id: id)
        }
    }

    private func deleteSelection(historyIDs: Set<UUID>, snippetIDs: Set<UUID>) async -> Bool {
        let allIDs = Array(historyIDs.union(snippetIDs))
        guard await onPrepareForPermanentDeletion(allIDs) else { return false }
        if historyIDs.isEmpty { return await savedLibraryController.delete(ids: snippetIDs) }
        if snippetIDs.isEmpty { return await historyController.deletePermanently(ids: historyIDs) }
        guard historyController.supportsAtomicSnippetDeletion else { return false }
        return await savedLibraryController.removeAfterAtomicDeletion(ids: snippetIDs) {
            await self.historyController.deletePermanently(
                ids: historyIDs,
                deletingSnippetIDs: snippetIDs
            )
        }
    }

    private func pasteItem(id: UUID, asPlainText: Bool) {
        guard let token = actionState.beginAction() else { return }
        let previousApplication = previousApplicationState.application
        itemActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishItemAction(token) }
            guard await self.historyController.preparePayloadForUse(id: id),
                  !Task.isCancelled,
                  self.actionState.isCurrent(token, panelIsVisible: self.isVisible) else {
                NSSound.beep()
                return
            }
            let preparedClipboardVersion: Int?
            if asPlainText {
                preparedClipboardVersion = self.historyController.copyItemAsPlainText(id: id)
                    ? self.historyController.currentPasteboardVersion : nil
            } else {
                preparedClipboardVersion = await self.historyController.copyItemForPaste(id: id) {
                    self.actionState.isCurrent(token, panelIsVisible: self.isVisible)
                }
            }
            guard let preparedClipboardVersion else {
                NSSound.beep()
                return
            }
            self.onManualClipboardWrite()
            guard !Task.isCancelled,
                  self.actionState.isCurrent(token, panelIsVisible: self.isVisible) else {
                NSSound.beep()
                return
            }

            guard self.commitItemAction(token) else { return }
            guard let previousApplication else { return }
            previousApplication.activate(options: [])
            let pasteCommandSender = self.pasteCommandSender
            let activationDeadline = ProcessInfo.processInfo.systemUptime + 0.4
            while !previousApplication.isActive,
                  ProcessInfo.processInfo.systemUptime < activationDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == previousApplication.processIdentifier,
                  await pasteCommandSender.sendPasteCommand(
                      to: previousApplication.processIdentifier,
                      expectedPasteboardVersion: preparedClipboardVersion,
                      currentPasteboardVersion: { self.historyController.currentPasteboardVersion }
                  ) else {
                NSSound.beep()
                return
            }
        }
    }

    private func copyItemAndClose(id: UUID) {
        guard let token = actionState.beginAction() else { return }
        let previousApplication = previousApplicationState.application
        itemActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishItemAction(token) }
            guard await self.historyController.preparePayloadForUse(id: id),
                  !Task.isCancelled,
                  self.actionState.isCurrent(token, panelIsVisible: self.isVisible) else {
                return
            }
            guard await self.historyController.copyItem(id: id, canWrite: {
                self.actionState.isCurrent(token, panelIsVisible: self.isVisible)
            }) else { return }
            self.onManualClipboardWrite()
            guard !Task.isCancelled,
                  self.actionState.isCurrent(token, panelIsVisible: self.isVisible),
                  self.commitItemAction(token) else {
                return
            }
            previousApplication?.activate(options: [])
        }
    }

    private func pasteSavedItem(id: UUID, asPlainText: Bool) {
        guard let token = actionState.beginAction() else { return }
        let previousApplication = previousApplicationState.application
        itemActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishItemAction(token) }
            guard let preparedCopy = await self.savedLibraryController.copyForPaste(
                      id: id,
                      asPlainText: asPlainText
                  ),
                  !Task.isCancelled,
                  self.actionState.isCurrent(token, panelIsVisible: self.isVisible),
                  self.commitItemAction(token),
                  let previousApplication else {
                NSSound.beep()
                return
            }
            self.onManualClipboardWrite()
            previousApplication.activate(options: [])
            let preparedClipboardVersion = preparedCopy.pasteboardVersion
            let expansion = preparedCopy.expansion
            var cursorAccess: SystemClipboardSnippetPasteCursorAccess?
            var cursorContext: ClipboardSnippetPasteCursorContext?
            defer { cursorAccess?.stop() }
            let activationDeadline = ProcessInfo.processInfo.systemUptime + 0.4
            while !previousApplication.isActive,
                  ProcessInfo.processInfo.systemUptime < activationDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == previousApplication.processIdentifier,
                  await pasteCommandSender.sendPasteCommand(
                      to: previousApplication.processIdentifier,
                      beforeSending: {
                          guard self.historyController.currentPasteboardVersion == preparedClipboardVersion else { return false }
                          if let offset = expansion.cursorUTF16OffsetFromEnd, offset > 0,
                             let access = SystemClipboardSnippetPasteCursorAccess(processIdentifier: previousApplication.processIdentifier) {
                              cursorAccess = access
                              if let selection = access.selection {
                                  cursorContext = ClipboardSnippetPasteCursorContext(selection: selection, expansion: expansion)
                              }
                          }
                          return self.historyController.currentPasteboardVersion == preparedClipboardVersion
                      }
                  ) else {
                NSSound.beep()
                return
            }
            self.savedLibraryController.recordSuccessfulUse(id: id)
            if let cursorAccess, let cursorContext {
                await cursorContext.apply(access: cursorAccess)
            }
        }
    }

    private func copySavedItemAndClose(id: UUID) {
        guard let token = actionState.beginAction() else { return }
        let previousApplication = previousApplicationState.application
        itemActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishItemAction(token) }
            guard await self.savedLibraryController.copy(id: id) != nil,
                  !Task.isCancelled,
                  self.actionState.isCurrent(token, panelIsVisible: self.isVisible),
                  self.commitItemAction(token) else {
                return
            }
            self.onManualClipboardWrite()
            previousApplication?.activate(options: [])
        }
    }

    private func finishItemAction(_ token: ClipboardHistoryPanelActionState.Token) {
        actionState.finish(token)
        if actionState.activeToken == nil {
            itemActionTask = nil
        }
    }

    private func commitItemAction(_ token: ClipboardHistoryPanelActionState.Token) -> Bool {
        guard actionState.commit(token) else { return false }
        itemActionTask = nil
        _ = previousApplicationState.consume()
        historyController.releasePayloadIfReloadable(id: model.selectedItemID)
        panel?.orderOut(nil)
        removeKeyMonitor()
        return true
    }

    private func invalidatePendingItemAction() {
        itemActionTask?.cancel()
        itemActionTask = nil
    }
}

private enum ClipboardHistoryClearRequest: Identifiable {
    case all
    case selected(ClipboardHistoryPanelActionContext)

    var id: String {
        switch self {
        case .all:
            "all"
        case let .selected(context):
            "selected-" + context.itemIDs.map(\.uuidString).joined(separator: "-")
        }
    }
}

struct ClipboardHistoryPanelPresentation: Equatable {
    let showsLoading: Bool
    let showsErrorOnly: Bool
    let showsEmptyState: Bool
    let showsSearchEmptyState: Bool
    let showsHistory: Bool
    let showsInlineStorageError: Bool

    static func resolve(
        itemCount: Int,
        visibleItemCount: Int,
        hasStorageError: Bool,
        isLoaded: Bool,
        isSnippetScope: Bool = false,
        snippetsAreLoaded: Bool = true,
        snippetsHaveStorageError: Bool = false
    ) -> Self {
        let isLoaded = isSnippetScope ? snippetsAreLoaded : isLoaded
        let hasStorageError = isSnippetScope ? snippetsHaveStorageError : hasStorageError
        guard isLoaded else {
            return Self(
                showsLoading: true,
                showsErrorOnly: false,
                showsEmptyState: false,
                showsSearchEmptyState: false,
                showsHistory: false,
                showsInlineStorageError: false
            )
        }
        if itemCount == 0 {
            return Self(
                showsLoading: false,
                showsErrorOnly: hasStorageError,
                showsEmptyState: !hasStorageError,
                showsSearchEmptyState: false,
                showsHistory: false,
                showsInlineStorageError: false
            )
        }
        return Self(
            showsLoading: false,
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

    let controller: ClipboardHistoryController
    let savedLibraryController: ClipboardSavedLibraryController
    @ObservedObject var model: ClipboardHistoryPanelModel
    let previewCache: ClipboardEmbeddedPreviewCache
    let previewPasteboard: any ClipboardPasteboardAccess
    let onCopyAndClose: (UUID) -> Void
    let onPasteAndClose: (UUID, Bool) -> Void
    let onIgnoreNextCopy: () -> Void
    let onDelete: (UUID) async -> Void
    let onDeleteSelection: (Set<UUID>, Set<UUID>) async -> Bool
    let onExport: (UUID, ClipboardExportFormat) -> Void
    let onShowReferencedFiles: (UUID) -> Void
    let onCopyReferencedFiles: (UUID) -> Void
    let onCopyCombined: ([UUID]) -> Void
    let onPasteCombined: ([UUID]) -> Void
    let onShare: ([UUID]) -> Void
    let onExportCombined: ([UUID], ClipboardExportFormat) -> Void
    let onStartSequentialQueue: ([UUID]) async -> Bool
    let onPasteSavedItem: (UUID, Bool) -> Void
    let onCopySavedItem: (UUID) -> Void
    let onPresentActionPalette: (
        [ClipboardHistoryExportMenuEntry],
        @escaping (ClipboardHistoryExportMenuEntry.Action) -> Void
    ) -> Void
    let onDismissActionPalette: () -> Void
    let shortcutTextProvider: (String) -> String?
    let shortcutSettingsContextProvider: () -> PluginSettingsContext?
    let onClose: () -> Void
    let localization: PluginLocalization

    @ObservedObject private var settings: ClipboardHistorySettingsStore
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.locale) private var locale
    @State private var clearRequest: ClipboardHistoryClearRequest?
    @State private var detailMetadataByItemID: [UUID: ClipboardHistoryDetailMetadata] = [:]
    @State private var shortcutDisplayRevision: UInt = 0
    @State private var snippetEditorDraft: ClipboardSnippetDraft?
    @State private var savedMetadataDraft: ClipboardSavedMetadataDraft?
    @State private var isShortcutGuidePresented = false

    init(
        controller: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController,
        model: ClipboardHistoryPanelModel,
        localization: PluginLocalization,
        previewPasteboard: any ClipboardPasteboardAccess,
        previewCache: ClipboardEmbeddedPreviewCache = ClipboardEmbeddedPreviewCache(),
        onCopyAndClose: @escaping (UUID) -> Void,
        onPasteAndClose: @escaping (UUID, Bool) -> Void,
        onIgnoreNextCopy: @escaping () -> Void,
        onDelete: @escaping (UUID) async -> Void,
        onDeleteSelection: @escaping (Set<UUID>, Set<UUID>) async -> Bool = { _, _ in false },
        onExport: @escaping (UUID, ClipboardExportFormat) -> Void,
        onShowReferencedFiles: @escaping (UUID) -> Void,
        onCopyReferencedFiles: @escaping (UUID) -> Void,
        onCopyCombined: @escaping ([UUID]) -> Void,
        onPasteCombined: @escaping ([UUID]) -> Void,
        onShare: @escaping ([UUID]) -> Void,
        onExportCombined: @escaping ([UUID], ClipboardExportFormat) -> Void,
        onStartSequentialQueue: @escaping ([UUID]) async -> Bool,
        onPasteSavedItem: @escaping (UUID, Bool) -> Void,
        onCopySavedItem: @escaping (UUID) -> Void,
        onPresentActionPalette: @escaping (
            [ClipboardHistoryExportMenuEntry],
            @escaping (ClipboardHistoryExportMenuEntry.Action) -> Void
        ) -> Void,
        onDismissActionPalette: @escaping () -> Void,
        shortcutTextProvider: @escaping (String) -> String?,
        shortcutSettingsContextProvider: @escaping () -> PluginSettingsContext?,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.savedLibraryController = savedLibraryController
        self.model = model
        self.localization = localization
        self.previewPasteboard = previewPasteboard
        self.previewCache = previewCache
        self.onCopyAndClose = onCopyAndClose
        self.onPasteAndClose = onPasteAndClose
        self.onIgnoreNextCopy = onIgnoreNextCopy
        self.onDelete = onDelete
        self.onDeleteSelection = onDeleteSelection
        self.onExport = onExport
        self.onShowReferencedFiles = onShowReferencedFiles
        self.onCopyReferencedFiles = onCopyReferencedFiles
        self.onCopyCombined = onCopyCombined
        self.onPasteCombined = onPasteCombined
        self.onShare = onShare
        self.onExportCombined = onExportCombined
        self.onStartSequentialQueue = onStartSequentialQueue
        self.onPasteSavedItem = onPasteSavedItem
        self.onCopySavedItem = onCopySavedItem
        self.onPresentActionPalette = onPresentActionPalette
        self.onDismissActionPalette = onDismissActionPalette
        self.shortcutTextProvider = shortcutTextProvider
        self.shortcutSettingsContextProvider = shortcutSettingsContextProvider
        self.onClose = onClose
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    private var visibleItems: [ClipboardHistoryItem] {
        model.visibleItems
    }

    private var selectedItem: ClipboardHistoryItem? {
        guard let selectedItemID = model.selectedItemID else { return nil }
        return model.item(forPresentationID: selectedItemID)
    }

    private var selectedSavedItem: ClipboardSavedItem? {
        guard let selectedItemID = model.selectedItemID else { return nil }
        return model.savedItem(forPresentationID: selectedItemID)
    }

    private var searchText: Binding<String> { $model.query }

    private var logicalItemCount: Int {
        model.scopedItemCount
    }

    private var presentation: ClipboardHistoryPanelPresentation {
        .resolve(
            itemCount: logicalItemCount,
            visibleItemCount: visibleItems.count,
            hasStorageError: model.runtimeStatus.historyErrorMessage != nil,
            isLoaded: model.runtimeStatus.isHistoryLoaded,
            isSnippetScope: model.mode == .snippets,
            snippetsAreLoaded: model.runtimeStatus.isSavedLibraryLoaded,
            snippetsHaveStorageError: model.runtimeStatus.savedFatalErrorMessage != nil
        )
    }

    private var scopedStorageError: String? {
        model.mode == .snippets
            ? model.runtimeStatus.savedFatalErrorMessage
            : model.runtimeStatus.historyErrorMessage
    }

    private func retryScopedStorage() {
        if model.mode == .snippets { savedLibraryController.retryLoading() }
        else { controller.retryStorageAccess() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginPaletteMetrics.contentSpacing) {
            panelToolbar
            if presentation.showsInlineStorageError,
               let errorMessage = scopedStorageError {
                storageErrorBanner(errorMessage)
            }
            if model.mode == .all || model.mode == .snippets {
                if let message = model.runtimeStatus.savedFatalErrorMessage, model.mode == .all {
                    snippetErrorBanner(message, retry: true)
                } else if let message = model.runtimeStatus.savedErrorMessage,
                          model.runtimeStatus.savedFatalErrorMessage == nil {
                    snippetErrorBanner(message, retry: false)
                }
            }
            panelContent
            footer
                .id(shortcutDisplayRevision)
                .disabled(model.isPreparingPresentation)
        }
        .padding(PluginPaletteMetrics.contentPadding)
        .background {
            ClipboardHistoryWindowSurface(role: .history, reducesTransparency: accessibilityReduceTransparency)
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
        .overlay(alignment: .bottomTrailing) {
            // Export must remain available even when its footer hint does not fit.
            ClipboardHistoryExportMenuPresenter(
                requestID: model.exportMenuRequestID,
                entries: { currentExportMenuEntries() },
                onSelect: { performActionMenuAction($0) }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
        .onAppear {
            model.updateRuntimeStatus(
                historyController: controller,
                savedLibraryController: savedLibraryController
            )
            model.updateItems(controller.items, revision: controller.presentationRevision)
            model.updateSavedItems(
                savedLibraryController.items,
                revision: savedLibraryController.presentationRevision
            )
            repairSelection()
        }
        .onReceive(controller.itemUpdates) { update in
            model.updateItems(update.items, revision: update.revision, changedIDs: update.changedIDs)
            previewCache.retain(where: model.containsPreview)
        }
        .onReceive(savedLibraryController.itemUpdates) { update in
            model.updateSavedItems(update.items, revision: update.revision)
        }
        .onReceive(controller.objectWillChange) { _ in
            Task { @MainActor in
                await Task.yield()
                model.updateRuntimeStatus(
                    historyController: controller,
                    savedLibraryController: savedLibraryController
                )
            }
        }
        .onReceive(savedLibraryController.objectWillChange) { _ in
            Task { @MainActor in
                await Task.yield()
                model.updateRuntimeStatus(
                    historyController: controller,
                    savedLibraryController: savedLibraryController
                )
            }
        }
        .onChange(of: model.selectionLimitReachedRevision) { _, _ in
            let message = localization.format(
                "panel.selection.limitReached",
                defaultValue: "You can select up to %lld items.",
                ClipboardHistoryPanelModel.maximumMultiSelectionItemCount
            )
            NSSound.beep()
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
        .onChange(of: visibleItems.map(\.id)) { _, _ in repairSelection() }
        .onChange(of: model.savedEditRequestID) { _, _ in
            guard selectedSavedItem?.isSnippet == true,
                  model.actionItemIDs.count == 1 else { return }
            beginEditingSelectedSavedItem()
        }
        .onChange(of: model.actionMenuRequestID) { _, _ in
            let entries = actionMenuEntries()
            guard !entries.isEmpty, let context = model.actionContext else {
                model.dismissActionMenu()
                return
            }
            onPresentActionPalette(entries) { action in
                performActionMenuAction(action, expectedContext: context)
            }
        }
        .onChange(of: model.actionContext) { _, _ in
            if model.isActionPalettePresented { model.dismissActionMenu() }
        }
        .onChange(of: model.isActionPalettePresented) { _, isPresented in
            if !isPresented { onDismissActionPalette() }
        }
        .onChange(of: model.deleteConfirmationRequestID) { _, _ in
            guard let context = model.consumeDeleteConfirmationContext(),
                  model.canPerformAction(in: context) else { return }
            clearRequest = .selected(context)
        }
        .alert(item: $clearRequest) { request in
            switch request {
            case .all:
                Alert(
                    title: Text(localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？")),
                    message: Text(localization.string(
                        "clear.all.message",
                        defaultValue: "All History items will be permanently deleted. Saved items are not affected."
                    ) + "\n\n" + localization.string(
                        "queue.explicit.retentionNotice",
                        defaultValue: "An active explicit paste queue keeps its encrypted copies until the queue finishes or is canceled."
                    )),
                    primaryButton: .destructive(Text(localization.string("common.clearAll", defaultValue: "全部清除"))) {
                        Task { await controller.clearAllHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case let .selected(context):
                Alert(
                    title: Text(localization.format(
                        "panel.selection.delete.title",
                        defaultValue: "Permanently Delete Selection (%lld)?",
                        context.itemIDs.count
                    )),
                    message: Text(localization.string(
                        "panel.selection.delete.message",
                        defaultValue: "The selected items will be permanently deleted, including saved copies or snippets. This can’t be undone."
                    )),
                    primaryButton: .destructive(Text(localization.string("common.delete", defaultValue: "Delete"))) {
                        Task { await deleteSelectedItems(in: context) }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "Cancel")))
                )
            }
        }
        .sheet(item: $snippetEditorDraft) { draft in
            ClipboardSnippetEditorSheet(
                initialDraft: draft,
                settings: settings,
                errorMessage: model.runtimeStatus.savedErrorMessage,
                localization: localization,
                previewPasteboard: previewPasteboard,
                onSave: { updatedDraft in
                    guard let saved = await savedLibraryController.saveSnippet(updatedDraft) else {
                        return false
                    }
                    if updatedDraft.isNew {
                        model.revealCreatedSnippet(id: saved.id, savedItems: savedLibraryController.items)
                    } else {
                        model.updateSavedItems(savedLibraryController.items)
                        model.selectedItemID = saved.id
                    }
                    snippetEditorDraft = nil
                    return true
                },
                onCancel: { snippetEditorDraft = nil }
            )
        }
        .sheet(item: $savedMetadataDraft) { draft in
            ClipboardSavedMetadataEditorSheet(
                initialDraft: draft,
                localization: localization,
                onSave: { updatedDraft in
                    Task { @MainActor in
                        guard await controller.updateSavedMetadata(updatedDraft) != nil else { return }
                        savedMetadataDraft = nil
                    }
                },
                onCancel: { savedMetadataDraft = nil }
            )
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mode == .snippets, !presentation.showsHistory {
                // Empty and filtered-out states retain the same creation entry point.
                GeometryReader { geometry in
                    listHeader.frame(width: listWidth(availableWidth: geometry.size.width))
                }
                .frame(height: 36)
            }
            panelResults
        }
    }

    @ViewBuilder
    private var panelResults: some View {
        if model.isPreparingPresentation {
            if visibleItems.isEmpty {
                Color.clear
                    .overlay { delayedSearchProgress }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                historyResults
                    .overlay { delayedSearchProgress }
            }
        } else if presentation.showsLoading {
            ProgressView(
                localization.string(
                    "panel.status.loading",
                    defaultValue: "正在载入加密历史记录…"
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation.showsErrorOnly, let errorMessage = scopedStorageError {
            ContentUnavailableView {
                Label(
                    model.mode == .snippets
                        ? localization.string("settings.snippets.section", defaultValue: "Snippets")
                        : localization.string("panel.error.title", defaultValue: "无法读取剪贴板历史"),
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                    retryScopedStorage()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation.showsEmptyState, model.mode == .snippets {
            ContentUnavailableView {
                Label(localization.string("settings.snippets.section", defaultValue: "Snippets"), systemImage: "text.quote")
            } description: {
                Text(localization.string(
                    "settings.snippets.description",
                    defaultValue: "Reusable editable templates with optional keywords, tags, and paste-time variables."
                ))
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
            Color.clear
                .overlay {
                    if model.showsSearchProgress {
                        ProgressView(localization.string("panel.search.searching", defaultValue: "正在搜索…"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if presentation.showsSearchEmptyState {
            if model.query.isEmpty,
               model.contentFilter != .all || model.semanticFilter != .any {
                ContentUnavailableView(
                    localization.string("panel.filter.empty", defaultValue: "此类型没有记录"),
                    systemImage: activeFilterSystemImage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: model.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if presentation.showsHistory {
            historyResults
        }
    }

    @ViewBuilder
    private var delayedSearchProgress: some View {
        if model.showsSearchProgress {
            ProgressView(localization.string(
                "panel.search.searching",
                defaultValue: "正在搜索…"
            ))
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var historyResults: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                historyList
                    .frame(width: listWidth(availableWidth: geometry.size.width))
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(model.runtimeStatus.isClearingHistory || model.isPreparingPresentation)
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
                retryScopedStorage()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private func snippetErrorBanner(_ message: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(localization.string("settings.snippets.section", defaultValue: "Snippets"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if retry {
                Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                    savedLibraryController.retryLoading()
                }
                .buttonStyle(.bordered).controlSize(.small)
            } else {
                Button { savedLibraryController.clearError() } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localization.string("common.close", defaultValue: "Close"))
                .accessibilityLabel(localization.string("common.close", defaultValue: "Close"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }

    private var panelToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PluginPaletteSearchToolbar(
                    text: searchText,
                    placeholder: searchPlaceholder,
                    accessibilityLabel: searchPlaceholder,
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

                    if model.mode != .snippets {
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
                        .accessibilityLabel(
                            settings.isPaused
                                ? localization.string("common.resume", defaultValue: "恢复")
                                : localization.string("common.pause", defaultValue: "暂停")
                        )
                    }

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PluginPaletteToolbarControlStyle())
                    .help(localization.string("panel.close.help", defaultValue: "关闭（Esc）"))
                    .accessibilityLabel(localization.string("panel.close.help", defaultValue: "关闭（Esc）"))
                }
                .frame(maxWidth: .infinity)
            }

            if showsFilterControlBar {
                filterControlBar
            }
        }
    }

    private var showsFilterControlBar: Bool {
        !availableFilterFamilies.isEmpty
    }

    private var availableFilterFamilies: [ClipboardHistoryFilterFamily] {
        model.availableFilterFamilies
    }

    private var searchPlaceholder: String {
        switch model.mode {
        case .all:
            localization.string(
                "panel.search.all.placeholder",
                defaultValue: "Search history, saved items, and snippets"
            )
        case .history:
            localization.string(
                "panel.search.placeholder",
                defaultValue: "搜索剪贴板历史或来源应用"
            )
        case .saved:
            localization.string(
                "saved.search.placeholder",
                defaultValue: "Search saved items, tags, or keywords"
            )
        case .snippets:
            localization.string(
                "saved.search.placeholder",
                defaultValue: "Search snippets, tags, or keywords"
            )
        }
    }

    private func modeTitle(_ mode: ClipboardPanelMode) -> String {
        switch mode {
        case .all:
            localization.string("panel.mode.all", defaultValue: "All")
        case .history:
            localization.string("panel.mode.history", defaultValue: "History")
        case .saved:
            localization.string("panel.mode.saved", defaultValue: "Saved")
        case .snippets:
            localization.string("saved.kind.snippet", defaultValue: "Snippets")
        }
    }

    private func modeSystemImage(_ mode: ClipboardPanelMode) -> String {
        switch mode {
        case .all: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .saved: "bookmark"
        case .snippets: "text.quote"
        }
    }

    private var filterControlBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(availableFilterFamilies) { family in
                        let isSelected = model.selectedFilterFamily == family
                        Button {
                            model.selectFilterFamily(family)
                        } label: {
                            compactFilterFamilyLabel(family)
                        }
                        .buttonStyle(.plain)
                        .help(filterFamilyHelp(family))
                        .accessibilityLabel(Text(
                            "\(filterFamilyTitle(family)): \(filterFamilyValue(family))"
                        ))
                        .accessibilityValue(Text(
                            ClipboardHistorySetupAccessibility.disclosureValue(
                                isExpanded: isSelected,
                                localization: localization
                            )
                        ))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)

            ScrollView(.horizontal) {
                filterOptionStrip
            }
            .scrollIndicators(.hidden)
            .frame(height: 30, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localization.string("panel.filter.title", defaultValue: "Filters"))
    }

    @ViewBuilder
    private var filterOptionStrip: some View {
        switch model.selectedFilterFamily {
        case .scope:
            HStack(spacing: 4) {
                ForEach(Array(model.availableScopeModes.enumerated()), id: \.element) { index, mode in
                    Button {
                        model.selectFilterOption(at: index)
                    } label: {
                        Label(modeTitle(mode), systemImage: modeSystemImage(mode))
                    }
                    .buttonStyle(ClipboardFilterOptionButtonStyle(isSelected: model.mode == mode))
                    .help("\(filterOptionShortcut(index: index)) · \(modeTitle(mode))")
                    .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }
        case .type:
            HStack(spacing: 4) {
                ForEach(Array(([.all] + model.availableContentFilters).enumerated()), id: \.element) { index, filter in
                    Button {
                        model.selectFilterOption(at: index)
                        repairSelection()
                    } label: {
                        Label(filterTitle(filter), systemImage: filterSystemImage(filter))
                    }
                    .buttonStyle(ClipboardFilterOptionButtonStyle(
                        isSelected: model.contentFilter == filter
                    ))
                    .help("\(filterOptionShortcut(index: index)) · \(filterTitle(filter))")
                    .accessibilityAddTraits(model.contentFilter == filter ? .isSelected : [])
                }
            }
        case .content:
            HStack(spacing: 4) {
                ForEach(Array(([.any] + model.availableSemanticFilters).enumerated()), id: \.element) { index, filter in
                    Button {
                        model.selectFilterOption(at: index)
                        repairSelection()
                    } label: {
                        Label(
                            semanticFilterTitle(filter),
                            systemImage: semanticFilterSystemImage(filter)
                        )
                    }
                    .buttonStyle(ClipboardFilterOptionButtonStyle(
                        isSelected: model.semanticFilter == filter
                    ))
                    .help("\(filterOptionShortcut(index: index)) · \(semanticFilterTitle(filter))")
                    .accessibilityAddTraits(model.semanticFilter == filter ? .isSelected : [])
                }
            }
        }
    }

    private func compactFilterFamilyLabel(
        _ family: ClipboardHistoryFilterFamily
    ) -> some View {
        let isSelected = model.selectedFilterFamily == family
        let isFiltered = switch family {
        case .scope: model.mode != .all
        case .type: model.contentFilter != .all
        case .content: model.semanticFilter != .any
        }
        return HStack(spacing: 6) {
            Image(systemName: filterFamilySystemImage(family))
            Text("\(filterFamilyTitle(family)): \(filterFamilyValue(family))")
                .lineLimit(1)
            Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                .font(.caption2)
        }
            .font(PluginSettingsTheme.Typography.secondaryLabel)
            .foregroundStyle(isFiltered ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(
                isFiltered
                    ? PluginSettingsTheme.Palette.activeControlBackground
                    : PluginSettingsTheme.Palette.fieldBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.secondary.opacity(0.55)
                        : PluginSettingsTheme.Palette.cardBorder, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func filterFamilyTitle(_ family: ClipboardHistoryFilterFamily) -> String {
        switch family {
        case .scope: localization.string("panel.mode.searchIn", defaultValue: "Scope")
        case .type: localization.string("panel.filter.family.type", defaultValue: "Type")
        case .content: localization.string("panel.filter.family.content", defaultValue: "Content")
        }
    }

    private func filterFamilyValue(_ family: ClipboardHistoryFilterFamily) -> String {
        switch family {
        case .scope: modeTitle(model.mode)
        case .type: filterTitle(model.contentFilter)
        case .content: semanticFilterTitle(model.semanticFilter)
        }
    }

    private func filterFamilySystemImage(_ family: ClipboardHistoryFilterFamily) -> String {
        switch family {
        case .scope: modeSystemImage(model.mode)
        case .type: filterSystemImage(model.contentFilter)
        case .content: semanticFilterSystemImage(model.semanticFilter)
        }
    }

    private func filterFamilyHelp(_ family: ClipboardHistoryFilterFamily) -> String {
        switch family {
        case .scope:
            localization.string("panel.mode.searchIn", defaultValue: "Scope")
        case .type:
            localization.string("panel.filter.title", defaultValue: "Filter by Type")
        case .content:
            localization.string("panel.filter.contains", defaultValue: "Contains")
        }
    }

    private func listWidth(availableWidth: CGFloat) -> CGFloat {
        min(Layout.listMaximumWidth, max(Layout.listMinimumWidth, availableWidth * 0.34))
    }

    private var listHeader: some View {
            HStack(spacing: 8) {
                if model.isMultiSelectionEnabled {
                    Button {
                        if model.areAllVisibleItemsSelected { model.clearMultiSelection() }
                        else { model.selectAllVisibleItems() }
                    } label: {
                        Image(systemName: model.areAllVisibleItemsSelected ? "checkmark.square.fill"
                            : (model.selectedItemIDs.isEmpty ? "square" : "minus.square.fill"))
                            .frame(width: 36, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(selectAllTitle)
                    .accessibilityLabel(selectAllTitle)
                    .accessibilityValue(localization.format("panel.selection.count", defaultValue: "%lld selected",
                        model.selectedItemIDs.count))
                }
                if model.showsMultiSelectionControl {
                Button {
                    model.setMultiSelectionEnabled(!model.isMultiSelectionEnabled)
                } label: {
                    HStack(spacing: 5) {
                        if !model.isMultiSelectionEnabled {
                            Image(systemName: "square").frame(width: 36)
                        }
                        Text(model.isMultiSelectionEnabled
                            ? localization.string("common.done", defaultValue: "Done")
                            : localization.string("panel.selection.select", defaultValue: "Select"))
                    }
                        .padding(.horizontal, model.isMultiSelectionEnabled ? 12 : 0)
                        .frame(height: 32)
                        .foregroundStyle(
                            model.isMultiSelectionEnabled ? Color.accentColor : Color.primary
                        )
                        .background(
                            model.isMultiSelectionEnabled
                                ? PluginSettingsTheme.Palette.activeControlBackground
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help((model.isMultiSelectionEnabled
                    ? localization.string("common.done", defaultValue: "Done")
                    : localization.string(
                    "panel.selection.action",
                    defaultValue: "Select Multiple Items"
                )) + " (" + panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelMultiSelect,
                    fallback: "⌘L") + ")")
                .accessibilityLabel(model.isMultiSelectionEnabled
                    ? localization.string("common.done", defaultValue: "Done")
                    : localization.string(
                    "panel.selection.action",
                    defaultValue: "Select Multiple Items"
                ))
                .accessibilityAddTraits(model.isMultiSelectionEnabled ? .isSelected : [])
                }
                if model.isMultiSelectionEnabled {
                    selectionToggleShortcutHint
                }
                Spacer()
                if model.mode == .snippets, !model.isMultiSelectionEnabled {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            resultCount.fixedSize()
                            newSnippetButton
                        }
                        newSnippetButton
                    }
                } else {
                    resultCount
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
    }

    private var resultCount: some View {
        Text(localization.format("panel.results.visibleCount", defaultValue: "%lld results", visibleItems.count))
            .font(PluginSettingsTheme.Typography.secondaryLabel)
            .foregroundStyle(.secondary)
    }

    private var newSnippetButton: some View {
        Button { snippetEditorDraft = .empty } label: {
            Label(localization.string("saved.create", defaultValue: "New Snippet"), systemImage: "plus")
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("mactools.clipboard.new-snippet")
        .disabled(!model.runtimeStatus.isSavedLibraryLoaded || model.runtimeStatus.savedFatalErrorMessage != nil)
    }

    private var historyList: some View {
        let quickPasteNumbers = Dictionary(
            uniqueKeysWithValues: visibleItems.prefix(9).enumerated().map { index, item in
                (item.id, index + 1)
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            listHeader

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if item.id == visibleItems.first?.id {
                                sectionTitle(localization.string(
                                    "panel.section.results",
                                    defaultValue: "Results"
                                ))
                            }
                            row(item, quickPasteNumber: quickPasteNumbers[item.id])
                        }
                        .id(item.id)
                    }
                    if model.hasMoreResults || model.showsSearchProgress {
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
                    // Without an anchor, ScrollViewReader moves only enough to reveal
                    // an off-screen row and leaves already-visible clicks in place.
                    proxy.scrollTo(itemID)
                }
                .onChange(of: visibleItems.map(\.id)) { _, _ in
                    guard let itemID = model.requestedScrollItemID,
                          visibleItems.contains(where: { $0.id == itemID }) else { return }
                    _ = model.consumeRequestedScrollItemID()
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(itemID, anchor: .center)
                    }
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
        let selectionNumber = model.selectionNumber(for: item.id)
        let isMarked = selectionNumber != nil
        let isSaved = model.effectiveSavedState(for: item)
        let isSavePending = model.pendingSavedItemIDs.contains(item.id)
        return HStack(alignment: .top, spacing: PluginPaletteMetrics.rowContentSpacing) {
            rowLeadingControl(
                item: item,
                isSelected: isSelected,
                isMarked: isMarked
            )
            VStack(
                alignment: .leading,
                spacing: PluginPaletteMetrics.rowTitleDescriptionSpacing
            ) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTitle(item).replacingOccurrences(of: "\n", with: " "))
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(isSelected ? selectedRowTextColor : Color.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isSaved || isSavePending {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(isSelected ? selectedRowTextColor.opacity(0.85) : Color.secondary)
                            .help(localization.string("saved.kind.clip", defaultValue: "Saved Item"))
                            .opacity(isSavePending ? 0.65 : 1)
                    }
                    if let badgeNumber = model.rowNumber(for: item.id, quickPasteNumber: quickPasteNumber) {
                        Text(model.isMultiSelectionEnabled ? "\(badgeNumber)" : "⌘\(badgeNumber)")
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(isSelected ? selectedRowTextColor.opacity(0.78) : Color.secondary)
                            .frame(minWidth: 24, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                HStack(spacing: 5) {
                    Text(rowSubtitle(item))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ClipboardRelativeTimestamp(date: item.capturedAt)
                        .fixedSize()
                }
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(isSelected ? selectedRowTextColor.opacity(0.78) : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginPaletteSelectableRow(isSelected: isSelected)
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture(count: 1)
                .onEnded { value in
                    guard ClipboardHistoryRowHitTesting.targetsFocus(
                        atX: value.location.x,
                        isMultiSelectionEnabled: model.isMultiSelectionEnabled
                    ) else { return }
                    model.selectedItemID = item.id
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2)
                .onEnded { value in
                    guard !model.isMultiSelectionEnabled,
                          ClipboardHistoryRowHitTesting.targetsFocus(
                              atX: value.location.x,
                              isMultiSelectionEnabled: false
                          ) else { return }
                    pastePanelItem(item.id, asPlainText: false)
                }
        )
        .help(ClipboardHistoryTimestampFormatting.exactString(for: item.capturedAt, locale: locale))
        .contextMenu {
            Button(localization.string("panel.footer.paste", defaultValue: "粘贴")) {
                pastePanelItem(item.id, asPlainText: false)
            }
            Button(plainTextPasteTitle(for: item)) {
                pastePanelItem(item.id, asPlainText: true)
            }
            .disabled(!ClipboardPlainTextConversion.isAvailable(for: item))
            Button(localization.string("common.copy", defaultValue: "复制")) {
                copyPanelItem(item.id)
            }
            Button(localization.string("share.action", defaultValue: "Share")) {
                sharePanelItems([item.id])
            }
            exportActions(for: item)
            Divider()
            if !model.isSavedPresentation(item.id) {
                Button(isSaved
                    ? localization.string("saved.remove", defaultValue: "Unsave Clip")
                    : localization.string("saved.save", defaultValue: "Save Clip")) {
                    toggleSaved(item.id)
                }
                .disabled(isSavePending)
                Divider()
            }
            Button(localization.string("common.delete", defaultValue: "删除"), role: .destructive) {
                deletePanelItem(item.id)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(item))
        .accessibilityValue(Text(rowAccessibilityValue(item: item, selectionNumber: selectionNumber)))
        .accessibilityIdentifier("mactools.clipboard-history.item.\(item.id.uuidString)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(
            (model.isMultiSelectionEnabled ? isMarked : isSelected) ? .isSelected : []
        )
        .accessibilityAction {
            model.selectedItemID = item.id
        }
        .accessibilityActions {
            if model.isMultiSelectionEnabled {
                Button(
                    isMarked
                        ? localization.string("panel.selection.remove", defaultValue: "Remove from Selection")
                        : localization.string("panel.selection.add", defaultValue: "Add to Selection")
                ) {
                    model.toggleMultiSelection(for: item.id)
                }
            } else {
                Button(localization.string("panel.footer.paste", defaultValue: "粘贴")) {
                    pastePanelItem(item.id, asPlainText: false)
                }
            }
        }
    }

    @ViewBuilder
    private func rowLeadingControl(
        item: ClipboardHistoryItem,
        isSelected: Bool,
        isMarked: Bool
    ) -> some View {
        if model.isMultiSelectionEnabled {
            Button {
                model.toggleMultiSelection(for: item.id)
            } label: {
                Image(systemName: isMarked ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isSelected ? selectedRowTextColor : Color.accentColor)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                isMarked
                    ? localization.string("panel.selection.remove", defaultValue: "Remove from Selection")
                    : localization.string("panel.selection.add", defaultValue: "Add to Selection")
            )
            .accessibilityLabel(
                isMarked
                    ? localization.string("panel.selection.remove", defaultValue: "Remove from Selection")
                    : localization.string("panel.selection.add", defaultValue: "Add to Selection")
            )
        } else {
            Image(systemName: itemSystemImage(item))
                .font(.body)
                .foregroundStyle(isSelected ? selectedRowTextColor : Color.accentColor)
                .frame(width: PluginPaletteMetrics.rowIconWidth, height: 20)
                .help(detailKindTitle(item))
                .accessibilityLabel(detailKindTitle(item))
        }
    }

    private func rowSubtitle(_ item: ClipboardHistoryItem) -> String {
        if let snippet = model.savedItem(forPresentationID: item.id), snippet.isSnippet {
            return [localization.string("saved.kind.snippet", defaultValue: "Snippet"), snippet.keyword]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return item.sourceApplication?.name ?? localization.string("common.unknownSource", defaultValue: "Unknown Source")
    }

    private var selectAllTitle: String {
        model.areAllVisibleItemsSelected
            ? localization.string("panel.selection.clear", defaultValue: "Clear Selection")
            : localization.string("panel.selection.all", defaultValue: "Select All Visible")
    }

    private var selectionOrderHint: String {
        localization.string("panel.selection.order", defaultValue: "Items are combined in selection order.")
    }

    private var selectionContext: String {
        if model.actionItemIDs.count == ClipboardHistoryPanelModel.maximumMultiSelectionItemCount {
            return localization.format(
                "panel.selection.orderedCountMaximum",
                defaultValue: "%lld selected · Maximum · Selection order",
                model.actionItemIDs.count
            )
        }
        return localization.format(
            "panel.selection.orderedCount",
            defaultValue: "%lld selected · Selection order",
            model.actionItemIDs.count
        )
    }

    private func rowAccessibilityLabel(_ item: ClipboardHistoryItem) -> String {
        let parts = [
            displayTitle(item).replacingOccurrences(of: "\n", with: " "),
            detailKindTitle(item),
            rowSubtitle(item),
            ClipboardHistoryTimestampFormatting.exactString(for: item.capturedAt, locale: locale),
        ]
        return parts.joined(separator: ", ")
    }

    private func rowAccessibilityValue(
        item: ClipboardHistoryItem,
        selectionNumber: Int?
    ) -> String {
        var values: [String] = []
        if model.effectiveSavedState(for: item) {
            values.append(localization.string("saved.kind.clip", defaultValue: "Saved Item"))
        }
        if let selectionNumber {
            values.append(localization.format(
                "panel.selection.position",
                defaultValue: "Position %lld of %lld in selection",
                selectionNumber,
                model.actionItemIDs.count
            ))
        }
        return values.joined(separator: ", ")
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if let snippet = selectedSavedItem, snippet.isSnippet {
                            Text(snippet.title)
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                                .lineLimit(2)
                            snippetMetadata(snippet)
                        } else {
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
                    }
                    Spacer()
                    detailActions(item)
                }
                if selectedSavedItem?.isSnippet == true {
                    ClipboardSnippetKeywordNotice(settings: settings, localization: localization)
                }
                if model.isMultiSelectionEnabled {
                    Text(localization.format("panel.selection.preview", defaultValue: "Preview: %@ · Actions use the selection",
                        displayTitle(item)))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(selectionOrderHint)
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

    private func snippetMetadata(_ snippet: ClipboardSavedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(localization.string("snippet.templatePreview", defaultValue: "Template Preview"),
                systemImage: "text.quote")
            if let keyword = snippet.keyword, !keyword.isEmpty {
                Text(keyword).font(.system(.subheadline, design: .monospaced))
                Text(snippetExpansionStatusTitle)
            } else {
                Text(localization.string("settings.saved.expansion.status.noKeywords", defaultValue: "No Keywords"))
            }
            if !snippet.tags.isEmpty {
                Label(snippet.tags.joined(separator: ", "), systemImage: "tag")
                    .lineLimit(2)
                    .help(snippet.tags.joined(separator: ", "))
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .foregroundStyle(.secondary)
    }

    private var snippetExpansionStatusTitle: String {
        switch settings.keywordExpansionStatus {
        case .off: localization.string("settings.saved.expansion.status.off", defaultValue: "Off")
        case .noKeywords: localization.string("settings.saved.expansion.status.noKeywords", defaultValue: "No Keywords")
        case .accessibilityRequired: localization.string("permission.accessibility.title", defaultValue: "Permission Needed")
        case .ready: localization.string("settings.saved.expansion.status.listening", defaultValue: "Listening")
        case .unavailable: localization.string("settings.saved.expansion.status.unavailable", defaultValue: "Unavailable")
        }
    }

    private func detailActions(_ item: ClipboardHistoryItem) -> some View {
        let isSaved = model.effectiveSavedState(for: item)
        let isSavePending = model.pendingSavedItemIDs.contains(item.id)
        return HStack(spacing: 6) {
            if model.isMultiSelectionEnabled {
                Button {
                    performActionMenuAction(.share)
                } label: {
                    Label(localization.format("panel.selection.shareCount", defaultValue: "Share %lld", model.actionItemIDs.count),
                        systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ClipboardHistoryDetailActionStyle())
                .disabled(model.actionItemIDs.isEmpty)
                Button(localization.format("panel.selection.pasteCount", defaultValue: "Paste %lld", model.actionItemIDs.count)) {
                    performActionMenuAction(.pasteCombined)
                }
                .buttonStyle(ClipboardHistoryDetailActionStyle(isPrimary: true))
                .help(selectionOrderHint)
                .disabled(model.actionItemIDs.isEmpty)
            } else {
            if selectedSavedItem?.isSnippet == true {
                Button {
                    beginEditingSelectedSavedItem()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(ClipboardHistoryDetailActionStyle())
                .help(localization.string("saved.edit", defaultValue: "Edit Snippet")
                    + " (" + panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelEditSnippet,
                        fallback: "⌥⌘E"
                    ) + ")")
                .accessibilityLabel(Text(
                    localization.string("saved.edit", defaultValue: "Edit Snippet")
                ))
            }
            if !model.isSavedPresentation(item.id) {
                Button {
                    toggleSaved(item.id)
                } label: {
                    Image(systemName: isSaved
                        ? "bookmark.fill"
                        : "bookmark")
                        .opacity(isSavePending ? 0.65 : 1)
                }
                .buttonStyle(ClipboardHistoryDetailActionStyle())
                .disabled(isSavePending)
                .help(isSaved
                    ? localization.string("saved.remove", defaultValue: "Unsave Clip")
                    : localization.string("saved.save", defaultValue: "Save Clip"))
                .accessibilityLabel(Text(isSaved
                    ? localization.string("saved.remove", defaultValue: "Unsave Clip")
                    : localization.string("saved.save", defaultValue: "Save Clip")))
                .accessibilityValue(Text(isSaved
                    ? localization.string("saved.kind.clip", defaultValue: "Saved Item")
                    : localization.string("saved.state.notSaved", defaultValue: "Not Saved")))
            }
            Button {
                sharePanelItems([item.id])
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(ClipboardHistoryDetailActionStyle())
            .help(localization.string("share.action", defaultValue: "Share"))
            .accessibilityLabel(Text(
                localization.string("share.action", defaultValue: "Share")
            ))
            Button(localization.string("panel.footer.paste", defaultValue: "粘贴")) {
                pastePanelItem(item.id, asPlainText: false)
            }
                .buttonStyle(ClipboardHistoryDetailActionStyle(isPrimary: true))
                .accessibilityIdentifier("mactools.clipboard-history.paste")
            }
            Button {
                model.requestActionMenu()
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(ClipboardHistoryDetailActionStyle())
            .overlay {
                if model.isActionPalettePresented {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(
                localization.string("common.actions", defaultValue: "Actions")
            )
        }
        .fixedSize()
        .disabled(model.runtimeStatus.isClearingHistory)
    }

    @ViewBuilder
    private func exportActions(for item: ClipboardHistoryItem) -> some View {
        Divider()
        if item.kind == .files {
            exportMenuItems(for: item)
        } else {
            let options = exportOptions(for: item)
            if options.isEmpty {
                Button(localization.string("export.unavailable", defaultValue: "无法导出此格式")) {}
                    .disabled(true)
            } else {
                Menu(localization.string("export.action", defaultValue: "导出为")) {
                    exportMenuItems(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func exportMenuItems(for item: ClipboardHistoryItem) -> some View {
        if item.kind == .files {
            Button(localization.string("export.showInFinder", defaultValue: "在访达中显示")) {
                onShowReferencedFiles(item.id)
            }
            Button(localization.string("export.copyToFolder", defaultValue: "复制到文件夹…")) {
                onCopyReferencedFiles(item.id)
            }
        } else {
            let options = exportOptions(for: item)
            if options.isEmpty {
                Button(localization.string("export.unavailable", defaultValue: "无法导出此格式")) {}
                    .disabled(true)
            } else {
                ForEach(options) { option in
                    Button(ClipboardHistoryExportTitles.format(
                        option.format,
                        localization: localization
                    )) {
                        exportPanelItems([item.id], format: option.format)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isMultiSelectionEnabled {
            multiSelectionFooter
        } else {
            standardFooter
        }
    }

    private var savedFooter: some View {
        PluginPaletteFooter {
            EmptyView()
        } trailing: {
            HStack(spacing: 12) {
                PluginPaletteKeyboardHint(
                    key: ClipboardHistoryFixedShortcut.navigationDisplay,
                    action: localization.string("panel.footer.navigate", defaultValue: "Navigate")
                )
                footerActionHint(
                    key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.paste),
                    action: localization.string("panel.footer.paste", defaultValue: "Paste"),
                    isEnabled: model.selectedSavedItemID != nil
                ) {
                    guard let itemID = model.selectedSavedItemID else { return }
                    onPasteSavedItem(itemID, false)
                }
                footerActionHint(
                    key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.copy),
                    action: localization.string("common.copy", defaultValue: "Copy"),
                    isEnabled: model.selectedSavedItemID != nil
                ) {
                    guard let itemID = model.selectedSavedItemID else { return }
                    onCopySavedItem(itemID)
                }
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                    footerActionHint(
                        key: panelShortcutText(
                            ClipboardHistoryPlugin.ShortcutID.panelShare,
                            fallback: "⇧⌘E"
                        ),
                        action: localization.string("share.action", defaultValue: "Share"),
                        isEnabled: model.selectedSavedItemID != nil,
                        shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
                    ) {
                        guard let itemID = model.selectedSavedItemID else { return }
                        onShare([itemID])
                    }
                }
                footerActionHint(
                    key: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelActions,
                        fallback: "⌘K"
                    ),
                    action: localization.string("common.actions", defaultValue: "Actions"),
                    isEnabled: model.selectedSavedItemID != nil,
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelActions
                ) {
                    model.requestActionMenu()
                }
                footerActionHint(
                    key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.close),
                    action: localization.string("common.close", defaultValue: "Close")
                ) {
                    onClose()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var standardFooter: some View {
        PluginPaletteFooter {
            EmptyView()
        } trailing: {
            ViewThatFits(in: .horizontal) {
                standardFooterContents(showsFilters: true, showsPlainText: true)
                standardFooterContents(showsFilters: false, showsPlainText: true)
                standardFooterContents(showsFilters: false, showsPlainText: false)
                standardFooterContents(showsFilters: false, showsPlainText: false, isCompact: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func standardFooterContents(
        showsFilters: Bool,
        showsPlainText: Bool,
        isCompact: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            if !isCompact {
                HStack(spacing: 10) {
                    PluginPaletteKeyboardHint(
                        key: ClipboardHistoryFixedShortcut.navigationDisplay,
                        action: localization.string("panel.footer.navigate", defaultValue: "Navigate")
                    )
                    if showsFilters {
                        filterShortcutHints
                    }
                }
                footerGroupDivider
            }
            HStack(spacing: 10) {
                footerActionHint(
                    key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.paste),
                    action: localization.string("panel.footer.paste", defaultValue: "Paste"),
                    isEnabled: selectedItem != nil && !model.runtimeStatus.isClearingHistory
                ) {
                    guard let selectedItem else { return }
                    pastePanelItem(selectedItem.id, asPlainText: false)
                }
                if showsPlainText {
                    footerActionHint(
                        key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.pastePlainText),
                        action: localization.string("panel.pastePlain", defaultValue: "Plain Text"),
                        isEnabled: selectedItem.map {
                            ClipboardPlainTextConversion.isAvailable(for: $0)
                        } == true && !model.runtimeStatus.isClearingHistory
                    ) {
                        guard let selectedItem else { return }
                        pastePanelItem(selectedItem.id, asPlainText: true)
                    }
                }
            }
            if !isCompact {
                footerGroupDivider
                footerExportMenu
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                    footerActionHint(
                        key: panelShortcutText(
                            ClipboardHistoryPlugin.ShortcutID.panelShare,
                            fallback: "⇧⌘E"
                        ),
                        action: localization.string("share.action", defaultValue: "Share"),
                        isEnabled: selectedItem != nil,
                        shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
                    ) {
                        sharePanelItems(model.actionItemIDs)
                    }
                }
                footerGroupDivider
            }
            footerActionsMenu
            if !showsFilters || !showsPlainText {
                footerShortcutOverflow
            }
            footerActionHint(
                key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.close),
                action: localization.string("common.close", defaultValue: "关闭")
            ) {
                onClose()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A read-only shortcut guide, distinct from the executable action palette.
    private var footerShortcutOverflow: some View {
        let entries = shortcutOverflowEntries
        let actionHints = entries.map {
            ClipboardHistoryShortcutGuideHint(title: $0.title, shortcut: $0.shortcut ?? "—")
        }
        let closingHints = [
            ClipboardHistoryShortcutGuideHint(
                title: localization.string("common.actions", defaultValue: "Actions"),
                shortcut: panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelActions, fallback: "⌘K")
            ),
            ClipboardHistoryShortcutGuideHint(
                title: localization.string("common.close", defaultValue: "Close"),
                shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.close)
            ),
        ]
        return Button {
            isShortcutGuidePresented.toggle()
        } label: {
            Image(systemName: "keyboard")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShortcutGuidePresented) {
            ClipboardHistoryShortcutGuide(
                title: localization.string("panel.shortcuts.guide", defaultValue: "Shortcuts"),
                navigation: shortcutNavigationHints,
                actions: actionHints,
                closing: closingHints
            )
        }
        .fixedSize()
        .accessibilityLabel(localization.string("panel.shortcuts.guide", defaultValue: "Shortcuts"))
        .accessibilityIdentifier("mactools.clipboard-history.more-shortcuts")
        .help(([localization.string("panel.footer.moreShortcuts", defaultValue: "More Shortcuts")]
            + shortcutNavigationHints.map { shortcutGuideLabel($0.title, $0.shortcut) }
            + entries.map { shortcutGuideLabel($0.title, $0.shortcut ?? "—") }
            + [shortcutGuideLabel(localization.string("common.actions", defaultValue: "Actions"),
                                  panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelActions, fallback: "⌘K")),
               shortcutGuideLabel(
                   localization.string("common.close", defaultValue: "Close"),
                   ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.close)
               )]
        ).joined(separator: "\n"))
    }

    private var shortcutOverflowEntries: [ClipboardHistoryExportMenuEntry] {
        var entries = actionMenuEntries().filter { $0.shortcut != nil && $0.action != .requestExport }
        if !model.isMultiSelectionEnabled, model.actionItemIDs.count == 1,
           selectedItem.map({ ClipboardPlainTextConversion.isAvailable(for: $0) }) == true,
           !entries.contains(where: { $0.action == .pastePlainText }) {
            entries.append(ClipboardHistoryExportMenuEntry(
                title: localization.string("panel.pastePlain", defaultValue: "Plain Text"),
                action: .pastePlainText,
                shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.pastePlainText)
            ))
        }
        if !currentExportMenuEntries().isEmpty {
            entries.append(ClipboardHistoryExportMenuEntry(
                title: localization.string("export.shortcut", defaultValue: "Export"),
                action: .requestExport,
                shortcut: panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelExport, fallback: "⌘E")
            ))
        }
        return entries
    }

    private var shortcutNavigationHints: [ClipboardHistoryShortcutGuideHint] {
        func hint(_ title: String, _ shortcut: String) -> ClipboardHistoryShortcutGuideHint {
            .init(title: title, shortcut: shortcut)
        }
        var hints = [hint(
            localization.string("panel.footer.navigate", defaultValue: "Navigate"),
            ClipboardHistoryFixedShortcut.navigationDisplay
        )]
        if !model.isMultiSelectionEnabled, !visibleItems.isEmpty {
            hints.append(hint(
                localization.string("panel.footer.paste", defaultValue: "Paste"),
                ClipboardHistoryFixedShortcut.numberedDisplay(modifiers: .command, count: 9)
            ))
        }
        if availableFilterFamilies.count > 1 {
            let shortcut = panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelCycleScope, fallback: "⌃Tab")
            hints.append(hint(localization.string("panel.footer.filter", defaultValue: "Filter Group"),
                                           shortcut == "—" ? shortcut : "\(shortcut) / ⇧\(shortcut)"))
        }
        if model.filterOptionCount > 0 {
            hints.append(hint(
                filterOptionShortcutTitle,
                ClipboardHistoryFixedShortcut.numberedDisplay(
                    modifiers: .control,
                    count: model.filterOptionCount
                )
            ))
        }
        if model.isMultiSelectionEnabled {
            hints.append(hint(
                localization.string("panel.selection.selectAll", defaultValue: "Select All Visible"),
                panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelSelectAll, fallback: "⌥⌘A")
            ))
            hints.append(hint(
                localization.string("panel.selection.extend", defaultValue: "Extend Selection"),
                [
                    ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.extendPrevious),
                    ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.extendNext),
                ].joined(separator: " / ")
            ))
        }
        return hints
    }

    private func shortcutGuideLabel(_ title: String, _ shortcut: String) -> String {
        "\(title)  ·  \(shortcut)"
    }

    private var footerGroupDivider: some View {
        Divider()
            .frame(height: 24)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var filterShortcutHints: some View {
        if availableFilterFamilies.count > 1 {
            footerActionHint(
                key: panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelCycleScope, fallback: "⌃Tab"),
                action: localization.string("panel.footer.filter", defaultValue: "Filter Group"),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelCycleScope
            ) {
                model.cycleFilterFamily()
            }
        }
        if model.filterOptionCount > 0 {
            PluginPaletteKeyboardHint(
                key: ClipboardHistoryFixedShortcut.numberedDisplay(
                    modifiers: .control,
                    count: model.filterOptionCount
                ),
                action: filterOptionShortcutTitle
            )
        }
    }

    private func filterOptionShortcut(index: Int) -> String {
        guard ClipboardHistoryFixedShortcut.numberKeyCodes.indices.contains(index) else {
            return "—"
        }
        return ClipboardHistoryFixedShortcut.display(ShortcutBinding(
            keyCode: ClipboardHistoryFixedShortcut.numberKeyCodes[index],
            modifiers: .control
        ))
    }

    private var filterOptionShortcutTitle: String {
        switch model.selectedFilterFamily {
        case .scope:
            localization.string("panel.filter.chooseScope", defaultValue: "Choose Scope")
        case .type:
            localization.string("panel.filter.chooseType", defaultValue: "Choose Type")
        case .content:
            localization.string("panel.filter.chooseContent", defaultValue: "Choose Content")
        }
    }

    private var selectionToggleShortcutHint: some View {
        ClipboardHistoryInlineShortcutAction(
            shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelToggleSelection,
            shortcutSettingsContextProvider: shortcutSettingsContextProvider,
            changeShortcutTitle: localization.string("panel.shortcuts.change", defaultValue: "Change Shortcut…"),
            onShortcutChanged: { shortcutDisplayRevision &+= 1 },
            perform: { model.toggleFocusedSelection() }
        ) {
            Text(panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelToggleSelection, fallback: "⌘Return"))
                .font(PluginSettingsTheme.Typography.secondaryLabel.monospaced())
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .help(localization.string("panel.selection.toggleFocused", defaultValue: "Mark or Unmark Item"))
        .accessibilityLabel(localization.string("panel.selection.toggleFocused", defaultValue: "Mark or Unmark Item"))
        .disabled(model.selectedItemID == nil)
    }

    private var multiSelectionFooter: some View {
        PluginPaletteFooter {
            Label(selectionContext, systemImage: "list.number")
            .font(PluginSettingsTheme.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(selectionOrderHint)
        } trailing: {
            HStack(spacing: 8) {
                Button {
                    performActionMenuAction(.copyCombined)
                } label: {
                    Label(
                        localization.string("panel.combine.copy", defaultValue: "Copy Combined"),
                        systemImage: "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.selectedItemIDs.isEmpty)

                footerActionsMenu
                footerShortcutOverflow
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func shortcutHints(includeSecondaryActions: Bool) -> some View {
        HStack(spacing: 12) {
            PluginPaletteKeyboardHint(
                key: ClipboardHistoryFixedShortcut.navigationDisplay,
                action: localization.string("panel.footer.navigate", defaultValue: "浏览")
            )
            footerActionHint(
                key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.paste),
                action: localization.string("panel.footer.paste", defaultValue: "粘贴"),
                isEnabled: selectedItem != nil && !model.runtimeStatus.isClearingHistory
                ) {
                    guard let selectedItem else { return }
                    pastePanelItem(selectedItem.id, asPlainText: false)
                }
            if includeSecondaryActions {
                footerActionHint(
                    key: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelShare,
                        fallback: "⇧⌘E"
                    ),
                    action: localization.string("share.action", defaultValue: "Share"),
                    isEnabled: !model.actionItemIDs.isEmpty,
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
                ) {
                    sharePanelItems(model.actionItemIDs)
                }
                footerActionHint(
                    key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.pastePlainText),
                    action: localization.string("panel.pastePlain", defaultValue: "粘贴为纯文本"),
                    isEnabled: selectedItem.map {
                        ClipboardPlainTextConversion.isAvailable(for: $0)
                    } == true && !model.runtimeStatus.isClearingHistory
                ) {
                    guard let selectedItem else { return }
                    pastePanelItem(selectedItem.id, asPlainText: true)
                }
            }
            PluginPaletteKeyboardHint(
                key: ClipboardHistoryFixedShortcut.numberedDisplay(modifiers: .command, count: 9),
                action: localization.string("panel.footer.paste", defaultValue: "粘贴")
            )
            filterShortcutHints
            if includeSecondaryActions {
                footerActionHint(
                    key: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelSave,
                        fallback: "⌘P"
                    ),
                    action: localization.string("saved.save", defaultValue: "Save"),
                    isEnabled: selectedItem != nil && !model.runtimeStatus.isClearingHistory,
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelSave
                ) {
                    guard let selectedItem else { return }
                    toggleSaved(selectedItem.id)
                }
                footerActionHint(
                    key: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelDelete,
                        fallback: "⇧⌘⌫"
                    ),
                    action: localization.string("common.delete", defaultValue: "删除"),
                    isEnabled: selectedItem != nil && !model.runtimeStatus.isClearingHistory,
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelDelete
                ) {
                    guard let selectedItem else { return }
                    deletePanelItem(selectedItem.id)
                }
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var footerActionsMenu: some View {
        ClipboardHistoryInlineShortcutAction(
            shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelActions,
            shortcutSettingsContextProvider: shortcutSettingsContextProvider,
            changeShortcutTitle: localization.string(
                "panel.shortcuts.change",
                defaultValue: "Change Shortcut…"
            ),
            onShortcutChanged: { shortcutDisplayRevision &+= 1 },
            perform: { model.requestActionMenu() }
        ) {
            ClipboardHistoryInteractiveKeyboardHint(
                key: panelShortcutText(
                    ClipboardHistoryPlugin.ShortcutID.panelActions,
                    fallback: "⌘K"
                ),
                action: localization.string("common.actions", defaultValue: "Actions")
            )
        }
        .fixedSize()
    }

    private func actionMenuEntries() -> [ClipboardHistoryExportMenuEntry] {
        rawActionMenuEntries().filter {
            $0.action != .toggleMultiSelection || model.showsMultiSelectionControl
        }.map { entry in
            switch entry.action {
            case .format, .combinedExport:
                return ClipboardHistoryExportMenuEntry(
                    title: localization.format("export.action.named", defaultValue: "Export as %@", entry.title),
                    action: entry.action, group: entry.group, systemImage: entry.systemImage,
                    shortcut: entry.shortcut, shortcutDefinitionID: entry.shortcutDefinitionID,
                    keywords: entry.keywords
                )
            default: return entry
            }
        }
    }

    private func rawActionMenuEntries() -> [ClipboardHistoryExportMenuEntry] {
        if !model.isMultiSelectionEnabled, model.actionItemIDs.count == 1, selectedSavedItem != nil {
            return unifiedSavedActionMenuEntries()
        }
        let ids = model.actionItemIDs
        var entries: [ClipboardHistoryExportMenuEntry] = []
        if model.isMultiSelectionEnabled, !ids.isEmpty {
            entries += [
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("panel.combine.copy", defaultValue: "Copy Combined"),
                    action: .copyCombined,
                    systemImage: "doc.on.doc",
                    shortcut: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelCopyCombined,
                        fallback: "⇧⌘C"
                    ),
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelCopyCombined
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("panel.combine.paste", defaultValue: "Paste Combined"),
                    action: .pasteCombined,
                    systemImage: "arrow.right.doc.on.clipboard",
                    shortcut: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelPasteCombined,
                        fallback: "⇧⌘Return"
                    ),
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelPasteCombined
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.format("panel.selection.shareCount", defaultValue: "Share %lld", ids.count),
                    action: .share,
                    group: .exportAndShare,
                    systemImage: "square.and.arrow.up",
                    shortcut: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelShare,
                        fallback: "⇧⌘E"
                    ),
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("export.format.text", defaultValue: "Text File"),
                    action: .combinedExport(.plainText),
                    group: .exportAndShare,
                    systemImage: "doc.plaintext"
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("export.format.markdown", defaultValue: "Markdown"),
                    action: .combinedExport(.markdown),
                    group: .exportAndShare,
                    systemImage: "text.document"
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("export.format.html", defaultValue: "HTML"),
                    action: .combinedExport(.html),
                    group: .exportAndShare,
                    systemImage: "chevron.left.forwardslash.chevron.right"
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("export.format.pdf", defaultValue: "PDF"),
                    action: .combinedExport(.pdf),
                    group: .exportAndShare,
                    systemImage: "doc.richtext"
                ),
            ]
            if model.canStartSequentialQueue {
                entries.append(ClipboardHistoryExportMenuEntry(
                    title: localization.string("panel.queue.replace", defaultValue: "Start New Queue"),
                    action: .startQueue,
                    group: .selection,
                    systemImage: "list.number"
                ))
            }
        } else if let item = selectedItem, let id = ids.first, id == item.id {
            entries += [
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("panel.footer.paste", defaultValue: "Paste"),
                    action: .paste,
                    systemImage: "arrow.right.doc.on.clipboard",
                    shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.paste)
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("common.copy", defaultValue: "Copy"),
                    action: .copy,
                    systemImage: "doc.on.clipboard",
                    shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.copy)
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("share.action", defaultValue: "Share"),
                    action: .share,
                    group: .exportAndShare,
                    systemImage: "square.and.arrow.up",
                    shortcut: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelShare,
                        fallback: "⇧⌘E"
                    ),
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
                ),
            ]
            if item.isSaved {
                entries.append(ClipboardHistoryExportMenuEntry(
                    title: localization.string("saved.remove", defaultValue: "Unsave Clip"),
                    action: .removeFromSaved,
                    group: .selection,
                    systemImage: "bookmark.slash"
                ))
            } else {
                entries.append(ClipboardHistoryExportMenuEntry(
                    title: localization.string("saved.save", defaultValue: "Save Clip"),
                    action: .saveToLibrary,
                    group: .selection,
                    systemImage: "bookmark",
                    shortcut: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelSave,
                        fallback: "⌘P"
                    ),
                    shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelSave
                ))
            }
            entries.append(ClipboardHistoryExportMenuEntry(
                title: localization.string("common.delete", defaultValue: "Delete Permanently"),
                action: .delete,
                group: .selection,
                systemImage: "trash",
                shortcut: panelShortcutText(
                    ClipboardHistoryPlugin.ShortcutID.panelDelete,
                    fallback: "⇧⌘⌫"
                ),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelDelete
            ))
            if ClipboardPlainTextConversion.isAvailable(for: item) {
                entries.insert(
                    ClipboardHistoryExportMenuEntry(
                        title: plainTextPasteTitle(for: item),
                        action: .pastePlainText,
                        systemImage: "textformat",
                        shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.pastePlainText)
                    ),
                    at: 1
                )
                entries.append(ClipboardHistoryExportMenuEntry(
                    title: localization.string(
                        "snippet.createFromClip",
                        defaultValue: "Create Snippet from Clip…"
                    ),
                    action: .createSnippet,
                    group: .selection,
                    systemImage: "text.badge.plus"
                ))
            }
            entries += exportMenuEntries(for: item).map { entry in
                ClipboardHistoryExportMenuEntry(
                    title: entry.title,
                    action: entry.action,
                    group: .exportAndShare,
                    systemImage: exportActionSystemImage(entry.action)
                )
            }
            if item.savedMetadata != nil {
                entries.append(ClipboardHistoryExportMenuEntry(
                    title: localization.string("saved.editDetails", defaultValue: "Edit Name and Tags"),
                    action: .editSaved,
                    group: .selection,
                    systemImage: "pencil"
                ))
            }
        }

        if model.isMultiSelectionEnabled, model.selectedItemID != nil {
            entries.append(ClipboardHistoryExportMenuEntry(
                title: localization.string("panel.selection.toggleFocused", defaultValue: "Mark or Unmark Item"),
                action: .toggleFocusedSelection,
                group: .selection,
                systemImage: "checkmark.square",
                shortcut: panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelToggleSelection, fallback: "⌘Return"),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelToggleSelection
            ))
        }
        entries.append(ClipboardHistoryExportMenuEntry(
            title: model.isMultiSelectionEnabled
                ? localization.string("common.done", defaultValue: "Done Selecting")
                : localization.string("panel.selection.action", defaultValue: "Select Multiple Items"),
            action: .toggleMultiSelection,
            group: .selection,
            systemImage: "checklist",
            shortcut: panelShortcutText(
                ClipboardHistoryPlugin.ShortcutID.panelMultiSelect,
                fallback: "⌘L"
            ),
            shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelMultiSelect
        ))
        if model.isMultiSelectionEnabled, !ids.isEmpty {
            entries.append(ClipboardHistoryExportMenuEntry(
                title: localization.format(
                    "panel.selection.delete.action",
                    defaultValue: "Delete Selection (%lld)…",
                    ids.count
                ),
                action: .delete,
                group: .selection,
                systemImage: "trash",
                shortcut: panelShortcutText(
                    ClipboardHistoryPlugin.ShortcutID.panelDelete,
                    fallback: "⇧⌘⌫"
                ),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelDelete
            ))
        }
        entries += historyActionMenuEntries()
        return entries
    }

    private func unifiedSavedActionMenuEntries() -> [ClipboardHistoryExportMenuEntry] {
        var entries = [
            ClipboardHistoryExportMenuEntry(
                title: localization.string("panel.footer.paste", defaultValue: "Paste"),
                action: .paste,
                systemImage: "arrow.right.doc.on.clipboard",
                shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.paste)
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("common.copy", defaultValue: "Copy"),
                action: .copy,
                systemImage: "doc.on.clipboard",
                shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.copy)
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("share.action", defaultValue: "Share"),
                action: .share,
                group: .exportAndShare,
                systemImage: "square.and.arrow.up",
                shortcut: panelShortcutText(
                    ClipboardHistoryPlugin.ShortcutID.panelShare,
                    fallback: "⇧⌘E"
                ),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("export.format.text", defaultValue: "Text File"),
                action: .combinedExport(.plainText),
                group: .exportAndShare,
                systemImage: "doc.plaintext"
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("export.format.markdown", defaultValue: "Markdown"),
                action: .combinedExport(.markdown),
                group: .exportAndShare,
                systemImage: "text.document"
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("export.format.html", defaultValue: "HTML"),
                action: .combinedExport(.html),
                group: .exportAndShare,
                systemImage: "chevron.left.forwardslash.chevron.right"
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("export.format.pdf", defaultValue: "PDF"),
                action: .combinedExport(.pdf),
                group: .exportAndShare,
                systemImage: "doc.richtext"
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("saved.edit", defaultValue: "Edit Snippet"),
                action: .editSaved,
                group: .selection,
                systemImage: "pencil",
                shortcut: panelShortcutText(ClipboardHistoryPlugin.ShortcutID.panelEditSnippet, fallback: "⌥⌘E"),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelEditSnippet
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("common.delete", defaultValue: "Delete"),
                action: .delete,
                systemImage: "trash",
                shortcut: panelShortcutText(
                    ClipboardHistoryPlugin.ShortcutID.panelDelete,
                    fallback: "⇧⌘⌫"
                ),
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelDelete
            ),
        ]
        entries.append(ClipboardHistoryExportMenuEntry(
            title: model.isMultiSelectionEnabled
                ? localization.string("common.done", defaultValue: "Done Selecting")
                : localization.string("panel.selection.action", defaultValue: "Select Multiple Items"),
            action: .toggleMultiSelection,
            group: .selection,
            systemImage: "checklist",
            shortcut: panelShortcutText(
                ClipboardHistoryPlugin.ShortcutID.panelMultiSelect,
                fallback: "⌘L"
            ),
            shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelMultiSelect
        ))
        return entries
    }

    private func savedActionMenuEntries() -> [ClipboardHistoryExportMenuEntry] {
        guard let id = model.selectedSavedItemID,
              let item = savedLibraryController.items.first(where: { $0.id == id }) else {
            return []
        }
        var entries = [
            ClipboardHistoryExportMenuEntry(
                title: localization.string("panel.footer.paste", defaultValue: "Paste"),
                action: .paste,
                systemImage: "arrow.right.doc.on.clipboard",
                shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.paste)
            ),
            ClipboardHistoryExportMenuEntry(
                title: localization.string("common.copy", defaultValue: "Copy"),
                action: .copy,
                systemImage: "doc.on.clipboard",
                shortcut: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.copy)
            ),
        ]
        entries.append(ClipboardHistoryExportMenuEntry(
            title: localization.string("share.action", defaultValue: "Share"),
            action: .share,
            group: .exportAndShare,
            systemImage: "square.and.arrow.up",
            shortcut: panelShortcutText(
                ClipboardHistoryPlugin.ShortcutID.panelShare,
                fallback: "⇧⌘E"
            ),
            shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelShare
        ))
        entries.append(ClipboardHistoryExportMenuEntry(
            title: item.isSnippet
                ? localization.string("saved.edit", defaultValue: "Edit Snippet")
                : localization.string("saved.editDetails", defaultValue: "Edit Details"),
            action: .editSaved,
            systemImage: "pencil"
        ))
        entries.append(ClipboardHistoryExportMenuEntry(
            title: localization.string("common.delete", defaultValue: "Delete"),
            action: .delete,
            systemImage: "trash",
            shortcut: panelShortcutText(
                ClipboardHistoryPlugin.ShortcutID.panelDelete,
                fallback: "⇧⌘⌫"
            ),
            shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelDelete
        ))
        return entries
    }

    private func panelShortcutText(_ shortcutID: String, fallback _: String) -> String {
        shortcutTextProvider(shortcutID) ?? "—"
    }

    private func historyActionMenuEntries() -> [ClipboardHistoryExportMenuEntry] {
        var entries = [
            ClipboardHistoryExportMenuEntry(
                title: settings.isPaused
                    ? localization.string("common.resume", defaultValue: "Resume")
                    : localization.string("common.pause", defaultValue: "Pause"),
                action: .toggleCollection,
                group: .history,
                systemImage: settings.isPaused ? "play.fill" : "pause.fill"
            ),
            ClipboardHistoryExportMenuEntry(
                title: controller.isIgnoringNextCopy
                    ? localization.string("panel.action.cancelIgnore", defaultValue: "Cancel Ignore Next Copy")
                    : localization.string("shortcut.ignoreNext.title", defaultValue: "Ignore Next Copy"),
                action: .ignoreNextCopy,
                group: .history,
                systemImage: "eye.slash"
            ),
        ]
        if (model.scopedItemCount > 0 || model.runtimeStatus.historyErrorMessage != nil),
           !model.runtimeStatus.isClearingHistory {
            entries.append(ClipboardHistoryExportMenuEntry(
                title: localization.string("clear.all.menu", defaultValue: "Clear All History"),
                action: .clearAll,
                group: .history,
                systemImage: "trash.slash"
            ))
        }
        return entries
    }

    private func exportActionSystemImage(
        _ action: ClipboardHistoryExportMenuEntry.Action
    ) -> String {
        switch action {
        case .showInFinder: "folder"
        case .copyToFolder: "folder.badge.plus"
        case let .format(format):
            switch format {
            case .plainText: "doc.plaintext"
            case .markdown: "text.document"
            case .html: "chevron.left.forwardslash.chevron.right"
            case .pdf: "doc.richtext"
            case .png, .jpeg, .tiff: "photo"
            case .original: "doc"
            case .webLocation: "link"
            case .recognizedText: "text.viewfinder"
            }
        default: "square.and.arrow.down"
        }
    }

    private func performActionMenuAction(
        _ action: ClipboardHistoryExportMenuEntry.Action,
        expectedContext: ClipboardHistoryPanelActionContext? = nil
    ) {
        if let expectedContext, !model.canPerformAction(in: expectedContext) { return }
        let ids = expectedContext?.itemIDs ?? model.actionItemIDs
        switch action {
        case .paste:
            if let id = ids.first {
                pastePanelItem(id, asPlainText: false)
            }
        case .pastePlainText:
            guard let id = ids.first else { return }
            pastePanelItem(id, asPlainText: true)
        case .copy:
            if let id = ids.first {
                copyPanelItem(id)
            }
        case .copyCombined:
            onCopyCombined(ids)
        case .pasteCombined:
            onPasteCombined(ids)
        case .share:
            sharePanelItems(ids)
        case let .combinedExport(format):
            exportPanelItems(ids, format: format, combining: true)
        case .startQueue:
            guard let context = expectedContext ?? model.actionContext,
                  context.canStartSequentialQueue else { return }
            Task { _ = await onStartSequentialQueue(ids) }
        case .requestExport:
            model.requestExportMenu()
        case .saveToLibrary:
            guard let id = ids.first else { return }
            toggleSaved(id)
        case .createSnippet:
            guard let item = selectedItem,
                  let content = ClipboardPlainTextConversion.text(for: item),
                  !content.isEmpty else { return }
            snippetEditorDraft = ClipboardSnippetDraft(
                id: UUID(),
                title: displayTitle(item),
                content: content,
                tags: [],
                keyword: nil,
                isNew: true
            )
        case .delete:
            if let context = expectedContext ?? model.actionContext,
               context.isMultiSelectionEnabled {
                model.requestDeleteConfirmation(for: context)
            } else if let id = ids.first {
                deletePanelItem(id)
            }
        case .removeFromHistory:
            return
        case .removeFromSaved:
            guard let id = ids.first else { return }
            toggleSaved(id)
        case .editSaved:
            beginEditingSelectedSavedItem()
        case let .format(format):
            guard let id = ids.first else { return }
            exportPanelItems([id], format: format)
        case .showInFinder:
            guard let id = ids.first else { return }
            onShowReferencedFiles(id)
        case .copyToFolder:
            guard let id = ids.first else { return }
            onCopyReferencedFiles(id)
        case .toggleMultiSelection:
            model.setMultiSelectionEnabled(!model.isMultiSelectionEnabled)
        case .toggleFocusedSelection:
            model.toggleFocusedSelection()
        case .toggleCollection:
            guard controller.isCollectionOperational else { return }
            settings.setPaused(!settings.isPaused)
        case .ignoreNextCopy:
            if controller.isIgnoringNextCopy {
                controller.cancelNextCaptureSuppression()
            } else if controller.canSuppressNextCapture {
                onIgnoreNextCopy()
            }
        case .clearAll:
            clearRequest = .all
        }
    }

    private func pastePanelItem(_ itemID: UUID, asPlainText: Bool) {
        if model.isSavedPresentation(itemID) {
            onPasteSavedItem(itemID, asPlainText)
        } else {
            onPasteAndClose(itemID, asPlainText)
        }
    }

    private func copyPanelItem(_ itemID: UUID) {
        if model.isSavedPresentation(itemID) {
            onCopySavedItem(itemID)
        } else {
            onCopyAndClose(itemID)
        }
    }

    private func sharePanelItems(_ itemIDs: [UUID]) {
        guard !itemIDs.isEmpty else { return }
        onShare(itemIDs)
    }

    private func exportPanelItems(_ itemIDs: [UUID], format: ClipboardExportFormat, combining: Bool = false) {
        guard !itemIDs.isEmpty else { return }
        if let historyID = ClipboardPanelExportRoute.historyItemID(
            ids: itemIDs, snippetIDs: model.visibleSavedPresentationItemIDs, combining: combining
        ) {
            onExport(historyID, format)
        } else {
            onExportCombined(itemIDs, format)
        }
    }

    private func exportOptions(for item: ClipboardHistoryItem) -> [ClipboardExportOption] {
        if model.isSavedPresentation(item.id) {
            return ClipboardPanelExportRoute.snippetFormats.map { .init(format: $0, isDefault: $0 == .plainText) }
        }
        return ClipboardHistoryExportPlanner.options(for: item)
    }

    private func deletePanelItem(_ itemID: UUID) {
        Task { await onDelete(itemID) }
    }

    private func deleteSelectedItems(in context: ClipboardHistoryPanelActionContext) async {
        guard context.isMultiSelectionEnabled,
              !context.itemIDs.isEmpty,
              model.canPerformAction(in: context) else {
            NSSound.beep()
            return
        }
        let historyItemIDs = Set(context.itemIDs).subtracting(context.snippetIDs)
        guard await onDeleteSelection(historyItemIDs, context.snippetIDs) else {
            NSSound.beep()
            return
        }
    }

    private func toggleSaved(_ itemID: UUID) {
        guard model.beginSavedMutation(for: itemID) else { return }
        Task { @MainActor in
            _ = await controller.toggleSaved(id: itemID)
            model.finishSavedMutation(for: itemID)
        }
    }

    private func beginEditingSelectedSavedItem() {
        guard let id = model.selectedItemID else { return }
        if model.isSavedPresentation(id) {
            Task { @MainActor in
                guard let draft = await savedLibraryController.draft(for: id),
                      model.selectedItemID == id else { return }
                savedMetadataDraft = nil
                snippetEditorDraft = draft
            }
            return
        }
        guard let item = controller.items.first(where: { $0.id == id }),
              let metadata = item.savedMetadata else { return }
        snippetEditorDraft = nil
        savedMetadataDraft = ClipboardSavedMetadataDraft(
            id: item.id,
            title: metadata.title,
            tags: metadata.tags
        )
    }

    @ViewBuilder
    private func combinedExportButtons(itemIDs: [UUID]) -> some View {
        Button(localization.string("export.format.text", defaultValue: "Text File")) {
            onExportCombined(itemIDs, .plainText)
        }
        Button(localization.string("export.format.markdown", defaultValue: "Markdown")) {
            onExportCombined(itemIDs, .markdown)
        }
        Button(localization.string("export.format.html", defaultValue: "HTML")) {
            onExportCombined(itemIDs, .html)
        }
        Button(localization.string("export.format.pdf", defaultValue: "PDF")) {
            onExportCombined(itemIDs, .pdf)
        }
    }

    private func footerActionHint(
        key: String,
        action: String,
        isEnabled: Bool = true,
        shortcutDefinitionID: String? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        ClipboardHistoryInlineShortcutAction(
            shortcutDefinitionID: shortcutDefinitionID,
            shortcutSettingsContextProvider: shortcutSettingsContextProvider,
            changeShortcutTitle: localization.string(
                "panel.shortcuts.change",
                defaultValue: "Change Shortcut…"
            ),
            onShortcutChanged: { shortcutDisplayRevision &+= 1 },
            perform: perform
        ) {
            ClipboardHistoryInteractiveKeyboardHint(key: key, action: action)
        }
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private var footerExportMenu: some View {
        let entries = currentExportMenuEntries()
        if !model.actionItemIDs.isEmpty {
            ClipboardHistoryInlineShortcutAction(
                shortcutDefinitionID: ClipboardHistoryPlugin.ShortcutID.panelExport,
                shortcutSettingsContextProvider: shortcutSettingsContextProvider,
                changeShortcutTitle: localization.string(
                    "panel.shortcuts.change",
                    defaultValue: "Change Shortcut…"
                ),
                onShortcutChanged: { shortcutDisplayRevision &+= 1 },
                perform: { model.requestExportMenu() }
            ) {
                ClipboardHistoryInteractiveKeyboardHint(
                    key: panelShortcutText(
                        ClipboardHistoryPlugin.ShortcutID.panelExport,
                        fallback: "⌘E"
                    ),
                    action: localization.string("export.shortcut", defaultValue: "导出")
                )
            }
            .fixedSize()
            .disabled(model.runtimeStatus.isClearingHistory || entries.isEmpty)
            .accessibilityLabel(localization.string("export.shortcut", defaultValue: "导出"))
            .accessibilityHint(panelShortcutText(
                ClipboardHistoryPlugin.ShortcutID.panelExport,
                fallback: "⌘E"
            ))
        } else {
            PluginPaletteKeyboardHint(
                key: panelShortcutText(
                    ClipboardHistoryPlugin.ShortcutID.panelExport,
                    fallback: "⌘E"
                ),
                action: localization.string("export.shortcut", defaultValue: "导出")
            )
            .opacity(0.5)
        }
    }

    private func currentExportMenuEntries() -> [ClipboardHistoryExportMenuEntry] {
        if model.isMultiSelectionEnabled || selectedSavedItem != nil {
            return actionMenuEntries().filter { entry in
                switch entry.action {
                case .format, .combinedExport, .showInFinder, .copyToFolder:
                    true
                default:
                    false
                }
            }
        }
        guard let selectedItem else { return [] }
        return exportMenuEntries(for: selectedItem)
    }

    private func exportMenuEntries(
        for item: ClipboardHistoryItem
    ) -> [ClipboardHistoryExportMenuEntry] {
        if item.kind == .files {
            return [
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("export.showInFinder", defaultValue: "在访达中显示"),
                    action: .showInFinder
                ),
                ClipboardHistoryExportMenuEntry(
                    title: localization.string("export.copyToFolder", defaultValue: "复制到文件夹…"),
                    action: .copyToFolder
                ),
            ]
        }
        return ClipboardHistoryExportPlanner.options(for: item).map { option in
            ClipboardHistoryExportMenuEntry(
                title: ClipboardHistoryExportTitles.format(
                    option.format,
                    localization: localization
                ),
                action: .format(option.format)
            )
        }
    }

    private func performExportMenuAction(
        _ action: ClipboardHistoryExportMenuEntry.Action,
        for item: ClipboardHistoryItem
    ) {
        switch action {
        case let .format(format):
            onExport(item.id, format)
        case .showInFinder:
            onShowReferencedFiles(item.id)
        case .copyToFolder:
            onCopyReferencedFiles(item.id)
        case .paste, .pastePlainText, .copy, .copyCombined, .pasteCombined,
             .share, .combinedExport, .startQueue, .requestExport, .saveToLibrary, .delete,
             .createSnippet, .removeFromHistory, .removeFromSaved,
             .editSaved, .toggleMultiSelection, .toggleFocusedSelection,
             .toggleCollection, .ignoreNextCopy,
             .clearAll:
            return
        }
    }

    private func handleSearchFieldCommand(_ command: PluginPaletteSearchCommand) {
        switch command {
        case let .moveSelection(offset):
            model.moveSelection(by: offset)
        case .submit:
            if model.isMultiSelectionEnabled {
                if !model.actionItemIDs.isEmpty { performActionMenuAction(.pasteCombined) }
                return
            }
            guard let selectedItemID = model.selectedItemID else { return }
            pastePanelItem(selectedItemID, asPlainText: false)
        case .alternateSubmit:
            if model.isMultiSelectionEnabled {
                if !model.actionItemIDs.isEmpty { performActionMenuAction(.pasteCombined) }
                return
            }
            guard let selectedItemID = model.selectedItemID else { return }
            pastePanelItem(selectedItemID, asPlainText: true)
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
            ClipboardEmbeddedPreviewView(
                item: item,
                cache: previewCache,
                resetID: model.previewResetRevision,
                isActive: model.isPreviewPresentationActive
            ) { image in
                imagePreviewCanvas(image, showsTransparencyGrid: item.kind == .image)
            } unavailable: {
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
        if let color = ClipboardColorValue.literal(for: item) {
            ClipboardColorSwatchView(value: color, localization: localization)
        } else {
            nonLiteralColorDetailPreview(item)
        }
    }

    @ViewBuilder
    private func nonLiteralColorDetailPreview(_ item: ClipboardHistoryItem) -> some View {
        switch item.kind {
        case .image, .pdf:
            ClipboardEmbeddedPreviewView(
                item: item,
                cache: previewCache,
                resetID: model.previewResetRevision,
                isActive: model.isPreviewPresentationActive
            ) { image in
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } unavailable: {
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
        case .color:
            ClipboardNativeColorPreviewView(item: item, localization: localization)
        case .media:
            unavailablePreview(item)
        }
    }

    private func unavailablePreview(_ item: ClipboardHistoryItem) -> some View {
        Label(kindTitle(item.kind), systemImage: kindSystemImage(item.kind))
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func displayTitle(_ item: ClipboardHistoryItem) -> String {
        if let savedItem = model.savedItem(forPresentationID: item.id) {
            return savedItem.title
        }
        if model.mode == .saved, let title = item.savedMetadata?.title, !title.isEmpty {
            return title
        }
        return item.text.isEmpty ? kindTitle(item.kind) : item.text
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
        case .color: "paintpalette"
        case .media: "play.rectangle"
        }
    }

    private var activeFilterSystemImage: String {
        model.semanticFilter == .any
            ? filterSystemImage(model.contentFilter)
            : semanticFilterSystemImage(model.semanticFilter)
    }

    private func semanticFilterTitle(_ filter: ClipboardHistorySemanticFilter) -> String {
        switch filter {
        case .any:
            localization.string("panel.filter.anyContent", defaultValue: "任何内容")
        case .link:
            localization.string("content.kind.link", defaultValue: "链接")
        case .email:
            localization.string("content.kind.email", defaultValue: "电子邮件")
        case .recognizedText:
            localization.string("content.kind.recognizedText", defaultValue: "识别文字")
        }
    }

    private func semanticFilterSystemImage(_ filter: ClipboardHistorySemanticFilter) -> String {
        switch filter {
        case .any: "line.3.horizontal.decrease.circle"
        case .link: "link"
        case .email: "envelope"
        case .recognizedText: "text.viewfinder"
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

}

private struct ClipboardFilterOptionButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PluginSettingsTheme.Typography.secondaryLabel)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(
                isSelected
                    ? PluginSettingsTheme.Palette.activeControlBackground
                    : configuration.isPressed
                        ? PluginSettingsTheme.Palette.fieldBackground
                        : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum ClipboardHistoryActionPalettePlacement {
    static func origin(
        parentFrame: NSRect,
        paletteSize: NSSize,
        visibleFrame: NSRect,
        spacing: CGFloat = 10
    ) -> NSPoint {
        let preferredX = parentFrame.maxX + spacing
        let x = min(max(preferredX, visibleFrame.minX), visibleFrame.maxX - paletteSize.width)
        let preferredY = parentFrame.maxY - paletteSize.height
        let y = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - paletteSize.height)
        return NSPoint(x: x, y: y)
    }
}

@MainActor
final class ClipboardHistoryActionPaletteModel: ObservableObject {
    struct Section: Identifiable {
        let id: ClipboardHistoryExportMenuEntry.Group
        let entries: [ClipboardHistoryExportMenuEntry]
    }

    @Published private(set) var entries: [ClipboardHistoryExportMenuEntry] = []
    @Published private(set) var contextTitle = ""
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuildSections()
            selectedAction = filteredEntries.first?.action
        }
    }
    @Published var selectedAction: ClipboardHistoryExportMenuEntry.Action?
    @Published private(set) var sections: [Section] = []
    @Published private(set) var focusRequestID: UInt = 0
    @Published private(set) var keyboardScrollRevision: UInt = 0

    private(set) var filteredEntries: [ClipboardHistoryExportMenuEntry] = []

    func present(entries: [ClipboardHistoryExportMenuEntry], contextTitle: String) {
        self.entries = entries
        self.contextTitle = contextTitle
        if query.isEmpty {
            rebuildSections()
            selectedAction = filteredEntries.first?.action
        } else {
            query = ""
        }
        focusRequestID &+= 1
    }

    func dismiss() {
        entries = []
        contextTitle = ""
        query = ""
        filteredEntries = []
        sections = []
        selectedAction = nil
    }

    func requestKeyboardScroll() {
        keyboardScrollRevision &+= 1
    }

    private func rebuildSections() {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredEntries = ClipboardHistoryExportMenuEntry.visibleEntries(entries, query: normalizedQuery)
        let grouped = Dictionary(grouping: filteredEntries, by: \.group)
        sections = grouped.keys.sorted().map { Section(id: $0, entries: grouped[$0] ?? []) }
    }
}

@MainActor
private final class ClipboardHistoryActionPaletteController: NSObject, NSWindowDelegate {
    private final class PalettePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private let localization: PluginLocalization
    private let model: ClipboardHistoryActionPaletteModel
    private var panel: PalettePanel?
    private var hostingView: NSHostingView<ClipboardHistoryActionPalette>?
    private weak var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var shortcutEntries: [ClipboardHistoryExportMenuEntry] = []
    private var shortcutBindingsProvider: (() -> [String: ShortcutBinding])?
    private var shortcutSettingsContextProvider: (() -> PluginSettingsContext?)?
    private var onSelect: ((ClipboardHistoryExportMenuEntry.Action) -> Void)?
    private var isRecordingShortcut = false

    init(localization: PluginLocalization) {
        self.localization = localization
        self.model = ClipboardHistoryActionPaletteModel()
    }

    var isVisible: Bool { panel?.isVisible == true }
    var isKeyWindow: Bool { panel?.isKeyWindow == true }
    var hasActiveShortcutRecorder: Bool { isRecordingShortcut }

    func ownsKeyEvent(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        return panel.isVisible && panel.isKeyWindow && event.window === panel
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        guard ownsKeyEvent(event), panel?.attachedSheet == nil else { return false }
        let editor = event.window?.firstResponder as? NSTextView
        guard let action = ClipboardHistoryActionPaletteShortcuts.action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            entries: shortcutEntries,
            bindings: shortcutBindingsProvider?() ?? [:],
            isEditingText: editor?.isFieldEditor == true,
            hasSelectedText: (editor?.selectedRange().length ?? 0) > 0,
            hasMarkedText: editor?.hasMarkedText() == true,
            isRecordingShortcut: isRecordingShortcut
        ) else { return false }
        if !event.isARepeat { onSelect?(action) }
        return true
    }

    func show(
        entries: [ClipboardHistoryExportMenuEntry],
        contextTitle: String,
        relativeTo parentWindow: NSWindow,
        shortcutSettingsContextProvider: @escaping () -> PluginSettingsContext?,
        shortcutBindingsProvider: @escaping () -> [String: ShortcutBinding],
        onSelect: @escaping (ClipboardHistoryExportMenuEntry.Action) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        self.parentWindow = parentWindow
        self.onDismiss = onDismiss
        self.shortcutEntries = entries
        self.shortcutBindingsProvider = shortcutBindingsProvider
        self.onSelect = onSelect
        isRecordingShortcut = false
        self.shortcutSettingsContextProvider = shortcutSettingsContextProvider
        model.present(entries: entries, contextTitle: contextTitle)
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        reposition(relativeTo: parentWindow)
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func reposition(relativeTo parentWindow: NSWindow) {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        let visibleFrame = parentWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        panel.setFrameOrigin(ClipboardHistoryActionPalettePlacement.origin(
            parentFrame: parentWindow.frame,
            paletteSize: panel.frame.size,
            visibleFrame: visibleFrame
        ))
    }

    func dismiss(notify: Bool = true) {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parentWindow = nil
        shortcutEntries = []
        shortcutBindingsProvider = nil
        shortcutSettingsContextProvider = nil
        onSelect = nil
        isRecordingShortcut = false
        model.dismiss()
        let callback = onDismiss
        onDismiss = nil
        if notify {
            callback?()
        }
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = localization.string("common.actions", defaultValue: "Actions")
        panel.setAccessibilityTitle(localization.string("common.actions", defaultValue: "Actions"))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let hostingView = NSHostingView(rootView: ClipboardHistoryActionPalette(
            model: model,
            localization: localization,
            shortcutSettingsContextProvider: { [weak self] in self?.shortcutSettingsContextProvider?() },
            onShortcutRecordingChanged: { [weak self] in self?.isRecordingShortcut = $0 },
            onSelect: { [weak self] action in self?.onSelect?(action) },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        self.hostingView = hostingView
        panel.contentView = hostingView
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}

private struct ClipboardHistoryActionPalette: View {
    @ObservedObject var model: ClipboardHistoryActionPaletteModel
    let localization: PluginLocalization
    let shortcutSettingsContextProvider: () -> PluginSettingsContext?
    let onShortcutRecordingChanged: (Bool) -> Void
    let onSelect: (ClipboardHistoryExportMenuEntry.Action) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @State private var shortcutDisplayRevision: UInt = 0
    @State private var keyboardNavigationMouseLocation: NSPoint?

    private var filteredEntries: [ClipboardHistoryExportMenuEntry] {
        model.filteredEntries
    }

    var body: some View {
        VStack(spacing: 0) {
            PluginPaletteSearchToolbar(
                text: $model.query,
                placeholder: localization.string(
                    "panel.actions.search",
                    defaultValue: "Search actions…"
                ),
                accessibilityLabel: localization.string(
                    "panel.actions.search",
                    defaultValue: "Search actions…"
                ),
                accessibilityIdentifier: "mactools.clipboard-history.actions.search",
                clearAccessibilityLabel: localization.string("common.clear", defaultValue: "Clear"),
                focusRequestID: model.focusRequestID,
                onCommand: handleSearchCommand
            ) {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PluginPaletteToolbarControlStyle())
                .help(localization.string("common.close", defaultValue: "Close"))
                .accessibilityLabel(localization.string("common.close", defaultValue: "Close"))
            }
            .padding(PluginPaletteMetrics.contentPadding)

            if !model.contextTitle.isEmpty {
                Text(model.contextTitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.sections) { section in
                            Text(groupTitle(section.id))
                                .font(PluginSettingsTheme.Typography.secondaryLabel)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)

                            ForEach(section.entries) { entry in
                                actionRow(entry)
                                    .id(entry.action)
                            }
                        }

                        if filteredEntries.isEmpty {
                            ContentUnavailableView.search(text: model.query)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 390)
                .onChange(of: model.keyboardScrollRevision) { _, _ in
                    guard let action = model.selectedAction else { return }
                    proxy.scrollTo(action, anchor: .center)
                }
            }

            Divider()
            HStack {
                Text(localization.string("panel.actions.hint", defaultValue: "Type to filter actions"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                PluginPaletteKeyboardHint(
                    key: ClipboardHistoryFixedShortcut.display(ClipboardHistoryFixedShortcut.close),
                    action: localization.string("common.close", defaultValue: "Close")
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 430, height: 520)
        .background {
            ClipboardHistoryWindowSurface(role: .actions, reducesTransparency: accessibilityReduceTransparency)
        }
        .onChange(of: model.query) { _, _ in
            keyboardNavigationMouseLocation = nil
        }
    }

    private func actionRow(_ entry: ClipboardHistoryExportMenuEntry) -> some View {
        let isSelected = model.selectedAction == entry.action
        return ClipboardHistoryInlineShortcutAction(
            shortcutDefinitionID: entry.shortcutDefinitionID,
            shortcutSettingsContextProvider: shortcutSettingsContextProvider,
            changeShortcutTitle: localization.string(
                "panel.shortcuts.change",
                defaultValue: "Change Shortcut…"
            ),
            onShortcutChanged: { shortcutDisplayRevision &+= 1 },
            onRecordingChanged: onShortcutRecordingChanged,
            perform: { onSelect(entry.action) }
        ) {
            HStack(spacing: 10) {
                Image(systemName: entry.systemImage)
                    .frame(width: 20)
                Text(entry.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut = actionShortcutText(entry) {
                    Text(shortcut)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(isSelected ? selectedRowTextColor.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(isSelected ? selectedRowTextColor : Color.primary)
            .pluginPaletteSelectableRow(isSelected: isSelected)
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            let currentLocation = NSEvent.mouseLocation
            if let keyboardNavigationMouseLocation,
               hypot(
                   currentLocation.x - keyboardNavigationMouseLocation.x,
                   currentLocation.y - keyboardNavigationMouseLocation.y
               ) < 1
            {
                return
            }
            keyboardNavigationMouseLocation = nil
            guard model.selectedAction != entry.action else { return }
            model.selectedAction = entry.action
        }
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func actionShortcutText(_ entry: ClipboardHistoryExportMenuEntry) -> String? {
        guard let definitionID = entry.shortcutDefinitionID else { return entry.shortcut }
        return shortcutSettingsContextProvider()?.shortcutItem(definitionID: definitionID)?.bindingText
            ?? entry.shortcut
    }

    private func handleSearchCommand(_ command: PluginPaletteSearchCommand) {
        switch command {
        case let .moveSelection(offset):
            guard !filteredEntries.isEmpty else { return }
            keyboardNavigationMouseLocation = NSEvent.mouseLocation
            let currentIndex = model.selectedAction.flatMap { action in
                filteredEntries.firstIndex { $0.action == action }
            } ?? 0
            let nextIndex = ClipboardHistoryPanelModel.wrappedIndex(
                currentIndex + offset,
                count: filteredEntries.count
            )
            model.selectedAction = filteredEntries[nextIndex].action
            model.requestKeyboardScroll()
        case .submit, .alternateSubmit:
            guard let selectedAction = model.selectedAction else { return }
            onSelect(selectedAction)
        case .cancel:
            onDismiss()
        }
    }

    private func groupTitle(_ group: ClipboardHistoryExportMenuEntry.Group) -> String {
        switch group {
        case .item:
            localization.string("panel.actions.group.item", defaultValue: "Item Actions")
        case .exportAndShare:
            localization.string("panel.actions.group.export", defaultValue: "Export & Share")
        case .selection:
            localization.string("panel.actions.group.selection", defaultValue: "Selection Actions")
        case .history:
            localization.string("panel.actions.group.history", defaultValue: "History Actions")
        }
    }
}

struct ClipboardHistoryExportMenuEntry: Equatable, Identifiable {
    /// Rendering and keyboard navigation consume the same stable, grouped order.
    static func visibleEntries(_ entries: [Self], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = entries.filter { entry in
            query.isEmpty || ClipboardHistorySearch.matches(
                text: ([entry.title] + entry.keywords).joined(separator: " "), query: query
            )
        }
        return Group.allCases.flatMap { group in matching.filter { $0.group == group } }
    }

    enum Group: Int, CaseIterable, Comparable {
        case item
        case exportAndShare
        case selection
        case history

        static func < (lhs: Group, rhs: Group) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Action: Equatable, Hashable {
        case format(ClipboardExportFormat)
        case showInFinder
        case copyToFolder
        case paste
        case pastePlainText
        case copy
        case copyCombined
        case pasteCombined
        case share
        case combinedExport(ClipboardExportFormat)
        case startQueue
        case requestExport
        case saveToLibrary
        case createSnippet
        case delete
        case removeFromHistory
        case removeFromSaved
        case editSaved
        case toggleMultiSelection
        case toggleFocusedSelection
        case toggleCollection
        case ignoreNextCopy
        case clearAll
    }

    let title: String
    let action: Action
    let group: Group
    let systemImage: String
    let shortcut: String?
    let shortcutDefinitionID: String?
    let keywords: [String]

    init(
        title: String,
        action: Action,
        group: Group = .item,
        systemImage: String = "command",
        shortcut: String? = nil,
        shortcutDefinitionID: String? = nil,
        keywords: [String] = []
    ) {
        self.title = title
        self.action = action
        self.group = group
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.shortcutDefinitionID = shortcutDefinitionID
        self.keywords = keywords
    }

    var id: Action { action }
}

enum ClipboardHistoryActionPaletteShortcuts {
    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        entries: [ClipboardHistoryExportMenuEntry],
        bindings: [String: ShortcutBinding],
        isEditingText: Bool,
        hasSelectedText: Bool,
        hasMarkedText: Bool,
        isRecordingShortcut: Bool
    ) -> ClipboardHistoryExportMenuEntry.Action? {
        guard !hasMarkedText, !isRecordingShortcut else { return nil }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // Return submits the highlighted action, not necessarily the Paste row.
        guard !(flags.isEmpty && [36, 76, 53].contains(keyCode)) else { return nil }
        if isEditingText, !flags.intersection([.command, .option]).isEmpty,
           [123, 124, 125, 126].contains(keyCode) { return nil }
        if isEditingText, flags.contains(.command) {
            // Retain the field editor's selection, cut, paste, and undo behavior.
            if [0, 7, 9, 6].contains(keyCode) { return nil }
            if keyCode == 8, flags == .command, hasSelectedText { return nil }
        }
        let candidate = ShortcutBinding(keyCode: keyCode, modifiers: ShortcutModifiers.from(flags))
        return entries.first { entry in
            if let id = entry.shortcutDefinitionID {
                return bindings[id] == candidate
            }
            switch entry.action {
            case .copy:
                return keyCode == 8 && flags == .command
            case .pastePlainText:
                return [36, 76].contains(keyCode) && flags == .shift
            default:
                return false
            }
        }?.action
    }
}

@MainActor
private struct ClipboardHistoryExportMenuPresenter: NSViewRepresentable {
    let requestID: UInt
    let entries: () -> [ClipboardHistoryExportMenuEntry]
    let onSelect: (ClipboardHistoryExportMenuEntry.Action) -> Void

    func makeNSView(context: Context) -> ClipboardHistoryExportMenuAnchorView {
        let view = ClipboardHistoryExportMenuAnchorView()
        view.lastHandledRequestID = requestID
        view.configure(entries: entries, onSelect: onSelect)
        return view
    }

    func updateNSView(_ nsView: ClipboardHistoryExportMenuAnchorView, context: Context) {
        nsView.configure(entries: entries, onSelect: onSelect)
        nsView.presentMenuIfNeeded(requestID: requestID)
    }
}

@MainActor
private final class ClipboardHistoryExportMenuAnchorView: NSView {
    var lastHandledRequestID: UInt = 0

    private var entries: (() -> [ClipboardHistoryExportMenuEntry])?
    private var onSelect: ((ClipboardHistoryExportMenuEntry.Action) -> Void)?
    private var retainedTargets: [ClipboardHistoryExportMenuItemTarget] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    func configure(
        entries: @escaping () -> [ClipboardHistoryExportMenuEntry],
        onSelect: @escaping (ClipboardHistoryExportMenuEntry.Action) -> Void
    ) {
        self.entries = entries
        self.onSelect = onSelect
    }

    func presentMenuIfNeeded(requestID: UInt) {
        guard requestID != lastHandledRequestID else { return }
        lastHandledRequestID = requestID
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(presentMenu),
            object: nil
        )
        perform(#selector(presentMenu), with: nil, afterDelay: 0)
    }

    @objc private func presentMenu() {
        guard window != nil, let onSelect, let entries = entries?(), !entries.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        retainedTargets = entries.map { entry in
            let target = ClipboardHistoryExportMenuItemTarget(
                action: entry.action,
                onSelect: onSelect
            )
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(ClipboardHistoryExportMenuItemTarget.select(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.isEnabled = true
            menu.addItem(item)
            return target
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: bounds.minX, y: bounds.maxY + 4),
            in: self
        )
    }
}

@MainActor
private final class ClipboardHistoryExportMenuItemTarget: NSObject {
    private let action: ClipboardHistoryExportMenuEntry.Action
    private let onSelect: (ClipboardHistoryExportMenuEntry.Action) -> Void

    init(
        action: ClipboardHistoryExportMenuEntry.Action,
        onSelect: @escaping (ClipboardHistoryExportMenuEntry.Action) -> Void
    ) {
        self.action = action
        self.onSelect = onSelect
    }

    @objc func select(_ sender: NSMenuItem) {
        onSelect(action)
    }
}

private struct ClipboardHistoryInlineShortcutAction<Label: View>: View {
    let shortcutDefinitionID: String?
    let shortcutSettingsContextProvider: () -> PluginSettingsContext?
    let changeShortcutTitle: String
    var onShortcutChanged: () -> Void = {}
    var onRecordingChanged: (Bool) -> Void = { _ in }
    let perform: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isRecordingShortcut = false

    var body: some View {
        Button {
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true,
               canEditShortcut {
                isRecordingShortcut = true
            } else {
                perform()
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background {
            if canEditShortcut {
                PluginShortcutRecordingAnchor(
                    isPresented: $isRecordingShortcut,
                    onRecord: recordShortcut,
                    onBeginRecording: beginShortcutRecording,
                    onEndRecording: { onRecordingChanged(false) }
                )
            }
        }
        .contextMenu {
            if canEditShortcut {
                Button(changeShortcutTitle, systemImage: "keyboard") {
                    isRecordingShortcut = true
                }
            }
        }
    }

    private var shortcutItem: ShortcutSettingsItem? {
        guard let shortcutDefinitionID else { return nil }
        return shortcutSettingsContextProvider()?.shortcutItem(definitionID: shortcutDefinitionID)
    }

    private var canEditShortcut: Bool {
        shortcutItem != nil
    }

    private func beginShortcutRecording() {
        onRecordingChanged(true)
        guard let item = shortcutItem else { return }
        shortcutSettingsContextProvider()?.beginShortcutRecording(for: item.id)
    }

    private func recordShortcut(_ binding: ShortcutBinding) -> PluginShortcutRecordingResult {
        guard let item = shortcutItem, let context = shortcutSettingsContextProvider() else {
            return .rejected(changeShortcutTitle)
        }
        let result = context.recordShortcut(binding, for: item.id)
        if result == .accepted {
            onShortcutChanged()
        }
        return result
    }
}

private struct ClipboardHistoryInteractiveKeyboardHint: View {
    let key: String
    let action: String

    @State private var isHovering = false

    var body: some View {
        PluginPaletteKeyboardHint(key: key, action: action)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(
                isHovering ? Color.primary.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovering = $0 }
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
