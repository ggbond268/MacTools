import Combine
import Foundation

@MainActor
final class CalendarComponentViewModel: ObservableObject {
    @Published private(set) var month: CalendarMonthModel
    @Published private(set) var selectedDay: CalendarDayModel?
    @Published private(set) var authorization: CalendarEventAuthorization
    @Published private(set) var isLoadingEvents = false

    private let eventService: CalendarEventServicing
    private let holidayProvider: CalendarHolidayProvider
    private let calendar: Calendar
    private var displayedMonthStart: Date
    private var selectedDate: Date
    private var eventsByDay: [Date: [CalendarEventSummary]] = [:]
    private var loadTask: Task<Void, Never>?

    init(
        eventService: CalendarEventServicing = CalendarEventService(),
        holidayProvider: CalendarHolidayProvider = .bundled(),
        calendar: Calendar = CalendarComponentCalendars.gregorianFollowingSystem(),
        today: Date = Date()
    ) {
        self.eventService = eventService
        self.holidayProvider = holidayProvider
        self.calendar = calendar
        self.displayedMonthStart = CalendarComponentCalendars.monthStart(containing: today, calendar: calendar)
        self.selectedDate = calendar.startOfDay(for: today)
        self.authorization = eventService.authorization
        self.month = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider
        ).makeMonth(containing: today, today: today)
        self.selectedDay = month.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    func start() {
        refresh()
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    func refresh() {
        rebuildMonth()
        reloadEvents()
    }

    func moveMonth(by value: Int) {
        guard let nextMonth = calendar.date(byAdding: .month, value: value, to: displayedMonthStart) else {
            return
        }

        displayedMonthStart = CalendarComponentCalendars.monthStart(containing: nextMonth, calendar: calendar)
        selectedDate = displayedMonthStart
        eventsByDay = [:]
        rebuildMonth()
        reloadEvents()
    }

    func goToToday() {
        let today = calendar.startOfDay(for: Date())
        displayedMonthStart = CalendarComponentCalendars.monthStart(containing: today, calendar: calendar)
        selectedDate = today
        eventsByDay = [:]
        rebuildMonth(today: today)
        reloadEvents()
    }

    func select(_ day: CalendarDayModel) {
        selectedDate = day.date
        selectedDay = day
    }

    func open(_ day: CalendarDayModel) {
        select(day)
        eventService.openSystemCalendar(at: day.date)
    }

    private func reloadEvents() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else {
                return
            }

            authorization = eventService.authorization
            guard authorization.isFullAccess else {
                eventsByDay = [:]
                isLoadingEvents = false
                rebuildMonth()
                return
            }

            guard let firstDate = month.days.first?.date,
                  let lastDate = month.days.last?.date,
                  let endDate = calendar.date(byAdding: .day, value: 1, to: lastDate) else {
                return
            }

            isLoadingEvents = true

            do {
                let events = try await eventService.events(from: firstDate, to: endDate)
                guard !Task.isCancelled else {
                    return
                }

                eventsByDay = CalendarEventGrouper.group(
                    events: events,
                    visibleDates: month.days.map(\.date),
                    calendar: calendar
                )
                isLoadingEvents = false
                rebuildMonth()
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                eventsByDay = [:]
                isLoadingEvents = false
                rebuildMonth()
            }
        }
    }

    private func rebuildMonth(today: Date = Date()) {
        month = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider
        ).makeMonth(
            containing: displayedMonthStart,
            today: today,
            eventsByDay: eventsByDay
        )

        selectedDay = month.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
            ?? month.days.first { $0.isToday }
            ?? month.days.first
    }
}
