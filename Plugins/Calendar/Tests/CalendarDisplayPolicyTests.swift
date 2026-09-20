import Foundation
import XCTest
import MacToolsPluginKit
@testable import CalendarPlugin

final class CalendarDisplayPolicyTests: XCTestCase {
    func testDefaultUsesLanguageWithoutInferringItFromRegionOrSystemCalendar() {
        let cases: [(String, CalendarAlternateCalendar)] = [
            ("zh", .chinese), ("zh-Hans", .chinese), ("zh-Hant", .chinese),
            ("zh_Hans_US", .chinese), ("zh_Hant_TW", .chinese), ("zh_Hans_SG", .chinese),
            ("en_CN", .none), ("en_HK", .none), ("en_US", .none), ("ja_JP", .none),
            ("ko_KR", .none), ("ar_SA", .none), ("en_US@rg=cnzzzz", .none),
            ("en_US@calendar=chinese", .none), ("zhx", .none)
        ]
        for (identifier, expected) in cases {
            XCTAssertEqual(CalendarDisplayPolicy.defaultAlternateCalendar(languageIdentifier: identifier), expected, identifier)
        }
    }

    func testRenderingUsesSavedCalendarRegardlessOfRegionOrTimeZone() throws {
        for identifier in ["en_CN", "zh_Hans_US", "en_HK", "en_US@calendar=chinese"] {
            var calendar = makeCalendar(identifier)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))
            for selection in CalendarAlternateCalendar.allCases {
                let day = CalendarMonthModelBuilder(calendar: calendar, alternateCalendar: selection)
                    .makeDay(for: date, today: date)
                XCTAssertEqual(!day.alternateCalendarText.isEmpty, selection == .chinese, identifier)
                XCTAssertEqual(!day.alternateCalendarDateText.isEmpty, selection == .chinese, identifier)
            }
        }
    }

    func testManualLunarPreferenceDoesNotEnableOrDisableMainlandHolidayBadges() throws {
        for identifier in ["en_CN", "zh_Hans_US", "zh_Hant_TW", "en_HK", "zh_Hant_MO", "zh_Hans_SG"] {
            let calendar = makeCalendar(identifier)
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 4)))
            let provider = try CalendarHolidayProvider(data: Data(#"{"2026":{"0104":1}}"#.utf8))
            for selection in CalendarAlternateCalendar.allCases {
                let day = CalendarMonthModelBuilder(calendar: calendar, holidayProvider: provider, alternateCalendar: selection)
                    .makeDay(for: date, today: date)
                XCTAssertEqual(!day.alternateCalendarText.isEmpty, selection == .chinese, identifier)
                XCTAssertEqual(day.holidayKind, identifier == "en_CN" ? .workday : nil, identifier)
            }
        }
    }

    func testNonLunarWeekdayHasNoPlaceholderSubtitleAndKeepsEvents() throws {
        let calendar = makeCalendar("zh_Hans_US")
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))
        let event = CalendarEventSummary(id: "event", title: "Mid-Autumn gathering", timeText: "18:00",
            startDate: date, endDate: date.addingTimeInterval(3600), isAllDay: false, color: .accent)
        let day = CalendarMonthModelBuilder(calendar: calendar).makeDay(for: date, today: date, events: [event])
        XCTAssertTrue(CalendarDayPresentation.dateSubtitle(for: day).isEmpty)
        XCTAssertEqual(day.events, [event], "Hiding lunar annotations must never filter subscribed calendar events")
    }

    func testMonthTitleUsesLocalizedMonthNameAndOrder() throws {
        let calendar = makeCalendar("en_US")
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        for (locale, expected) in [("en_US", "April 2026"), ("fr_FR", "avril 2026"), ("zh_CN", "2026年4月")] {
            let month = CalendarMonthModelBuilder(calendar: calendar, displayLocale: Locale(identifier: locale))
                .makeMonth(containing: date)
            XCTAssertEqual(month.title, expected)
        }
    }

    func testLeapMonthDoesNotRepeatRegularMonthFestival() throws {
        let calendar = makeCalendar("zh_CN")
        var lunar = Calendar(identifier: .chinese)
        lunar.timeZone = calendar.timeZone
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2009, month: 1, day: 1)))
        let leapDate = try XCTUnwrap((0..<365).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .first {
                let parts = lunar.dateComponents([.month, .day, .isLeapMonth], from: $0)
                return parts.month == 5 && parts.day == 5 && parts.isLeapMonth == true
            })
        let day = CalendarMonthModelBuilder(calendar: calendar, alternateCalendar: .chinese)
            .makeDay(for: leapDate, today: leapDate)
        XCTAssertEqual(day.alternateCalendarText, PluginLocalization(bundle: .main).string("lunar.day.5", defaultValue: "初五"))
    }

    private func makeCalendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: identifier)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
