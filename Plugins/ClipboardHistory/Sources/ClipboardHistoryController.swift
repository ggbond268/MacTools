import AppKit
import Foundation

@MainActor
protocol ClipboardPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var typeNames: Set<String> { get }
    func readPlainText() -> String?
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult
    @discardableResult func writePlainText(_ text: String) -> Bool
    @discardableResult func writePayload(_ payload: ClipboardHistoryPayload) -> Bool
}

enum ClipboardPasteboardReadResult: Equatable, Sendable {
    case payload(ClipboardHistoryPayload)
    case empty
    case oversized
}

enum ClipboardPlainTextRewriteResult: Equatable, Sendable {
    case succeeded
    case imageTextRecognitionPending
    case imageTextUnavailable
    case unavailable
}

@MainActor
final class GeneralClipboardPasteboard: ClipboardPasteboardAccess {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    var typeNames: Set<String> {
        Set(pasteboard.pasteboardItems?.flatMap { $0.types.map(\.rawValue) } ?? [])
    }

    func readPlainText() -> String? {
        pasteboard.string(forType: .string)
    }

    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult {
        guard let sourceItems = pasteboard.pasteboardItems, !sourceItems.isEmpty else {
            return .empty
        }

        var storedItems: [ClipboardStoredPasteboardItem] = []
        var storedByteCount = 0
        for sourceItem in sourceItems {
            var representations: [ClipboardStoredRepresentation] = []
            var seenTypes = Set<String>()
            for type in sourceItem.types where seenTypes.insert(type.rawValue).inserted {
                let typeIdentifier = type.rawValue
                guard ClipboardRepresentationType.isSupported(typeIdentifier) else { continue }

                let data: Data?
                if [
                    ClipboardRepresentationType.plainText,
                    ClipboardRepresentationType.fileURL,
                    ClipboardRepresentationType.url,
                ].contains(typeIdentifier) {
                    data = sourceItem.string(forType: type).map { Data($0.utf8) }
                } else {
                    data = sourceItem.data(forType: type)
                }
                guard let data, !data.isEmpty else { continue }
                guard data.count <= maximumByteCount - storedByteCount else {
                    return .oversized
                }
                storedByteCount += data.count
                representations.append(ClipboardStoredRepresentation(
                    typeIdentifier: typeIdentifier,
                    data: data
                ))
            }
            if !representations.isEmpty {
                storedItems.append(ClipboardStoredPasteboardItem(representations: representations))
            }
        }

        guard !storedItems.isEmpty else { return .empty }
        return .payload(ClipboardHistoryPayload(pasteboardItems: storedItems))
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
}

@MainActor
final class WorkspaceClipboardSourceContextProvider: ClipboardSourceContextProviding {
    func frontmostApplication() -> ClipboardSourceApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
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
    }

    private struct SaveRequest {
        var items: [ClipboardHistoryItem]
        var revision: UInt64
        var completions: [@Sendable (SaveOutcome) -> Void]
    }

    private let persistence: any ClipboardHistoryPersisting
    private let queue = DispatchQueue(label: "cc.ggbond.mactools.clipboard-history.persistence")
    private let lock = NSLock()
    private var pendingSave: SaveRequest?
    private var isDraining = false
    private var durableItems: [ClipboardHistoryItem] = []

    init(persistence: any ClipboardHistoryPersisting) {
        self.persistence = persistence
    }

