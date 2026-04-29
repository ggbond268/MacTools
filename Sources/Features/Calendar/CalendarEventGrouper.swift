import Foundation

enum CalendarEventGrouper {
    static func group(
        events: [CalendarEventInput],
        visibleDates: [Date],
        calendar: Calendar
    ) -> [Date: [CalendarEventSummary]] {
        let dayStarts = visibleDates.map { calendar.startOfDay(for: $0) }
        var grouped = Dictionary(uniqueKeysWithValues: dayStarts.map { ($0, [CalendarEventSummary]()) })

        for event in events {
            for dayStart in dayStarts where overlaps(event: event, dayStart: dayStart, calendar: calendar) {
                grouped[dayStart, default: []].append(summary(for: event, dayStart: dayStart, calendar: calendar))
            }
        }

        return grouped.mapValues { summaries in
            summaries.sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay && !rhs.isAllDay
                }

                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }

                return lhs.title.localizedCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private static func overlaps(event: CalendarEventInput, dayStart: Date, calendar: Calendar) -> Bool {
        guard let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return false
        }

        let eventEnd = normalizedEndDate(for: event, calendar: calendar)
        return event.startDate < nextDayStart && eventEnd > dayStart
    }

    private static func summary(
        for event: CalendarEventInput,
        dayStart: Date,
        calendar: Calendar
    ) -> CalendarEventSummary {
        CalendarEventSummary(
            id: "\(event.id)-\(CalendarComponentCalendars.dayID(for: dayStart, calendar: calendar))",
            title: event.title.isEmpty ? "未命名日程" : event.title,
            timeText: timeText(for: event, dayStart: dayStart, calendar: calendar),
            startDate: event.startDate,
            endDate: normalizedEndDate(for: event, calendar: calendar),
            isAllDay: event.isAllDay,
            color: event.color
        )
    }

    private static func normalizedEndDate(for event: CalendarEventInput, calendar: Calendar) -> Date {
        if event.endDate > event.startDate {
            return event.endDate
        }

        return calendar.date(byAdding: .minute, value: 1, to: event.startDate) ?? event.startDate
    }

    private static func timeText(for event: CalendarEventInput, dayStart: Date, calendar: Calendar) -> String {
        guard !event.isAllDay else {
            return "全天"
        }

        let endDate = normalizedEndDate(for: event, calendar: calendar)
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let visibleStart = max(event.startDate, dayStart)
        let visibleEnd = min(endDate, nextDayStart)

        if visibleStart >= visibleEnd {
            return formatTime(event.startDate)
        }

        return "\(formatTime(visibleStart))–\(formatTime(visibleEnd))"
    }

    private static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
