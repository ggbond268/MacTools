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

    func testExhaustionCannotBePresentedAsSteadyNearReset() {
        XCTAssertEqual(pace(state(used: 100, elapsed: 0.99))?.level, .exhausted)
        XCTAssertEqual(pace(state(used: 125, elapsed: 0.5))?.level, .exhausted)
    }

    func testRejectsMissingExpiredAndInvalidResetTimes() {
        for reset: Date? in [nil, now, now.addingTimeInterval(-1), now.addingTimeInterval(week + 1),
                            Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            let window = AIUsageWindow(id: "weekly", usedPercent: 80, resetsAt: reset, duration: week)
            XCTAssertNil(pace(AIUsageProviderState(snapshot: AIUsageSnapshot(windows: [window], plan: nil, fetchedAt: now))))
        }
    }

    func testHidesRetainedFailedAndExpiredReadings() {
        var reading = state(used: 80, elapsed: 0.5)
        reading.failure = .network
        XCTAssertNil(pace(reading))
        reading.failure = nil
        XCTAssertNil(AIUsagePace.make(state: reading, now: now.addingTimeInterval(601), refreshInterval: 300))
        XCTAssertNil(AIUsagePace.make(state: reading, now: now.addingTimeInterval(1_801), refreshInterval: 900))
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

    private func pace(_ state: AIUsageProviderState) -> AIUsagePace? {
        AIUsagePace.make(state: state, now: now, refreshInterval: 300)
    }

    private func state(used: Double, elapsed: Double, id: String = "weekly", duration: TimeInterval? = 604_800) -> AIUsageProviderState {
        let window = AIUsageWindow(id: id, usedPercent: used, resetsAt: now.addingTimeInterval((duration ?? week) * (1 - elapsed)), duration: duration)
        return AIUsageProviderState(snapshot: AIUsageSnapshot(windows: [window], plan: nil, fetchedAt: now))
    }
}
