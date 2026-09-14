import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class CalendarComponentViewModel: ObservableObject {
    @Published private(set) var month: CalendarMonthModel
    @Published private(set) var selectedDay: CalendarDayModel?
    @Published private(set) var todayDay: CalendarDayModel?
    @Published private(set) var authorization: CalendarEventAuthorization
    @Published private(set) var isLoadingEvents = false

    private let eventService: CalendarEventServicing
    private let holidayProvider: CalendarHolidayProvider
    private var calendar: Calendar
    private let localization: PluginLocalization
    private let now: () -> Date
    private var displayedMonthStart: Date
    private var selectedDate: Date
    private var todayDate: Date
    private var eventsByDay: [Date: [CalendarEventSummary]] = [:]
    private var loadTask: Task<Void, Never>?
    private var isStarted = false

    init(
        eventService: CalendarEventServicing = CalendarEventService(),
        holidayProvider: CalendarHolidayProvider,
        calendar: Calendar = CalendarComponentCalendars.gregorian(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        today: Date = Date(),
        now: @escaping () -> Date = Date.init
    ) {
        self.eventService = eventService
        self.holidayProvider = holidayProvider
        self.calendar = calendar
        self.localization = localization
        self.now = now
        let initialToday = calendar.startOfDay(for: today)
        self.displayedMonthStart = CalendarComponentCalendars.monthStart(containing: initialToday, calendar: calendar)
        self.selectedDate = initialToday
        self.todayDate = initialToday
        self.authorization = eventService.authorization
        let initialMonth = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider,
            localization: localization
        ).makeMonth(containing: initialToday, today: initialToday)
        self.month = initialMonth
        self.selectedDay = initialMonth.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
        self.todayDay = initialMonth.days.first { $0.isToday }
    }

    func start() {
        isStarted = true
        refresh()
    }

    func stop() {
        isStarted = false
        loadTask?.cancel()
        loadTask = nil
        isLoadingEvents = false
    }

    func refresh() {
        todayDate = calendar.startOfDay(for: now())
        rebuildMonth()
        reloadEvents()
    }

    func setWeekStartDay(_ day: CalendarWeekStartDay) {
        guard calendar.firstWeekday != day.calendarFirstWeekday else {
            return
        }

        loadTask?.cancel()
        calendar.firstWeekday = day.calendarFirstWeekday
        eventsByDay = [:]
        rebuildMonth()
        if isStarted {
            reloadEvents()
        }
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
        let today = calendar.startOfDay(for: now())
        todayDate = today
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

            let visibleDates = month.days.map(\.date)
            let requestedToday = todayDate
            guard let firstDate = visibleDates.first,
                  let lastDate = visibleDates.last,
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: requestedToday),
                  let endDate = calendar.date(byAdding: .day, value: 1, to: lastDate) else {
                return
            }

            isLoadingEvents = true

            do {
                let events = try await eventService.events(from: firstDate, to: endDate)
                guard !Task.isCancelled else {
                    return
                }

                var groupedEvents = CalendarEventGrouper.group(
                    events: events,
                    visibleDates: visibleDates,
                    calendar: calendar,
                    localization: localization
                )
                if requestedToday < firstDate || requestedToday >= endDate {
                    let todayEvents = try await eventService.events(from: requestedToday, to: tomorrow)
                    guard !Task.isCancelled else {
                        return
                    }

                    // Group each query only for its own dates so a cross-day event
                    // returned by both queries appears once per day.
                    groupedEvents[requestedToday] = CalendarEventGrouper.group(
                        events: todayEvents,
                        visibleDates: [requestedToday],
                        calendar: calendar,
                        localization: localization
                    )[requestedToday] ?? []
                }
                eventsByDay = groupedEvents
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

    private func rebuildMonth(today: Date? = nil) {
        let referenceToday = today.map(calendar.startOfDay(for:)) ?? todayDate
        month = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider,
            localization: localization
        ).makeMonth(
            containing: displayedMonthStart,
            today: referenceToday,
            eventsByDay: eventsByDay
        )

        selectedDay = month.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
            ?? month.days.first { $0.isToday }
            ?? month.days.first
        todayDay = CalendarMonthModelBuilder(
            calendar: calendar,
            holidayProvider: holidayProvider,
            localization: localization
        )
        .makeMonth(containing: referenceToday, today: referenceToday, eventsByDay: eventsByDay)
        .days.first { $0.isToday }
    }
}
