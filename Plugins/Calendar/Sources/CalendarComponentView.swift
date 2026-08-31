import AppKit
import SwiftUI
import MacToolsPluginKit

private enum CalendarComponentLayout {
    static let contentPadding: CGFloat = 8
    static let sectionSpacing: CGFloat = 3
    static let gridSpacing: CGFloat = 6
    static let headerHeight: CGFloat = 20
    static let weekdayHeight: CGFloat = 10
    static let dayCellSize: CGFloat = 36
    static let cornerRadius: CGFloat = PluginComponentPanelLayoutMetrics.cardCornerRadius
}

struct CalendarComponentView: View {
    @ObservedObject private var viewModel: CalendarComponentViewModel
    private let localization: PluginLocalization

    init(
        context: PluginComponentContext,
        viewModel: CalendarComponentViewModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.viewModel = viewModel
        self.localization = localization
    }

    var body: some View {
        VStack(spacing: CalendarComponentLayout.sectionSpacing) {
            calendarCard
            selectedDayDetails
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var calendarCard: some View {
        VStack(spacing: CalendarComponentLayout.sectionSpacing) {
            CalendarHeaderView(
                title: viewModel.month.title,
                localization: localization,
                onPrevious: { viewModel.moveMonth(by: -1) },
                onToday: { viewModel.goToToday() },
                onNext: { viewModel.moveMonth(by: 1) }
            )

            CalendarWeekdayRow(
                symbols: viewModel.month.weekdaySymbols,
                dayCellSize: CalendarComponentLayout.dayCellSize,
                gridSpacing: CalendarComponentLayout.gridSpacing
            )

            CalendarMonthGrid(
                days: viewModel.month.days,
                selectedDayID: viewModel.selectedDay?.id,
                dayCellSize: CalendarComponentLayout.dayCellSize,
                gridSpacing: CalendarComponentLayout.gridSpacing,
                localization: localization,
                onSelect: { viewModel.select($0) },
                onOpen: { viewModel.open($0) }
            )
        }
        .padding(CalendarComponentLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            PluginComponentCardBackground(
                cornerRadius: CalendarComponentLayout.cornerRadius
            )
        )
    }

    @ViewBuilder
    private var selectedDayDetails: some View {
        if let selectedDay = viewModel.selectedDay {
            CalendarSelectedDayDetails(
                day: selectedDay,
                localization: localization
            )
        }
    }
}

private struct CalendarHeaderView: View {
    private enum Layout {
        static let todayButtonMinimumWidth: CGFloat = 32
        static let todayButtonMaximumWidth: CGFloat = 48
        static let todayButtonHorizontalPadding: CGFloat = 4
    }

    let title: String
    let localization: PluginLocalization
    let onPrevious: () -> Void
    let onToday: () -> Void
    let onNext: () -> Void
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            CalendarIconButton(
                systemName: "chevron.left",
                help: localization.string("header.previous.help", defaultValue: "上个月"),
                action: onPrevious
            )
            Button(action: onToday) {
                Text(localization.string("header.today.button", defaultValue: "今天"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Layout.todayButtonHorizontalPadding)
                    .frame(
                        minWidth: Layout.todayButtonMinimumWidth,
                        maxWidth: Layout.todayButtonMaximumWidth,
                        minHeight: 20,
                        maxHeight: 20
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(localization.string("header.today.help", defaultValue: "回到今天"))
            CalendarIconButton(
                systemName: "chevron.right",
                help: localization.string("header.next.help", defaultValue: "下个月"),
                action: onNext
            )
        }
        .frame(height: 20)
    }
}

private struct CalendarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text.secondary)
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
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: gridSpacing) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.text.secondary)
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
    let localization: PluginLocalization
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
                    localization: localization,
                    onOpen: { onOpen(day) }
                )
                .frame(width: dayCellSize, height: dayCellSize)
                .background(
                    CalendarEventPopoverPresenter(
                        title: CalendarDayPresentation.dateTitle(for: day),
                        subtitle: CalendarDayPresentation.dateSubtitle(for: day, localization: localization),
                        events: day.events,
                        localization: localization,
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
    let localization: PluginLocalization
    let onOpen: () -> Void

    @Environment(\.pluginComponentTheme) private var theme

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

                    if !day.lunarText.isEmpty {
                        Text(day.lunarText)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(secondaryTextStyle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }

                    CalendarEventDots(events: day.visibleEvents)
                        .padding(.top, 1)
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let holidayKind = day.holidayKind {
                    CalendarHolidayBadge(kind: holidayKind, localization: localization)
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
            return theme.interaction.selection(theme.dataSeries.primary)
        }

        if day.isToday {
            return theme.interaction.emphasis(theme.dataSeries.primary)
        }

        return day.isInDisplayedMonth
            ? theme.surfaces.nested
            : theme.surfaces.nestedMuted
    }

    private var borderColor: Color {
        day.isToday ? theme.dataSeries.primary.opacity(0.95) : .clear
    }

    private var primaryTextStyle: Color {
        if day.isInDisplayedMonth {
            return day.isWeekend ? theme.text.secondary : theme.text.primary
        }

        return theme.text.tertiary
    }

    private var secondaryTextStyle: Color {
        day.isInDisplayedMonth ? theme.text.secondary : theme.text.tertiary
    }

    private var accessibilityLabel: String {
        var parts = [day.dayNumber]
        if !day.lunarText.isEmpty {
            parts.append(day.lunarText)
        }
        if day.isToday {
            parts.append(localization.string("accessibility.today", defaultValue: "今天"))
        }
        if let holidayKind = day.holidayKind {
            parts.append(CalendarDayPresentation.holidayText(for: holidayKind, localization: localization))
        }
        if !day.events.isEmpty {
            parts.append(
                localization.format(
                    "accessibility.eventCount",
                    defaultValue: "%d 个日程",
                    day.events.count
                )
            )
        }
        return parts.joined(
            separator: localization.string("list.separator.comma", defaultValue: "，")
        )
    }
}

private struct CalendarHolidayBadge: View {
    let kind: CalendarHolidayKind
    let localization: PluginLocalization
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Text(kind.badgeText(localization: localization))
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(theme.text.primary)
            .frame(width: 14, height: 14)
            .background(
                Circle()
                    .fill(
                        theme.interaction.selection(
                            kind == .holiday ? theme.dataSeries.tertiary : theme.dataSeries.secondary
                        )
                    )
            )
    }
}

