import Foundation

struct AIUsagePace: Equatable, Sendable {
    enum Period: Equatable, Sendable {
        case weekly
        case fiveHour

        var duration: TimeInterval { self == .weekly ? 604_800 : 18_000 }
    }

    enum Level: Equatable, Sendable {
        case steady
        case ahead
        case exhausted
    }

    let period: Period
    let level: Level
    let usedPercent: Double
    let elapsedPercent: Double

    static let tolerancePercentagePoints = 5.0

    static func make(state: AIUsageProviderState, now: Date, refreshInterval: TimeInterval) -> Self? {
        guard now.timeIntervalSince1970.isFinite, refreshInterval.isFinite, refreshInterval > 0,
              let snapshot = state.snapshot, snapshot.fetchedAt.timeIntervalSince1970.isFinite,
              snapshot.fetchedAt <= now, !state.isStale(at: now, interval: refreshInterval) else { return nil }

        // API slot names describe priority, not duration. Prefer an explicit weekly window.
        let weeks = snapshot.windows.filter { $0.duration == Period.weekly.duration }
        let period: Period = weeks.isEmpty ? .fiveHour : .weekly
        let windows = weeks.isEmpty ? snapshot.windows.filter { $0.duration == Period.fiveHour.duration } : weeks
        guard windows.count == 1, let window = windows.first,
              let reset = window.resetsAt, reset.timeIntervalSince1970.isFinite, reset > now,
              window.usedPercent.isFinite, window.usedPercent >= 0 else { return nil }

        // Compare usage and elapsed time at the same observation, not against a moving clock.
        let duration = period.duration
        let elapsed = duration - reset.timeIntervalSince(snapshot.fetchedAt)
        guard elapsed >= 0, elapsed < duration else { return nil }
        let elapsedPercent = elapsed / duration * 100
        let level: Level
        if window.usedPercent >= 100 {
            level = .exhausted
        } else if window.usedPercent > elapsedPercent + tolerancePercentagePoints {
            level = .ahead
        } else {
            level = .steady
        }
        return Self(period: period, level: level, usedPercent: window.usedPercent, elapsedPercent: elapsedPercent)
    }
}
