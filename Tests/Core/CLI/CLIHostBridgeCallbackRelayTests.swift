import XCTest
import MacToolsCLIProtocol
@testable import MacTools

final class CLIHostBridgeCallbackRelayTests: XCTestCase {
    func testReconnectCallbackCanEnterFromDetachedTaskAndRunsOnMainActor() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let relay = CLIHostBridgeCallbackRelay { generation in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(generation, 7)
            reconnected.fulfill()
        }

        await Task.detached {
            relay.makeReconnectHandler(for: 7)()
        }.value

        await fulfillment(of: [reconnected], timeout: 1)
    }

    func testErrorCallbackCanEnterFromDetachedTaskAndRunsOnMainActor() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let relay = CLIHostBridgeCallbackRelay { generation in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(generation, 8)
            reconnected.fulfill()
        }

        await Task.detached {
            relay.makeReconnectErrorHandler(for: 8)(CallbackError.expected)
        }.value

        await fulfillment(of: [reconnected], timeout: 1)
    }

    func testAuthenticatedIncompatibleHostRegistrationDoesNotReconnect() async throws {
        let reconnected = expectation(description: "Reconnect callback did not run")
        reconnected.isInverted = true
        let registered = expectation(description: "Registration callback ran")
        let relay = CLIHostBridgeCallbackRelay(
            reconnect: { _ in reconnected.fulfill() },
            registered: { generation in
                XCTAssertEqual(generation, 9)
                registered.fulfill()
            },
            connectionIsBroker: { _ in true }
        )
        let connection = NSXPCConnection(serviceName: "test.invalid")
        let response = try CLIProtocolCodec.encodeResponse(CLIHandshakeResponse(
            selectedProtocolVersion: nil,
            brokerVersion: "1",
            brokerBuild: "1",
            hostVersion: "2",
            hostBuild: "2",
            hostReady: false,
            message: "No compatible host protocol version."
        ))

        relay.makeRegistrationReplyHandler(for: connection, generation: 9)(response)

        await fulfillment(of: [registered, reconnected], timeout: 0.1)
    }

    func testRejectedRegistrationReconnectsWithoutResettingBackoff() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let registered = expectation(description: "Registration callback did not run")
        registered.isInverted = true
        let relay = CLIHostBridgeCallbackRelay(
            reconnect: { generation in
                XCTAssertEqual(generation, 10)
                reconnected.fulfill()
            },
            registered: { _ in registered.fulfill() },
            connectionIsBroker: { _ in false }
        )
        let connection = NSXPCConnection(serviceName: "test.invalid")

        relay.makeRegistrationReplyHandler(for: connection, generation: 10)(Data())

        await fulfillment(of: [reconnected, registered], timeout: 0.1)
    }
}

private enum CallbackError: Error {
    case expected
}