private struct CalendarEventDots: View {
    private static let dotSize: CGFloat = 3
    private static let rowHeight: CGFloat = 5

    let events: [CalendarEventSummary]

    var body: some View {
        HStack(spacing: 2) {
            if events.isEmpty {
                Color.clear
                    .frame(width: Self.dotSize, height: Self.dotSize)
            } else {
                ForEach(events) { event in
                    Circle()
                        .fill(Color(calendarEventColor: event.color))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                }
            }
        }
        .frame(height: Self.rowHeight)
    }
}

private struct CalendarEventPopoverPresenter: NSViewRepresentable {
    let title: String
    let subtitle: String
    let events: [CalendarEventSummary]
    let localization: PluginLocalization
    let isPresented: Bool
    @Environment(\.pluginComponentTheme) private var theme

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
            localization: localization,
            theme: theme,
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
            localization: PluginLocalization,
            theme: PluginComponentTheme,
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
                events: events,
                localization: localization
            )
            .foregroundStyle(theme.text.primary)
            .background(theme.surfaces.card)
            .environment(\.pluginComponentTheme, theme)
            let hostingController = NSHostingController(rootView: content)
            CalendarAppearancePreference.stored().apply(to: hostingController.view)
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: 230, height: min(hostingController.view.fittingSize.height, 260))
            CalendarAppearancePreference.stored().apply(to: popover)

            if !popover.isShown {
                PluginPresentationSafety.prepareForWindowOrdering()
                popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
                CalendarAppearancePreference.stored().apply(to: popover)
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
    let localization: PluginLocalization
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }

            Rectangle()
                .fill(theme.surfaces.track)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(events.prefix(6))) { event in
                    CalendarEventRow(event: event)
                }

                if events.count > 6 {
                    Text(
                        localization.format(
                            "event.moreCount",
                            defaultValue: "还有 %d 个日程",
                            events.count - 6
                        )
                    )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.text.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
    }
}

private struct CalendarSelectedDayDetails: View {
    let day: CalendarDayModel
    let localization: PluginLocalization
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarDayPresentation.dateTitle(for: day))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(CalendarDayPresentation.dateSubtitle(for: day, localization: localization))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !day.events.isEmpty {
                Rectangle()
                    .fill(theme.surfaces.track)
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(day.visibleEvents) { event in
                        CalendarEventRow(event: event)
                    }
                }
            }
        }
        .padding(CalendarComponentLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PluginComponentCardBackground(
                cornerRadius: CalendarComponentLayout.cornerRadius
            )
        )
        .accessibilityElement(children: .contain)
    }
}

enum CalendarDayPresentation {
    static func dateTitle(for day: CalendarDayModel) -> String {
        let formatter = DateFormatter()
        formatter.locale = PluginRuntimeLocalization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day.date)
    }

    static func dateSubtitle(
        for day: CalendarDayModel,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        var parts: [String] = []
        if !day.lunarDateText.isEmpty {
            parts.append(day.lunarDateText)
            if !day.lunarText.isEmpty && !day.lunarDateText.contains(day.lunarText) {
                parts.append(day.lunarText)
            }
        } else if !day.lunarText.isEmpty {
            parts.append(day.lunarText)
        }
        if let holidayKind = day.holidayKind {
            parts.append(holidayText(for: holidayKind, localization: localization))
        } else if day.isWeekend {
            parts.append(localization.string("day.weekend", defaultValue: "周末"))
        }
        if day.events.count > CalendarDayModel.maximumVisibleEvents {
            parts.append(
                localization.format(
                    "event.moreCount",
                    defaultValue: "还有 %d 个日程",
                    day.events.count - CalendarDayModel.maximumVisibleEvents
                )
            )
        }
        return parts.joined(separator: localization.string("list.separator.dot", defaultValue: " · "))
    }

    static func holidayText(
        for holidayKind: CalendarHolidayKind,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        switch holidayKind {
        case .holiday:
            return localization.string("day.holiday", defaultValue: "休息日")
        case .workday:
            return localization.string("day.workday", defaultValue: "调休工作日")
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEventSummary
    @Environment(\.pluginComponentTheme) private var theme

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
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
        }
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
