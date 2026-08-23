import Foundation

struct CLIRequestAdmissionState<ClientID: Hashable> {
    enum Rejection: Equatable {
        case duplicateRequestID
        case clientCapacity
        case globalCapacity
        case recursiveInvocation
        case invalidInvocationContext
        case cancelledBeforeAdmission
    }

    enum CancellationDisposition: Equatable {
        case recorded
        case forwardToHost
    }

    private(set) var activeRequests: [UUID: ClientID] = [:]
    private(set) var activeInvocationContexts: [UUID: CLIInvocationContext] = [:]
    private(set) var pendingCancellations: [UUID: ClientID] = [:]
    private(set) var activeCancellations: Set<UUID> = []
    private(set) var forwardedRequests: Set<UUID> = []
    let maximumRequestsPerClient: Int
    let maximumRequestsGlobally: Int

    init(maximumRequestsPerClient: Int = 8, maximumRequestsGlobally: Int = 32) {
        self.maximumRequestsPerClient = maximumRequestsPerClient
        self.maximumRequestsGlobally = maximumRequestsGlobally
    }

    mutating func admit(
        requestID: UUID,
        clientID: ClientID,
        invocationContext: CLIInvocationContext? = nil
    ) -> Rejection? {
        if pendingCancellations[requestID] == clientID {
            pendingCancellations[requestID] = nil
            return .cancelledBeforeAdmission
        }
        guard activeRequests[requestID] == nil else { return .duplicateRequestID }
        if let invocationContext {
            guard invocationContext.depth > 0,
                  invocationContext.depth <= CLIProtocolVersion.maximumInvocationDepth else {
                return .invalidInvocationContext
            }
            if activeInvocationContexts.values.contains(where: {
                $0.chainID == invocationContext.chainID
            }) {
                return .recursiveInvocation
            }
            return .invalidInvocationContext
        }
        guard activeRequests.count < maximumRequestsGlobally else { return .globalCapacity }
        guard activeRequests.values.lazy.filter({ $0 == clientID }).count
                < maximumRequestsPerClient else { return .clientCapacity }
        activeRequests[requestID] = clientID
        activeInvocationContexts[requestID] = CLIInvocationContext(
            chainID: UUID(),
            depth: 0
        )
        return nil
    }

    mutating func finish(requestID: UUID, clientID: ClientID) {
        guard activeRequests[requestID] == clientID else { return }
        activeRequests[requestID] = nil
        activeInvocationContexts[requestID] = nil
        activeCancellations.remove(requestID)
        forwardedRequests.remove(requestID)
    }

    func owns(requestID: UUID, clientID: ClientID) -> Bool {
        activeRequests[requestID] == clientID
    }

    func invocationContext(requestID: UUID, clientID: ClientID) -> CLIInvocationContext? {
        guard owns(requestID: requestID, clientID: clientID) else { return nil }
        return activeInvocationContexts[requestID]
    }

    /// Atomically transitions an admitted request to host forwarding. A cancellation
    /// recorded after admission but before this transition consumes the request instead.
    mutating func beginForwarding(requestID: UUID, clientID: ClientID) -> Bool {
        guard owns(requestID: requestID, clientID: clientID) else { return false }
        if activeCancellations.remove(requestID) != nil { return false }
        forwardedRequests.insert(requestID)
        return true
    }

    /// Records cancellation before admission/forwarding, or identifies work that has already
    /// been enqueued to the host and therefore needs an explicit host cancellation message.
    mutating func cancel(
        requestID: UUID,
        clientID: ClientID
    ) -> CancellationDisposition? {
        if activeRequests[requestID] == clientID {
            if forwardedRequests.contains(requestID) { return .forwardToHost }
            activeCancellations.insert(requestID)
            return .recorded
        }
        if activeRequests[requestID] != nil { return nil }
        if pendingCancellations[requestID] == clientID { return .recorded }
        guard pendingCancellations.values.lazy.filter({ $0 == clientID }).count
                < maximumRequestsPerClient else { return nil }
        pendingCancellations[requestID] = clientID
        return .recorded
    }

    mutating func removeRequests(clientID: ClientID) -> [UUID] {
        let requestIDs = activeRequests.compactMap { requestID, owner in
            owner == clientID ? requestID : nil
        }
        requestIDs.forEach { activeRequests[$0] = nil }
        requestIDs.forEach { activeInvocationContexts[$0] = nil }
        requestIDs.forEach { activeCancellations.remove($0) }
        requestIDs.forEach { forwardedRequests.remove($0) }
        pendingCancellations = pendingCancellations.filter { $0.value != clientID }
        return requestIDs
    }
}
