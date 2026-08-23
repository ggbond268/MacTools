import Foundation

struct CLIRequestAdmissionState<ClientID: Hashable> {
    enum Rejection: Equatable {
        case duplicateRequestID
        case clientCapacity
        case globalCapacity
    }

    private(set) var activeRequests: [UUID: ClientID] = [:]
    let maximumRequestsPerClient: Int
    let maximumRequestsGlobally: Int

    init(maximumRequestsPerClient: Int = 8, maximumRequestsGlobally: Int = 32) {
        self.maximumRequestsPerClient = maximumRequestsPerClient
        self.maximumRequestsGlobally = maximumRequestsGlobally
    }

    mutating func admit(requestID: UUID, clientID: ClientID) -> Rejection? {
        guard activeRequests[requestID] == nil else { return .duplicateRequestID }
        guard activeRequests.count < maximumRequestsGlobally else { return .globalCapacity }
        guard activeRequests.values.lazy.filter({ $0 == clientID }).count
                < maximumRequestsPerClient else { return .clientCapacity }
        activeRequests[requestID] = clientID
        return nil
    }

    mutating func finish(requestID: UUID, clientID: ClientID) {
        guard activeRequests[requestID] == clientID else { return }
        activeRequests[requestID] = nil
    }

    func owns(requestID: UUID, clientID: ClientID) -> Bool {
        activeRequests[requestID] == clientID
    }

    mutating func removeRequests(clientID: ClientID) -> [UUID] {
        let requestIDs = activeRequests.compactMap { requestID, owner in
            owner == clientID ? requestID : nil
        }
        requestIDs.forEach { activeRequests[$0] = nil }
        return requestIDs
    }
}
