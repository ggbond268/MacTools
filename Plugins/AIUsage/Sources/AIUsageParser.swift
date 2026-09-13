import Foundation

enum AIUsageParser {
    static func parse(_ data: Data, provider: AIUsageProvider, now: Date) throws -> AIUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure.invalidResponse
        }
        var windows: [AIUsageWindow] = []
        switch provider {
        case .codex:
            let rate = root["rate_limit"] as? [String: Any] ?? [:]
            for (key, id) in [("primary_window", "session"), ("secondary_window", "weekly")] {
                guard let row = rate[key] as? [String: Any],
                      let percent = number(row["used_percent"]) else { continue }
                let reset = date(row["reset_at"])
                    ?? number(row["reset_after_seconds"]).map { now.addingTimeInterval(max(0, $0)) }
                windows.append(AIUsageWindow(
                    id: id, usedPercent: max(0, percent), resetsAt: reset,
                    duration: number(row["limit_window_seconds"])
                ))
            }
        case .claude:
            let limits = root["limits"] as? [[String: Any]] ?? []
            for (key, kind, id, duration) in [
                ("five_hour", "session", "session", 18_000.0),
                ("seven_day", "weekly_all", "weekly", 604_800.0)
            ] {
                let legacy = root[key] as? [String: Any]
                let generic = limits.first {
                    $0["kind"] as? String == kind && number($0["percent"]) != nil
                }
                if let generic, generic["is_active"] as? Bool == false { continue }
                guard let percent = number(generic?["percent"]) ?? number(legacy?["utilization"]) else { continue }
                windows.append(AIUsageWindow(
                    id: id, usedPercent: max(0, percent),
                    resetsAt: date(generic?["resets_at"]) ?? date(legacy?["resets_at"]), duration: duration
                ))
            }
        }
        guard !windows.isEmpty else { throw AIUsageFailure.invalidResponse }
        return AIUsageSnapshot(windows: windows, plan: root["plan_type"] as? String, fetchedAt: now)
    }

    static func number(_ value: Any?) -> Double? {
        guard !(value is NSNull), let value,
              CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value), number > 0, number < 32_503_680_000 {
            return Date(timeIntervalSince1970: number)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
