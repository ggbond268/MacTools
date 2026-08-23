import Foundation

final class CLIRequestSendState: @unchecked Sendable {
    private let lock = NSLock()
    private var didBeginSending = false
    private var isCancelled = false
    private var didForwardCancellation = false

    func beginSending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        didBeginSending = true
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func takeCancellationToForward() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCancelled, didBeginSending, !didForwardCancellation else { return false }
        didForwardCancellation = true
        return true
    }
}

final class CLICommandTaskState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int32, Error>?
    private var isCancelled = false

    func install(_ task: Task<Int32, Error>) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

final class CLISignalState: @unchecked Sendable {
    private let lock = NSLock()
    private var handled = false
    private var finished = false

    func beginHandlingSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !handled, !finished else { return false }
        handled = true
        return true
    }

    func beginFinishing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

struct CLIHostCancellationRelayState {
    enum Disposition: Equatable {
        case cancelActive
        case recordedBeforeRegistration
        case alreadyCompleted
        case capacityExceeded
    }

    private(set) var pendingRequestIDs: Set<UUID> = []
    private(set) var completedRequestIDs: Set<UUID> = []
    private var completedOrder: [UUID] = []
    let maximumTrackedRequestCount: Int

    init(maximumTrackedRequestCount: Int = 32) {
        self.maximumTrackedRequestCount = maximumTrackedRequestCount
    }

    mutating func shouldBeginHandling(_ requestID: UUID) -> Bool {
        completedRequestIDs.remove(requestID)
        completedOrder.removeAll { $0 == requestID }
        return pendingRequestIDs.remove(requestID) == nil
    }

    mutating func cancellationDisposition(
        requestID: UUID,
        hasActiveTask: Bool
    ) -> Disposition {
        if hasActiveTask { return .cancelActive }
        if completedRequestIDs.contains(requestID) { return .alreadyCompleted }
        if pendingRequestIDs.contains(requestID) { return .recordedBeforeRegistration }
        guard pendingRequestIDs.count < maximumTrackedRequestCount else {
            return .capacityExceeded
        }
        pendingRequestIDs.insert(requestID)
        return .recordedBeforeRegistration
    }

    mutating func markCompleted(_ requestID: UUID) {
        pendingRequestIDs.remove(requestID)
        guard completedRequestIDs.insert(requestID).inserted else { return }
        completedOrder.append(requestID)
        while completedOrder.count > maximumTrackedRequestCount {
            completedRequestIDs.remove(completedOrder.removeFirst())
        }
    }

    mutating func reset() {
        pendingRequestIDs.removeAll()
        completedRequestIDs.removeAll()
        completedOrder.removeAll()
    }
}
