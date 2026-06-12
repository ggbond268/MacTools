import AppKit
import Charts
import SwiftUI
import MacToolsPluginKit

private struct ActivityBarPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(
            roundedRect: rect,
            cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
            style: .continuous
        )
    }
}

private enum ActivityBarComponentLayout {
    static let cardCornerRadius = PluginComponentPanelLayoutMetrics.cardCornerRadius
}

private enum ActivityBarTrendMode: String, CaseIterable {
    case codingTools = "Coding Tools"
    case input = "Input"

    func label(localization: PluginLocalization) -> String {
        switch self {
        case .codingTools:
            localization.string("component.trendMode.codingTools", defaultValue: "Coding Tools")
        case .input:
            localization.string("component.trendMode.input", defaultValue: "Input")
        }
    }
}

private enum ActivityBarChartRange: String, CaseIterable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case fourteenDays = "14d"
    case thirtyDays = "30d"

    var dayCount: Int {
        switch self {
        case .oneDay:
            return 1
        case .sevenDays:
            return 7
        case .fourteenDays:
            return 14
        case .thirtyDays:
            return 30
        }
    }

    var label: String { rawValue }
}

private enum ActivityBarFunFact {
    static let secondsPerClick = 0.50
    static let keysPerPage = 550

    static func forDay(_ stats: ActivityBarDailyStats, localization: PluginLocalization) -> String? {
        var facts: [String] = []

        if stats.keystrokes > 0 {
            let pages = Double(stats.keystrokes) / Double(keysPerPage)
            if pages >= 1 {
                let formatted = ActivityBarFormatting.decimal(stats.keystrokes)
                let fullPages = Int(pages.rounded())
                facts.append(
                    localization.format(
                        "component.funFact.typedPages",
                        defaultValue: "You typed %@ keys today. That's about writing %d full pages.",
                        formatted,
                        fullPages
                    )
                )
            }
        }

        if stats.pointerClicks > 0 {
            let clickMins = (Double(stats.pointerClicks) * secondsPerClick) / 60
            if clickMins >= 1 {
                let formatted = ActivityBarFormatting.decimal(stats.pointerClicks)
                let minutes = Int(clickMins.rounded())
                facts.append(
                    localization.format(
                        "component.funFact.clickMinutes",
                        defaultValue: "You clicked %@ times. That's like tapping your desk for about %d minutes.",
                        formatted,
                        minutes
                    )
                )
            }
        }

        guard !facts.isEmpty else {
            return nil
        }

        let hash = stats.date.utf8.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1) }
        return facts[abs(hash) % facts.count]
    }
}

struct ActivityBarComponentView: View {
    private static let claudeColor = Color(red: 0xCB / 255.0, green: 0x64 / 255.0, blue: 0x41 / 255.0)
    private static let cursorColor = Color.black
    private static let codexColor = Color(red: 0x10 / 255.0, green: 0xA3 / 255.0, blue: 0x7F / 255.0)
    private static let visibleCodingTools: [ActivityBarCodingTool] = [.claudeCode, .codex]

    @ObservedObject var controller: ActivityBarController
    let localization: PluginLocalization
    let dismiss: () -> Void

    @State private var hoveredDate: String?
    @State private var hoveredScreenTimeDate: String?
    @State private var expandedAppName: String?
    @State private var selectedDateOffset = 0
    @State private var trendMode: ActivityBarTrendMode = .input
    @AppStorage("activity-bar.stats-expanded") private var statsExpanded = true
    @AppStorage("activity-bar.chart-range") private var chartRange = ActivityBarChartRange.sevenDays

