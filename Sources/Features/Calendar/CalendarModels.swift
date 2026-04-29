import Foundation

struct CalendarEventColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let accent = CalendarEventColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
}

struct CalendarEventInput: Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let color: CalendarEventColor
}

struct CalendarEventSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let timeText: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let color: CalendarEventColor
}

enum CalendarHolidayKind: Int, Equatable, Sendable {
    case workday = 1
    case holiday = 2

    var badgeText: String {
        switch self {
        case .workday:
            return "班"
        case .holiday:
            return "休"
        }
    }
}

struct CalendarDayModel: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let dayNumber: String
    let lunarText: String
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isWeekend: Bool
    let holidayKind: CalendarHolidayKind?
    let events: [CalendarEventSummary]

    var visibleEvents: [CalendarEventSummary] {
        Array(events.prefix(Self.maximumVisibleEvents))
    }

    static let maximumVisibleEvents = 3
}

struct CalendarMonthModel: Equatable, Sendable {
    let displayedMonthStart: Date
    let title: String
    let weekdaySymbols: [String]
    let days: [CalendarDayModel]
}

enum CalendarComponentCalendars {
    static func gregorianFollowingSystem() -> Calendar {
        let current = Calendar.autoupdatingCurrent
        var calendar = current.identifier == .gregorian ? current : Calendar(identifier: .gregorian)
        calendar.locale = current.locale
        calendar.timeZone = current.timeZone
        calendar.firstWeekday = current.firstWeekday
        return calendar
    }

    static func monthStart(containing date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? calendar.startOfDay(for: date)
    }

    static func dayID(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d%02d%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

struct CalendarMonthModelBuilder {
    private let calendar: Calendar
    private let lunarCalendar: Calendar
    private let holidayProvider: CalendarHolidayProvider

    init(
        calendar: Calendar = CalendarComponentCalendars.gregorianFollowingSystem(),
        holidayProvider: CalendarHolidayProvider = .empty
    ) {
        self.calendar = calendar
        self.holidayProvider = holidayProvider
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.locale = Locale(identifier: "zh_Hans_CN")
        lunarCalendar.timeZone = calendar.timeZone
        self.lunarCalendar = lunarCalendar
    }

    func makeMonth(
        containing monthDate: Date,
        today: Date = Date(),
        eventsByDay: [Date: [CalendarEventSummary]] = [:]
    ) -> CalendarMonthModel {
        let monthStart = CalendarComponentCalendars.monthStart(containing: monthDate, calendar: calendar)
        let title = Self.monthTitle(for: monthStart, calendar: calendar)
        let days = makeDays(displayedMonthStart: monthStart, today: today, eventsByDay: eventsByDay)

        return CalendarMonthModel(
            displayedMonthStart: monthStart,
            title: title,
            weekdaySymbols: weekdaySymbols(),
            days: days
        )
    }

    func makeDays(
        displayedMonthStart: Date,
        today: Date = Date(),
        eventsByDay: [Date: [CalendarEventSummary]] = [:]
    ) -> [CalendarDayModel] {
        guard let gridStart = gridStartDate(for: displayedMonthStart) else {
            return []
        }

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }

            let dayStart = calendar.startOfDay(for: date)
            let components = calendar.dateComponents([.year, .month, .day], from: dayStart)
            let isInDisplayedMonth = calendar.isDate(dayStart, equalTo: displayedMonthStart, toGranularity: .month)
            let holidayKind = holidayProvider.kind(for: dayStart, calendar: calendar)

            return CalendarDayModel(
                id: CalendarComponentCalendars.dayID(for: dayStart, calendar: calendar),
                date: dayStart,
                dayNumber: String(components.day ?? 0),
                lunarText: lunarText(for: dayStart),
                isInDisplayedMonth: isInDisplayedMonth,
                isToday: calendar.isDate(dayStart, inSameDayAs: today),
                isWeekend: calendar.isDateInWeekend(dayStart),
                holidayKind: holidayKind,
                events: eventsByDay[dayStart] ?? []
            )
        }
    }

    private func gridStartDate(for displayedMonthStart: Date) -> Date? {
        let weekday = calendar.component(.weekday, from: displayedMonthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -leadingDays, to: displayedMonthStart)
    }

    private func weekdaySymbols() -> [String] {
        let symbols = ["日", "一", "二", "三", "四", "五", "六"]
        let startIndex = max(calendar.firstWeekday - 1, 0) % symbols.count
        return Array(symbols[startIndex..<symbols.count] + symbols[0..<startIndex])
    }

    private func lunarText(for date: Date) -> String {
        let components = lunarCalendar.dateComponents([.year, .month, .day, .isLeapMonth], from: date)
        let month = components.month ?? 1
        let day = components.day ?? 1

        if isLastDayOfLunarYear(date) {
            return "除夕"
        }

        if let festival = lunarFestival(month: month, day: day) {
            return festival
        }

        if day == 1 {
            let prefix = components.isLeapMonth == true ? "闰" : ""
            return prefix + Self.lunarMonthName(month)
        }

        return Self.lunarDayName(day)
    }

    private func isLastDayOfLunarYear(_ date: Date) -> Bool {
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: date) else {
            return false
        }

        let year = lunarCalendar.component(.year, from: date)
        let nextYear = lunarCalendar.component(.year, from: nextDay)
        return year != nextYear
    }

    private func lunarFestival(month: Int, day: Int) -> String? {
        switch (month, day) {
        case (1, 1):
            return "春节"
        case (1, 15):
            return "元宵"
        case (5, 5):
            return "端午"
        case (7, 7):
            return "七夕"
        case (8, 15):
            return "中秋"
        case (9, 9):
            return "重阳"
        case (12, 8):
            return "腊八"
        case (12, 23):
            return "小年"
        default:
            return nil
        }
    }

    private static func monthTitle(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d年%02d月", components.year ?? 0, components.month ?? 0)
    }

    private static func lunarMonthName(_ month: Int) -> String {
        let names = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        guard (1...names.count).contains(month) else {
            return "月"
        }

        return names[month - 1]
    }

    private static func lunarDayName(_ day: Int) -> String {
        let names = [
            "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"
        ]
        guard (1...names.count).contains(day) else {
            return ""
        }

        return names[day - 1]
    }
}