    func load() async throws -> [ClipboardHistoryItem] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let loadedItems = try persistence.load()
                    durableItems = loadedItems
                    continuation.resume(returning: loadedItems)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func saveBarrier(_ items: [ClipboardHistoryItem], revision: UInt64) async -> SaveOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: persist(items, revision: revision))
            }
        }
    }

    func enqueueSave(
        _ items: [ClipboardHistoryItem],
        revision: UInt64,
        completion: @escaping @Sendable (SaveOutcome) -> Void
    ) {
        let shouldStart = lock.withLock {
            if var pendingSave {
                if revision >= pendingSave.revision {
                    pendingSave.items = items
                    pendingSave.revision = revision
                }
                pendingSave.completions.append(completion)
                self.pendingSave = pendingSave
            } else {
                pendingSave = SaveRequest(
                    items: items,
                    revision: revision,
                    completions: [completion]
                )
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
                guard let request = pendingSave else {
                    isDraining = false
                    return nil
                }
                pendingSave = nil
                return request
            }) else {
                return
            }

            let outcome = persist(request.items, revision: request.revision)
            request.completions.forEach { $0(outcome) }
        }
    }

    private func persist(_ items: [ClipboardHistoryItem], revision: UInt64) -> SaveOutcome {
        do {
            try persistence.save(items)
            durableItems = items
            return SaveOutcome(revision: revision, durableItems: items, error: nil)
        } catch {
            return SaveOutcome(revision: revision, durableItems: durableItems, error: error)
        }
    }
}

@MainActor
final class ClipboardHistoryController: NSObject, ObservableObject {
    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var isIgnoringNextCopy = false
    @Published private(set) var isClearingHistory = false
    @Published private(set) var isCaptureBlockedByPinnedItems = false

    var onChange: (() -> Void)?
    var onCaptureSuppressionEvent: ((ClipboardCaptureSuppressionEvent) -> Void)?
    var onCaptureRejection: ((ClipboardCaptureIgnoreReason, Int) -> Void)?

    let settings: ClipboardHistorySettingsStore

    private let pasteboard: any ClipboardPasteboardAccess
    private let sourceContext: any ClipboardSourceContextProviding
    private let persistence: any ClipboardHistoryPersisting
    private let persistenceWorker: ClipboardHistoryPersistenceWorker
    private let monitoringInterval: TimeInterval
    private let captureSuppressionSettlingInterval: TimeInterval
    private let imageTextRecognizer: any ClipboardImageTextRecognizing
    private let errorMessageProvider: (Error) -> String

    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var imageIndexingTask: Task<Void, Never>?
    private var pendingImageIndexItemIDs: [UUID] = []
    private var pendingImageIndexItemIDSet = Set<UUID>()
    private var captureSuppressionTask: Task<Void, Never>?
    private var captureSuppressionGeneration: UInt64 = 0
    private var captureSuppressionHardDeadline: TimeInterval?
    private var hasObservedSuppressedChange = false
    private var captureSuppressionMode: ClipboardCaptureSuppressionMode?
    private var persistenceRevision: UInt64 = 0
    private var needsSettingsReconciliation = false
    private var lastSeenChangeCount: Int
    private var currentHistoryItemPasteboardState: (itemID: UUID, changeCount: Int)?

    init(
        settings: ClipboardHistorySettingsStore,
        pasteboard: any ClipboardPasteboardAccess = GeneralClipboardPasteboard(),
        sourceContext: any ClipboardSourceContextProviding = WorkspaceClipboardSourceContextProvider(),
        persistence: any ClipboardHistoryPersisting,
        monitoringInterval: TimeInterval = 0.5,
        captureSuppressionSettlingInterval: TimeInterval = 0.75,
        imageTextRecognizer: any ClipboardImageTextRecognizing = VisionClipboardImageTextRecognizer(),
        errorMessageProvider: @escaping (Error) -> String = { $0.localizedDescription }
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.sourceContext = sourceContext
        self.persistence = persistence
        self.persistenceWorker = ClipboardHistoryPersistenceWorker(persistence: persistence)
        self.monitoringInterval = monitoringInterval
        self.captureSuppressionSettlingInterval = captureSuppressionSettlingInterval
        self.imageTextRecognizer = imageTextRecognizer
        self.errorMessageProvider = errorMessageProvider
        self.lastSeenChangeCount = pasteboard.changeCount
        super.init()
    }

