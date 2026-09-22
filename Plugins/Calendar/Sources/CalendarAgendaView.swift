import SwiftUI
import MacToolsPluginKit

struct CalendarAgendaView: View {
    let days: [CalendarDayModel]
    let dates: [Date]
    let today: Date
    let authorization: CalendarEventAuthorization
    let errorMessage: String?
    let localization: PluginLocalization
    let onOpenDay: (CalendarDayModel) -> Void
    let onRequestAccess: () -> Void
    let onRetry: () -> Void

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(localization.string("agenda.title", defaultValue: "近期日程"), systemImage: "calendar.badge.clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text.primary)
                Spacer(minLength: 4)
                Text(CalendarAgendaPresentation.rangeText(dates: dates))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }

            if !authorization.isFullAccess {
                status(
                    localization.string("agenda.permission", defaultValue: "允许读取日历后查看日程"),
                    actionTitle: authorization == .notDetermined
                        ? localization.string("agenda.allow", defaultValue: "授权")
                        : localization.string("agenda.openSettings", defaultValue: "打开设置"),
                    action: onRequestAccess
                )
            } else if let errorMessage {
                status(errorMessage, actionTitle: localization.string("agenda.retry", defaultValue: "重试"), action: onRetry)
            } else {
                agendaList
            }
        }
        .padding(CalendarComponentLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var agendaList: some View {
        // Resolve short content and the bounded scrolling fallback in one layout
        // pass, without publishing an estimated height before the measured height.
        ViewThatFits(in: .vertical) {
            agendaContent
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    agendaContent
                }
                .scrollIndicators(.never)
                .onChange(of: dates) { _, _ in
                    if let firstDay = days.first { proxy.scrollTo(firstDay.id, anchor: .top) }
                }
            }
            .frame(height: CalendarComponentLayout.maximumAgendaListHeight)
        }
        .frame(maxHeight: CalendarComponentLayout.maximumAgendaListHeight)
    }

    private var agendaContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(days) { day in
                daySection(day).id(day.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func daySection(_ day: CalendarDayModel) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(day.dayNumber)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text.primary)
                    .frame(width: 30, height: 30)
                    .background(
                        day.isToday ? .clear : theme.surfaces.nested,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        if day.isToday { CalendarTodayOutline() }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(CalendarAgendaPresentation.dayTitle(day.date, today: today, localization: localization))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.text.primary)
                    let subtitle = CalendarDayPresentation.dateSubtitle(
                        for: day, includesOverflowCount: false, localization: localization
                    )
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.text.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(CalendarAgendaPresentation.shortDate(day.date))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.text.secondary)
            }
            .padding(.bottom, 2)

            ForEach(day.events) { event in
                CalendarAgendaEventRow(event: event, localization: localization) { onOpenDay(day) }
            }
        }
    }

    private func status(_ text: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct CalendarAgendaEventRow: View {
    let event: CalendarEventSummary
    let localization: PluginLocalization
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: event.color.red, green: event.color.green, blue: event.color.blue, opacity: event.color.alpha))
                    .frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.text.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([event.timeText, event.calendarTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.text.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHovered ? theme.surfaces.controlHover : theme.surfaces.nestedMuted, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(localization.string("agenda.openDay", defaultValue: "在日历中打开这一天"))
    }
}

enum CalendarAgendaPresentation {
    static func rangeText(dates: [Date]) -> String {
        guard let first = dates.first, let last = dates.last else { return "" }
        let formatter = DateIntervalFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.dateTemplate = "MMMd"
        return first == last ? shortDate(first) : formatter.string(from: first, to: last)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    static func dayTitle(_ date: Date, today: Date, localization: PluginLocalization) -> String {
        let offset = Calendar.current.dateComponents([.day], from: today, to: date).day
        switch offset {
        case 0: return localization.string("accessibility.today", defaultValue: "今天")
        case 1: return localization.string("agenda.tomorrow", defaultValue: "明天")
        case -1: return localization.string("agenda.yesterday", defaultValue: "昨天")
        default:
            let formatter = DateFormatter()
            formatter.locale = PluginRuntimeLocalization.locale
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        }
    }
}
