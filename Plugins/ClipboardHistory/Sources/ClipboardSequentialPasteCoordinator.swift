import Combine
import Foundation

@MainActor
final class ClipboardSequentialPasteCoordinator: ObservableObject {
    static let recentHistoryLimit = ClipboardSequentialPasteSession.maximumItemCount

    @Published private(set) var session: ClipboardSequentialPasteSession?
    @Published private(set) var persistenceError: Error?

    private let store: ClipboardSequentialPasteSessionPersisting
    private var restoreTask: Task<ClipboardSequentialPasteSession?, Error>?
    private var hasRestoredExplicitQueue = false
    private var isStartingExplicitQueue = false

    init(
        store: ClipboardSequentialPasteSessionPersisting = ClipboardSequentialPasteMemoryStore(),
        initialSession: ClipboardSequentialPasteSession? = nil
    ) {
        self.store = store
        session = initialSession
        hasRestoredExplicitQueue = initialSession != nil
    }

    func restoreExplicitQueue() async throws {
        if hasRestoredExplicitQueue { return }
        let task: Task<ClipboardSequentialPasteSession?, Error>
        if let restoreTask {
            task = restoreTask
        } else {
            let store = store
            task = Task { try await store.loadExplicitSession() }
            restoreTask = task
        }
        do {
            let restored = try await task.value
            try Task.checkCancellation()
            guard !hasRestoredExplicitQueue else { return }
            if session == nil { session = restored }
            hasRestoredExplicitQueue = true
            persistenceError = nil
            restoreTask = nil
        } catch {
            restoreTask = nil
            persistenceError = error
            throw error
        }
    }

    func protectedItemIDs() -> Set<UUID> {
        guard let session, !session.isComplete, session.source == .recentHistory else { return [] }
        return Set(session.itemIDs)
    }

    func startExplicitQueue(
        snapshots: [ClipboardSequentialPasteSnapshot],
        now: Date = Date()
    ) async throws {
        try await restoreExplicitQueue()
        if isStartingExplicitQueue || session?.isComplete == false {
            throw ClipboardSequentialQueueError.activeQueueExists
        }
        isStartingExplicitQueue = true
        defer { isStartingExplicitQueue = false }
        let nextSession = try ClipboardSequentialPasteSession(
            explicitSnapshots: snapshots,
            createdAt: now
        )
        try await store.saveExplicitSession(nextSession)
        try Task.checkCancellation()
        session = nextSession
        persistenceError = nil
    }

    func nextOperation(
        recentHistoryItemIDs: [UUID],
        now: Date = Date()
    ) async throws -> ClipboardSequentialPasteOperation? {
        try await restoreExplicitQueue()
        try await retryFailedPersistenceIfNeeded()
        ensureActiveSession(recentHistoryItemIDs: recentHistoryItemIDs, now: now)
        guard let activeSession = session, !activeSession.isComplete else { return nil }
        return activeSession.nextOperation
    }

    func nextItemID(
        recentHistoryItemIDs: [UUID],
        now: Date = Date()
    ) async throws -> UUID? {
        try await nextOperation(
            recentHistoryItemIDs: recentHistoryItemIDs,
            now: now
        )?.itemID
    }

    @discardableResult
    func recordSuccessfulPaste(
        operation: ClipboardSequentialPasteOperation,
        now: Date = Date()
    ) async -> Bool {
        guard var next = session, next.matches(operation) else { return false }
        next.recordSuccessfulPaste(now: now)
        // The paste is irreversible. Keep the advanced state in memory on failure and block
        // later steps until a retry makes it durable, preventing an immediate duplicate paste.
        session = next
        return await persistCurrentSession()
    }

    @discardableResult
    func markCurrentUnavailable(
        operation: ClipboardSequentialPasteOperation,
        now: Date = Date()
    ) async -> Bool {
        await mutateDurably(matching: operation) { $0.markCurrentUnavailable(now: now) }
    }

    func skip(now: Date = Date()) async -> Bool {
        await mutateDurably { $0.skip(now: now) }
    }

    func moveToPrevious(now: Date = Date()) async -> Bool {
        await mutateDurably { $0.moveToPrevious(now: now) }
    }

    func restart(now: Date = Date()) async -> Bool {
        await mutateDurably { $0.restart(now: now) }
    }

    func cancel() async -> Bool {
        do {
            try await store.saveExplicitSession(nil)
            session = nil
            persistenceError = nil
            return true
        } catch {
            persistenceError = error
            return false
        }
    }

    func invalidatePendingPersistence() {
        restoreTask?.cancel()
        restoreTask = nil
        persistenceError = nil
    }

    /// Prevents an in-flight restore or later retry from recreating clipboard storage
    /// after the user explicitly resets or removes the plugin's local data.
    func prepareForStorageReset() {
        restoreTask?.cancel()
        restoreTask = nil
        session = nil
        persistenceError = nil
        hasRestoredExplicitQueue = true
        isStartingExplicitQueue = false
    }

    func resetImplicitQueueForExternalCopy() {
        guard session?.source == .recentHistory else { return }
        session = nil
    }

    private func ensureActiveSession(recentHistoryItemIDs: [UUID], now: Date) {
        if let session, !session.isComplete { return }
        let recentIDs = Array(recentHistoryItemIDs.prefix(Self.recentHistoryLimit))
        session = try? ClipboardSequentialPasteSession(
            recentHistoryItemIDs: recentIDs,
            createdAt: now
        )
    }

    private func mutateDurably(
        _ mutation: (inout ClipboardSequentialPasteSession) -> Void
    ) async -> Bool {
        guard var next = session else { return false }
        mutation(&next)
        return await save(next)
    }

    private func mutateDurably(
        matching operation: ClipboardSequentialPasteOperation,
        _ mutation: (inout ClipboardSequentialPasteSession) -> Void
    ) async -> Bool {
        guard var next = session, next.matches(operation) else { return false }
        mutation(&next)
        return await save(next)
    }

    private func save(_ next: ClipboardSequentialPasteSession) async -> Bool {
        let stored = next.source == .explicitQueue && !next.isComplete ? next : nil
        do {
            try await store.saveExplicitSession(stored)
            session = next
            persistenceError = nil
            return true
        } catch {
            persistenceError = error
            return false
        }
    }

    private func persistCurrentSession() async -> Bool {
        guard let session else { return true }
        let stored = session.source == .explicitQueue && !session.isComplete ? session : nil
        do {
            try await store.saveExplicitSession(stored)
            persistenceError = nil
            return true
        } catch {
            persistenceError = error
            return false
        }
    }

    private func retryFailedPersistenceIfNeeded() async throws {
        guard persistenceError != nil else { return }
        guard await persistCurrentSession() else {
            throw persistenceError ?? ClipboardHistoryStoreError.unavailableStorage
        }
    }
}
