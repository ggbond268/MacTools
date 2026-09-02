import AppKit
import Combine
import Foundation

@MainActor
protocol ClipboardCopyEventMonitoring: AnyObject {
    func start(onCopyOrCut: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class SystemClipboardCopyEventMonitor: ClipboardCopyEventMonitoring {
    private var monitor: Any?

    func start(onCopyOrCut: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isCopyOrCut(event) else { return }
            Task { @MainActor in onCopyOrCut() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func isCopyOrCut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers == [.command] else { return false }
        return event.keyCode == 8 || event.keyCode == 7 // C or X on the hardware keyboard.
    }
}

@MainActor
protocol ClipboardPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var captureComplexityIsWithinLimits: Bool { get }
    var requiresAsynchronousPayloadRead: Bool { get }
    var typeNames: Set<String> { get }
    func readPlainText() -> String?
    func readPlainTextAsynchronously(maximumByteCount: Int, expectedChangeCount: Int) async -> ClipboardPasteboardReadResult
    func readSemanticTextAsynchronously(maximumByteCount: Int, expectedChangeCount: Int) async -> ClipboardPasteboardReadResult
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult
    func readTypeNames(expectedChangeCount: Int) -> ClipboardPasteboardTypeReadResult
    func readPayload(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) -> ClipboardPasteboardReadResult
    func readPayloadAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult
    func cancelAsynchronousPayloadRead()
    @discardableResult func writePlainText(_ text: String) -> Bool
    @discardableResult func writePayload(_ payload: ClipboardHistoryPayload) -> Bool
}

enum ClipboardPasteboardReadResult: Equatable, Sendable {
    case payload(ClipboardHistoryPayload)
    case empty
    case oversized
    case tooManyObjects
    case changed
}

enum ClipboardPasteboardTypeReadResult: Equatable, Sendable {
    case types(Set<String>)
    case tooManyObjects
    case changed
}

extension ClipboardPasteboardAccess {
    var captureComplexityIsWithinLimits: Bool { true }
    var requiresAsynchronousPayloadRead: Bool { false }
    func readPlainText() -> String? { nil }

    func readPlainTextAsynchronously(maximumByteCount: Int, expectedChangeCount: Int) async -> ClipboardPasteboardReadResult {
        guard !Task.isCancelled, changeCount == expectedChangeCount else { return .changed }
        let text = readPlainText()
        guard !Task.isCancelled, changeCount == expectedChangeCount else { return .changed }
        guard let text else { return .empty }
        guard text.utf8.count <= maximumByteCount else { return .oversized }
        return .payload(.plainText(text))
    }

    func readSemanticTextAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        await readPlainTextAsynchronously(
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
    }

    func readTypeNames(expectedChangeCount: Int) -> ClipboardPasteboardTypeReadResult {
        guard changeCount == expectedChangeCount else { return .changed }
        guard captureComplexityIsWithinLimits else { return .tooManyObjects }
        let names = typeNames
        guard changeCount == expectedChangeCount else { return .changed }
        return .types(names)
    }

    func readPayload(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) -> ClipboardPasteboardReadResult {
        guard changeCount == expectedChangeCount else { return .changed }
        let result = readPayload(maximumByteCount: maximumByteCount)
        guard changeCount == expectedChangeCount else { return .changed }
        return result
    }

    func readPayloadAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        readPayload(
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
    }

    func cancelAsynchronousPayloadRead() {}
}

enum ClipboardPlainTextRewriteResult: Equatable, Sendable {
    case succeeded
    case imageTextRecognitionPending
    case imageTextUnavailable
    case unavailable
}

@MainActor
final class GeneralClipboardPasteboard: ClipboardPasteboardAccess {
    nonisolated static let maximumPasteboardItemCount = ClipboardPasteboardReaderWire.maximumPasteboardItemCount
    nonisolated static let maximumRepresentationCountPerItem = ClipboardPasteboardReaderWire.maximumRepresentationCountPerItem
    nonisolated static let maximumTotalRepresentationCount = ClipboardPasteboardReaderWire.maximumTotalRepresentationCount
    private let pasteboard: NSPasteboard
    private nonisolated let pasteboardName: NSPasteboard.Name
    private nonisolated let payloadReader: ClipboardPasteboardReaderProcess

    nonisolated var payloadReaderForTesting: ClipboardPasteboardReaderProcess { payloadReader }

    init(
        pasteboard: NSPasteboard = .general,
        resourceBundle: Bundle = .main,
        payloadReader: ClipboardPasteboardReaderProcess? = nil
    ) {
        self.pasteboard = pasteboard
        self.pasteboardName = pasteboard.name
        self.payloadReader = payloadReader ?? ClipboardPasteboardReaderProcess {
            resourceBundle.url(
                forResource: "mactools-clipboard-pasteboard-reader-helper",
                withExtension: nil,
                subdirectory: "PasteboardReaderHelper"
            )
        }
    }

    var changeCount: Int { pasteboard.changeCount }
    var requiresAsynchronousPayloadRead: Bool { true }

    var captureComplexityIsWithinLimits: Bool {
        Self.captureComplexityIsWithinLimits(pasteboard.pasteboardItems ?? [])
    }

    var typeNames: Set<String> {
        guard let sourceItems = pasteboard.pasteboardItems,
              Self.captureComplexityIsWithinLimits(sourceItems) else {
            return []
        }
        return Set(sourceItems.flatMap { $0.types.map(\.rawValue) })
    }

    func readTypeNames(expectedChangeCount: Int) -> ClipboardPasteboardTypeReadResult {
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        guard let sourceItems = pasteboard.pasteboardItems else {
            return pasteboard.changeCount == expectedChangeCount ? .types([]) : .changed
        }
        guard Self.captureComplexityIsWithinLimits(sourceItems) else {
            return pasteboard.changeCount == expectedChangeCount ? .tooManyObjects : .changed
        }
        let names = Set(sourceItems.flatMap { $0.types.map(\.rawValue) })
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        return .types(names)
    }

    nonisolated func readPlainTextAsynchronously(maximumByteCount: Int, expectedChangeCount: Int) async -> ClipboardPasteboardReadResult {
        guard !Task.isCancelled else { return .changed }
        let request = ClipboardPlainTextReadWork.request(
            pasteboardName: pasteboardName,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
        do {
            let response = try await payloadReader.read(request)
            guard !Task.isCancelled else { return .changed }
            return Self.readResult(from: response)
        } catch {
            return .changed
        }
    }

    nonisolated func readSemanticTextAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        guard !Task.isCancelled else { return .changed }
        let request = ClipboardPlainTextReadWork.semanticRequest(
            pasteboardName: pasteboardName,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
        do {
            let response = try await payloadReader.read(request)
            guard !Task.isCancelled else { return .changed }
            return Self.readResult(from: response)
        } catch {
            return .changed
        }
    }

    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult {
        Self.readPayload(from: pasteboard, maximumByteCount: maximumByteCount)
    }

    func readPayload(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) -> ClipboardPasteboardReadResult {
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        let result = readPayload(maximumByteCount: maximumByteCount)
        guard pasteboard.changeCount == expectedChangeCount else { return .changed }
        return result
    }

    nonisolated func readPayloadAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        guard !Task.isCancelled else { return .changed }
        let request = ClipboardPasteboardReaderRequest(
            pasteboardName: pasteboardName.rawValue,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
        do {
            let response = try await payloadReader.read(request)
            guard !Task.isCancelled else { return .changed }
            return Self.readResult(from: response)
        } catch {
            return .changed
        }
    }

    func cancelAsynchronousPayloadRead() {
        Task { await payloadReader.stop() }
    }

    private nonisolated static func readPayload(
        from pasteboard: NSPasteboard,
        maximumByteCount: Int
    ) -> ClipboardPasteboardReadResult {
        readResult(from: ClipboardPasteboardReaderWire.read(.init(
            pasteboardName: pasteboard.name.rawValue,
            maximumByteCount: maximumByteCount,
            expectedChangeCount: pasteboard.changeCount
        )))
    }

    nonisolated static func captureComplexityIsWithinLimits(
        _ sourceItems: [NSPasteboardItem]
    ) -> Bool {
        ClipboardPasteboardReaderWire.captureComplexityIsWithinLimits(sourceItems)
    }

    private nonisolated static func readResult(
        from response: ClipboardPasteboardReaderResponse
    ) -> ClipboardPasteboardReadResult {
        switch response.status {
        case .payload:
            let items = response.items.map { item in
                ClipboardStoredPasteboardItem(representations: item.representations.map {
                    ClipboardStoredRepresentation(typeIdentifier: $0.typeIdentifier, data: $0.data)
                })
            }
            return .payload(ClipboardHistoryPayload(pasteboardItems: items))
        case .empty:
            return .empty
        case .oversized:
            return .oversized
        case .tooManyObjects:
            return .tooManyObjects
        case .changed:
            return .changed
        case .unsafe:
            return .changed
        }
    }

    func writePlainText(_ text: String) -> Bool {
        writePayload(.plainText(text))
    }

    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool {
        let destinationObjects: [any NSPasteboardWriting] = payload.pasteboardItems.compactMap { storedItem in
            if let fileURLRepresentation = storedItem.representations.first(where: {
                $0.typeIdentifier == ClipboardRepresentationType.fileURL
            }),
               let value = String(data: fileURLRepresentation.data, encoding: .utf8),
               let fileURL = URL(
                   string: value.trimmingCharacters(in: .whitespacesAndNewlines)
               ),
               fileURL.isFileURL {
                // Native NSURL pasteboard writers provide the file representations Finder expects.
                return fileURL as NSURL
            }

            let destinationItem = NSPasteboardItem()
            var wroteRepresentation = false
            for representation in storedItem.representations {
                let type = NSPasteboard.PasteboardType(representation.typeIdentifier)
                let succeeded: Bool
                if [
                    ClipboardRepresentationType.plainText,
                    ClipboardRepresentationType.fileURL,
                    ClipboardRepresentationType.url,
                ].contains(representation.typeIdentifier),
                   let value = String(data: representation.data, encoding: .utf8) {
                    succeeded = destinationItem.setString(value, forType: type)
                } else {
                    succeeded = destinationItem.setData(representation.data, forType: type)
                }
                wroteRepresentation = wroteRepresentation || succeeded
            }
            return wroteRepresentation ? destinationItem : nil
        }
        guard !destinationObjects.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(destinationObjects)
    }
}

@MainActor
protocol ClipboardSourceContextProviding: AnyObject {
    func frontmostApplication() -> ClipboardSourceApplication?
    func takeRecentlyActivatedApplications() -> [ClipboardSourceApplication]
    func discardRecentlyActivatedApplications()
}

extension ClipboardSourceContextProviding {
    func takeRecentlyActivatedApplications() -> [ClipboardSourceApplication] { [] }
    func discardRecentlyActivatedApplications() {}
}

@MainActor
final class WorkspaceClipboardSourceContextProvider: NSObject, ClipboardSourceContextProviding {
    private var recentlyActivatedApplicationsByBundleID: [String: ClipboardSourceApplication] = [:]

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func frontmostApplication() -> ClipboardSourceApplication? {
        Self.sourceApplication(from: NSWorkspace.shared.frontmostApplication)
    }

    func takeRecentlyActivatedApplications() -> [ClipboardSourceApplication] {
        defer { recentlyActivatedApplicationsByBundleID.removeAll(keepingCapacity: true) }
        return Array(recentlyActivatedApplicationsByBundleID.values)
    }

    func discardRecentlyActivatedApplications() {
        recentlyActivatedApplicationsByBundleID.removeAll(keepingCapacity: true)
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let sourceApplication = Self.sourceApplication(from: application) else {
            return
        }
        recentlyActivatedApplicationsByBundleID[sourceApplication.bundleIdentifier.lowercased()] =
            sourceApplication
    }

    private static func sourceApplication(
        from application: NSRunningApplication?
    ) -> ClipboardSourceApplication? {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }
        return ClipboardSourceApplication(
            bundleIdentifier: bundleIdentifier,
            name: application.localizedName ?? bundleIdentifier
        )
    }
}

private final class ClipboardHistoryPersistenceWorker: @unchecked Sendable {
    struct SaveOutcome: @unchecked Sendable {
        let revision: UInt64
        let durableItems: [ClipboardHistoryItem]
        let error: (any Error)?
        let latestFailure: (revision: UInt64, error: any Error)?
    }

    private struct SaveRequest {
        var mutations: [ClipboardHistoryMutation]
        var revision: UInt64
        var completions: [@Sendable (SaveOutcome) -> Void]
        let isBarrier: Bool
        let deletingSavedItemIDs: Set<UUID>
    }

    private let persistence: any ClipboardHistoryPersisting
    private let queue = DispatchQueue(label: "cc.ggbond.mactools.clipboard-history.persistence")
    private let lock = NSLock()
    private var pendingSaves: [SaveRequest] = []
    private var isDraining = false
    private var durableItems: [ClipboardHistoryItem] = []
    private var latestFailure: (revision: UInt64, error: any Error)?

    init(persistence: any ClipboardHistoryPersisting) {
        self.persistence = persistence
    }

    func load() async throws -> [ClipboardHistoryItem] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let loadedItems = try persistence.load()
                    durableItems = loadedItems
                    latestFailure = nil
                    continuation.resume(returning: loadedItems)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func saveBarrier(
        _ mutation: ClipboardHistoryMutation,
        revision: UInt64,
        deletingSavedItemIDs: Set<UUID> = []
    ) async -> SaveOutcome {
        await withCheckedContinuation { continuation in
            enqueue(
                mutation,
                revision: revision,
                isBarrier: true,
                deletingSavedItemIDs: deletingSavedItemIDs
            ) { continuation.resume(returning: $0) }
        }
    }

    func enqueueSave(
        _ mutation: ClipboardHistoryMutation,
        revision: UInt64,
        completion: @escaping @Sendable (SaveOutcome) -> Void
    ) {
        enqueue(
            mutation,
            revision: revision,
            isBarrier: false,
            deletingSavedItemIDs: [],
            completion: completion
        )
    }

    private func enqueue(_ mutation: ClipboardHistoryMutation, revision: UInt64, isBarrier: Bool,
                         deletingSavedItemIDs: Set<UUID>,
                         completion: @escaping @Sendable (SaveOutcome) -> Void) {
        let shouldStart = lock.withLock {
            if !isBarrier, let last = pendingSaves.indices.last, !pendingSaves[last].isBarrier {
                pendingSaves[last].mutations.append(mutation)
                pendingSaves[last].revision = revision
                pendingSaves[last].completions.append(completion)
            } else {
                pendingSaves.append(SaveRequest(
                    mutations: [mutation],
                    revision: revision,
                    completions: [completion],
                    isBarrier: isBarrier,
                    deletingSavedItemIDs: deletingSavedItemIDs
                ))
            }
            guard !isDraining else { return false }
            isDraining = true
            return true
        }
        guard shouldStart else { return }
        queue.async { [weak self] in
            self?.drainSaves()
        }
    }

    func reset() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let result = Result {
                    try persistence.reset()
                    durableItems = []
                    latestFailure = nil
                    try persistence.prepare()
                }
                continuation.resume(with: result)
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func drainSaves() {
        while true {
            guard let request = lock.withLock({ () -> SaveRequest? in
                guard !pendingSaves.isEmpty else {
                    isDraining = false
                    return nil
                }
                return pendingSaves.removeFirst()
            }) else {
                return
            }

            let outcome = persist(
                request.mutations,
                revision: request.revision,
                requiresTargets: request.isBarrier,
                deletingSavedItemIDs: request.deletingSavedItemIDs
            )
            request.completions.forEach { $0(outcome) }
        }
    }

    private func persist(
        _ mutations: [ClipboardHistoryMutation],
        revision: UInt64,
        requiresTargets: Bool,
        deletingSavedItemIDs: Set<UUID>
    ) -> SaveOutcome {
        do {
            let combined = ClipboardHistoryMutation(changes: mutations.flatMap(\.changes))
            if requiresTargets {
                let ids = Set(durableItems.map(\.id))
                guard !combined.changes.contains(where: {
                    $0.before != nil && $0.after != nil && !ids.contains($0.id)
                }) else { throw ClipboardHistoryPayloadAccessError.unavailable }
            }
            let items = combined.applying(to: durableItems)
            if deletingSavedItemIDs.isEmpty {
                try persistence.saveChanges(items, applying: combined)
            } else if let unifiedPersistence = persistence as? any ClipboardUnifiedDeletionPersisting {
                try unifiedPersistence.saveChanges(
                    items,
                    applying: combined,
                    deletingSavedItemIDs: deletingSavedItemIDs
                )
            } else {
                throw ClipboardHistoryStoreError.unavailableStorage
            }
            durableItems = items
            return SaveOutcome(revision: revision, durableItems: items, error: nil, latestFailure: latestFailure)
        } catch {
            latestFailure = (revision, error)
            return SaveOutcome(revision: revision, durableItems: durableItems, error: error, latestFailure: latestFailure)
        }
    }
}

@MainActor
final class ClipboardHistoryController: NSObject, ObservableObject {
    static let maximumSynchronousCaptureByteCount = 256 * 1_024
    static let imageTextIndexBatchSize = 25
    static let maximumBackgroundImageTextIndexItemCount = 100
    static let sourceApplicationAttributionGraceInterval: TimeInterval = 1.5

    private enum ItemMutation {
        case content
    }

    struct ItemsUpdate {
        let items: [ClipboardHistoryItem]
        let revision: UInt64
        /// Nil requests full reconciliation (load, deletion, retention or recovery).
        let changedIDs: Set<UUID>?
    }

    let itemUpdates = PassthroughSubject<ItemsUpdate, Never>()
    private var publicationChangedIDs: Set<UUID>?
    private(set) var presentationRevision: UInt64 = 0
    @Published private(set) var items: [ClipboardHistoryItem] = [] {
        didSet {
            presentationRevision &+= 1
            itemUpdates.send(ItemsUpdate(
                items: items,
                revision: presentationRevision,
                changedIDs: publicationChangedIDs
            ))
        }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var storageError: ClipboardHistoryStoreError?
    @Published private(set) var isLoaded = false
    @Published private(set) var isIgnoringNextCopy = false
    @Published private var itemMutation: ItemMutation?
    @Published private(set) var isCaptureBlockedByProtectedItems = false

    /// Only content mutations disable the panel. Saving a bookmark still holds
    /// the persistence barrier, but must not dim every control while it commits.
    var isClearingHistory: Bool { itemMutation == .content }

    private var isMutatingItems: Bool { itemMutation != nil }

    var onChange: (() -> Void)?
    var onCaptureSuppressionEvent: ((ClipboardCaptureSuppressionEvent) -> Void)?
    var onPrivateCopyLeaseChange: ((ClipboardPrivateCopyLease?) -> Void)?
    var onCaptureRejection: ((ClipboardCaptureIgnoreReason, Int) -> Void)?
    var onExternalPasteboardChange: (() -> Void)?
    var onWillClearHistory: (() -> Void)?
    var onWillResetPersistentHistory: (() -> Void)?
    var onItemCaptured: ((UUID) -> Void)?

    let settings: ClipboardHistorySettingsStore
    var currentPasteboardVersion: Int { pasteboard.changeCount }

    private let pasteboard: any ClipboardPasteboardAccess
    private let sourceContext: any ClipboardSourceContextProviding
    private let persistence: any ClipboardHistoryPersisting
    private let persistenceWorker: ClipboardHistoryPersistenceWorker
    private let monitoringInterval: TimeInterval
    private let captureSuppressionSettlingInterval: TimeInterval
    private let imageIndexBatchPauseNanoseconds: UInt64
    private let imageTextRecognizer: any ClipboardImageTextRecognizing
    private let errorMessageProvider: (Error) -> String
    private let copyEventMonitor: (any ClipboardCopyEventMonitoring)?

    private var timer: Timer?
    private var retentionTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var imageIndexingTask: Task<Void, Never>?
    private var imageIndexBatchContinuationTask: Task<Void, Never>?
    private var continuesBackgroundImageIndexing = false
    private var remainingBackgroundImageTextIndexItemCount = 0
    private var imageIndexPersistenceTask: Task<Void, Never>?
    private var hasPendingImageIndexPersistence = false
    private var pendingImageIndexPersistenceCount = 0
    private var pendingImageIndexItemIDs: [UUID] = []
    private var pendingImageIndexItemIDSet = Set<UUID>()
    private var imageIndexAttemptedItemIDs = Set<UUID>()
    private var captureProcessingTask: Task<Void, Never>?
    private var pasteboardPayloadReadTask: Task<Void, Never>?
    private var eventAssistedCaptureTask: Task<Void, Never>?
    private var pasteboardPayloadReadGeneration: UInt64 = 0
    private var captureProcessingGeneration: UInt64 = 0
    private var captureProcessingSequence: UInt64 = 0
    private var capturePolicyRevision: UInt64 = 0
    private var captureSuppressionTask: Task<Void, Never>?
    private var captureSuppressionGeneration: UInt64 = 0
    private var captureSuppressionHardDeadline: TimeInterval?
    private var hasObservedSuppressedChange = false
    private var captureSuppressionMode: ClipboardCaptureSuppressionMode?
    private var persistenceRevision: UInt64 = 0
    private var acknowledgedPersistenceRevision: UInt64 = 0
    private var submittedItems: [ClipboardHistoryItem] = []
    private var pendingMutations: [(revision: UInt64, mutation: ClipboardHistoryMutation, isPublished: Bool)] = []
    private var durableMutationTask: Task<Bool, Never>?
    private var durableMutationSequence: UInt64 = 0
    private var pendingDurableItemIDReferenceCounts: [UUID: Int] = [:]
    private var pendingDeletedItemIDs = Set<UUID>()
    private var storageGeneration: UInt64 = 0
    private var reloadAfterStop = false
    private var needsSettingsReconciliation = false
    private var lastSeenChangeCount: Int
    private var lastObservedFrontmostApplication: ClipboardSourceApplication?
    private var recentSourceApplicationAttribution: [
        String: (application: ClipboardSourceApplication, expiresAt: Date)
    ] = [:]
    private var currentHistoryItemPasteboardState: (itemID: UUID, changeCount: Int)?
    private var retentionProtectedItemIDs = Set<UUID>()
    private var effectiveRetentionProtectedItemIDs: Set<UUID> {
        retentionProtectedItemIDs.union(pendingDurableItemIDReferenceCounts.keys)
    }

    private var hasPendingDurableItemIDs: Bool {
        !pendingDurableItemIDReferenceCounts.isEmpty
    }

    var pendingDurableItemIDsForTesting: Set<UUID> {
        Set(pendingDurableItemIDReferenceCounts.keys)
    }

    init(
        settings: ClipboardHistorySettingsStore,
        pasteboard: any ClipboardPasteboardAccess = GeneralClipboardPasteboard(),
        sourceContext: any ClipboardSourceContextProviding = WorkspaceClipboardSourceContextProvider(),
        persistence: any ClipboardHistoryPersisting,
        monitoringInterval: TimeInterval = 0.5,
        captureSuppressionSettlingInterval: TimeInterval = 0.75,
        imageIndexBatchPauseNanoseconds: UInt64 = 2_000_000_000,
        imageTextRecognizer: any ClipboardImageTextRecognizing = VisionClipboardImageTextRecognizer(),
        copyEventMonitor: (any ClipboardCopyEventMonitoring)? = nil,
        errorMessageProvider: @escaping (Error) -> String = { $0.localizedDescription }
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.sourceContext = sourceContext
        self.persistence = persistence
        self.persistenceWorker = ClipboardHistoryPersistenceWorker(persistence: persistence)
        self.monitoringInterval = monitoringInterval
        self.captureSuppressionSettlingInterval = captureSuppressionSettlingInterval
        self.imageIndexBatchPauseNanoseconds = imageIndexBatchPauseNanoseconds
        self.imageTextRecognizer = imageTextRecognizer
        self.copyEventMonitor = copyEventMonitor
        self.errorMessageProvider = errorMessageProvider
        self.lastSeenChangeCount = pasteboard.changeCount
        super.init()
    }

    var recentItemIDsForSequentialPaste: [UUID] {
        Array(items.lazy.filter(\.isInHistory)
            .prefix(ClipboardSequentialPasteSession.maximumItemCount).map(\.id))
    }

    var savedItems: [ClipboardHistoryItem] {
        items.filter(\.isSaved)
    }

    var historyItems: [ClipboardHistoryItem] {
        items.filter(\.isInHistory)
    }

    func updateSequentialPasteProtectedItemIDs(_ itemIDs: Set<UUID>) {
        guard retentionProtectedItemIDs != itemIDs else { return }
        retentionProtectedItemIDs = itemIDs
        settingsDidChange()
    }

    var usage: ClipboardHistoryUsage {
        ClipboardHistoryUsage(items: items.filter(\.isInHistory))
    }

    var isCollectionOperational: Bool {
        isLoaded && errorMessage == nil && !isClearingHistory
    }

    var canResetUnreadablePersistentHistory: Bool {
        return switch storageError {
        case .missingEncryptionKey, .invalidEncryptionKey, .invalidEnvelope,
             .authenticationFailed, .historyTooLarge:
            true
        default:
            false
        }
    }

    var canSuppressNextCapture: Bool {
        isCollectionOperational && !settings.isPaused && timer != nil
    }

    func start() {
        copyEventMonitor?.start { [weak self] in self?.scheduleEventAssistedCapture() }
        if reloadAfterStop {
            reloadAfterStop = false
            isLoaded = false
        }
        guard loadTask == nil, !isLoaded else {
            startMonitoringIfPossible()
            return
        }

        seedSourceApplicationAttribution()
        if !isIgnoringNextCopy {
            lastSeenChangeCount = pasteboard.changeCount
        }
        let worker = persistenceWorker
        loadTask = Task { [weak self] in
            do {
                let loadedItems = try await worker.load()
                guard !Task.isCancelled else { return }
                self?.finishLoading(loadedItems)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishLoading(with: error)
            }
        }
    }

    func stop() {
        reloadAfterStop = true
        durableMutationTask?.cancel()
        durableMutationTask = nil
        pendingDurableItemIDReferenceCounts.removeAll()
        pendingDeletedItemIDs.removeAll()
        itemMutation = nil
        timer?.invalidate()
        timer = nil
        copyEventMonitor?.stop()
        eventAssistedCaptureTask?.cancel()
        eventAssistedCaptureTask = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        loadTask?.cancel()
        loadTask = nil
        cancelPendingCaptureProcessing()
        cancelPendingPasteboardPayloadRead()
        cancelImageIndexing()
        flushPendingImageIndexPersistence()
        storageGeneration &+= 1
        isLoaded = false
        currentHistoryItemPasteboardState = nil
        clearCaptureSuppression(notifyCancellation: false, clearsPrivateCopyLease: false)
        discardSourceApplicationAttribution()
        persistenceWorker.flush()
    }

    func removePersistentDataForUninstall() {
        stop()
        do {
            try persistence.removeAll()
            items = []
            refreshProtectedCapacityState()
            errorMessage = nil
            storageError = nil
            notifyChanged()
        } catch {
            errorMessage = errorMessageProvider(error)
            storageError = error as? ClipboardHistoryStoreError
            notifyChanged()
        }
    }

    func settingsDidChange() {
        capturePolicyRevision &+= 1
        if hasPendingDurableItemIDs { needsSettingsReconciliation = true }
        if settings.isPaused {
            copyEventMonitor?.stop()
            eventAssistedCaptureTask?.cancel()
            eventAssistedCaptureTask = nil
            cancelPendingCaptureProcessing()
            cancelPendingPasteboardPayloadRead()
            timer?.invalidate()
            timer = nil
            discardSourceApplicationAttribution()
        } else {
            copyEventMonitor?.start { [weak self] in self?.scheduleEventAssistedCapture() }
            if timer == nil, isLoaded, errorMessage == nil, !isIgnoringNextCopy {
                // Resuming deliberately ignores changes made while collection was paused.
                seedSourceApplicationAttribution()
                lastSeenChangeCount = pasteboard.changeCount
            }
            startMonitoringIfPossible()
        }
        guard !isMutatingItems else {
            needsSettingsReconciliation = true
            notifyChanged()
            return
        }
        let pruned = ClipboardRetentionPolicy.prune(
            items,
            settings: settings.snapshot,
            protectedItemIDs: effectiveRetentionProtectedItemIDs
        )
        if pruned != items {
            items = pruned
            persistCurrentItems()
        }
        refreshProtectedCapacityState()
        notifyChanged()
    }

    func retryStorageAccess() {
        guard loadTask == nil, !isMutatingItems else { return }
        storageGeneration &+= 1
        durableMutationTask?.cancel()
        durableMutationTask = nil
        pendingDurableItemIDReferenceCounts.removeAll()
        pendingDeletedItemIDs.removeAll()
        timer?.invalidate()
        timer = nil
        errorMessage = nil
        storageError = nil
        isLoaded = false
        notifyChanged()
        start()
    }

    func processPasteboardChange(now: Date = Date()) {
        guard isLoaded, errorMessage == nil, !settings.isPaused else { return }
        guard pasteboardPayloadReadTask == nil else { return }
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastSeenChangeCount else {
            // Track the stable foreground owner between clipboard changes. If focus moves while a
            // copy is still being committed, the next delta is conservatively attributed to both
            // the previous and current applications.
            lastObservedFrontmostApplication = sourceContext.frontmostApplication()
            retainSourceApplicationAttribution(
                sourceContext.takeRecentlyActivatedApplications(),
                now: now
            )
            return
        }
        lastSeenChangeCount = currentChangeCount
        currentHistoryItemPasteboardState = nil
        // Internal writes advance `lastSeenChangeCount` at their source. A delta that reaches the
        // monitor is therefore external and must end an implicit queue before retention runs.
        onExternalPasteboardChange?()

        // Consume suppression before asking for types, source context, or text. Private copies must
        // never cross the payload-reading boundary, even briefly in memory.
        if suppressPasteboardChangeIfNeeded() {
            discardSourceApplicationAttribution()
            return
        }
        guard !isMutatingItems else { return }

        let currentSettings = settings.snapshot
        if isCaptureBlockedByProtectedItems {
            onCaptureRejection?(.historyCapacityFull, currentSettings.maximumItemCount)
            return
        }

        retainSourceApplicationAttribution(
            sourceContext.takeRecentlyActivatedApplications(),
            now: now
        )
        let recentlyActivatedApplications = takeSourceApplicationAttribution(now: now)
        let previousSourceApplication = lastObservedFrontmostApplication
        let sourceApplication = sourceContext.frontmostApplication()
        lastObservedFrontmostApplication = sourceApplication
        let possibleSourceApplications = recentlyActivatedApplications
            + [previousSourceApplication, sourceApplication].compactMap { $0 }
        guard !possibleSourceApplications.contains(where: {
            Self.isExcluded($0, settings: currentSettings)
        }) else {
            return
        }

        let typeNames: Set<String>
        switch pasteboard.readTypeNames(expectedChangeCount: currentChangeCount) {
        case let .types(names):
            typeNames = names
        case .tooManyObjects:
            onCaptureRejection?(.tooManyObjects, GeneralClipboardPasteboard.maximumPasteboardItemCount)
            return
        case .changed:
            return
        }
        guard ClipboardCapturePolicy.preflight(
            types: typeNames,
            sourceApplication: sourceApplication,
            settings: currentSettings
        ) == nil else {
            return
        }

        if pasteboard.requiresAsynchronousPayloadRead {
            beginAsynchronousPasteboardPayloadRead(
                maximumByteCount: currentSettings.maximumItemByteCount,
                expectedChangeCount: currentChangeCount,
                sourceApplication: sourceApplication,
                capturedAt: now
            )
            return
        }
        handlePasteboardPayloadReadResult(
            pasteboard.readPayload(
                maximumByteCount: currentSettings.maximumItemByteCount,
                expectedChangeCount: currentChangeCount
            ),
            sourceApplication: sourceApplication,
            changeCount: currentChangeCount,
            capturedAt: now
        )
    }

    private func scheduleEventAssistedCapture() {
        guard isLoaded, errorMessage == nil, !settings.isPaused else { return }
        eventAssistedCaptureTask?.cancel()
        let initialChangeCount = pasteboard.changeCount
        eventAssistedCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [10, 30, 80, 160] {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
                guard !Task.isCancelled else { return }
                if self.pasteboard.changeCount != initialChangeCount {
                    self.processPasteboardChange()
                    self.eventAssistedCaptureTask = nil
                    return
                }
            }
            self.eventAssistedCaptureTask = nil
        }
    }

    private func beginAsynchronousPasteboardPayloadRead(
        maximumByteCount: Int,
        expectedChangeCount: Int,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date
    ) {
        let pasteboard = pasteboard
        pasteboardPayloadReadGeneration &+= 1
        let generation = pasteboardPayloadReadGeneration
        pasteboardPayloadReadTask = Task { @MainActor [weak self] in
            let result = await pasteboard.readPayloadAsynchronously(
                maximumByteCount: maximumByteCount,
                expectedChangeCount: expectedChangeCount
            )
            guard let self else { return }
            self.pasteboardPayloadReadTask = nil
            guard !Task.isCancelled,
                  self.pasteboardPayloadReadGeneration == generation,
                  self.pasteboard.changeCount == expectedChangeCount else {
                return
            }
            self.handlePasteboardPayloadReadResult(
                result,
                sourceApplication: sourceApplication,
                changeCount: expectedChangeCount,
                capturedAt: capturedAt
            )
        }
    }

    private func handlePasteboardPayloadReadResult(
        _ result: ClipboardPasteboardReadResult,
        sourceApplication: ClipboardSourceApplication?,
        changeCount currentChangeCount: Int,
        capturedAt: Date
    ) {
        guard !isMutatingItems, errorMessage == nil else { return }
        let currentSettings = settings.snapshot
        let payload: ClipboardHistoryPayload
        switch result {
        case let .payload(capturedPayload):
            payload = capturedPayload
        case .empty:
            return
        case .oversized:
            onCaptureRejection?(.oversized, currentSettings.maximumItemByteCount)
            return
        case .tooManyObjects:
            onCaptureRejection?(.tooManyObjects, GeneralClipboardPasteboard.maximumPasteboardItemCount)
            return
        case .changed:
            return
        }

        guard ClipboardCapturePolicy.preflight(
            types: Set(payload.representations.map(\.typeIdentifier)),
            sourceApplication: sourceApplication,
            settings: currentSettings
        ) == nil else {
            return
        }

        if captureProcessingTask != nil
            || payload.byteCount > Self.maximumSynchronousCaptureByteCount
            || items.first?.isSearchTextTruncated == true {
            enqueueCaptureProcessing(
                payload: payload,
                sourceApplication: sourceApplication,
                changeCount: currentChangeCount,
                capturedAt: capturedAt
            )
            return
        }
        let decision = ClipboardCapturePolicy.evaluatePayload(
            payload,
            sourceApplication: sourceApplication,
            settings: currentSettings,
            newestItem: items.first(where: { $0.isInHistory && !pendingDeletedItemIDs.contains($0.id) }),
            now: capturedAt
        )
        applyCaptureDecision(
            decision,
            settings: currentSettings,
            changeCount: currentChangeCount
        )
    }

    private static func isExcluded(
        _ sourceApplication: ClipboardSourceApplication?,
        settings: ClipboardHistorySettings
    ) -> Bool {
        guard let bundleIdentifier = sourceApplication?.bundleIdentifier else { return false }
        return settings.excludedApplications.contains {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    func waitForCaptureProcessingForTesting() async {
        await captureProcessingTask?.value
    }

    private func enqueueCaptureProcessing(
        payload: ClipboardHistoryPayload,
        sourceApplication: ClipboardSourceApplication?,
        changeCount: Int,
        capturedAt: Date
    ) {
        let previousTask = captureProcessingTask
        let generation = captureProcessingGeneration
        captureProcessingSequence &+= 1
        let sequence = captureProcessingSequence
        captureProcessingTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard !Task.isCancelled,
                  let self,
                  self.captureProcessingGeneration == generation,
                  !self.isMutatingItems,
                  self.errorMessage == nil else {
                return
            }
            defer {
                if self.captureProcessingSequence == sequence {
                    self.captureProcessingTask = nil
                }
            }
            while true {
                guard !Task.isCancelled,
                      self.captureProcessingGeneration == generation,
                      !self.isMutatingItems,
                      self.errorMessage == nil else {
                    return
                }
                let policyRevision = self.capturePolicyRevision
                let settings = self.settings.snapshot
                guard ClipboardCapturePolicy.preflight(
                    types: Set(payload.representations.map(\.typeIdentifier)),
                    sourceApplication: sourceApplication,
                    settings: settings
                ) == nil else { return }
                let newestItem = self.items.first(where: {
                    $0.isInHistory && !self.pendingDeletedItemIDs.contains($0.id)
                })
                let worker = Task.detached(priority: .userInitiated) {
                    ClipboardCapturePolicy.evaluatePayload(
                        payload,
                        sourceApplication: sourceApplication,
                        settings: settings,
                        newestItem: newestItem,
                        now: capturedAt
                    )
                }
                let decision = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled,
                      self.captureProcessingGeneration == generation,
                      !self.isMutatingItems,
                      self.errorMessage == nil else {
                    return
                }
                guard self.capturePolicyRevision == policyRevision else {
                    continue
                }
                self.applyCaptureDecision(
                    decision,
                    settings: settings,
                    changeCount: changeCount
                )
                break
            }
        }
    }

    private func applyCaptureDecision(
        _ decision: ClipboardCaptureDecision,
        settings currentSettings: ClipboardHistorySettings,
        changeCount currentChangeCount: Int
    ) {
        switch decision {
        case let .capture(capturedItem):
            let existingIndex = items.firstIndex { $0.payloadDigest == capturedItem.payloadDigest }
            if let existingIndex,
               let recaptured = items[existingIndex].recaptured(from: capturedItem) {
                var candidates = items
                candidates.remove(at: existingIndex)
                candidates.insert(recaptured, at: 0)
                applyCapturedItem(
                    recaptured,
                    candidates: candidates,
                    settings: currentSettings,
                    changeCount: currentChangeCount
                )
                return
            }
            self.applyCapturedItem(
                capturedItem,
                candidates: [capturedItem] + items,
                settings: currentSettings,
                changeCount: currentChangeCount
            )
            return
        case let .ignore(reason):
            if reason == .duplicateNewestItem,
               let newestItem = items.first(where: \.isInHistory) {
                if pasteboard.changeCount == currentChangeCount {
                    currentHistoryItemPasteboardState = (
                        itemID: newestItem.id,
                        changeCount: currentChangeCount
                    )
                }
            }
            if reason == .oversized {
                onCaptureRejection?(.oversized, currentSettings.maximumItemByteCount)
            }
            return
        }
    }

    private func applyCapturedItem(
        _ item: ClipboardHistoryItem,
        candidates: [ClipboardHistoryItem],
        settings currentSettings: ClipboardHistorySettings,
        changeCount currentChangeCount: Int
    ) {
        let retention = ClipboardRetentionPolicy.evaluate(
            candidates,
            settings: currentSettings,
            protectedItemIDs: effectiveRetentionProtectedItemIDs
        )
        let updated = retention.items
        guard updated.contains(where: { $0.id == item.id && $0.isInHistory }) else {
            if item.payloadByteCount > currentSettings.maximumTotalPayloadByteCount {
                onCaptureRejection?(.oversized, currentSettings.maximumTotalPayloadByteCount)
            } else {
                onCaptureRejection?(.historyCapacityFull, currentSettings.maximumItemCount)
            }
            return
        }
        guard updated != items else {
            return
        }
        items = updated
        isCaptureBlockedByProtectedItems = retention.isCaptureBlockedByProtectedItems
        if pasteboard.changeCount == currentChangeCount,
           updated.contains(where: { $0.id == item.id }) {
            currentHistoryItemPasteboardState = (
                itemID: item.id,
                changeCount: currentChangeCount
            )
        }
        persistCurrentItems(changedIDs: retention.evictedItemCount == 0 ? [item.id] : nil)
        notifyChanged()
        enqueueImageTextIndexing(for: [item])
        onItemCaptured?(item.id)
    }

    private func cancelPendingCaptureProcessing() {
        captureProcessingGeneration &+= 1
        captureProcessingTask?.cancel()
        captureProcessingTask = nil
    }

    @discardableResult
    func ignoreNextCopy(
        expiringAfter timeout: TimeInterval = 15,
        mode: ClipboardCaptureSuppressionMode = .ignoreNextCopy
    ) -> Bool {
        guard canSuppressNextCapture else { return false }
        // A pasteboard delta from before this command must not consume the one-shot suppression.
        // Reading changeCount does not cross the payload-reading privacy boundary.
        lastSeenChangeCount = pasteboard.changeCount
        hasObservedSuppressedChange = false
        captureSuppressionMode = mode
        captureSuppressionHardDeadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        isIgnoringNextCopy = true
        if mode == .privateCopy {
            onPrivateCopyLeaseChange?(ClipboardPrivateCopyLease(
                baselineChangeCount: lastSeenChangeCount,
                expiresAt: Date().addingTimeInterval(max(0, timeout))
            ))
        }
        notifyChanged(reschedulesRetention: false)
        onCaptureSuppressionEvent?(.armed(mode: mode, timeout: timeout))
        scheduleCaptureSuppressionExpiration(after: timeout)
        return true
    }

    func cancelNextCaptureSuppression() {
        clearCaptureSuppression(notifyCancellation: true)
    }

    @discardableResult
    func restorePrivateCopySuppression(
        _ lease: ClipboardPrivateCopyLease,
        now: Date = Date()
    ) -> Bool {
        let remaining = lease.expiresAt.timeIntervalSince(now)
        guard remaining > 0 else {
            onPrivateCopyLeaseChange?(nil)
            return false
        }
        let currentChangeCount = pasteboard.changeCount
        lastSeenChangeCount = currentChangeCount
        captureSuppressionMode = .privateCopy
        isIgnoringNextCopy = true
        if currentChangeCount != lease.baselineChangeCount {
            hasObservedSuppressedChange = true
            captureSuppressionHardDeadline = ProcessInfo.processInfo.systemUptime
                + captureSuppressionSettlingInterval
            let refreshedLease = ClipboardPrivateCopyLease(
                baselineChangeCount: currentChangeCount,
                expiresAt: now.addingTimeInterval(captureSuppressionSettlingInterval)
            )
            onPrivateCopyLeaseChange?(refreshedLease)
            onCaptureSuppressionEvent?(.consumed(mode: .privateCopy))
            scheduleCaptureSuppressionExpiration(after: captureSuppressionSettlingInterval)
        } else {
            hasObservedSuppressedChange = false
            captureSuppressionHardDeadline = ProcessInfo.processInfo.systemUptime + remaining
            scheduleCaptureSuppressionExpiration(after: remaining)
        }
        notifyChanged(reschedulesRetention: false)
        return true
    }

    private func clearCaptureSuppression(
        notifyCancellation: Bool,
        clearsPrivateCopyLease: Bool = true
    ) {
        guard isIgnoringNextCopy || captureSuppressionTask != nil else { return }
        let mode = captureSuppressionMode
        let hadObservedSuppressedChange = hasObservedSuppressedChange
        captureSuppressionGeneration &+= 1
        captureSuppressionTask?.cancel()
        captureSuppressionTask = nil
        captureSuppressionHardDeadline = nil
        hasObservedSuppressedChange = false
        captureSuppressionMode = nil
        isIgnoringNextCopy = false
        if clearsPrivateCopyLease, mode == .privateCopy {
            onPrivateCopyLeaseChange?(nil)
        }
        discardSourceApplicationAttribution()
        notifyChanged(reschedulesRetention: false)
        if notifyCancellation,
           !hadObservedSuppressedChange,
           let mode {
            onCaptureSuppressionEvent?(.cancelled(mode: mode))
        }
    }

    @discardableResult
    func copyItem(id: UUID, canWrite: @MainActor () -> Bool = { true }) async -> Bool {
        await copyItemForPaste(id: id, canWrite: canWrite) != nil
    }

    /// Returns the version owned by this write, even if the caller resumes later.
    func copyItemForPaste(id: UUID, canWrite: @MainActor () -> Bool = { true }) async -> Int? {
        guard !isMutatingItems else { return nil }
        guard let item = items.first(where: { $0.id == id }),
              let payload = try? await item.loadPayloadAsync() else { return nil }
        let fileURLs = payload.fileURLs
        if !fileURLs.isEmpty {
            let hasUnavailableReferences = await Task.detached(priority: .userInitiated) {
                fileURLs.contains { !FileManager.default.fileExists(atPath: $0.path) }
            }.value
            guard !Task.isCancelled, !hasUnavailableReferences else {
                item.discardCachedPayloadIfReloadable()
                return nil
            }
        }
        guard !Task.isCancelled,
              !isMutatingItems,
              canWrite(),
              let index = items.firstIndex(where: { $0.id == id }) else {
            item.discardCachedPayloadIfReloadable()
            return nil
        }
        guard pasteboard.writePayload(payload) else {
            item.discardCachedPayloadIfReloadable()
            return nil
        }
        let writtenVersion = pasteboard.changeCount
        items[index].discardCachedPayloadIfReloadable()
        currentHistoryItemPasteboardState = (
            itemID: items[index].id,
            changeCount: pasteboard.changeCount
        )
        lastSeenChangeCount = pasteboard.changeCount
        recordItemUsage(at: index)
        return writtenVersion
    }

    func preparePayloadForUse(id: UUID) async -> Bool {
        guard !isMutatingItems,
              let item = items.first(where: { $0.id == id }) else {
            return false
        }
        let isAvailable = (try? await item.loadPayloadAsync()) != nil
        guard !Task.isCancelled else {
            item.discardCachedPayloadIfReloadable()
            return false
        }
        if isAvailable, item.kind == .image, !item.hasCompletedImageTextIndexing {
            enqueueImageTextIndexing(for: [item])
        }
        return isAvailable
    }

    func releasePayloadIfReloadable(id: UUID?) {
        guard let id, let item = items.first(where: { $0.id == id }) else { return }
        item.discardCachedPayloadIfReloadable()
    }

    func requestImageTextIndexing(id: UUID?) {
        guard let id,
              let item = items.first(where: {
                  $0.id == id && $0.kind == .image && !$0.hasCompletedImageTextIndexing
              }) else {
            return
        }
        imageIndexAttemptedItemIDs.remove(item.id)
        enqueueImageTextIndexing(for: [item])
    }

    @discardableResult
    func copyItemAsPlainText(id: UUID) -> Bool {
        guard !isMutatingItems else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard let text = ClipboardPlainTextConversion.text(for: items[index]) else { return false }
        guard pasteboard.writePlainText(text) else { return false }
        items[index].discardCachedPayloadIfReloadable()
        currentHistoryItemPasteboardState = nil
        lastSeenChangeCount = pasteboard.changeCount
        recordItemUsage(at: index)
        return true
    }

    @discardableResult
    func copyCombinedItemsAsPlainText(ids: [UUID]) async -> Bool {
        guard !isMutatingItems else { return false }
        guard let text = await combinedPlainText(ids: ids),
              pasteboard.writePlainText(text) else { return false }
        currentHistoryItemPasteboardState = nil
        lastSeenChangeCount = pasteboard.changeCount
        recordCombinedItemUsage(ids: ids)
        return true
    }

    @discardableResult
    func writeCombinedPlainText(_ text: String, historyItemIDs: [UUID]) -> Bool {
        guard !isMutatingItems, !text.isEmpty, pasteboard.writePlainText(text) else {
            return false
        }
        currentHistoryItemPasteboardState = nil
        lastSeenChangeCount = pasteboard.changeCount
        recordCombinedItemUsage(ids: historyItemIDs)
        return true
    }

    func combinedPlainText(ids: [UUID]) async -> String? {
        guard !isMutatingItems else { return nil }
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let selectedItems = ids.compactMap { itemsByID[$0] }
        guard !selectedItems.isEmpty, selectedItems.count == ids.count else { return nil }
        let worker = Task.detached(priority: .userInitiated) { () -> String? in
            var convertedItems: [String] = []
            convertedItems.reserveCapacity(selectedItems.count)
            for item in selectedItems {
                guard !Task.isCancelled else { return nil }
                let text: String
                do {
                    guard let converted = try ClipboardPlainTextConversion.completeText(for: item)
                    else { return nil }
                    text = converted
                } catch {
                    return nil
                }
                convertedItems.append(text)
            }
            return convertedItems.joined(separator: "\n\n")
        }
        let text = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        selectedItems.forEach { $0.discardCachedPayloadIfReloadable() }
        guard !Task.isCancelled, let text, !text.isEmpty else { return nil }
        return text
    }

    func recordCombinedItemUsage(ids: [UUID]) {
        let usedAt = Date()
        let selectedIDs = Set(ids)
        var updated = items
        for index in updated.indices where selectedIDs.contains(updated[index].id) {
            updated[index].lastUsedAt = usedAt
        }
        publishItems(updated, changedIDs: selectedIDs)
        persistCurrentItems(changedIDs: selectedIDs)
        notifyChanged(reschedulesRetention: false)
    }

    /// Replaces the current system clipboard with visible text derived from its safe rich-text
    /// representations, falling back to native plain text or completed OCR from the history item
    /// captured from the same still-current pasteboard change. Clipboard reading remains
    /// independent of history loading and collection state.
    @discardableResult
    func rewriteCurrentClipboardAsPlainText() async -> ClipboardPlainTextRewriteResult {
        let expectedChangeCount = pasteboard.changeCount
        let readResult = await pasteboard.readSemanticTextAsynchronously(
            maximumByteCount: settings.snapshot.maximumItemByteCount,
            expectedChangeCount: expectedChangeCount
        )
        guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else {
            return .unavailable
        }
        if case let .payload(payload) = readResult,
           let text = ClipboardPlainTextConversion.visibleText(for: payload) {
            guard pasteboard.writePlainText(text) else { return .unavailable }
            currentHistoryItemPasteboardState = nil
            lastSeenChangeCount = pasteboard.changeCount
            return .succeeded
        }

        guard let currentHistoryItemPasteboardState,
              currentHistoryItemPasteboardState.changeCount == expectedChangeCount,
              let item = items.first(where: {
                  $0.id == currentHistoryItemPasteboardState.itemID && $0.kind == .image
              }) else {
            return .unavailable
        }
        guard item.hasCompletedImageTextIndexing else {
            return .imageTextRecognitionPending
        }
        guard let text = ClipboardPlainTextConversion.text(for: item) else {
            return .imageTextUnavailable
        }
        guard pasteboard.writePlainText(text) else { return .unavailable }
        item.discardCachedPayloadIfReloadable()
        self.currentHistoryItemPasteboardState = nil
        lastSeenChangeCount = pasteboard.changeCount
        return .succeeded
    }

    /// Marks a pasteboard write performed by another Clipboard domain as internal so the history
    /// monitor neither captures a rendered snippet nor treats it as an external queue reset.
    func markCurrentPasteboardChangeAsInternal() {
        currentHistoryItemPasteboardState = nil
        lastSeenChangeCount = pasteboard.changeCount
    }

    private func recordItemUsage(at index: Int) {
        var updated = items
        updated[index].lastUsedAt = Date()
        publishItems(updated, changedIDs: [updated[index].id])
        persistCurrentItems(changedIDs: [items[index].id])
        notifyChanged(reschedulesRetention: false)
    }

    func recordSuccessfulUse(id: UUID) {
        guard !isMutatingItems,
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        recordItemUsage(at: index)
    }

    @discardableResult
    func deleteItem(id: UUID) async -> Bool {
        await mutateItemsDurably(targetIDs: [id]) { items in
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].isInHistory else { return nil }
            var updated = items
            if updated[index].isSaved { updated[index].setHistoryMembership(false) }
            else { updated.remove(at: index) }
            return updated
        }
    }

    /// Permanently removes the unified item regardless of its History or Saved memberships.
    @discardableResult
    func deletePermanently(id: UUID) async -> Bool {
        await deletePermanently(ids: [id])
    }

    /// Permanently removes a captured set of unified items in one durable mutation.
    @discardableResult
    func deletePermanently(ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return false }
        return await mutateItemsDurably(targetIDs: ids) { items in
            let availableIDs = Set(items.lazy.map(\.id))
            guard ids.isSubset(of: availableIDs) else { return nil }
            return items.filter { !ids.contains($0.id) }
        }
    }

    var supportsAtomicSnippetDeletion: Bool {
        persistence is any ClipboardUnifiedDeletionPersisting
    }

    /// Permanently removes History/Saved clips and snippet rows in one storage transaction.
    @discardableResult
    func deletePermanently(
        ids: Set<UUID>,
        deletingSnippetIDs snippetIDs: Set<UUID>
    ) async -> Bool {
        guard !ids.isEmpty, !snippetIDs.isEmpty, supportsAtomicSnippetDeletion else { return false }
        return await mutateItemsDurably(
            targetIDs: ids,
            deletingSavedItemIDs: snippetIDs
        ) { items in
            let availableIDs = Set(items.lazy.map(\.id))
            guard ids.isSubset(of: availableIDs) else { return nil }
            return items.filter { !ids.contains($0.id) }
        }
    }

    @discardableResult
    func toggleSaved(id: UUID) async -> Bool {
        await mutateItemsDurably(targetIDs: [id]) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = items
            if updated[index].isSaved {
                updated[index].setSavedMetadata(nil)
                if !updated[index].isInHistory { updated.remove(at: index) }
            } else {
                updated[index].setSavedMetadata(ClipboardHistorySavedMetadata(
                    title: self.suggestedSavedTitle(for: updated[index]), savedAt: Date()))
            }
            return updated
        }
    }

