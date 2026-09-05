import XCTest
@testable import MacTools

final class CLIHostRequestStateTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

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

    func testCancellationHandlerRunsForCancellationBeforeOrAfterInstallation() {
        for installFirst in [false, true] {
            let state = CLIHostRequestState()
            let requestID = UUID()
            let calls = Counter()
            XCTAssertTrue(state.begin(requestID))
            let install = {
                state.installCancellationHandler(requestID) {
                    calls.increment()
                }
            }
            if installFirst { install() }
            XCTAssertTrue(state.cancel(requestID))
            if !installFirst { install() }
            XCTAssertEqual(calls.value, 1)
            state.finish(requestID)
        }
    }
}