    init(
        controller: ActivityBarController,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        dismiss: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.localization = localization
        self.dismiss = dismiss
    }

    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: selectedDateOffset, to: Date()) ?? Date()
    }

    private var selectedDateKey: String {
        dateKey(for: selectedDate)
    }

    private var selectedInputStats: ActivityBarDailyStats {
        controller.inputStats.stats(for: selectedDateKey)
    }

    private var selectedCodingStats: ActivityBarCodingDailyStats {
        controller.codingStats.stats(for: selectedDateKey)
    }

    private var isViewingToday: Bool {
        selectedDateOffset == 0
    }

    private var canGoBack: Bool {
        let keys = Set(controller.inputStats.sortedDateKeys + controller.codingStats.sortedDateKeys)
        guard let earliest = keys.sorted().first else {
            return false
        }

        return selectedDateKey > earliest
    }

    private var hasCodingToolsData: Bool {
        controller.codingStats.days.values.contains { day in
            hasCodingStats(visibleCodingAggregateStats(in: day))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            todayStats

            if showsAISection {
                divider
                aiSection
            }

            divider
            topAppsSection

            divider
            statsDisclosure
            if statsExpanded {
                if trendMode == .codingTools {
                    codingToolsChart
                } else {
                    weeklyChart
                    divider
                    screenTimeSection
                }
            }

            divider
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: ActivityBarPanelShape())
        .overlay {
            ActivityBarPanelShape()
                .stroke(Color.black.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.2), value: statsExpanded)
        .animation(.easeInOut(duration: 0.2), value: chartRange)
        .animation(.easeInOut(duration: 0.2), value: trendMode)
        .animation(.easeInOut(duration: 0.15), value: selectedDateOffset)
        .onAppear {
            controller.refresh()
            trendMode = hasCodingToolsData ? .codingTools : .input
        }
    }

    private var headerBar: some View {
        HStack {
                Text(localization.string("component.title", defaultValue: "Activity Bar"))
                .font(.title3.bold())
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedDateOffset -= 1
                        expandedAppName = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(canGoBack ? 0.55 : 0.2))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack)

                Text(displayDateString)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.55))
                    .lineLimit(1)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedDateOffset += 1
                        expandedAppName = nil
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary.opacity(isViewingToday ? 0.2 : 0.55))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isViewingToday)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var todayStats: some View {
        let day = selectedInputStats

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                statCell(
                    icon: "keyboard",
                    value: ActivityBarFormatting.decimal(day.keystrokes),
                    label: localization.string("component.metric.keystrokes", defaultValue: "Keystrokes")
                )
                statCell(
                    icon: "cursorarrow.click.2",
                    value: ActivityBarFormatting.decimal(day.pointerClicks),
                    label: localization.string("component.metric.clicks", defaultValue: "Clicks")
                )
            }

            HStack(spacing: 10) {
                statCell(
                    icon: "scroll",
                    value: ActivityBarFormatting.decimal(day.scrollEvents),
                    label: localization.string("component.metric.scrolls", defaultValue: "Scrolls")
                )
                statCell(
                    icon: "macwindow.on.rectangle",
                    value: ActivityBarFormatting.duration(day.screenTimeSeconds),
                    label: localization.string("component.metric.screenTime", defaultValue: "Screen Time")
                )
            }

            if let fact = inputInsightText {
                Text(fact)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        .blue.opacity(0.08),
                        in: RoundedRectangle(
                            cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statCell(icon: String, value: String, label: String, tint: Color = .blue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .primary.opacity(0.04),
            in: RoundedRectangle(
                cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                style: .continuous
            )
        )
    }

    private var inputInsightText: String? {
        if let fact = ActivityBarFunFact.forDay(selectedInputStats, localization: localization) {
            return fact
        }

        if isViewingToday, !controller.isTrackingEnabled {
            return localization.string(
                "component.inputInsight.enableTracking",
                defaultValue: "Grant Input Monitoring and turn this on to start collecting local stats."
            )
        }

        return nil
    }

    private var showsAISection: Bool {
        !codingToolRows(for: selectedCodingStats).isEmpty
            || (isViewingToday && controller.codingStats.activeSessionCount > 0)
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localization.string("component.ai.title", defaultValue: "Time AI Worked for You"))
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.bottom, 2)

            let rows = codingToolRows(for: selectedCodingStats)
            if rows.isEmpty {
                codingToolRow(
                    row: CodingToolDisplayRow(
                        id: "active-ai",
                        name: "Claude / Codex",
                        duration: 0,
                        detail: localization.format(
                            "component.ai.activeSessions",
                            defaultValue: "%d active",
                            controller.codingStats.activeSessionCount
                        ),
                        tint: Self.codexColor,
                        systemImage: "terminal",
                        iconSize: 13
                    )
                )
            } else {
                ForEach(rows) { row in
                    codingToolRow(row: row)
                }
            }

            if isViewingToday {
                aiWeeklyComparison
            }
        }
        .padding(.vertical, 8)
    }

    private func codingToolRow(row: CodingToolDisplayRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.systemImage)
                .font(.system(size: row.iconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(row.tint, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.body)
                    .lineLimit(1)

                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Spacer(minLength: 8)

            Text(ActivityBarFormatting.duration(row.duration))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            .primary.opacity(0.04),
            in: RoundedRectangle(
                cornerRadius: ActivityBarComponentLayout.cardCornerRadius,
                style: .continuous
            )
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var aiWeeklyComparison: some View {
        let avg = aiDailyAvgLastWeek
        if avg > 0 {
            let today = visibleCodingAggregateStats(in: controller.codingStats.today).durationSeconds
            let ratio = today / avg
            let aboveAvg = ratio >= 1
            let pct = Int(((ratio - 1) * 100).rounded())

            HStack(spacing: 6) {
                Image(systemName: aboveAvg ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(aboveAvg ? .green : .primary.opacity(0.45))

                if pct == 0 {
                    Text(
                        localization.format(
                            "component.ai.dailyAverage.same",
                            defaultValue: "On par with your daily avg (%@)",
                            shortDuration(avg)
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.55))
                } else {
                    let comparison = aboveAvg
                        ? localization.format(
                            "component.ai.dailyAverage.above",
                            defaultValue: "%d%% above your daily avg (%@)",
                            abs(pct),
                            shortDuration(avg)
                        )
                        : localization.format(
                            "component.ai.dailyAverage.below",
                            defaultValue: "%d%% below your daily avg (%@)",
                            abs(pct),
                            shortDuration(avg)
                        )
                    Text(comparison)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
        }
    }

    private var aiDailyAvgLastWeek: TimeInterval {
        let today = dateKey(for: Date())
        let days = controller.codingStats
            .recentDays(count: 8)
            .filter { $0.date != today && visibleCodingAggregateStats(in: $0).durationSeconds > 0 }

        guard !days.isEmpty else {
            return 0
        }

        return days
            .map { visibleCodingAggregateStats(in: $0).durationSeconds }
            .reduce(0, +) / Double(days.count)
    }

    private var topAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localization.string("component.topApps.title", defaultValue: "Top Apps by Screen Time"))
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            let apps = Array(selectedInputStats.topApps.prefix(5))
            if apps.isEmpty {
                Text(
                    controller.isTrackingEnabled
                        ? localization.string("component.topApps.empty", defaultValue: "No activity yet")
                        : localization.string("component.topApps.enableTracking", defaultValue: "Turn on tracking to rank your apps")
                )
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.55))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            } else {
                let maxTime = apps.first?.stats.screenTimeSeconds ?? 1
                ForEach(apps, id: \.name) { app in
                    appRow(name: app.name, stats: app.stats, maxScreenTime: maxTime)
                }
                .onAppear {
                    if expandedAppName == nil {
                        expandedAppName = apps.first?.name
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func appRow(name: String, stats: ActivityBarAppStats, maxScreenTime: Double) -> some View {
        let isExpanded = expandedAppName == name

        return VStack(spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedAppName = isExpanded ? nil : name
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.55))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(name)
                        .font(.body)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(ActivityBarFormatting.duration(stats.screenTimeSeconds))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                let ratio = CGFloat(stats.screenTimeSeconds) / CGFloat(Swift.max(maxScreenTime, 1))
                RoundedRectangle(cornerRadius: 2)
                    .fill(.blue.opacity(0.25))
                    .frame(width: geo.size.width * ratio, height: 3)
            }
            .frame(height: 3)

            if isExpanded {
                HStack(spacing: 16) {
                    appDetailItem(icon: "keyboard", value: ActivityBarFormatting.decimal(stats.keystrokes))
                    appDetailItem(icon: "cursorarrow.click.2", value: ActivityBarFormatting.decimal(stats.pointerClicks))
                    appDetailItem(icon: "scroll", value: ActivityBarFormatting.decimal(stats.scrollEvents))
                }
                .padding(.top, 4)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func appDetailItem(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.primary.opacity(0.55))

            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary.opacity(0.55))
                .lineLimit(1)
        }
    }

    private var statsDisclosure: some View {
        HStack {
            Button {
                statsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(localization.string("component.trends.title", defaultValue: "Trends"))
                        .font(.headline)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.55))
                        .rotationEffect(.degrees(statsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if statsExpanded {
                Spacer(minLength: 8)

                ForEach(ActivityBarTrendMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            trendMode = mode
                            hoveredDate = nil
                        }
                    } label: {
                        Text(mode.label(localization: localization))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary.opacity(trendMode == mode ? 1 : 0.35))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var codingToolsChart: some View {
        let days = controller.codingStats.recentDays(count: chartRange.dayCount, endingAt: selectedDate)
        let compactMode = chartRange.dayCount > 7
        let dateLabels = days.map { chartLabel($0.date) }
        let hasData = days.contains { hasCodingStats(visibleCodingAggregateStats(in: $0)) }
        let maxMinutes = days
            .map { day in
                Swift.max(
                    toolStats(.claudeCode, in: day).durationSeconds / 60,
                    toolStats(.codex, in: day).durationSeconds / 60
                )
            }
            .max() ?? 0
        let yUpperBound = Swift.max(maxMinutes * 1.15, 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                rangePickerBar
                Spacer(minLength: 8)
                legendDot(color: Self.claudeColor, label: "Claude")
                legendDot(color: Self.codexColor, label: "Codex")
            }
            .padding(.horizontal, 6)

            ZStack {
                Chart {
                    // `hasData ? days : []` keeps the content a plain ForEach (no
                    // `_ConditionalContent`, whose ChartContent conformance is macOS 27-only);
                    // an empty range draws nothing, exactly as the old `if hasData` did.
                    ForEach(hasData ? days : []) { day in
                        let d = chartLabel(day.date)
                        let isHovered = hoveredDate == d
                        let claudeMins = toolStats(.claudeCode, in: day).durationSeconds / 60
                        let codexMins = toolStats(.codex, in: day).durationSeconds / 60

                        LineMark(x: .value("Date", d), y: .value("Minutes", claudeMins), series: .value("Tool", "Claude"))
                            .foregroundStyle(by: .value("Tool", "Claude"))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Date", d), y: .value("Minutes", codexMins), series: .value("Tool", "Codex"))
                            .foregroundStyle(by: .value("Tool", "Codex"))
                            .interpolationMethod(.catmullRom)

                        // Unconditional marks; opacity/symbol size carry the hover state (the old
                        // if/else-if produced _ConditionalContent). The annotation body is a plain
                        // View, so its `if isHovered` is fine.
                        RuleMark(x: .value("Date", d))
                            .foregroundStyle(.gray.opacity(isHovered ? 0.3 : 0))
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                if isHovered {
                                    VStack(spacing: 2) {
                                        Text(shortDate(day.date))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.primary.opacity(0.55))
                                        HStack(spacing: 6) {
                                            Text(shortDuration(claudeMins * 60)).foregroundStyle(Self.claudeColor)
                                            Text(shortDuration(codexMins * 60)).foregroundStyle(Self.codexColor)
                                        }
                                        .font(.system(size: 10).bold().monospacedDigit())
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                    .offset(y: 30)
                                }
                            }

                        chartPoint(x: d, y: claudeMins, color: Self.claudeColor, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                        chartPoint(x: d, y: codexMins, color: Self.codexColor, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                    }
                }
                .chartForegroundStyleScale([
                    "Claude": Self.claudeColor,
                    "Codex": Self.codexColor,
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...yUpperBound)
                .chartYAxis {
                    if hasData {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let minutes = value.as(Double.self) {
                                    Text(talkAxisLabel(minutes))
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let label = value.as(String.self), !compactMode || shouldShowXLabel(label, in: dateLabels) {
                                Text(label)
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    if hasData {
                        chartHoverOverlay(proxy: proxy, labels: dateLabels, hoveredLabel: $hoveredDate)
                    }
                }

                if !hasData {
                    emptyChartMessage(localization.string("component.chart.emptyCoding", defaultValue: "No coding activity"))
                }
            }
            .frame(height: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var weeklyChart: some View {
        let days = controller.inputStats.recentDays(count: chartRange.dayCount, endingAt: selectedDate)
        let compactMode = chartRange.dayCount > 7
        let dateLabels = days.map { chartLabel($0.date) }
        let hasData = days.contains { $0.totalInputs > 0 }
        let maxInputCount = days
            .map { day in
                Swift.max(day.keystrokes, Swift.max(day.pointerClicks, day.scrollEvents))
            }
            .max() ?? 0
        let yUpperBound = Swift.max(Double(maxInputCount) * 1.15, 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                rangePickerBar
                Spacer(minLength: 8)
                legendDot(color: .blue, label: localization.string("component.legend.keys", defaultValue: "Keys"))
                legendDot(color: .orange, label: localization.string("component.legend.clicks", defaultValue: "Clicks"))
                legendDot(color: .green, label: localization.string("component.legend.scrolls", defaultValue: "Scrolls"))
            }
            .padding(.horizontal, 6)

            ZStack {
                Chart {
                    // See codingToolsChart: `hasData ? days : []` avoids _ConditionalContent.
                    ForEach(hasData ? days : []) { day in
                        let d = chartLabel(day.date)
                        let isHovered = hoveredDate == d

                        LineMark(x: .value("Date", d), y: .value("Count", day.keystrokes), series: .value("Metric", "Keystrokes"))
                            .foregroundStyle(by: .value("Metric", "Keystrokes"))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Date", d), y: .value("Count", day.pointerClicks), series: .value("Metric", "Clicks"))
                            .foregroundStyle(by: .value("Metric", "Clicks"))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Date", d), y: .value("Count", day.scrollEvents), series: .value("Metric", "Scrolls"))
                            .foregroundStyle(by: .value("Metric", "Scrolls"))
                            .interpolationMethod(.catmullRom)

                        RuleMark(x: .value("Date", d))
                            .foregroundStyle(.gray.opacity(isHovered ? 0.3 : 0))
                            .lineStyle(StrokeStyle(dash: [4, 4]))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                if isHovered {
                                    VStack(spacing: 2) {
                                        Text(shortDate(day.date))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.primary.opacity(0.55))
                                        HStack(spacing: 6) {
                                            Text("\(day.keystrokes)").foregroundStyle(.blue)
                                            Text("\(day.pointerClicks)").foregroundStyle(.orange)
                                            Text("\(day.scrollEvents)").foregroundStyle(.green)
                                        }
                                        .font(.system(size: 10).bold().monospacedDigit())
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                    .offset(y: 30)
                                }
                            }

                        chartPoint(x: d, y: Double(day.keystrokes), color: .blue, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                        chartPoint(x: d, y: Double(day.pointerClicks), color: .orange, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                        chartPoint(x: d, y: Double(day.scrollEvents), color: .green, size: hoverPointSize(isHovered: isHovered, compactMode: compactMode))
                    }
                }
                .chartForegroundStyleScale([
                    "Keystrokes": Color.blue,
                    "Clicks": Color.orange,
                    "Scrolls": Color.green,
                ])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...yUpperBound)
                .chartYAxis {
                    if hasData {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let count = value.as(Double.self) {
                                    Text(ActivityBarFormatting.count(Int(count)))
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let label = value.as(String.self), !compactMode || shouldShowXLabel(label, in: dateLabels) {
                                Text(label)
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    if hasData {
                        chartHoverOverlay(proxy: proxy, labels: dateLabels, hoveredLabel: $hoveredDate)
                    }
                }

                if !hasData {
                    emptyChartMessage(localization.string("component.chart.emptyInput", defaultValue: "No input activity"))
                }
            }
            .frame(height: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var screenTimeSection: some View {
        let days = controller.inputStats.recentDays(count: chartRange.dayCount, endingAt: selectedDate)
        let compactMode = chartRange.dayCount > 7
        let labels = days.map { chartLabel($0.date) }

        return VStack(alignment: .leading, spacing: 6) {
            Text(localization.string("component.screenTime.title", defaultValue: "Screen Time"))
                .font(.headline)

            Chart {
                ForEach(days) { day in
                    let d = chartLabel(day.date)
                    let isHovered = hoveredScreenTimeDate == d
                    BarMark(
                        x: .value("Date", d),
                        y: .value("Duration", day.screenTimeSeconds / 60)
                    )
                    .foregroundStyle(isHovered ? .blue.opacity(0.7) : .blue.opacity(0.4))
                    .cornerRadius(2)
                    .annotation(position: .top, spacing: 2) {
                        if isHovered, day.screenTimeSeconds > 0 {
                            Text(shortDuration(day.screenTimeSeconds))
                                .font(.system(size: 9).bold().monospacedDigit())
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) {
                            Text(talkAxisLabel(minutes))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let label = value.as(String.self), !compactMode || shouldShowXLabel(label, in: labels) {
                            Text(label)
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                chartHoverOverlay(proxy: proxy, labels: labels, hoveredLabel: $hoveredScreenTimeDate)
            }
            .frame(height: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var rangePickerBar: some View {
        HStack(spacing: 0) {
            ForEach(ActivityBarChartRange.allCases, id: \.self) { range in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        chartRange = range
                        hoveredDate = nil
                        hoveredScreenTimeDate = nil
                    }
                } label: {
                    Text(range.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(chartRange == range ? .white : .primary.opacity(0.55))
                        .background(
                            chartRange == range ? Color.blue : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.55))
                .lineLimit(1)
        }
    }

    private func emptyChartMessage(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func chartPoint(x: String, y: Double, color: Color, size: CGFloat) -> some ChartContent {
        PointMark(x: .value("Date", x), y: .value("Value", y))
            .foregroundStyle(color)
            .symbolSize(size)
    }

    /// Hover-driven point size, kept unconditional (0 hides the mark on compact
    /// non-hovered days) so the Chart body has no `_ConditionalContent` — whose
    /// `ChartContent` conformance is macOS 27-only and fails the 27-SDK build at
    /// a 14.0 deployment target.
    private func hoverPointSize(isHovered: Bool, compactMode: Bool) -> CGFloat {
        if isHovered { return 30 }
        return compactMode ? 0 : 12
    }

    private func chartHoverOverlay(proxy: ChartProxy, labels: [String], hoveredLabel: Binding<String?>) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else {
                            return
                        }

                        let frame = geo[plotFrame]
                        let x = location.x - frame.origin.x
                        var closest: String?
                        var closestDist: CGFloat = .infinity

                        for label in labels {
                            if let position = proxy.position(forX: label) {
                                let distance = abs(position - x)
                                if distance < closestDist {
                                    closestDist = distance
                                    closest = label
                                }
                            }
                        }

                        hoveredLabel.wrappedValue = closest
                    case .ended:
                        hoveredLabel.wrappedValue = nil
                    }
                }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            Button {
                controller.installHooks()
            } label: {
                Text(localization.string("component.footer.hooks", defaultValue: "Hooks"))
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.55))
            }
            .buttonStyle(.plain)

            Button {
                controller.openInputMonitoringSettings()
            } label: {
                Text(localization.string("component.footer.permissions", defaultValue: "Permissions"))
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.55))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: dismiss) {
                Text(localization.string("component.footer.close", defaultValue: "Close"))
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var divider: some View {
        Divider()
            .padding(.horizontal, 12)
    }

    private func codingToolRows(for day: ActivityBarCodingDailyStats) -> [CodingToolDisplayRow] {
        let knownRows = Self.visibleCodingTools.compactMap { tool -> CodingToolDisplayRow? in
            let stats = toolStats(tool, in: day)
            guard hasCodingStats(stats) else {
                return nil
            }

            return displayRow(for: tool, stats: stats)
        }

        if !knownRows.isEmpty {
            return knownRows
        }

        let aggregateStats = ActivityBarProjectStats(
            durationSeconds: day.durationSeconds,
            wordCount: day.wordCount,
            toolCallCount: day.toolCallCount
        )
        guard hasCodingStats(aggregateStats) else {
            return []
        }

        return [
            CodingToolDisplayRow(
                id: "ai-tools",
                name: "Claude / Codex",
                duration: aggregateStats.durationSeconds,
                detail: codingDetailText(for: aggregateStats),
                tint: Self.codexColor,
                systemImage: "terminal",
                iconSize: 13
            )
        ]
    }

    private func displayRow(for tool: ActivityBarCodingTool, stats: ActivityBarProjectStats) -> CodingToolDisplayRow {
        switch tool {
        case .claudeCode:
            return CodingToolDisplayRow(
                id: tool.rawValue,
                name: tool.rawValue,
                duration: stats.durationSeconds,
                detail: codingDetailText(for: stats),
                tint: Self.claudeColor,
                systemImage: "sparkles",
                iconSize: 12
            )
        case .cursor:
            return CodingToolDisplayRow(
                id: tool.rawValue,
                name: tool.rawValue,
                duration: stats.durationSeconds,
                detail: codingDetailText(for: stats),
                tint: Self.cursorColor,
                systemImage: "cube.fill",
                iconSize: 13
            )
        case .codex:
            return CodingToolDisplayRow(
                id: tool.rawValue,
                name: tool.rawValue,
                duration: stats.durationSeconds,
                detail: codingDetailText(for: stats),
                tint: Self.codexColor,
                systemImage: "terminal",
                iconSize: 13
            )
        }
    }

    private func toolStats(_ tool: ActivityBarCodingTool, in day: ActivityBarCodingDailyStats) -> ActivityBarProjectStats {
        if let stats = day.perTool[tool.rawValue] {
            return stats
        }

        if day.perTool.isEmpty, tool == .claudeCode {
            return ActivityBarProjectStats(
                durationSeconds: day.durationSeconds,
                wordCount: day.wordCount,
                toolCallCount: day.toolCallCount
            )
        }

        return ActivityBarProjectStats()
    }

    private func visibleCodingAggregateStats(in day: ActivityBarCodingDailyStats) -> ActivityBarProjectStats {
        let visibleToolStats = Self.visibleCodingTools.map { toolStats($0, in: day) }
        if visibleToolStats.contains(where: { hasCodingStats($0) }) {
            return visibleToolStats.reduce(ActivityBarProjectStats()) { result, stats in
                ActivityBarProjectStats(
                    durationSeconds: result.durationSeconds + stats.durationSeconds,
                    wordCount: result.wordCount + stats.wordCount,
                    toolCallCount: result.toolCallCount + stats.toolCallCount
                )
            }
        }

        guard day.perTool.isEmpty else {
            return ActivityBarProjectStats()
        }

        return ActivityBarProjectStats(
            durationSeconds: day.durationSeconds,
            wordCount: day.wordCount,
            toolCallCount: day.toolCallCount
        )
    }

    private func hasCodingStats(_ stats: ActivityBarProjectStats) -> Bool {
        stats.durationSeconds > 0 || stats.wordCount > 0 || stats.toolCallCount > 0
    }

    private func codingDetailText(for stats: ActivityBarProjectStats) -> String {
        localization.format(
            "component.ai.detail",
            defaultValue: "%@ words · %@ tools",
            ActivityBarFormatting.decimal(stats.wordCount),
            ActivityBarFormatting.decimal(stats.toolCallCount)
        )
    }

    private var displayDateString: String {
        if isViewingToday {
            return localization.string("component.date.today", defaultValue: "Today")
        }

        if selectedDateOffset == -1 {
            return localization.string("component.date.yesterday", defaultValue: "Yesterday")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: selectedDate)
    }

    private func shortDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return dateString
        }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private func chartLabel(_ dateString: String) -> String {
        if chartRange.dayCount <= 7 {
            return shortDate(dateString)
        }

        let parts = dateString.split(separator: "-")
        guard parts.count == 3 else {
            return dateString
        }

        let day = Int(parts[2]) ?? 0
        if day == 1 {
            return shortDate(dateString)
        }

        return "\(day)"
    }

    private func shouldShowXLabel(_ label: String, in allLabels: [String]) -> Bool {
        guard let index = allLabels.firstIndex(of: label) else {
            return false
        }

        let step = chartRange.dayCount <= 14 ? 2 : 5
        return index % step == 0 || index == allLabels.count - 1
    }

    private func talkAxisLabel(_ minutes: Double) -> String {
        if minutes >= 60 {
            return "\(Int(minutes / 60))h"
        }

        return "\(Int(minutes))m"
    }

    private func shortDuration(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }

        return "\(secs)s"
    }

    private func dateKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private struct CodingToolDisplayRow: Identifiable {
        let id: String
        let name: String
        let duration: TimeInterval
        let detail: String?
        let tint: Color
        let systemImage: String
        let iconSize: CGFloat
    }
}