    func updateSavedMetadata(_ draft: ClipboardSavedMetadataDraft) async -> ClipboardHistoryItem? {
        guard await mutateItemsDurably(targetIDs: [draft.id], transform: { items in
            guard let index = items.firstIndex(where: { $0.id == draft.id }), items[index].isSaved else { return nil }
            var updated = items
            updated[index].updateSavedMetadata(
                title: ClipboardSavedItem.normalizedTitle(draft.title, fallback: updated[index].text),
                tags: ClipboardSavedItem.normalizedTags(draft.tags), updatedAt: Date())
            return updated
        }) else { return nil }
        return items.first { $0.id == draft.id }
    }

    @discardableResult
    func deleteSavedItem(id: UUID) async -> Bool {
        await mutateItemsDurably(targetIDs: [id]) { items in
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].isSaved else { return nil }
            var updated = items
            updated[index].setSavedMetadata(nil)
            if !updated[index].isInHistory { updated.remove(at: index) }
            return updated
        }
    }

    @discardableResult
    func clearAllHistory() async -> Bool {
        onWillClearHistory?()
        return await mutateItemsDurably(blocksCollection: true) { items in
            items.compactMap { item -> ClipboardHistoryItem? in
                guard item.isSaved else { return nil }
                var savedOnlyItem = item
                savedOnlyItem.setHistoryMembership(false)
                return savedOnlyItem
            }
        }
    }

    @discardableResult
    func clearAllSavedItems() async -> Bool {
        await mutateItemsDurably(blocksCollection: true) { items in
            items.compactMap { item -> ClipboardHistoryItem? in
                guard item.isInHistory else { return nil }
                var retained = item
                retained.setSavedMetadata(nil)
                return retained
            }
        }
    }

    @discardableResult
    func resetUnreadablePersistentHistory() async -> Bool {
        guard canResetUnreadablePersistentHistory else { return false }
        return await resetPersistentHistory()
    }

    func matchingItems(query: String) -> [ClipboardHistoryItem] {
        ClipboardHistorySearch.filter(items, query: query)
    }

    private func finishLoading(_ loadedItems: [ClipboardHistoryItem]) {
        loadTask = nil
        isLoaded = true
        submittedItems = loadedItems
        pendingMutations = []
        let pruned = ClipboardRetentionPolicy.prune(
            loadedItems,
            settings: settings.snapshot,
            protectedItemIDs: effectiveRetentionProtectedItemIDs
        )
        items = pruned
        errorMessage = nil
        storageError = nil
        refreshProtectedCapacityState()
        if pruned != loadedItems {
            persistCurrentItems()
        }
        notifyChanged()
        startMonitoringIfPossible()
        // Queue only lightweight identifiers, then process one image at a time. This keeps
        // startup work bounded without permanently leaving older images unsearchable.
        remainingBackgroundImageTextIndexItemCount =
            Self.maximumBackgroundImageTextIndexItemCount
        continuesBackgroundImageIndexing = true
        enqueueNextBackgroundImageTextIndexBatch()
    }

    private func finishLoading(with error: Error) {
        loadTask = nil
        isLoaded = true
        errorMessage = errorMessageProvider(error)
        storageError = error as? ClipboardHistoryStoreError
        discardSourceApplicationAttribution()
        notifyChanged()
    }

    private func startMonitoringIfPossible() {
        guard timer == nil, isLoaded, errorMessage == nil, !settings.isPaused else { return }
        timer = Timer.scheduledTimer(
            timeInterval: monitoringInterval,
            target: self,
            selector: #selector(checkPasteboardTimer),
            userInfo: nil,
            repeats: true
        )
        timer?.tolerance = min(0.1, monitoringInterval / 4)
    }

    private func pruneExpiredItemsIfNeeded(now: Date) {
        let currentSettings = settings.snapshot
        guard let interval = currentSettings.expiration.interval else { return }
        let cutoff = now.addingTimeInterval(-interval)
        let protectedIDs = effectiveRetentionProtectedItemIDs
        guard items.contains(where: {
            $0.isInHistory
                && !protectedIDs.contains($0.id)
                && $0.capturedAt < cutoff
        }) else {
            return
        }
        let pruned = ClipboardRetentionPolicy.prune(
            items,
            settings: currentSettings,
            now: now,
            protectedItemIDs: effectiveRetentionProtectedItemIDs
        )
        guard pruned != items else { return }
        items = pruned
        refreshProtectedCapacityState()
        persistCurrentItems()
        notifyChanged()
    }

    func processRetentionExpiration(now: Date = Date()) {
        pruneExpiredItemsIfNeeded(now: now)
        scheduleRetentionExpiration(now: now)
    }

    private func scheduleRetentionExpiration(now: Date = Date()) {
        retentionTimer?.invalidate()
        retentionTimer = nil
        guard isLoaded,
              errorMessage == nil,
              let interval = settings.snapshot.expiration.interval else { return }
        let protectedIDs = effectiveRetentionProtectedItemIDs
        guard let nextExpiration = items.lazy
            .filter({ $0.isInHistory && !protectedIDs.contains($0.id) })
            .map({ $0.capturedAt.addingTimeInterval(interval) })
            .min() else { return }
        retentionTimer = Timer.scheduledTimer(
            timeInterval: max(0.05, nextExpiration.timeIntervalSince(now)),
            target: self,
            selector: #selector(checkRetentionTimer),
            userInfo: nil,
            repeats: false
        )
    }

    private func seedSourceApplicationAttribution() {
        discardSourceApplicationAttribution()
        lastObservedFrontmostApplication = sourceContext.frontmostApplication()
    }

    private func suggestedSavedTitle(for item: ClipboardHistoryItem) -> String {
        if let fileName = item.fileURLs.first?.lastPathComponent, !fileName.isEmpty {
            return fileName
        }
        let firstLine = item.text.split(whereSeparator: \Character.isNewline)
            .first.map(String.init) ?? ""
        return ClipboardSavedItem.normalizedTitle(firstLine, fallback: item.kind.rawValue)
    }

    private func suppressPasteboardChangeIfNeeded() -> Bool {
        guard isIgnoringNextCopy else { return false }
        // Once the first write is consumed, privacy takes precedence over the arm timeout: every
        // transition renews a complete quiet interval. Continuous churn therefore stays behind
        // the no-read boundary until it settles or the user explicitly cancels suppression.
        captureSuppressionHardDeadline = ProcessInfo.processInfo.systemUptime
            + captureSuppressionSettlingInterval
        if captureSuppressionMode == .privateCopy {
            onPrivateCopyLeaseChange?(ClipboardPrivateCopyLease(
                baselineChangeCount: lastSeenChangeCount,
                expiresAt: Date().addingTimeInterval(captureSuppressionSettlingInterval)
            ))
        }
        if !hasObservedSuppressedChange {
            hasObservedSuppressedChange = true
            if let captureSuppressionMode {
                onCaptureSuppressionEvent?(.consumed(mode: captureSuppressionMode))
            }
        }
        // A single Copy operation may clear and then populate the pasteboard in separate writes.
        // Require a complete quiet interval after every observed change so the whole burst stays
        // behind the no-read boundary.
        scheduleCaptureSuppressionExpiration(after: captureSuppressionSettlingInterval)
        return true
    }

    private func scheduleCaptureSuppressionExpiration(after timeout: TimeInterval) {
        captureSuppressionGeneration &+= 1
        let generation = captureSuppressionGeneration
        captureSuppressionTask?.cancel()
        let remainingUntilHardDeadline = captureSuppressionHardDeadline.map {
            max(0, $0 - ProcessInfo.processInfo.systemUptime)
        } ?? 0
        let boundedTimeout = min(max(0, timeout), remainingUntilHardDeadline)
        let nanoseconds = UInt64(boundedTimeout * 1_000_000_000)
        captureSuppressionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.captureSuppressionGeneration == generation else {
                return
            }
            self.captureSuppressionTask = nil
            let currentChangeCount = self.pasteboard.changeCount
            if currentChangeCount != self.lastSeenChangeCount {
                self.lastSeenChangeCount = currentChangeCount
                _ = self.suppressPasteboardChangeIfNeeded()
                return
            }
            let mode = self.captureSuppressionMode
            let hadObservedSuppressedChange = self.hasObservedSuppressedChange
            self.captureSuppressionHardDeadline = nil
            self.hasObservedSuppressedChange = false
            self.captureSuppressionMode = nil
            self.isIgnoringNextCopy = false
            if mode == .privateCopy {
                self.onPrivateCopyLeaseChange?(nil)
            }
            self.discardSourceApplicationAttribution()
            self.notifyChanged(reschedulesRetention: false)
            if !hadObservedSuppressedChange, let mode {
                self.onCaptureSuppressionEvent?(.expired(mode: mode))
            }
        }
    }

    @objc private func checkPasteboardTimer() {
        processPasteboardChange()
    }

    @objc private func checkRetentionTimer() {
        retentionTimer = nil
        processRetentionExpiration()
    }

    private func retainSourceApplicationAttribution(
        _ applications: [ClipboardSourceApplication],
        now: Date
    ) {
        recentSourceApplicationAttribution = recentSourceApplicationAttribution.filter {
            $0.value.expiresAt >= now
        }
        let expiresAt = now.addingTimeInterval(Self.sourceApplicationAttributionGraceInterval)
        for application in applications {
            recentSourceApplicationAttribution[application.bundleIdentifier.lowercased()] = (
                application,
                expiresAt
            )
        }
    }

    private func takeSourceApplicationAttribution(now: Date) -> [ClipboardSourceApplication] {
        defer { recentSourceApplicationAttribution.removeAll(keepingCapacity: true) }
        return recentSourceApplicationAttribution.values.compactMap { attribution in
            attribution.expiresAt >= now ? attribution.application : nil
        }
    }

    private func discardSourceApplicationAttribution() {
        recentSourceApplicationAttribution.removeAll(keepingCapacity: true)
        sourceContext.discardRecentlyActivatedApplications()
    }

    private func persistCurrentItems(changedIDs: Set<UUID>? = nil) {
        let mutation: ClipboardHistoryMutation
        if let changedIDs, !hasPendingImageIndexPersistence {
            mutation = Self.targetedMutation(from: submittedItems, to: items, ids: changedIDs)
        } else {
            mutation = ClipboardHistoryMutation.between(submittedItems, items)
        }
        submittedItems = items
        let revision = registerMutation(mutation)
        let generation = storageGeneration
        persistenceWorker.enqueueSave(mutation, revision: revision) { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self, self.storageGeneration == generation else { return }
                self.handlePersistenceOutcome(outcome)
            }
        }
    }

    /// User operations have FIFO intent ordering, while unrelated capture/OCR/usage updates keep
    /// flowing. Only bulk clear/reset suspends intake. Completion merges fields into the latest
    /// live item; it never replaces the collection that existed before the await.
    private func mutateItemsDurably(
        targetIDs: Set<UUID> = [],
        blocksCollection: Bool = false,
        deletingSavedItemIDs: Set<UUID> = [],
        transform: @escaping @MainActor ([ClipboardHistoryItem]) -> [ClipboardHistoryItem]?
    ) async -> Bool {
        guard !isMutatingItems else { return false }
        let previous = durableMutationTask
        let generation = storageGeneration
        retainPendingDurableItemIDs(targetIDs)
        durableMutationSequence &+= 1
        let sequence = durableMutationSequence
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.storageGeneration == generation {
                    self.releasePendingDurableItemIDs(targetIDs)
                    self.pendingDeletedItemIDs.subtract(targetIDs)
                    self.itemMutation = nil
                    self.reconcileSettingsIfNeeded()
                    self.refreshProtectedCapacityState()
                    self.startNextImageTextIndexingIfNeeded()
                    if blocksCollection { self.notifyChanged() }
                }
            }
            _ = await previous?.value
            guard !Task.isCancelled, self.storageGeneration == generation,
                  self.isLoaded, self.errorMessage == nil, !self.isMutatingItems else { return false }
            if blocksCollection {
                self.cancelPendingCaptureProcessing()
                self.cancelPendingPasteboardPayloadRead()
                self.cancelImageIndexing()
                self.itemMutation = .content
                self.notifyChanged()
            }
            guard let replacement = transform(self.items) else { return false }
            // Flush prior OCR deltas before the user mutation; don't cancel their persistence.
            self.flushPendingImageIndexPersistence()
            let mutation = blocksCollection
                ? ClipboardHistoryMutation.between(self.items, replacement)
                : Self.targetedMutation(from: self.items, to: replacement, ids: targetIDs)
            self.pendingDeletedItemIDs.formUnion(mutation.changes.compactMap {
                $0.after == nil || $0.after?.isInHistory == false ? $0.id : nil
            })
            self.capturePolicyRevision &+= 1
            let revision = self.registerMutation(mutation, isPublished: false)
            let outcome = await self.persistenceWorker.saveBarrier(
                mutation,
                revision: revision,
                deletingSavedItemIDs: deletingSavedItemIDs
            )
            guard self.storageGeneration == generation else { return false }
            self.handlePersistenceOutcome(outcome)
            self.notifyChanged()
            return outcome.error == nil
        }
        durableMutationTask = task
        let result = await task.value
        if durableMutationSequence == sequence { durableMutationTask = nil }
        return result
    }

    private func retainPendingDurableItemIDs(_ itemIDs: Set<UUID>) {
        for itemID in itemIDs {
            pendingDurableItemIDReferenceCounts[itemID, default: 0] += 1
        }
    }

    private func releasePendingDurableItemIDs(_ itemIDs: Set<UUID>) {
        for itemID in itemIDs {
            guard let count = pendingDurableItemIDReferenceCounts[itemID] else { continue }
            if count <= 1 {
                pendingDurableItemIDReferenceCounts.removeValue(forKey: itemID)
            } else {
                pendingDurableItemIDReferenceCounts[itemID] = count - 1
            }
        }
    }

    private func resetPersistentHistory() async -> Bool {
        guard !isMutatingItems else { return false }
        onWillResetPersistentHistory?()
        storageGeneration &+= 1
        let generation = storageGeneration
        durableMutationTask?.cancel()
        durableMutationTask = nil
        pendingDurableItemIDReferenceCounts.removeAll()
        pendingDeletedItemIDs.removeAll()
        cancelPendingCaptureProcessing()
        cancelPendingPasteboardPayloadRead()
        cancelImageIndexing()
        cancelScheduledImageIndexPersistence()
        itemMutation = .content
        notifyChanged()
        do {
            try await persistenceWorker.reset()
            guard storageGeneration == generation else { return false }
            items = []
            submittedItems = []
            pendingMutations = []
            acknowledgedPersistenceRevision = persistenceRevision
            refreshProtectedCapacityState()
            errorMessage = nil
            storageError = nil
            isLoaded = true
            lastSeenChangeCount = pasteboard.changeCount
            itemMutation = nil
            notifyChanged()
            reconcileSettingsIfNeeded()
            startMonitoringIfPossible()
            return true
        } catch {
            guard storageGeneration == generation else { return false }
            itemMutation = nil
            errorMessage = errorMessageProvider(error)
            storageError = error as? ClipboardHistoryStoreError
            notifyChanged()
            return false
        }
    }

    private func reconcileSettingsIfNeeded() {
        guard needsSettingsReconciliation else { return }
        needsSettingsReconciliation = false
        settingsDidChange()
    }

    private func registerMutation(_ mutation: ClipboardHistoryMutation, isPublished: Bool = true) -> UInt64 {
        persistenceRevision &+= 1
        pendingMutations.append((persistenceRevision, mutation, isPublished))
        return persistenceRevision
    }

    private static func targetedMutation(
        from previous: [ClipboardHistoryItem], to next: [ClipboardHistoryItem], ids: Set<UUID>
    ) -> ClipboardHistoryMutation {
        let before = Dictionary(uniqueKeysWithValues: previous.lazy.filter { ids.contains($0.id) }.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: next.lazy.filter { ids.contains($0.id) }.map { ($0.id, $0) })
        return ClipboardHistoryMutation(changes: ids.compactMap { id in
            guard before[id] != after[id] else { return nil }
            return .init(id: id, before: before[id], after: after[id])
        })
    }

    private func handlePersistenceOutcome(_ outcome: ClipboardHistoryPersistenceWorker.SaveOutcome) {
        guard outcome.revision > acknowledgedPersistenceRevision else { return }
        // Successful background writes are already visible. Only durable-only user changes
        // need publication; avoid scanning/rebasing the full collection on every acknowledgement.
        if outcome.latestFailure == nil {
            let userWrites = pendingMutations.filter {
                $0.revision <= outcome.revision && !$0.isPublished
            }
            let committedIDs = Set(userWrites.flatMap { $0.mutation.changedIDs })
            let firstUserRevision = userWrites.first?.revision ?? .max
            // A newer genuine recopy may already be visible while a delete commits. Replay
            // only later published fields for these IDs so the delete cannot hide that recopy.
            let committed = ClipboardHistoryMutation(changes: pendingMutations.flatMap { pending in
                if !pending.isPublished, pending.revision <= outcome.revision { return pending.mutation.changes }
                if pending.isPublished, pending.revision > firstUserRevision {
                    return pending.mutation.changes.filter { committedIDs.contains($0.id) }
                }
                return []
            })
            acknowledgedPersistenceRevision = outcome.revision
            pendingMutations.removeAll { $0.revision <= outcome.revision }
            if !committed.changes.isEmpty {
                let unsent = hasPendingImageIndexPersistence
                    ? Self.targetedMutation(from: submittedItems, to: items, ids: committedIDs)
                    : ClipboardHistoryMutation(changes: [])
                publishItems(unsent.applying(to: committed.applying(to: items)), changedIDs: committedIDs)
                submittedItems = committed.applying(to: submittedItems)
                refreshProtectedCapacityState()
            }
            return
        }
        let unsentChanges = ClipboardHistoryMutation.between(submittedItems, items)
        acknowledgedPersistenceRevision = outcome.revision
        pendingMutations.removeAll { $0.revision <= outcome.revision }
        var rebased = outcome.durableItems
        for pending in pendingMutations where pending.isPublished {
            rebased = pending.mutation.applying(to: rebased)
        }
        submittedItems = rebased
        let updated = unsentChanges.applying(to: rebased)
        if items != updated { items = updated }
        refreshProtectedCapacityState()
        guard let error = outcome.latestFailure?.error else { return }
        capturePolicyRevision &+= 1
        cancelPendingCaptureProcessing()
        errorMessage = errorMessageProvider(error)
        storageError = error as? ClipboardHistoryStoreError
        timer?.invalidate()
        timer = nil
        notifyChanged()
    }

    private func notifyChanged(reschedulesRetention: Bool = true) {
        if reschedulesRetention { scheduleRetentionExpiration() }
        onChange?()
        objectWillChange.send()
    }

    private func publishItems(_ updated: [ClipboardHistoryItem], changedIDs: Set<UUID>) {
        publicationChangedIDs = changedIDs
        defer { publicationChangedIDs = nil }
        items = updated
    }

    private func enqueueImageTextIndexing(for candidates: [ClipboardHistoryItem]) {
        let eligible = candidates.lazy.filter {
            $0.kind == .image && !$0.hasCompletedImageTextIndexing
        }
        for item in eligible {
            guard pendingImageIndexItemIDSet.insert(item.id).inserted else { continue }
            pendingImageIndexItemIDs.append(item.id)
        }
        startNextImageTextIndexingIfNeeded()
    }

    private func enqueueNextBackgroundImageTextIndexBatch() {
        guard continuesBackgroundImageIndexing,
              remainingBackgroundImageTextIndexItemCount > 0,
              imageIndexingTask == nil,
              pendingImageIndexItemIDs.isEmpty,
              isLoaded,
              errorMessage == nil,
              !isMutatingItems else {
            return
        }
        let candidates = items.lazy.filter {
            $0.kind == .image
                && !$0.hasCompletedImageTextIndexing
                && !self.pendingImageIndexItemIDSet.contains($0.id)
                && !self.imageIndexAttemptedItemIDs.contains($0.id)
        }
        let batchSize = min(
            Self.imageTextIndexBatchSize,
            remainingBackgroundImageTextIndexItemCount
        )
        let batch = Array(candidates.prefix(batchSize))
        guard !batch.isEmpty else {
            continuesBackgroundImageIndexing = false
            return
        }
        remainingBackgroundImageTextIndexItemCount -= batch.count
        enqueueImageTextIndexing(for: batch)
    }

    private func startNextImageTextIndexingIfNeeded() {
        guard imageIndexingTask == nil,
              isLoaded,
              errorMessage == nil,
              !isMutatingItems else {
            return
        }

        while let itemID = pendingImageIndexItemIDs.first {
            pendingImageIndexItemIDs.removeFirst()
            pendingImageIndexItemIDSet.remove(itemID)
            imageIndexAttemptedItemIDs.insert(itemID)
            guard let item = items.first(where: {
                $0.id == itemID && $0.kind == .image && !$0.hasCompletedImageTextIndexing
            }) else {
                continue
            }

            let recognizer = imageTextRecognizer
            imageIndexingTask = Task { [weak self] in
                let payload = try? await item.loadPayloadAsync()
                guard let payload else {
                    guard !Task.isCancelled else { return }
                    self?.finishImageTextIndexingAttempt(
                        itemID: itemID,
                        recognizedText: nil,
                        didLoadPayload: false
                    )
                    return
                }
                defer { item.discardCachedPayloadIfReloadable() }
                guard !Task.isCancelled else { return }
                let recognizedText = await recognizer.recognizeText(in: payload)
                guard !Task.isCancelled else { return }
                self?.finishImageTextIndexingAttempt(
                    itemID: itemID,
                    recognizedText: recognizedText,
                    didLoadPayload: true
                )
            }
            return
        }
        scheduleNextBackgroundImageTextIndexBatchIfNeeded()
    }

    private func finishImageTextIndexingAttempt(
        itemID: UUID,
        recognizedText: String?,
        didLoadPayload: Bool
    ) {
        imageIndexingTask = nil
        defer { startNextImageTextIndexingIfNeeded() }
        guard didLoadPayload,
              !isMutatingItems,
              let index = items.firstIndex(where: { $0.id == itemID }),
              !items[index].hasCompletedImageTextIndexing else {
            return
        }
        var updated = items
        updated[index].setImageSearchText(recognizedText)
        updated[index].hasCompletedImageTextIndexing = true
        publishItems(updated, changedIDs: [itemID])
        scheduleImageIndexPersistence()
        notifyChanged(reschedulesRetention: false)
    }

    private func scheduleNextBackgroundImageTextIndexBatchIfNeeded() {
        guard continuesBackgroundImageIndexing,
              remainingBackgroundImageTextIndexItemCount > 0,
              imageIndexBatchContinuationTask == nil,
              imageIndexingTask == nil,
              pendingImageIndexItemIDs.isEmpty,
              items.contains(where: {
                  $0.kind == .image
                      && !$0.hasCompletedImageTextIndexing
                      && !imageIndexAttemptedItemIDs.contains($0.id)
              }) else {
            return
        }
        let pause = imageIndexBatchPauseNanoseconds
        imageIndexBatchContinuationTask = Task { @MainActor [weak self] in
            if pause > 0 {
                try? await Task.sleep(nanoseconds: pause)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, let self else { return }
            self.imageIndexBatchContinuationTask = nil
            self.enqueueNextBackgroundImageTextIndexBatch()
        }
    }

    private func scheduleImageIndexPersistence() {
        hasPendingImageIndexPersistence = true
        pendingImageIndexPersistenceCount += 1
        if pendingImageIndexPersistenceCount >= 10 {
            flushPendingImageIndexPersistence()
            return
        }
        guard imageIndexPersistenceTask == nil else { return }
        imageIndexPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushPendingImageIndexPersistence()
        }
    }

    private func cancelScheduledImageIndexPersistence() {
        imageIndexPersistenceTask?.cancel()
        imageIndexPersistenceTask = nil
        hasPendingImageIndexPersistence = false
        pendingImageIndexPersistenceCount = 0
    }

    private func flushPendingImageIndexPersistence() {
        imageIndexPersistenceTask?.cancel()
        imageIndexPersistenceTask = nil
        guard hasPendingImageIndexPersistence else { return }
        hasPendingImageIndexPersistence = false
        pendingImageIndexPersistenceCount = 0
        persistCurrentItems()
    }

    private func cancelImageIndexing() {
        imageIndexingTask?.cancel()
        imageIndexingTask = nil
        imageIndexBatchContinuationTask?.cancel()
        imageIndexBatchContinuationTask = nil
        continuesBackgroundImageIndexing = false
        remainingBackgroundImageTextIndexItemCount = 0
        pendingImageIndexItemIDs.removeAll()
        pendingImageIndexItemIDSet.removeAll()
        imageIndexAttemptedItemIDs.removeAll()
    }

    private func cancelPendingPasteboardPayloadRead() {
        pasteboardPayloadReadGeneration &+= 1
        pasteboardPayloadReadTask?.cancel()
        pasteboard.cancelAsynchronousPayloadRead()
        // Keep the logical slot occupied until the helper process exits and the read returns.
        // Cancellation invalidates the generation while the helper's forced teardown bounds it.
    }

    var pendingImageIndexItemCountForTesting: Int {
        pendingImageIndexItemIDs.count
    }

    private func refreshProtectedCapacityState() {
        let protectedIDs = effectiveRetentionProtectedItemIDs
        let protectedItems = items.filter {
            $0.isInHistory && protectedIDs.contains($0.id)
        }
        let protectedPayloadByteCount = protectedItems.reduce(0) { $0 + $1.payloadByteCount }
        isCaptureBlockedByProtectedItems =
            protectedItems.count >= settings.maximumItemCount
            || protectedPayloadByteCount >= settings.maximumTotalPayloadByteCount
    }
}
