import Foundation
import MacToolsPluginKit
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
final class ActivityBarFakeInputMonitor: ActivityBarInputMonitoring {
    var status: ActivityBarInputMonitorStatus = .idle
    var onEvent: ((ActivityBarInputEvent) -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var retryCallCount = 0
    /// When set, a retry while denied transitions the status to this value,
    /// simulating the user granting the permission between attempts.
    var statusAfterRetry: ActivityBarInputMonitorStatus?

    func start() {
        startCallCount += 1
        status = .running
    }

    func stop() {
        stopCallCount += 1
        status = .idle
    }

    func retryEventTapIfDenied() {
        retryCallCount += 1
        guard status == .inputMonitoringDenied else { return }
        if let statusAfterRetry {
            status = statusAfterRetry
        }
    }

    func emit(_ event: ActivityBarInputEvent) {
        onEvent?(event)
    }
}

final class ActivityBarFakeSocketServer: ActivityBarSocketServing {
    var isRunning = false
    var startError: Error?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
        isRunning = true
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
    }
}

func activityBarTestDate(
    year: Int = 2026,
    month: Int = 5,
    day: Int = 18,
    hour: Int = 9,
    minute: Int = 0,
    second: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    )!
}

func activityBarTestCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}
