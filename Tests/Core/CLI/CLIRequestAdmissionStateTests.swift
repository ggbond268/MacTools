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

    func testActiveInvocationMarkerRejectsRecursiveChildAndUnknownMarkerIsInvalid() throws {
        var state = CLIRequestAdmissionState<String>()
        let rootRequestID = UUID()
        XCTAssertNil(state.admit(requestID: rootRequestID, clientID: "root"))
        let context = try XCTUnwrap(
            state.invocationContext(requestID: rootRequestID, clientID: "root")
        )
        let childContext = CLIInvocationContext(
            chainID: context.chainID,
            depth: context.depth + 1
        )

        XCTAssertEqual(
            state.admit(
                requestID: UUID(),
                clientID: "child",
                invocationContext: childContext
            ),
            .recursiveInvocation
        )
        XCTAssertEqual(
            state.admit(
                requestID: UUID(),
                clientID: "forged",
                invocationContext: CLIInvocationContext(chainID: UUID(), depth: 1)
            ),
            .invalidInvocationContext
        )

        state.finish(requestID: rootRequestID, clientID: "root")
        XCTAssertEqual(
            state.admit(
                requestID: UUID(),
                clientID: "late-child",
                invocationContext: childContext
            ),
            .invalidInvocationContext
        )
    }

    func testRejectsInvocationDepthOutsideProtocolBound() {
        var state = CLIRequestAdmissionState<String>()
        XCTAssertEqual(
            state.admit(
                requestID: UUID(),
                clientID: "child",
                invocationContext: CLIInvocationContext(chainID: UUID(), depth: 0)
            ),
            .invalidInvocationContext
        )
        XCTAssertEqual(
            state.admit(
                requestID: UUID(),
                clientID: "child",
                invocationContext: CLIInvocationContext(
                    chainID: UUID(),
                    depth: CLIProtocolVersion.maximumInvocationDepth + 1
                )
            ),
            .invalidInvocationContext
        )
    }

    func testPreAdmissionCancellationIsConsumedAndDoesNotLeakCapacity() {
        var state = CLIRequestAdmissionState<String>()
        let requestID = UUID()

        XCTAssertEqual(state.cancel(requestID: requestID, clientID: "client"), .recorded)
        XCTAssertEqual(
            state.admit(requestID: requestID, clientID: "client"),
            .cancelledBeforeAdmission
        )
        XCTAssertTrue(state.pendingCancellations.isEmpty)
        XCTAssertNil(state.admit(requestID: requestID, clientID: "client"))
    }

    func testCancellationBetweenAdmissionAndForwardingPreventsHostDelivery() {
        var state = CLIRequestAdmissionState<String>()
        let requestID = UUID()

        XCTAssertNil(state.admit(requestID: requestID, clientID: "client"))
        XCTAssertEqual(state.cancel(requestID: requestID, clientID: "client"), .recorded)
        XCTAssertFalse(state.beginForwarding(requestID: requestID, clientID: "client"))
        XCTAssertFalse(state.forwardedRequests.contains(requestID))

        state.finish(requestID: requestID, clientID: "client")
        XCTAssertTrue(state.activeCancellations.isEmpty)
    }

    func testCancellationAfterForwardingMustBeDeliveredToHost() {
        var state = CLIRequestAdmissionState<String>()
        let requestID = UUID()

        XCTAssertNil(state.admit(requestID: requestID, clientID: "client"))
        XCTAssertTrue(state.beginForwarding(requestID: requestID, clientID: "client"))
        XCTAssertEqual(
            state.cancel(requestID: requestID, clientID: "client"),
            .forwardToHost
        )

        state.finish(requestID: requestID, clientID: "client")
        XCTAssertTrue(state.forwardedRequests.isEmpty)
    }
}
