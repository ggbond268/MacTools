import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import CalendarPlugin

final class CalendarMonthModelBuilderTests: XCTestCase {
    func testMonthSupportsEveryConfiguredFirstWeekday() throws {
        let expectedSymbols = ["日", "一", "二", "三", "四", "五", "六"]

        for firstWeekday in 1...7 {
            let calendar = Self.makeCalendar(firstWeekday: firstWeekday)
            let builder = CalendarMonthModelBuilder(calendar: calendar)
            let model = builder.makeMonth(
                containing: try Self.date(year: 2026, month: 4, day: 15, calendar: calendar)
            )

            XCTAssertEqual(model.days.count, 42, "firstWeekday=\(firstWeekday)")
            XCTAssertEqual(
                model.weekdaySymbols.first,
                expectedSymbols[firstWeekday - 1],
                "firstWeekday=\(firstWeekday)"
            )
            XCTAssertEqual(
                model.days.first.map { calendar.component(.weekday, from: $0.date) },
                firstWeekday,
                "firstWeekday=\(firstWeekday)"
            )
        }
    }

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
        var calendar = Self.makeCalendar(firstWeekday: 1)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
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

    func testHolidayBadgesAreHiddenForNonChineseLocales() throws {
        var calendar = Self.makeCalendar(firstWeekday: 1)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let data = #"{"2026":{"0101":2,"0104":1}}"#.data(using: .utf8)!
        let provider = try CalendarHolidayProvider(data: data)
        let builder = CalendarMonthModelBuilder(calendar: calendar, holidayProvider: provider)
        let model = builder.makeMonth(
            containing: try Self.date(year: 2026, month: 1, day: 15, calendar: calendar),
            today: try Self.date(year: 2026, month: 1, day: 2, calendar: calendar)
        )

        XCTAssertNil(model.days.first { $0.id == "20260101" }?.holidayKind)
        XCTAssertNil(model.days.first { $0.id == "20260104" }?.holidayKind)
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
            lunarDateText: "四月十三",
            isInDisplayedMonth: true,
            isToday: true,
            isWeekend: false,
            holidayKind: nil,
            events: events
        )

        XCTAssertEqual(model.visibleEvents.map(\.id), ["event-0", "event-1", "event-2"])
    }

    func testFestivalLabelKeepsTheFullLunarDate() throws {
        let calendar = Self.makeCalendar(firstWeekday: 1)
        let localization = PluginLocalization(bundle: .main)
        let builder = CalendarMonthModelBuilder(calendar: calendar, localization: localization)
        let model = builder.makeMonth(
            containing: try Self.date(year: 2026, month: 9, day: 15, calendar: calendar)
        )
        let midAutumnDate = try Self.date(year: 2026, month: 9, day: 25, calendar: calendar)

        let midAutumnDay = try XCTUnwrap(model.days.first { calendar.isDate($0.date, inSameDayAs: midAutumnDate) })
        let expectedLunarMonth = localization.string("lunar.month.8", defaultValue: "八月")
        let expectedLunarDay = localization.string("lunar.day.15", defaultValue: "十五")
        let expectedFestival = localization.string("lunar.festival.midAutumn", defaultValue: "中秋")

        XCTAssertEqual(midAutumnDay.lunarDateText, expectedLunarMonth + expectedLunarDay)
        XCTAssertEqual(midAutumnDay.lunarText, expectedFestival)
    }

    func testFestivalDateSubtitleIncludesFullLunarDateAndFestival() throws {
        let calendar = Self.makeCalendar(firstWeekday: 1)
        let localization = PluginLocalization(bundle: .main)
        let model = CalendarMonthModelBuilder(calendar: calendar, localization: localization).makeMonth(
            containing: try Self.date(year: 2026, month: 9, day: 15, calendar: calendar)
        )
        let midAutumnDate = try Self.date(year: 2026, month: 9, day: 25, calendar: calendar)
        let midAutumnDay = try XCTUnwrap(model.days.first { calendar.isDate($0.date, inSameDayAs: midAutumnDate) })

        let subtitle = CalendarDayPresentation.dateSubtitle(for: midAutumnDay, localization: localization)

        XCTAssertTrue(subtitle.contains(midAutumnDay.lunarDateText))
        XCTAssertTrue(subtitle.contains(midAutumnDay.lunarText))
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
