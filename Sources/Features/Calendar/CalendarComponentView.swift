import AppKit
import SwiftUI

struct CalendarComponentView: View {
    private enum Layout {
        static let contentPadding: CGFloat = 8
        static let sectionSpacing: CGFloat = 3
        static let gridSpacing: CGFloat = 6
        static let headerHeight: CGFloat = 20
        static let weekdayHeight: CGFloat = 10
        static let dayCellSize: CGFloat = 36
        static let cornerRadius: CGFloat = 16
    }

    @StateObject private var viewModel = CalendarComponentViewModel()
    init(context: PluginComponentContext) {}

    var body: some View {
        VStack(spacing: 0) {
            calendarCard
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var calendarCard: some View {
        VStack(spacing: Layout.sectionSpacing) {
            CalendarHeaderView(
                title: viewModel.month.title,
                onPrevious: { viewModel.moveMonth(by: -1) },
                onToday: { viewModel.goToToday() },
                onNext: { viewModel.moveMonth(by: 1) }
            )

            CalendarWeekdayRow(
                symbols: viewModel.month.weekdaySymbols,
                dayCellSize: Layout.dayCellSize,
                gridSpacing: Layout.gridSpacing
            )

            CalendarMonthGrid(
                days: viewModel.month.days,
                selectedDayID: viewModel.selectedDay?.id,
                dayCellSize: Layout.dayCellSize,
                gridSpacing: Layout.gridSpacing,
                onSelect: { viewModel.select($0) },
                onOpen: { viewModel.open($0) }
            )
        }
        .padding(Layout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(CalendarComponentBackground(cornerRadius: Layout.cornerRadius))
    }

}

private struct CalendarHeaderView: View {
    let title: String
    let onPrevious: () -> Void
    let onToday: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            CalendarIconButton(systemName: "chevron.left", help: "上个月", action: onPrevious)
            Button("今天", action: onToday)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .frame(width: 32, height: 20)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("回到今天")
            CalendarIconButton(systemName: "chevron.right", help: "下个月", action: onNext)
        }
        .frame(height: 20)
    }
}

private struct CalendarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CalendarWeekdayRow: View {
    let symbols: [String]
    let dayCellSize: CGFloat
    let gridSpacing: CGFloat

    var body: some View {
        HStack(spacing: gridSpacing) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: dayCellSize)
            }
        }
        .frame(height: 10)
    }
}

private struct CalendarMonthGrid: View {
    let days: [CalendarDayModel]
    let selectedDayID: String?
    let dayCellSize: CGFloat
    let gridSpacing: CGFloat
    let onSelect: (CalendarDayModel) -> Void
    let onOpen: (CalendarDayModel) -> Void