    var pinnedItems: [ClipboardHistoryItem] {
        items.filter(\.isPinned)
    }

    var recentItems: [ClipboardHistoryItem] {
        items.filter { !$0.isPinned }
    }

    var usage: ClipboardHistoryUsage {
        ClipboardHistoryUsage(items: items)
    }

    var isCollectionOperational: Bool {
        isLoaded && errorMessage == nil && !isClearingHistory && timer != nil
    }

    var canSuppressNextCapture: Bool {
        isCollectionOperational
    }

    func start() {
        guard loadTask == nil, !isLoaded else {
            startMonitoringIfPossible()
            return
        }

        lastSeenChangeCount = pasteboard.changeCount
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
        timer?.invalidate()
        timer = nil
        loadTask?.cancel()
        loadTask = nil
        cancelImageIndexing()
        currentHistoryItemPasteboardState = nil
        clearCaptureSuppression(notifyCancellation: false)
        persistenceWorker.flush()
    }

    func removePersistentDataForUninstall() {
        stop()
        do {
            try persistence.removeAll()
            items = []
            refreshCapacityState()
            errorMessage = nil
            notifyChanged()
        } catch {
            errorMessage = errorMessageProvider(error)
            notifyChanged()
        }
    }

    func settingsDidChange() {
        guard !isClearingHistory else {
            needsSettingsReconciliation = true
            notifyChanged()
            return
        }
        let pruned = ClipboardRetentionPolicy.prune(items, settings: settings.snapshot)
        if pruned != items {
            items = pruned
            persistCurrentItems()
        }
        refreshCapacityState()
        notifyChanged()
    }

    func processPasteboardChange(now: Date = Date()) {
        guard isLoaded, errorMessage == nil else { return }
        if !isClearingHistory {
            pruneExpiredItemsIfNeeded(now: now)
        }
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = currentChangeCount
        currentHistoryItemPasteboardState = nil

        // Consume suppression before asking for types, source context, or text. Private copies must
        // never cross the payload-reading boundary, even briefly in memory.
        if suppressPasteboardChangeIfNeeded() {
            return
        }
        guard !isClearingHistory else { return }

        let currentSettings = settings.snapshot
        if isCaptureBlockedByPinnedItems {
            onCaptureRejection?(.pinnedItemsFillCapacity, currentSettings.maximumItemCount)
            return
        }

        let sourceApplication = sourceContext.frontmostApplication()
        guard ClipboardCapturePolicy.preflight(
            types: pasteboard.typeNames,
            sourceApplication: sourceApplication,
            settings: currentSettings
        ) == nil else {
            return
        }

        let payload: ClipboardHistoryPayload
        switch pasteboard.readPayload(maximumByteCount: currentSettings.maximumItemByteCount) {
        case let .payload(capturedPayload):
            payload = capturedPayload
        case .empty:
            return
        case .oversized:
            onCaptureRejection?(.oversized, currentSettings.maximumItemByteCount)
            return
        }

        let decision = ClipboardCapturePolicy.evaluatePayload(
            payload,
            sourceApplication: sourceApplication,
            settings: currentSettings,
            newestItem: items.first,
            now: now
        )
        let item: ClipboardHistoryItem
        switch decision {
        case let .capture(capturedItem):
            item = capturedItem
        case let .ignore(reason):
            if reason == .duplicateNewestItem, let newestItem = items.first {
                currentHistoryItemPasteboardState = (
                    itemID: newestItem.id,
                    changeCount: currentChangeCount
                )
            }
            if reason == .oversized {
                onCaptureRejection?(.oversized, currentSettings.maximumItemByteCount)
            }
            return
        }

        let retention = ClipboardRetentionPolicy.evaluate(
            [item] + items,
            settings: currentSettings
        )
        let updated = retention.items
        guard updated != items else {
            if !updated.contains(where: { $0.id == item.id }) {
                onCaptureRejection?(.pinnedItemsFillCapacity, currentSettings.maximumItemCount)
            }
            return
        }
        items = updated
        isCaptureBlockedByPinnedItems = retention.isCaptureBlockedByPinnedItems
        if updated.contains(where: { $0.id == item.id }) {
            currentHistoryItemPasteboardState = (
                itemID: item.id,
                changeCount: currentChangeCount
            )
        }
        persistCurrentItems()
        notifyChanged()
        enqueueImageTextIndexing(for: [item])
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
        notifyChanged()
        onCaptureSuppressionEvent?(.armed(mode: mode, timeout: timeout))
        scheduleCaptureSuppressionExpiration(after: timeout)
        return true
    }

