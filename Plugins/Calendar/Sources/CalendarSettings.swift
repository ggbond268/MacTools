import Combine
import Foundation
import MacToolsPluginKit

enum CalendarWeekStartDay: String, CaseIterable, Identifiable, Sendable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String { rawValue }

    var calendarFirstWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }

    func displayName(locale: Locale = PluginRuntimeLocalization.locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        let index = calendarFirstWeekday - 1
        return formatter.weekdaySymbols.indices.contains(index)
            ? formatter.weekdaySymbols[index]
            : rawValue
    }
}

@MainActor
final class CalendarSettingsStore: ObservableObject {
    private enum StorageKey {
        static let weekStartDay = "settings.week-start-day"
        static let showsTodayDetails = "settings.shows-today-details"
    }

    @Published private(set) var weekStartDay: CalendarWeekStartDay
    @Published private(set) var showsTodayDetails: Bool

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
        self.weekStartDay = storage.string(forKey: StorageKey.weekStartDay)
            .flatMap(CalendarWeekStartDay.init(rawValue:))
            ?? .sunday
        self.showsTodayDetails = storage.object(forKey: StorageKey.showsTodayDetails) as? Bool ?? true
    }

    func setWeekStartDay(_ day: CalendarWeekStartDay) {
        guard weekStartDay != day else {
            return
        }

        weekStartDay = day
        storage.set(day.rawValue, forKey: StorageKey.weekStartDay)
    }

    func setShowsTodayDetails(_ value: Bool) {
        guard showsTodayDetails != value else {
            return
        }

        showsTodayDetails = value
        storage.set(value, forKey: StorageKey.showsTodayDetails)
    }
}
