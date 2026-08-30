import XCTest
@testable import MacTools

final class CLIHostRequestStateTests: XCTestCase {
    func testCancellationAppliesOnlyToActiveRequestAndIsClearedOnFinish() {
        let state = CLIHostRequestState()
        let requestID = UUID()

        XCTAssertFalse(state.cancel(requestID))
        XCTAssertTrue(state.begin(requestID))
        XCTAssertFalse(state.begin(requestID))
        XCTAssertTrue(state.cancel(requestID))
        XCTAssertTrue(state.isCancelled(requestID))

        state.finish(requestID)
        XCTAssertFalse(state.isCancelled(requestID))
        XCTAssertTrue(state.begin(requestID))
    }
}