    func cancelNextCaptureSuppression() {
        clearCaptureSuppression(notifyCancellation: true)
    }

    private func clearCaptureSuppression(notifyCancellation: Bool) {
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
        notifyChanged()
        if notifyCancellation,
           !hadObservedSuppressedChange,
           let mode {
            onCaptureSuppressionEvent?(.cancelled(mode: mode))
        }
    }

    @discardableResult
    func copyItem(id: UUID) -> Bool {
        guard !isClearingHistory else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard let payload = try? items[index].loadPayload() else { return false }
        guard !payload.hasUnavailableFileReferences else { return false }
        guard pasteboard.writePayload(payload) else { return false }
        items[index].discardCachedPayloadIfReloadable()
        currentHistoryItemPasteboardState = (
            itemID: items[index].id,
            changeCount: pasteboard.changeCount
        )
        markItemUsed(at: index)
        return true
    }

    func preparePayloadForUse(id: UUID) async -> Bool {
        guard !isClearingHistory,
              let item = items.first(where: { $0.id == id }) else {
            return false
        }
        return await Task.detached(priority: .userInitiated) {
            (try? item.loadPayload()) != nil
        }.value
    }

    func releasePayloadIfReloadable(id: UUID?) {
        guard let id, let item = items.first(where: { $0.id == id }) else { return }
        item.discardCachedPayloadIfReloadable()
    }

    @discardableResult
    func copyItemAsPlainText(id: UUID) -> Bool {
        guard !isClearingHistory else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard let text = ClipboardPlainTextConversion.text(for: items[index]) else { return false }
        guard pasteboard.writePlainText(text) else { return false }
        items[index].discardCachedPayloadIfReloadable()
        currentHistoryItemPasteboardState = nil
        markItemUsed(at: index)
        return true
    }

