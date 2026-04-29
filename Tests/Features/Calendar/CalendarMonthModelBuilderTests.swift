import XCTest
@testable import MacTools

final class CalendarMonthModelBuilderTests: XCTestCase {
    func testMonthAlwaysBuildsFortyTwoDaysFromConfiguredFirstWeekday() throws {
        var calendar = Self.makeCalendar(firstWeekday: 2)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let builder = CalendarMonthModelBuilder(calendar: calendar)
        let model = builder.makeMonth(
            containing: try Self.date(year: 2026, month: 4, day: 15, calendar: calendar),
            today: try Self.date(year: 2026, month: 4, day: 29, calendar: calendar)
        )

        XCTAssertEqual(model.days.count, 42)
        XCTAssertEqual(model.days.first?.date, try Self.date(year: 2026, month: 3, day: 30, calendar: calendar))
        XCTAssertEqual(model.days.filter(\.isInDisplayedMonth).count, 30)
        XCTAssertEqual(model.days.first(where: { $0.isToday })?.date, try Self.date(year: 2026, month: 4, day: 29, calendar: calendar))
        XCTAssertEqual(model.weekdaySymbols, ["一", "二", "三", "四", "五", "六", "日"])
    }

    func testWeekendAndHolidayOverrideCanCoexist() throws {
        let calendar = Self.makeCalendar(firstWeekday: 1)
        let data = #"{"2026":{"0101":2,"0104":1}}"#.data(using: .utf8)!
        let provider = try CalendarHolidayProvider(data: data)
        let builder = CalendarMonthModelBuilder(calendar: calendar, holidayProvider: provider)
        let model = builder.makeMonth(
            containing: try Self.date(year: 2026, month: 1, day: 15, calendar: calendar),
            today: try Self.date(year: 2026, month: 1, day: 2, calendar: calendar)
        )

        let holiday = try XCTUnwrap(model.days.first { $0.id == "20260101" })
        XCTAssertEqual(holiday.holidayKind, .holiday)

        let adjustedWorkday = try XCTUnwrap(model.days.first { $0.id == "20260104" })
        XCTAssertTrue(adjustedWorkday.isWeekend)
        XCTAssertEqual(adjustedWorkday.holidayKind, .workday)
    }

    func testVisibleEventsLimitKeepsFirstThreeEvents() throws {
        let calendar = Self.makeCalendar(firstWeekday: 1)
        let day = try Self.date(year: 2026, month: 4, day: 29, calendar: calendar)
        let events = (0..<4).map { index in
            CalendarEventSummary(
                id: "event-\(index)",
                title: "Event \(index)",
                timeText: "全天",
                startDate: day,
                endDate: day,
                isAllDay: true,
                color: .accent
            )
        }
        let model = CalendarDayModel(
            id: "20260429",
            date: day,
            dayNumber: "29",
            lunarText: "十三",
            isInDisplayedMonth: true,
            isToday: true,
            isWeekend: false,
            holidayKind: nil,
            events: events
        )

        XCTAssertEqual(model.visibleEvents.map(\.id), ["event-0", "event-1", "event-2"])
    }

    private static func makeCalendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
    }
}
