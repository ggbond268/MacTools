import XCTest
@testable import MacTools

final class CLIRequestAdmissionStateTests: XCTestCase {
    func testDefaultLimitsMatchProtocolVersionOneContract() {
        let state = CLIRequestAdmissionState<String>()
        XCTAssertEqual(state.maximumRequestsPerClient, 8)
        XCTAssertEqual(state.maximumRequestsGlobally, 32)
    }

    func testRejectsDuplicatePerClientAndGlobalCapacity() {
        var state = CLIRequestAdmissionState<String>(
            maximumRequestsPerClient: 2,
            maximumRequestsGlobally: 3
        )
        let first = UUID()
        let second = UUID()
        let third = UUID()
        XCTAssertNil(state.admit(requestID: first, clientID: "a"))
        XCTAssertEqual(
            state.admit(requestID: first, clientID: "b"),
            .duplicateRequestID
        )
        XCTAssertNil(state.admit(requestID: second, clientID: "a"))
        XCTAssertEqual(
            state.admit(requestID: UUID(), clientID: "a"),
            .clientCapacity
        )
        XCTAssertNil(state.admit(requestID: third, clientID: "b"))
        XCTAssertEqual(
            state.admit(requestID: UUID(), clientID: "c"),
            .globalCapacity
        )
    }

    func testLateFinishCannotRemoveReusedRequestOwnedByAnotherClient() {
        var state = CLIRequestAdmissionState<String>()
        let requestID = UUID()
        XCTAssertNil(state.admit(requestID: requestID, clientID: "old"))
        XCTAssertTrue(state.owns(requestID: requestID, clientID: "old"))
        XCTAssertFalse(state.owns(requestID: requestID, clientID: "new"))
        XCTAssertEqual(state.removeRequests(clientID: "old"), [requestID])
        XCTAssertNil(state.admit(requestID: requestID, clientID: "new"))
        state.finish(requestID: requestID, clientID: "old")
        XCTAssertEqual(state.activeRequests[requestID], "new")
    }
}
