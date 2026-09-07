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
    private var explicitQueueCreationGeneration: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    private var isCancellingQueue = false

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
        explicitQueueCreationGeneration &+= 1
        let creationGeneration = explicitQueueCreationGeneration
        mutationRevision &+= 1
        let revision = mutationRevision
        let nextSession = try ClipboardSequentialPasteSession(
            explicitSnapshots: snapshots,
            createdAt: now
        )
        try Task.checkCancellation()
        try await store.saveExplicitSession(nextSession)
        guard creationGeneration == explicitQueueCreationGeneration,
              revision == mutationRevision,
              !Task.isCancelled else {
            // The write may already be durable when the caller is cancelled. Compensate from a
            // fresh task so a hidden queue cannot reappear after the next app launch.
            let cleanup = Task { [store] in try await store.saveExplicitSession(nil) }
            do {
                try await cleanup.value
            } catch {
                persistenceError = error
                throw error
            }
            throw CancellationError()
        }
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
        guard !isCancellingQueue,
              var next = session,
              next.matches(operation) else { return false }
        mutationRevision &+= 1
        let revision = mutationRevision
        next.recordSuccessfulPaste(now: now)
        // The paste is irreversible. Keep the advanced state in memory on failure and block
        // later steps until a retry makes it durable, preventing an immediate duplicate paste.
        session = next
        return await persistCurrentSession(revision: revision)
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
        guard !isCancellingQueue else { return true }
        isCancellingQueue = true
        defer { isCancellingQueue = false }
        explicitQueueCreationGeneration &+= 1
        mutationRevision &+= 1
        let revision = mutationRevision
        do {
            try await store.saveExplicitSession(nil)
            guard revision == mutationRevision else { return false }
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

    /// Invalidates a queue that is still loading or saving its immutable snapshots. If its save
    /// has already committed, `startExplicitQueue` performs a compensating delete before it exits.
    func cancelPendingExplicitQueueCreation() {
        explicitQueueCreationGeneration &+= 1
    }

    /// Prevents an in-flight restore or later retry from recreating clipboard storage
    /// after the user explicitly resets or removes the plugin's local data.
    func prepareForStorageReset() {
        restoreTask?.cancel()
        restoreTask = nil
        explicitQueueCreationGeneration &+= 1
        mutationRevision &+= 1
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
        guard !isCancellingQueue, var next = session else { return false }
        mutationRevision &+= 1
        let revision = mutationRevision
        mutation(&next)
        return await save(next, revision: revision)
    }

    private func mutateDurably(
        matching operation: ClipboardSequentialPasteOperation,
        _ mutation: (inout ClipboardSequentialPasteSession) -> Void
    ) async -> Bool {
        guard !isCancellingQueue,
              var next = session,
              next.matches(operation) else { return false }
        mutationRevision &+= 1
        let revision = mutationRevision
        mutation(&next)
        return await save(next, revision: revision)
    }

    private func save(_ next: ClipboardSequentialPasteSession, revision: UInt64) async -> Bool {
        let stored = next.source == .explicitQueue && !next.isComplete ? next : nil
        do {
            try await store.saveExplicitSession(stored)
            guard revision == mutationRevision, !isCancellingQueue else { return false }
            session = next
            persistenceError = nil
            return true
        } catch {
            persistenceError = error
            return false
        }
    }

    private func persistCurrentSession(revision: UInt64? = nil) async -> Bool {
        guard let session else { return true }
        let stored = session.source == .explicitQueue && !session.isComplete ? session : nil
        do {
            try await store.saveExplicitSession(stored)
            if let revision,
               revision != mutationRevision || isCancellingQueue {
                return false
            }
            persistenceError = nil
            return true
        } catch {
            persistenceError = error
            return false
        }
    }

    private func retryFailedPersistenceIfNeeded() async throws {
        guard persistenceError != nil else { return }
        guard !isCancellingQueue, await persistCurrentSession() else {
            throw persistenceError ?? ClipboardHistoryStoreError.unavailableStorage
        }
    }
}
