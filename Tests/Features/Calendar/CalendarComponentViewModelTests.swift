import XCTest
@testable import MacTools

@MainActor
final class CalendarComponentViewModelTests: XCTestCase {
    func testOpenSelectsDayAndDelegatesToSystemCalendar() throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate
        )
        let targetDay = CalendarDayModel(
            id: "20260429",
            date: targetDate,
            dayNumber: "29",
            lunarText: "十三",
            isInDisplayedMonth: true,
            isToday: true,
            isWeekend: false,
            holidayKind: nil,
            events: []
        )

        viewModel.open(targetDay)

        XCTAssertEqual(viewModel.selectedDay?.id, "20260429")
        XCTAssertEqual(service.openedDates, [targetDate])
    }

    private static func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }
}

@MainActor
private final class MockCalendarEventService: CalendarEventServicing {
    var authorization: CalendarEventAuthorization = .denied("未授权")
    private(set) var openedDates: [Date] = []

    func requestAccess() async -> CalendarEventAuthorization {
        authorization
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        []
    }

    func openSystemCalendar(at date: Date) {
        openedDates.append(date)
    }
}
