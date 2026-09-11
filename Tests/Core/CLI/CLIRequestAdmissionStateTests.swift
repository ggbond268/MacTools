import MacToolsCLIProtocol
import XCTest
@testable import MacTools

final class CLIRequestAdmissionStateTests: XCTestCase {
    func testRejectsDuplicateRequestIDAcrossClients() {
        var state = CLIRequestAdmissionState()
        let first = ClientToken()
        let second = ClientToken()
        let requestID = UUID()

        XCTAssertTrue(state.admit(requestID: requestID, clientID: ObjectIdentifier(first)))
        XCTAssertFalse(state.admit(requestID: requestID, clientID: ObjectIdentifier(second)))
    }

    func testEnforcesPerClientAndGlobalLimitsAndReleasesCapacity() {
        var state = CLIRequestAdmissionState()
        var clients: [ClientToken] = []
        var admitted: [(UUID, ObjectIdentifier)] = []

        let first = ClientToken()
        clients.append(first)
        let firstID = ObjectIdentifier(first)
        for _ in 0..<CLIProtocolVersion.maximumInFlightRequestsPerClient {
            let requestID = UUID()
            XCTAssertTrue(state.admit(requestID: requestID, clientID: firstID))
            admitted.append((requestID, firstID))
        }
        XCTAssertFalse(state.admit(requestID: UUID(), clientID: firstID))

        while admitted.count < CLIProtocolVersion.maximumInFlightRequestsGlobally {
            let client = ClientToken()
            clients.append(client)
            let clientID = ObjectIdentifier(client)
            let requestID = UUID()
            XCTAssertTrue(state.admit(requestID: requestID, clientID: clientID))
            admitted.append((requestID, clientID))
        }
        let overflowClient = ClientToken()
        clients.append(overflowClient)
        XCTAssertFalse(state.admit(
            requestID: UUID(),
            clientID: ObjectIdentifier(overflowClient)
        ))

        let released = admitted[0]
        state.finish(requestID: released.0, clientID: released.1)
        XCTAssertTrue(state.admit(
            requestID: UUID(),
            clientID: ObjectIdentifier(overflowClient)
        ))
        XCTAssertFalse(clients.isEmpty)
    }

    func testDisconnectRemovesOnlyThatClientsRequests() {
        var state = CLIRequestAdmissionState()
        let first = ClientToken()
        let second = ClientToken()
        let firstID = ObjectIdentifier(first)
        let secondID = ObjectIdentifier(second)
        let firstRequest = UUID()
        let secondRequest = UUID()
        XCTAssertTrue(state.admit(requestID: firstRequest, clientID: firstID))
        XCTAssertTrue(state.admit(requestID: secondRequest, clientID: secondID))

        XCTAssertEqual(Set(state.removeAll(clientID: firstID)), [firstRequest])
        XCTAssertFalse(state.contains(requestID: firstRequest, clientID: firstID))
        XCTAssertTrue(state.contains(requestID: secondRequest, clientID: secondID))
    }
}

private final class ClientToken {}
