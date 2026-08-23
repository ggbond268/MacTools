import XCTest
@testable import MacTools

final class CLIHostBridgeCallbackRelayTests: XCTestCase {
    func testReconnectCallbackCanEnterFromDetachedTaskAndRunsOnMainActor() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let relay = CLIHostBridgeCallbackRelay {
            XCTAssertTrue(Thread.isMainThread)
            reconnected.fulfill()
        }

        await Task.detached {
            relay.makeReconnectHandler()()
        }.value

        await fulfillment(of: [reconnected], timeout: 1)
    }

    func testErrorCallbackCanEnterFromDetachedTaskAndRunsOnMainActor() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let relay = CLIHostBridgeCallbackRelay {
            XCTAssertTrue(Thread.isMainThread)
            reconnected.fulfill()
        }

        await Task.detached {
            relay.makeReconnectErrorHandler()(CallbackError.expected)
        }.value

        await fulfillment(of: [reconnected], timeout: 1)
    }
}

private enum CallbackError: Error {
    case expected
}
