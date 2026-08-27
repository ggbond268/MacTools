import XCTest
@testable import MacTools

final class CLIStartupDeadlineTests: XCTestCase {
    func testRemainingDurationIsCappedByOperationBudget() {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .seconds(10), now: start)

        XCTAssertEqual(
            deadline.cappedInstant(
                upTo: .seconds(1),
                now: start.advanced(by: .seconds(2))
            ),
            start.advanced(by: .seconds(3))
        )
    }

    func testRemainingDurationShrinksAtOverallDeadline() {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .seconds(10), now: start)

        XCTAssertEqual(
            deadline.cappedInstant(
                upTo: .seconds(1),
                now: start.advanced(by: .milliseconds(9_500))
            ),
            deadline.instant
        )
        XCTAssertNil(
            deadline.cappedInstant(
                upTo: .milliseconds(200),
                now: start.advanced(by: .seconds(10))
            )
        )
    }

    func testNearExpiryResponseWaitRetainsOriginalDoctorDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = CLIStartupDeadline(timeout: .milliseconds(100), now: start)
        try await clock.sleep(until: start.advanced(by: .milliseconds(80)))

        let responseDeadline = try XCTUnwrap(
            deadline.cappedInstant(upTo: .seconds(10), now: clock.now)
        )

        XCTAssertEqual(responseDeadline, deadline.instant)
        try await clock.sleep(until: responseDeadline)
        XCTAssertGreaterThan(
            clock.now.duration(to: start.advanced(by: .milliseconds(200))),
            .zero
        )
    }

    func testResponseDeadlineReservesCleanupBudgetInsideOverallDeadline() {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .seconds(10), now: start)
        let policy = CLIRequestCleanupPolicy(budget: .milliseconds(250))

        XCTAssertEqual(
            policy.responseDeadline(
                within: deadline,
                maximumWait: .seconds(10),
                now: start
            ),
            start.advanced(by: .milliseconds(9_750))
        )
    }

    func testCleanupAttemptsCancellationThenInvalidates() async {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .seconds(1), now: start)
        let policy = CLIRequestCleanupPolicy(budget: .milliseconds(250))
        let cancelled = expectation(description: "Cancellation attempted")
        let invalidated = expectation(description: "Connection invalidated")

        await policy.performCleanup(
            within: deadline,
            now: start,
            cancel: { cleanupDeadline in
                XCTAssertEqual(cleanupDeadline, start.advanced(by: .milliseconds(250)))
                cancelled.fulfill()
            },
            invalidate: { invalidated.fulfill() }
        )

        await fulfillment(of: [cancelled, invalidated], timeout: 0.1)
    }

    func testExpiredCleanupSkipsCancellationButStillInvalidates() async {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .milliseconds(100), now: start)
        let policy = CLIRequestCleanupPolicy(budget: .milliseconds(250))
        let cancelled = expectation(description: "Cancellation was not attempted")
        cancelled.isInverted = true
        let invalidated = expectation(description: "Connection invalidated")

        await policy.performCleanup(
            within: deadline,
            now: start.advanced(by: .milliseconds(100)),
            cancel: { _ in cancelled.fulfill() },
            invalidate: { invalidated.fulfill() }
        )

        await fulfillment(of: [invalidated, cancelled], timeout: 0.1)
    }

    func testPreparationFailureInvalidatesConnection() async {
        let invalidated = expectation(description: "Connection invalidated")
        let policy = CLIConnectionLifecyclePolicy()

        do {
            _ = try await policy.preserveConnectionOnSuccess(
                operation: { throw LifecycleError.expected },
                invalidate: { invalidated.fulfill() }
            ) as Bool
            XCTFail("Expected preparation failure")
        } catch LifecycleError.expected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [invalidated], timeout: 0.1)
    }

    func testPreparationCancellationInvalidatesConnection() async {
        let invalidated = expectation(description: "Connection invalidated")
        let policy = CLIConnectionLifecyclePolicy()

        do {
            _ = try await policy.preserveConnectionOnSuccess(
                operation: { throw CancellationError() },
                invalidate: { invalidated.fulfill() }
            ) as Bool
            XCTFail("Expected preparation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [invalidated], timeout: 0.1)
    }

    func testSuccessfulPreparationPreservesConnection() async {
        let invalidated = expectation(description: "Connection was not invalidated")
        invalidated.isInverted = true
        let policy = CLIConnectionLifecyclePolicy()

        let value = await policy.preserveConnectionOnSuccess(
            operation: { true },
            invalidate: { invalidated.fulfill() }
        )

        XCTAssertTrue(value)
        await fulfillment(of: [invalidated], timeout: 0.1)
    }
}

private enum LifecycleError: Error {
    case expected
}
