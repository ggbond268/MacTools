import XCTest
@testable import MacTools

final class CLIHostDiscoveryTests: XCTestCase {
    private let hostIdentifier = "app.ggbond.MacTools"

    func testSlowCandidateProviderReturnsAtDeadlineWithoutAwaitingWorker() async {
        let locator = CLIHostLocator(
            candidateProvider: { _ in
                Thread.sleep(forTimeInterval: 1)
                return []
            },
            identityEvaluator: { _ in .accepted }
        )

        await assertTimesOutPromptly(CLIHostDiscovery(locator: locator))
    }

    func testSlowIdentityAssessmentReturnsAtDeadlineWithoutAwaitingWorker() async {
        let candidate = CLIHostCandidate(
            url: URL(fileURLWithPath: "/Applications/MacTools.app"),
            bundleIdentifier: hostIdentifier,
            version: "1.2.0",
            build: "69"
        )
        let locator = CLIHostLocator(
            candidateProvider: { _ in [candidate] },
            identityEvaluator: { _ in
                Thread.sleep(forTimeInterval: 1)
                return .accepted
            }
        )

        await assertTimesOutPromptly(CLIHostDiscovery(locator: locator))
    }

    func testCancellationReturnsWithoutAwaitingBlockingDiscovery() async {
        let hostIdentifier = hostIdentifier
        let discovery = CLIHostDiscovery { _, _, _ in
            Thread.sleep(forTimeInterval: 1)
            throw CLIHostLocationError.notFound(bundleIdentifier: hostIdentifier)
        }
        let task = Task {
            try await discovery.locate(
                bundleIdentifier: hostIdentifier,
                version: "1.2.0",
                build: "69",
                deadline: CLIStartupDeadline(duration: .seconds(10))
            )
        }
        try? await Task.sleep(for: .milliseconds(20))
        let cancelledAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5)
    }

    func testRecoveryPolicyLaunchesOnceThenWaitsForReplacement() {
        XCTAssertEqual(
            CLIHostRecoveryPolicy.decision(
                brokerMatches: true,
                hostMatches: true,
                launchAllowed: true,
                didLaunch: false
            ),
            .continueHandshake
        )
        XCTAssertEqual(
            CLIHostRecoveryPolicy.decision(
                brokerMatches: false,
                hostMatches: true,
                launchAllowed: true,
                didLaunch: false
            ),
            .launchExactHost
        )
        XCTAssertEqual(
            CLIHostRecoveryPolicy.decision(
                brokerMatches: true,
                hostMatches: false,
                launchAllowed: true,
                didLaunch: false
            ),
            .launchExactHost
        )
        XCTAssertEqual(
            CLIHostRecoveryPolicy.decision(
                brokerMatches: false,
                hostMatches: false,
                launchAllowed: true,
                didLaunch: true
            ),
            .waitForReplacement
        )
        XCTAssertEqual(
            CLIHostRecoveryPolicy.decision(
                brokerMatches: true,
                hostMatches: false,
                launchAllowed: false,
                didLaunch: false
            ),
            .rejectHostVersion
        )
        XCTAssertEqual(
            CLIHostRecoveryPolicy.decision(
                brokerMatches: false,
                hostMatches: true,
                launchAllowed: false,
                didLaunch: false
            ),
            .rejectBrokerVersion
        )
    }

    func testStartupDeadlineUsesOnlyInjectedMonotonicTime() {
        let time = CLIManualMonotonicTime()
        var wallTime = Date(timeIntervalSince1970: 1_000)
        let deadline = CLIStartupDeadline(
            duration: .seconds(10),
            now: { time.now },
            sleep: { _ in }
        )

        wallTime = wallTime.addingTimeInterval(-3_600)
        XCTAssertEqual(deadline.remaining, .seconds(10))

        time.advance(by: .seconds(4))
        wallTime = wallTime.addingTimeInterval(7_200)
        XCTAssertEqual(deadline.remaining, .seconds(6))

        time.advance(by: .seconds(6))
        XCTAssertTrue(deadline.isExpired)
        XCTAssertEqual(wallTime, Date(timeIntervalSince1970: 4_600))
    }

    private func assertTimesOutPromptly(
        _ discovery: CLIHostDiscovery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let startedAt = Date()
        do {
            _ = try await discovery.locate(
                bundleIdentifier: hostIdentifier,
                version: "1.2.0",
                build: "69",
                deadline: CLIStartupDeadline(duration: .milliseconds(50))
            )
            XCTFail("Expected discovery timeout", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CLIHostDiscoveryError,
                .timedOut,
                file: file,
                line: line
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            0.5,
            file: file,
            line: line
        )
    }
}

private final class CLIManualMonotonicTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }
}
