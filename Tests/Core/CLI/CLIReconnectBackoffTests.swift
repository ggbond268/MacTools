import XCTest
@testable import MacTools

final class CLIReconnectBackoffTests: XCTestCase {
    func testBackoffGrowsExponentiallyAndCapsAtThirtySeconds() {
        var backoff = CLIReconnectBackoff()

        XCTAssertEqual(
            (0..<8).map { _ in backoff.nextDelay() },
            [
                .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                .seconds(16), .seconds(30), .seconds(30), .seconds(30),
            ]
        )
    }

    func testSuccessfulRegistrationResetsBackoff() {
        var backoff = CLIReconnectBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()

        backoff.reset()

        XCTAssertEqual(backoff.failureCount, 0)
        XCTAssertEqual(backoff.nextDelay(), .seconds(1))
    }

    func testOnlyLatestConnectionGenerationIsCurrent() {
        var generation = CLIConnectionGeneration()

        let first = generation.advance()
        let second = generation.advance()

        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }
}
