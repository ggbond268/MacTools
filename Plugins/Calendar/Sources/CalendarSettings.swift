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

enum CalendarAgendaDirection: String, CaseIterable, Sendable {
    case past
    case future
    case surrounding

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .past: localization.string("agenda.direction.past", defaultValue: "过去")
        case .future: localization.string("agenda.direction.future", defaultValue: "未来")
        case .surrounding: localization.string("agenda.direction.surrounding", defaultValue: "过去 + 未来")
        }
    }
}

struct CalendarAgendaRange: Equatable, Sendable {
    let dayCount: Int
    let direction: CalendarAgendaDirection

    init(dayCount: Int = 3, direction: CalendarAgendaDirection = .future) {
        self.dayCount = min(max(dayCount, 1), 7)
        self.direction = direction
    }

    func dates(relativeTo today: Date, calendar: Calendar) -> [Date] {
        let firstOffset: Int
        switch direction {
        case .past: firstOffset = -(dayCount - 1)
        case .future: firstOffset = 0
        case .surrounding: firstOffset = -((dayCount - 1) / 2)
        }
        let start = calendar.startOfDay(for: today)
        return (firstOffset..<(firstOffset + dayCount)).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }
}

@MainActor
final class CalendarSettingsStore: ObservableObject {
    private enum StorageKey {
        static let weekStartDay = "settings.week-start-day"
        static let showsRecentAgenda = "settings.shows-recent-agenda"
        static let legacyShowsTodayDetails = "settings.shows-today-details"
        static let agendaDayCount = "settings.agenda-day-count"
        static let agendaDirection = "settings.agenda-direction"
        static let alternateCalendar = "settings.alternate-calendar"
        static let legacyLunarDisplay = "settings.lunar-display"
    }

    @Published private(set) var weekStartDay: CalendarWeekStartDay
    @Published private(set) var showsRecentAgenda: Bool
    @Published private(set) var agendaRange: CalendarAgendaRange
    @Published private(set) var alternateCalendar: CalendarAlternateCalendar

    private let storage: PluginStorage

    init(storage: PluginStorage, languageIdentifier: String? = nil) {
        self.storage = storage
        let legacySelection: CalendarAlternateCalendar?
        switch storage.string(forKey: StorageKey.legacyLunarDisplay) {
        case "shown": legacySelection = .chinese
        case "hidden": legacySelection = CalendarAlternateCalendar.none
        default: legacySelection = nil
        }
        let alternateCalendar = storage.string(forKey: StorageKey.alternateCalendar)
            .flatMap(CalendarAlternateCalendar.init(rawValue:))
            ?? legacySelection ?? CalendarDisplayPolicy.defaultAlternateCalendar(languageIdentifier: languageIdentifier)
        self.alternateCalendar = alternateCalendar
        // Resolve the language-based default once. Later language changes must
        // preserve the selected calendar, including an explicit None selection.
        storage.set(alternateCalendar.rawValue, forKey: StorageKey.alternateCalendar)
        self.weekStartDay = storage.string(forKey: StorageKey.weekStartDay)
            .flatMap(CalendarWeekStartDay.init(rawValue:))
            ?? .sunday
        let showsRecentAgenda = storage.object(forKey: StorageKey.showsRecentAgenda) as? Bool
            ?? storage.object(forKey: StorageKey.legacyShowsTodayDetails) as? Bool ?? true
        self.showsRecentAgenda = showsRecentAgenda
        if storage.object(forKey: StorageKey.showsRecentAgenda) == nil {
            storage.set(showsRecentAgenda, forKey: StorageKey.showsRecentAgenda)
        }
        self.agendaRange = CalendarAgendaRange(
            dayCount: storage.object(forKey: StorageKey.agendaDayCount) as? Int ?? 3,
            direction: storage.string(forKey: StorageKey.agendaDirection)
                .flatMap(CalendarAgendaDirection.init(rawValue:)) ?? .future
        )
    }

    func setWeekStartDay(_ day: CalendarWeekStartDay) {
        guard weekStartDay != day else {
            return
        }

        weekStartDay = day
        storage.set(day.rawValue, forKey: StorageKey.weekStartDay)
    }

    func setShowsRecentAgenda(_ value: Bool) {
        guard showsRecentAgenda != value else {
            return
        }

        showsRecentAgenda = value
        storage.set(value, forKey: StorageKey.showsRecentAgenda)
    }

    func setAgendaRange(_ range: CalendarAgendaRange) {
        guard agendaRange != range else { return }
        agendaRange = range
        storage.set(range.dayCount, forKey: StorageKey.agendaDayCount)
        storage.set(range.direction.rawValue, forKey: StorageKey.agendaDirection)
    }

    func setAlternateCalendar(_ calendar: CalendarAlternateCalendar) {
        guard alternateCalendar != calendar else { return }
        alternateCalendar = calendar
        storage.set(calendar.rawValue, forKey: StorageKey.alternateCalendar)
    }
}
