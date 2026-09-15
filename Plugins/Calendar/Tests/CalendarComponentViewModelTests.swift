import XCTest
@testable import MacTools
@testable import CalendarPlugin

@MainActor
final class CalendarComponentViewModelTests: XCTestCase {
    func testChangingWeekStartReloadsEventsForNewGridRange() async throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate,
            now: { targetDate }
        )
        let sundayRequest = expectation(description: "Sunday-first event range loaded")
        service.onEventsRequest = sundayRequest.fulfill

        viewModel.start()
        await fulfillment(of: [sundayRequest], timeout: 1)

        let mondayRequest = expectation(description: "Monday-first event range loaded")
        service.onEventsRequest = mondayRequest.fulfill
        viewModel.setWeekStartDay(.monday)
        await fulfillment(of: [mondayRequest], timeout: 1)

        XCTAssertEqual(service.eventRanges.count, 2)
        XCTAssertEqual(
            service.eventRanges.map { CalendarComponentCalendars.dayID(for: $0.start, calendar: calendar) },
            ["20260329", "20260330"]
        )
        XCTAssertEqual(
            service.eventRanges.map { CalendarComponentCalendars.dayID(for: $0.end, calendar: calendar) },
            ["20260510", "20260511"]
        )
    }

    func testChangingWeekStartWhileStoppedDoesNotReloadEvents() async throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate,
            now: { targetDate }
        )
        let initialRequest = expectation(description: "Visible calendar loads events")
        service.onEventsRequest = initialRequest.fulfill
        viewModel.start()
        await fulfillment(of: [initialRequest], timeout: 1)
        viewModel.stop()

        let unexpectedRequest = expectation(description: "Hidden calendar should not load events")
        unexpectedRequest.isInverted = true
        service.onEventsRequest = unexpectedRequest.fulfill

        viewModel.setWeekStartDay(.monday)
        await fulfillment(of: [unexpectedRequest], timeout: 0.1)

        XCTAssertEqual(service.eventRanges.count, 1)
        XCTAssertEqual(viewModel.month.weekdaySymbols.first, "一")

        let resumedRequest = expectation(description: "Calendar reloads events when shown again")
        service.onEventsRequest = resumedRequest.fulfill
        viewModel.start()
        await fulfillment(of: [resumedRequest], timeout: 1)

        XCTAssertEqual(
            service.eventRanges.map { CalendarComponentCalendars.dayID(for: $0.start, calendar: calendar) },
            ["20260329", "20260330"]
        )
    }

    func testChangingWeekStartImmediatelyRebuildsMonthAndKeepsSelection() throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: targetDate
        )

        XCTAssertEqual(viewModel.month.days.first?.id, "20260329")
        XCTAssertEqual(viewModel.month.weekdaySymbols.first, "日")

        viewModel.setWeekStartDay(.monday)

        XCTAssertEqual(viewModel.month.days.first?.id, "20260330")
        XCTAssertEqual(viewModel.month.weekdaySymbols.first, "一")
        XCTAssertEqual(viewModel.selectedDay?.id, "20260415")
    }

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
            lunarDateText: "四月十三",
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

    func testSelectingDayDoesNotChangeTheTodayDetailSource() throws {
        let calendar = Self.makeCalendar()
        let service = MockCalendarEventService()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let targetDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 29)))
        let event = CalendarEventSummary(
            id: "event-1",
            title: "Planning",
            timeText: "10:00",
            startDate: targetDate,
            endDate: targetDate,
            isAllDay: false,
            color: .accent
        )
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today
        )
        let targetDay = CalendarDayModel(
            id: "20260429",
            date: targetDate,
            dayNumber: "29",
            lunarText: "十三",
            lunarDateText: "四月十三",
            isInDisplayedMonth: true,
            isToday: false,
            isWeekend: false,
            holidayKind: nil,
            events: [event]
        )

        viewModel.select(targetDay)

        XCTAssertEqual(viewModel.selectedDay, targetDay)
        XCTAssertEqual(viewModel.todayDay?.id, "20260415")
        XCTAssertNotEqual(viewModel.todayDay?.id, targetDay.id)
    }

    func testRefreshUpdatesTodayDetailAfterDayBoundary() throws {
        let calendar = Self.makeCalendar()
        var now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let viewModel = CalendarComponentViewModel(
            eventService: MockCalendarEventService(),
            holidayProvider: .empty,
            calendar: calendar,
            today: now,
            now: { now }
        )
        now = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))

        viewModel.refresh()

        XCTAssertEqual(viewModel.todayDay?.id, "20260416")
    }

    func testCrossDayEventAppearsOnceWhenTodayIsOutsideTheMonthGrid() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 25)))
        let endDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.eventInputs = [CalendarEventInput(
            id: "vacation",
            title: "Vacation",
            startDate: today,
            endDate: endDate,
            isAllDay: true,
            color: .accent
        )]
        let requests = expectation(description: "Month grid and today loaded")
        requests.expectedFulfillmentCount = 2
        service.onEventsRequest = requests.fulfill
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        defer { viewModel.stop() }

        viewModel.moveMonth(by: 1)
        await fulfillment(of: [requests], timeout: 1)

        XCTAssertEqual(service.eventRanges.count, 2)
        XCTAssertEqual(viewModel.todayDay?.events.map(\.title), ["Vacation"])
        let nextDay = try XCTUnwrap(viewModel.month.days.first { $0.id == "20260426" })
        XCTAssertEqual(nextDay.events.map(\.title), ["Vacation"])
    }

    func testDistantMonthKeepsQueriesBoundedAndPreservesTodaysEvents() async throws {
        let calendar = Self.makeCalendar()
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let distantDate = try XCTUnwrap(calendar.date(byAdding: .year, value: 10, to: today))
        let distantEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: distantDate))
        let service = MockCalendarEventService()
        service.authorization = .fullAccess
        service.eventInputs = [
            CalendarEventInput(id: "today", title: "Today", startDate: today,
                               endDate: tomorrow, isAllDay: true, color: .accent),
            CalendarEventInput(id: "future", title: "Future", startDate: distantDate,
                               endDate: distantEnd, isAllDay: true, color: .accent)
        ]
        let requests = expectation(description: "Only the month grid and today are queried")
        requests.expectedFulfillmentCount = 2
        service.onEventsRequest = requests.fulfill
        let viewModel = CalendarComponentViewModel(
            eventService: service,
            holidayProvider: .empty,
            calendar: calendar,
            today: today,
            now: { today }
        )
        defer { viewModel.stop() }

        viewModel.moveMonth(by: 120)
        await fulfillment(of: [requests], timeout: 1)

        XCTAssertEqual(service.eventRanges.count, 2)
        XCTAssertEqual(service.eventRanges.map {
            calendar.dateComponents([.day], from: $0.start, to: $0.end).day
        }, [42, 1])
        XCTAssertEqual(viewModel.todayDay?.events.map(\.title), ["Today"])
        let distantDay = try XCTUnwrap(viewModel.month.days.first {
            calendar.isDate($0.date, inSameDayAs: distantDate)
        })
        XCTAssertEqual(distantDay.events.map(\.title), ["Future"])
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
    private(set) var eventRanges: [(start: Date, end: Date)] = []
    var onEventsRequest: (() -> Void)?
    var eventInputs: [CalendarEventInput] = []

    func requestAccess() async -> CalendarEventAuthorization {
        authorization
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [CalendarEventInput] {
        eventRanges.append((startDate, endDate))
        onEventsRequest?()
        return eventInputs.filter { $0.startDate < endDate && $0.endDate > startDate }
    }

    func openSystemCalendar(at date: Date) {
        openedDates.append(date)
    }
}
