import XCTest
@testable import MacTools

@MainActor
final class CLIHostBridgeAuthorizationTests: XCTestCase {
    func testHandleRejectsCallerThatIsNotTheBrokerBeforeDecoding() {
        let bridge = CLIHostBridge(callerIsBroker: { false })
        var response: Data?

        bridge.handle(Data("not-json".utf8)) { response = $0 }

        XCTAssertEqual(response, Data())
    }

    func testCancelRejectsCallerThatIsNotTheBroker() {
        let bridge = CLIHostBridge(callerIsBroker: { false })
        var accepted: Bool?

        bridge.cancel(UUID()) { accepted = $0 }

        XCTAssertEqual(accepted, false)
    }
}
