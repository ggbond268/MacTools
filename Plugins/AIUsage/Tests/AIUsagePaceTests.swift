import Foundation
import XCTest
@testable import AIUsagePlugin

final class AIUsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 604_800

    func testComparesConsumptionWithElapsedWeek() throws {
        let ahead = try XCTUnwrap(pace(state(used: 80, elapsed: 0.5)))
        XCTAssertEqual(ahead.period, .weekly)
        XCTAssertEqual(ahead.level, .ahead)
        XCTAssertEqual(ahead.elapsedPercent, 50, accuracy: 0.0001)
        XCTAssertEqual(ahead.usedPercent, 80)
        XCTAssertEqual(pace(state(used: 50, elapsed: 0.5))?.level, .steady)
        XCTAssertEqual(pace(state(used: 0, elapsed: 0.5))?.level, .steady)
    }

    func testToleranceUsesPercentagePointsRatherThanRelativePercent() {
        XCTAssertEqual(pace(state(used: 55, elapsed: 0.5))?.level, .steady)
        XCTAssertEqual(pace(state(used: 55.1, elapsed: 0.5))?.level, .ahead)
        XCTAssertEqual(pace(state(used: 15, elapsed: 0.1))?.level, .steady)
        XCTAssertEqual(pace(state(used: 15.1, elapsed: 0.1))?.level, .ahead)
    }

    func testExhaustionCannotBePresentedAsSteadyNearReset() {
        XCTAssertEqual(pace(state(used: 100, elapsed: 0.99))?.level, .exhausted)
        XCTAssertEqual(pace(state(used: 125, elapsed: 0.5))?.level, .exhausted)
    }

    func testEarlyWindowsUseTheSamePaceRulesWithoutAHiddenPeriod() {
        XCTAssertNil(pace(state(used: 80, elapsed: -0.1)))
        for duration in [week, 18_000] {
            for elapsed in [0.0, 0.029, 0.03] {
                XCTAssertEqual(pace(state(used: 5, elapsed: elapsed, duration: duration))?.level, .steady)
                XCTAssertEqual(pace(state(used: 9, elapsed: elapsed, duration: duration))?.level, .ahead)
                XCTAssertEqual(pace(state(used: 100, elapsed: elapsed, duration: duration))?.level, .exhausted)
            }
        }
    }

    func testDoesNotGuessUnsupportedOrMissingDuration() {
        for duration: TimeInterval? in [nil, 0, -1, 86_400, .infinity, .nan] {
            XCTAssertNil(pace(state(used: 80, elapsed: 0.5, duration: duration)))
        }
        XCTAssertNil(pace(AIUsageProviderState()))
    }

    func testRejectsMissingExpiredAndInvalidResetTimes() {
        for reset: Date? in [nil, now, now.addingTimeInterval(-1), now.addingTimeInterval(week + 1),
                            Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            let window = AIUsageWindow(id: "weekly", usedPercent: 80, resetsAt: reset, duration: week)
            XCTAssertNil(pace(AIUsageProviderState(snapshot: AIUsageSnapshot(windows: [window], plan: nil, fetchedAt: now))))
        }
    }

    func testRejectsInvalidPercentagesAndObservationTimes() {
        for used in [-1.0, .infinity, -.infinity, .nan] {
            XCTAssertNil(pace(state(used: used, elapsed: 0.5)))
        }
        let reading = state(used: 80, elapsed: 0.5)
        XCTAssertNil(AIUsagePace.make(state: reading, now: now.addingTimeInterval(-1), refreshInterval: 300))
        XCTAssertNil(AIUsagePace.make(state: reading, now: Date(timeIntervalSince1970: .nan), refreshInterval: 300))
        for interval in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(AIUsagePace.make(state: reading, now: now, refreshInterval: interval))
        }
        let invalidObservation = AIUsageProviderState(snapshot: AIUsageSnapshot(
            windows: reading.snapshot!.windows, plan: nil, fetchedAt: Date(timeIntervalSince1970: .nan)
        ))
        XCTAssertNil(pace(invalidObservation))
    }

    func testHidesRetainedFailedAndExpiredReadings() {
        var reading = state(used: 80, elapsed: 0.5)
        reading.failure = .network
        XCTAssertNil(pace(reading))
        reading.failure = nil
        XCTAssertNil(AIUsagePace.make(state: reading, now: now.addingTimeInterval(601), refreshInterval: 300))
        XCTAssertNil(AIUsagePace.make(state: reading, now: now.addingTimeInterval(1_801), refreshInterval: 900))
    }

    func testTimePassingDoesNotMakeUnchangedUsageLookHealthier() {
        let reading = state(used: 55.01, elapsed: 0.5)
        let atFetch = pace(reading)
        let later = AIUsagePace.make(state: reading, now: now.addingTimeInterval(300), refreshInterval: 300)
        XCTAssertEqual(atFetch?.level, .ahead)
        XCTAssertEqual(later, atFetch)
    }

    func testHidesAfterResetEvenWhenSnapshotAgeIsFresh() {
        let reading = state(used: 90, elapsed: 1 - 60 / week)
        XCTAssertNotNil(pace(reading))
        XCTAssertNil(AIUsagePace.make(state: reading, now: now.addingTimeInterval(60), refreshInterval: 300))
    }

    func testBothProviderParsersSupplyCompatibleWeeklyWindows() throws {
        let codex = try AIUsageParser.parse(Data(#"{"rate_limit":{"secondary_window":{"used_percent":80,"reset_after_seconds":302400,"limit_window_seconds":604800}}}"#.utf8), provider: .codex, now: now)
        let claude = try AIUsageParser.parse(Data(#"{"seven_day":{"utilization":80,"resets_at":1800302400}}"#.utf8), provider: .claude, now: now)
        XCTAssertEqual(pace(AIUsageProviderState(snapshot: codex))?.level, .ahead)
        XCTAssertEqual(pace(AIUsageProviderState(snapshot: claude)), pace(AIUsageProviderState(snapshot: codex)))
    }

    func testCodexWeeklyPrimaryWindowIsRecognizedByDuration() throws {
        let snapshot = try AIUsageParser.parse(Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":5,"reset_after_seconds":583200,"limit_window_seconds":604800}}}"#.utf8), provider: .codex, now: now)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].duration, week)
        XCTAssertEqual(pace(AIUsageProviderState(snapshot: snapshot))?.level, .steady)
    }

    func testScreenshotLikeSingleWeeklyReadingIsSteadyBeforeAndAfterRefresh() throws {
        // A 6d 19h 30m countdown is only 4h 30m into the weekly window.
        let payload = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1800588600,"limit_window_seconds":604800}}}"#.utf8)
        let initial = try AIUsageParser.parse(payload, provider: .codex, now: now)
        XCTAssertEqual(pace(AIUsageProviderState(snapshot: initial))?.level, .steady)
        let refreshedAt = now.addingTimeInterval(33 * 60)
        let refreshed = try AIUsageParser.parse(payload, provider: .codex, now: refreshedAt)
        XCTAssertEqual(AIUsagePace.make(state: AIUsageProviderState(snapshot: refreshed), now: refreshedAt, refreshInterval: 300)?.level, .steady)
    }

    func testFiveHourOnlyAccountsUseFiveHourPaceRegardlessOfSlot() throws {
        let codexPrimary = try AIUsageParser.parse(Data(#"{"rate_limit":{"primary_window":{"used_percent":80,"reset_after_seconds":9000,"limit_window_seconds":18000}}}"#.utf8), provider: .codex, now: now)
        let codexSecondary = try AIUsageParser.parse(Data(#"{"rate_limit":{"secondary_window":{"used_percent":80,"reset_after_seconds":9000,"limit_window_seconds":18000}}}"#.utf8), provider: .codex, now: now)
        let claude = try AIUsageParser.parse(Data(#"{"five_hour":{"utilization":80,"resets_at":1800009000}}"#.utf8), provider: .claude, now: now)
        let expected = try XCTUnwrap(pace(AIUsageProviderState(snapshot: codexPrimary)))
        XCTAssertEqual(expected.period, .fiveHour)
        XCTAssertEqual(expected.level, .ahead)
        XCTAssertEqual(expected.elapsedPercent, 50, accuracy: 0.0001)
        XCTAssertEqual(pace(AIUsageProviderState(snapshot: codexSecondary)), expected)
        XCTAssertEqual(pace(AIUsageProviderState(snapshot: claude)), expected)
        XCTAssertEqual(pace(state(used: 55, elapsed: 0.5, duration: 18_000))?.level, .steady)
        XCTAssertEqual(pace(state(used: 100, elapsed: 0.99, duration: 18_000))?.level, .exhausted)
    }

    func testWeeklyPaceTakesPriorityWhenBothWindowsExistInEitherOrder() throws {
        let weekly = try XCTUnwrap(state(used: 40, elapsed: 0.5, id: "session").snapshot?.windows.first)
        let session = try XCTUnwrap(state(used: 100, elapsed: 0.5, id: "weekly", duration: 18_000).snapshot?.windows.first)
        for windows in [[weekly, session], [session, weekly]] {
            let reading = AIUsageProviderState(snapshot: AIUsageSnapshot(windows: windows, plan: nil, fetchedAt: now))
            XCTAssertEqual(pace(reading)?.period, .weekly)
            XCTAssertEqual(pace(reading)?.level, .steady)
            XCTAssertEqual(pace(reading)?.usedPercent, 40)
        }
    }

    func testDoesNotChooseArbitrarilyBetweenDuplicateDurationsOrSkipInvalidWeeklyWindow() throws {
        for duration in [week, 18_000] {
            let first = try XCTUnwrap(state(used: 40, elapsed: 0.5, id: "session", duration: duration).snapshot?.windows.first)
            let second = try XCTUnwrap(state(used: 80, elapsed: 0.5, duration: duration).snapshot?.windows.first)
            XCTAssertNil(pace(AIUsageProviderState(snapshot: AIUsageSnapshot(windows: [first, second], plan: nil, fetchedAt: now))))
        }
        let invalidWeek = AIUsageWindow(id: "weekly", usedPercent: 40, resetsAt: nil, duration: week)
        let session = try XCTUnwrap(state(used: 80, elapsed: 0.5, id: "session", duration: 18_000).snapshot?.windows.first)
        XCTAssertNil(pace(AIUsageProviderState(snapshot: AIUsageSnapshot(windows: [session, invalidWeek], plan: nil, fetchedAt: now))))
    }

    private func pace(_ state: AIUsageProviderState) -> AIUsagePace? {
        AIUsagePace.make(state: state, now: now, refreshInterval: 300)
    }

    private func state(used: Double, elapsed: Double, id: String = "weekly", duration: TimeInterval? = 604_800) -> AIUsageProviderState {
        let window = AIUsageWindow(id: id, usedPercent: used, resetsAt: now.addingTimeInterval((duration ?? week) * (1 - elapsed)), duration: duration)
        return AIUsageProviderState(snapshot: AIUsageSnapshot(windows: [window], plan: nil, fetchedAt: now))
    }
}
