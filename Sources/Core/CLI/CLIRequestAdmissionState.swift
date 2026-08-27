import Foundation
import MacToolsCLIProtocol

struct CLIRequestAdmissionState {
    private var requestsByClient: [ObjectIdentifier: Set<UUID>] = [:]

    mutating func admit(requestID: UUID, clientID: ObjectIdentifier) -> Bool {
        let globalCount = requestsByClient.values.reduce(0) { $0 + $1.count }
        var requests = requestsByClient[clientID, default: []]
        guard globalCount < CLIProtocolVersion.maximumInFlightRequestsGlobally,
              requests.count < CLIProtocolVersion.maximumInFlightRequestsPerClient,
              !requestsByClient.values.contains(where: { $0.contains(requestID) }) else {
            return false
        }
        requests.insert(requestID)
        requestsByClient[clientID] = requests
        return true
    }

    mutating func finish(requestID: UUID, clientID: ObjectIdentifier) {
        requestsByClient[clientID]?.remove(requestID)
        if requestsByClient[clientID]?.isEmpty == true {
            requestsByClient.removeValue(forKey: clientID)
        }
    }

    mutating func removeAll(clientID: ObjectIdentifier) -> [UUID] {
        Array(requestsByClient.removeValue(forKey: clientID) ?? [])
    }

    func contains(requestID: UUID, clientID: ObjectIdentifier) -> Bool {
        requestsByClient[clientID]?.contains(requestID) == true
    }
}