    /// Replaces the current system clipboard with its native plain-text representation, or with
    /// completed OCR from the history item captured from the same still-current pasteboard change.
    /// Native text remains independent of history loading and collection state.
    @discardableResult
    func rewriteCurrentClipboardAsPlainText() -> ClipboardPlainTextRewriteResult {
        if let text = pasteboard.readPlainText(), !text.isEmpty {
            guard pasteboard.writePlainText(text) else { return .unavailable }
            currentHistoryItemPasteboardState = nil
            lastSeenChangeCount = pasteboard.changeCount
            return .succeeded
        }

        guard let currentHistoryItemPasteboardState,
              currentHistoryItemPasteboardState.changeCount == pasteboard.changeCount,
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

    private func markItemUsed(at index: Int) {
        lastSeenChangeCount = pasteboard.changeCount
        items[index].lastUsedAt = Date()
        persistCurrentItems()
        notifyChanged()
    }

    func togglePin(id: UUID) {
        guard !isClearingHistory else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        items = ClipboardRetentionPolicy.prune(items, settings: settings.snapshot)
        refreshCapacityState()
        persistCurrentItems()
        notifyChanged()
    }

    @discardableResult
    func deleteItem(id: UUID) async -> Bool {
        guard !isClearingHistory else { return false }
        guard items.contains(where: { $0.id == id }) else { return false }
        return await replaceItemsDurably(with: items.filter { $0.id != id })
    }

    @discardableResult
    func clearUnpinnedHistory() async -> Bool {
        let retained = items.filter(\.isPinned)
        return await replaceItemsDurably(with: retained)
    }

    @discardableResult
    func clearAllHistory() async -> Bool {
        if errorMessage != nil {
            return await resetPersistentHistory()
        }
        return await replaceItemsDurably(with: [])
    }

    func matchingItems(query: String) -> [ClipboardHistoryItem] {
        ClipboardHistorySearch.filter(items, query: query)
    }

    private func finishLoading(_ loadedItems: [ClipboardHistoryItem]) {
        loadTask = nil
        isLoaded = true
        let pruned = ClipboardRetentionPolicy.prune(loadedItems, settings: settings.snapshot)
        items = pruned
        refreshCapacityState()
        if pruned != loadedItems {
            persistCurrentItems()
        }
        notifyChanged()
        startMonitoringIfPossible()
        enqueueImageTextIndexing(for: pruned)
    }

    private func finishLoading(with error: Error) {
        loadTask = nil
        isLoaded = true
        errorMessage = errorMessageProvider(error)
        notifyChanged()
    }

    private func startMonitoringIfPossible() {
        guard timer == nil, errorMessage == nil else { return }
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
        guard items.contains(where: { !$0.isPinned && $0.capturedAt < cutoff }) else {
            return
        }
        let pruned = ClipboardRetentionPolicy.prune(
            items,
            settings: currentSettings,
            now: now
        )
        guard pruned != items else { return }
        items = pruned
        refreshCapacityState()
        persistCurrentItems()
        notifyChanged()
    }

    private func suppressPasteboardChangeIfNeeded() -> Bool {
        guard isIgnoringNextCopy else { return false }
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
            self.notifyChanged()
            if !hadObservedSuppressedChange, let mode {
                self.onCaptureSuppressionEvent?(.expired(mode: mode))
            }
        }
    }

    @objc private func checkPasteboardTimer() {
        processPasteboardChange()
    }

    private func persistCurrentItems() {
        let request = makePersistenceRequest()
        persistenceWorker.enqueueSave(request.items, revision: request.revision) { [weak self] outcome in
            guard let error = outcome.error else { return }
            Task { @MainActor [weak self] in
                self?.handlePersistenceFailure(
                    error,
                    revision: outcome.revision,
                    durableItems: outcome.durableItems
                )
            }
        }
    }

    private func replaceItemsDurably(with replacement: [ClipboardHistoryItem]) async -> Bool {
        guard !isClearingHistory else { return false }
        isClearingHistory = true
        notifyChanged()

        let succeeded = await persistBarrierAndWait(replacement)
        if succeeded {
            items = replacement
            refreshCapacityState()
        }
        isClearingHistory = false
        notifyChanged()
        if succeeded {
            reconcileSettingsIfNeeded()
        }
        enqueueImageTextIndexing(for: items)
        return succeeded
    }

    private func persistBarrierAndWait(_ replacement: [ClipboardHistoryItem]) async -> Bool {
        let request = makePersistenceRequest(items: replacement)
        let outcome = await persistenceWorker.saveBarrier(
            request.items,
            revision: request.revision
        )
        guard let error = outcome.error else { return true }
        handlePersistenceFailure(
            error,
            revision: outcome.revision,
            durableItems: outcome.durableItems
        )
        return false
    }

    private func resetPersistentHistory() async -> Bool {
        guard !isClearingHistory else { return false }
        isClearingHistory = true
        notifyChanged()
        do {
            try await persistenceWorker.reset()
            items = []
            refreshCapacityState()
            errorMessage = nil
            isLoaded = true
            lastSeenChangeCount = pasteboard.changeCount
            isClearingHistory = false
            notifyChanged()
            reconcileSettingsIfNeeded()
            startMonitoringIfPossible()
            return true
        } catch {
            isClearingHistory = false
            errorMessage = errorMessageProvider(error)
            notifyChanged()
            return false
        }
    }

