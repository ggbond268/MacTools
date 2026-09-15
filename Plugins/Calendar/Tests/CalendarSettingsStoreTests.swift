import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import CalendarPlugin

@MainActor
final class CalendarSettingsStoreTests: XCTestCase {
    func testWeekStartDefaultsToSunday() {
        let store = CalendarSettingsStore(storage: CalendarSettingsMemoryStorage())

        XCTAssertEqual(store.weekStartDay, .sunday)
    }

    func testWeekStartDaysMapToFoundationWeekdayValues() {
        XCTAssertEqual(
            CalendarWeekStartDay.allCases.map(\.calendarFirstWeekday),
            Array(1...7)
        )
    }

    func testWeekStartDisplayNamesUseCompleteLocalizedWeekdays() {
        XCTAssertEqual(
            CalendarWeekStartDay.friday.displayName(locale: Locale(identifier: "ja_JP")),
            "金曜日"
        )
        XCTAssertEqual(
            CalendarWeekStartDay.sunday.displayName(locale: Locale(identifier: "es_ES")),
            "domingo"
        )
    }

    func testWeekStartPersistsAndReloads() {
        let storage = CalendarSettingsMemoryStorage()
        let store = CalendarSettingsStore(storage: storage)

        store.setWeekStartDay(.thursday)

        XCTAssertEqual(storage.string(forKey: "settings.week-start-day"), "thursday")
        XCTAssertEqual(CalendarSettingsStore(storage: storage).weekStartDay, .thursday)
    }

    func testInvalidWeekStartFallsBackToSunday() {
        let storage = CalendarSettingsMemoryStorage()
        storage.set("invalid", forKey: "settings.week-start-day")

        XCTAssertEqual(CalendarSettingsStore(storage: storage).weekStartDay, .sunday)
    }

    func testTodayDetailsDefaultToVisibleAndPersist() {
        let storage = CalendarSettingsMemoryStorage()
        let store = CalendarSettingsStore(storage: storage)

        XCTAssertTrue(store.showsTodayDetails)
        store.setShowsTodayDetails(false)

        XCTAssertEqual(storage.object(forKey: "settings.shows-today-details") as? Bool, false)
        XCTAssertFalse(CalendarSettingsStore(storage: storage).showsTodayDetails)
    }
}

@MainActor
private final class CalendarSettingsMemoryStorage: PluginStorage {
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
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else {
            return
        }
        values[key] = value
    }
}
