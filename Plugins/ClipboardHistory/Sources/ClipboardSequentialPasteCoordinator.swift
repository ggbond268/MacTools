import Combine
import Foundation

@MainActor
final class ClipboardSequentialPasteCoordinator: ObservableObject {
    static let recentHistoryLimit = ClipboardSequentialPasteSession.maximumItemCount

    @Published private(set) var session: ClipboardSequentialPasteSession?

    private let store: ClipboardSequentialPasteSessionPersisting

    init(store: ClipboardSequentialPasteSessionPersisting = ClipboardSequentialPasteMemoryStore()) {
        self.store = store
        session = store.loadExplicitSession()
    }

    func protectedItemIDs() -> Set<UUID> {
        guard let session, !session.isComplete else { return [] }
        return Set(session.itemIDs)
    }

    func startExplicitQueue(
        itemIDs: [UUID],
        now: Date = Date()
    ) throws {
        if let session, !session.isComplete {
            throw ClipboardSequentialQueueError.activeQueueExists
        }
        session = try ClipboardSequentialPasteSession(
            source: .explicitQueue,
            itemIDs: itemIDs,
            createdAt: now
        )
        persistExplicitSession()
    }

    func availablePasteRequestCount(
        recentHistoryItemIDs: [UUID],
        now: Date = Date()
    ) -> Int {
        ensureActiveSession(recentHistoryItemIDs: recentHistoryItemIDs, now: now)
        return session?.remainingCount ?? 0
    }

    func nextItemID(recentHistoryItemIDs: [UUID], now: Date = Date()) -> UUID? {
        nextOperation(recentHistoryItemIDs: recentHistoryItemIDs, now: now)?.itemID
    }

    func nextOperation(
        recentHistoryItemIDs: [UUID],
        now: Date = Date()
    ) -> ClipboardSequentialPasteOperation? {
        ensureActiveSession(recentHistoryItemIDs: recentHistoryItemIDs, now: now)
        guard let activeSession = session, !activeSession.isComplete else { return nil }
        return activeSession.nextOperation
    }

    @discardableResult
    func recordSuccessfulPaste(
        operation: ClipboardSequentialPasteOperation,
        now: Date = Date()
    ) -> Bool {
        mutateSession(matching: operation) { $0.recordSuccessfulPaste(now: now) }
    }

    @discardableResult
    func markCurrentUnavailable(
        operation: ClipboardSequentialPasteOperation,
        now: Date = Date()
    ) -> Bool {
        mutateSession(matching: operation) { $0.markCurrentUnavailable(now: now) }
    }

    func skip(now: Date = Date()) {
        mutateSession { $0.skip(now: now) }
    }

    func moveToPrevious(now: Date = Date()) {
        mutateSession { $0.moveToPrevious(now: now) }
    }

    func restart(now: Date = Date()) {
        mutateSession { $0.restart(now: now) }
    }

    func cancel() {
        session = nil
        store.saveExplicitSession(nil)
    }

    func resetImplicitQueueForExternalCopy() {
        guard session?.source == .recentHistory else { return }
        session = nil
    }

    private func ensureActiveSession(recentHistoryItemIDs: [UUID], now: Date) {
        if let session {
            if session.source == .explicitQueue, !session.isComplete {
                return
            }
            if session.source == .recentHistory, !session.isComplete {
                return
            }
        }

        let recentIDs = Array(recentHistoryItemIDs.prefix(Self.recentHistoryLimit))
        session = try? ClipboardSequentialPasteSession(
            source: .recentHistory,
            itemIDs: recentIDs,
            createdAt: now
        )
        persistExplicitSession()
    }

    private func mutateSession(
        _ mutation: (inout ClipboardSequentialPasteSession) -> Void
    ) {
        guard var session else { return }
        mutation(&session)
        self.session = session
        persistExplicitSession()
    }

    private func mutateSession(
        matching operation: ClipboardSequentialPasteOperation,
        _ mutation: (inout ClipboardSequentialPasteSession) -> Void
    ) -> Bool {
        guard var session, session.matches(operation) else { return false }
        mutation(&session)
        self.session = session
        persistExplicitSession()
        return true
    }

    private func persistExplicitSession() {
        guard session?.source == .explicitQueue else {
            store.saveExplicitSession(nil)
            return
        }
        store.saveExplicitSession(session)
    }
}