    private func reconcileSettingsIfNeeded() {
        guard needsSettingsReconciliation else { return }
        needsSettingsReconciliation = false
        settingsDidChange()
    }

    private func makePersistenceRequest(
        items requestedItems: [ClipboardHistoryItem]? = nil
    ) -> (items: [ClipboardHistoryItem], revision: UInt64) {
        persistenceRevision &+= 1
        return (requestedItems ?? items, persistenceRevision)
    }

    private func handlePersistenceFailure(
        _ error: Error,
        revision: UInt64,
        durableItems: [ClipboardHistoryItem]
    ) {
        guard revision == persistenceRevision else { return }
        items = durableItems
        refreshCapacityState()
        errorMessage = errorMessageProvider(error)
        timer?.invalidate()
        timer = nil
        notifyChanged()
    }

    private func notifyChanged() {
        onChange?()
        objectWillChange.send()
    }

    private func enqueueImageTextIndexing(for candidates: [ClipboardHistoryItem]) {
        for item in candidates where item.kind == .image && !item.hasCompletedImageTextIndexing {
            guard pendingImageIndexItemIDSet.insert(item.id).inserted else { continue }
            pendingImageIndexItemIDs.append(item.id)
        }
        startNextImageTextIndexingIfNeeded()
    }

    private func startNextImageTextIndexingIfNeeded() {
        guard imageIndexingTask == nil,
              isLoaded,
              errorMessage == nil,
              !isClearingHistory else {
            return
        }

        while let itemID = pendingImageIndexItemIDs.first {
            pendingImageIndexItemIDs.removeFirst()
            pendingImageIndexItemIDSet.remove(itemID)
            guard let item = items.first(where: {
                $0.id == itemID && $0.kind == .image && !$0.hasCompletedImageTextIndexing
            }) else {
                continue
            }

            let recognizer = imageTextRecognizer
            imageIndexingTask = Task { [weak self] in
                let payload = await Task.detached(priority: .utility) {
                    try? item.loadPayload()
                }.value
                guard let payload else { return }
                let recognizedText = await recognizer.recognizeText(in: payload)
                guard !Task.isCancelled else { return }
                self?.finishImageTextIndexing(itemID: itemID, recognizedText: recognizedText)
            }
            return
        }
    }

    private func finishImageTextIndexing(itemID: UUID, recognizedText: String?) {
        imageIndexingTask = nil
        defer { startNextImageTextIndexingIfNeeded() }
        guard !isClearingHistory,
              let index = items.firstIndex(where: { $0.id == itemID }),
              !items[index].hasCompletedImageTextIndexing else {
            return
        }
        items[index].setImageSearchText(recognizedText)
        items[index].hasCompletedImageTextIndexing = true
        items = ClipboardRetentionPolicy.prune(items, settings: settings.snapshot)
        refreshCapacityState()
        persistCurrentItems()
        notifyChanged()
    }

    private func cancelImageIndexing() {
        imageIndexingTask?.cancel()
        imageIndexingTask = nil
        pendingImageIndexItemIDs.removeAll()
        pendingImageIndexItemIDSet.removeAll()
    }

    private func refreshCapacityState() {
        let maximumItemCount = settings.maximumItemCount == ClipboardHistorySettings.noItemCountLimit
            ? ClipboardHistorySettings.maximumSupportedItemCount
            : settings.maximumItemCount
        var pinnedItemCount = 0
        var pinnedPayloadByteCount = 0
        for item in items where item.isPinned {
            pinnedItemCount += 1
            pinnedPayloadByteCount += item.payloadByteCount
        }
        isCaptureBlockedByPinnedItems =
            pinnedItemCount >= maximumItemCount
            || pinnedPayloadByteCount >= settings.maximumTotalPayloadByteCount
    }
}