    @State private var hoveredDayID: String?

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(dayCellSize), spacing: gridSpacing),
            count: 7
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(days) { day in
                CalendarDayCell(
                    day: day,
                    isSelected: selectedDayID == day.id,
                    onOpen: { onOpen(day) }
                )
                .frame(width: dayCellSize, height: dayCellSize)
                .background(
                    CalendarEventPopoverPresenter(
                        title: CalendarDayPresentation.dateTitle(for: day),
                        subtitle: CalendarDayPresentation.dateSubtitle(for: day),
                        events: day.events,
                        isPresented: hoveredDayID == day.id && !day.events.isEmpty
                    )
                )
                .onHover { isHovered in
                    if isHovered {
                        hoveredDayID = day.id
                        onSelect(day)
                    } else if hoveredDayID == day.id {
                        hoveredDayID = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDayModel
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: day.isToday ? 1.5 : 0)

                VStack(spacing: 1) {
                    Text(day.dayNumber)
                        .font(.system(size: 13, weight: day.isToday ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(primaryTextStyle)
                        .lineLimit(1)

                    Text(day.lunarText)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(secondaryTextStyle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    CalendarEventDots(events: day.visibleEvents)
                        .padding(.top, 1)
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let holidayKind = day.holidayKind {
                    CalendarHolidayBadge(kind: holidayKind)
                        .offset(x: 2, y: -3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }

        if day.isToday {
            return Color.accentColor.opacity(0.08)
        }

        return Color(nsColor: .controlBackgroundColor).opacity(day.isInDisplayedMonth ? 0.35 : 0.12)
    }

    private var borderColor: Color {
        day.isToday ? Color.accentColor.opacity(0.95) : .clear
    }

    private var primaryTextStyle: HierarchicalShapeStyle {
        if day.isInDisplayedMonth {
            return day.isWeekend ? .secondary : .primary
        }

        return .tertiary
    }

    private var secondaryTextStyle: HierarchicalShapeStyle {
        day.isInDisplayedMonth ? .secondary : .tertiary
    }

    private var accessibilityLabel: String {
        var parts = [day.dayNumber, day.lunarText]
        if day.isToday {
            parts.append("今天")
        }
        if let holidayKind = day.holidayKind {
            parts.append(holidayKind == .holiday ? "休息日" : "调休工作日")
        }
        if !day.events.isEmpty {
            parts.append("\(day.events.count) 个日程")
        }
        return parts.joined(separator: "，")
    }
}

private struct CalendarHolidayBadge: View {
    let kind: CalendarHolidayKind

    var body: some View {
        Text(kind.badgeText)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(
                Circle()
                    .fill(kind == .holiday ? Color(nsColor: .systemTeal) : Color(nsColor: .systemOrange))
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
            )
    }
}

private struct CalendarEventDots: View {
    let events: [CalendarEventSummary]

    var body: some View {
        HStack(spacing: 2) {
            if events.isEmpty {
                Color.clear
                    .frame(width: 4, height: 4)
            } else {
                ForEach(events) { event in
                    Circle()
                        .fill(Color(calendarEventColor: event.color))
                        .frame(width: 4, height: 4)
                }
            }
        }
        .frame(height: 5)
    }
}

private struct CalendarEventPopoverPresenter: NSViewRepresentable {
    let title: String
    let subtitle: String
    let events: [CalendarEventSummary]
    let isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            title: title,
            subtitle: subtitle,
            events: events,
            isPresented: isPresented,
            sourceView: nsView
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator {
        private var popover: NSPopover?

        @MainActor
        func update(
            title: String,
            subtitle: String,
            events: [CalendarEventSummary],
            isPresented: Bool,
            sourceView: NSView
        ) {
            guard isPresented, !events.isEmpty, sourceView.window != nil else {
                close()
                return
            }

            let popover = popover ?? makePopover()
            let content = CalendarFloatingEventPopoverContent(
                title: title,
                subtitle: subtitle,
                events: events
            )
            let hostingController = NSHostingController(rootView: content)
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: 230, height: min(hostingController.view.fittingSize.height, 260))

            if !popover.isShown {
                popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
            }

            self.popover = popover
        }

        @MainActor
        func close() {
            popover?.performClose(nil)
            popover = nil
        }

        @MainActor
        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            return popover
        }
    }
}

private struct CalendarFloatingEventPopoverContent: View {
    let title: String
    let subtitle: String
    let events: [CalendarEventSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(events.prefix(6))) { event in
                    CalendarEventRow(event: event)
                }

                if events.count > 6 {
                    Text("还有 \(events.count - 6) 个日程")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
    }
}

private enum CalendarDayPresentation {
    static func dateTitle(for day: CalendarDayModel) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day.date)
    }

    static func dateSubtitle(for day: CalendarDayModel) -> String {
        var parts = [day.lunarText]
        if let holidayKind = day.holidayKind {
            parts.append(holidayKind == .holiday ? "休息日" : "调休工作日")
        } else if day.isWeekend {
            parts.append("周末")
        }
        if day.events.count > CalendarDayModel.maximumVisibleEvents {
            parts.append("还有 \(day.events.count - CalendarDayModel.maximumVisibleEvents) 个日程")
        }
        return parts.joined(separator: " · ")
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEventSummary

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(calendarEventColor: event.color))
                .frame(width: 6, height: 6)

            Text(event.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(event.timeText)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct CalendarComponentBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.045))
    }
}

private extension Color {
    init(calendarEventColor color: CalendarEventColor) {
        self.init(
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }
}
