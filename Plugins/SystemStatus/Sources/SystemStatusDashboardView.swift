import Foundation
import AppKit
import SwiftUI
import MacToolsPluginKit

private enum SystemStatusHUDLayout {
    static let outerPadding: CGFloat = 0
    static let sectionSpacing: CGFloat = SystemStatusComponentLayout.dashboardSectionSpacing
    static let metricSpacing: CGFloat = SystemStatusComponentLayout.cardSpacing
    static let metricTileHeight: CGFloat = SystemStatusComponentLayout.dashboardMetricTileHeight
    static let metricInternalSpacing: CGFloat = 2
    static let metricTitleHeight: CGFloat = 18
    static let metricValueHeight: CGFloat = 22
    static let metricVisualHeight: CGFloat = 18
    static let metricFootnoteHeight: CGFloat = 14
    static let metricCardPadding: CGFloat = 6
    static let processRowHeight = SystemStatusComponentLayout.processRowHeight
    static let processListSpacing = SystemStatusComponentLayout.processRowSpacing
    static let chartDisplayInterval: TimeInterval = 30 * 60
    static let chartSampleLimit = 120
}

struct SystemStatusHUDChartSample: Equatable, Sendable {
    let timestamp: TimeInterval
    let value: Double
    var isAvailable = true
    var startsNewSegment = false
    var pressure: SystemStatusMemoryPressure? = nil
}

struct SystemStatusHUDRateChartSample: Equatable, Sendable {
    let timestamp: TimeInterval
    let firstValue: Double
    let secondValue: Double
    var isAvailable = true
    var startsNewSegment = false
}

enum SystemStatusHUDSingleLineChart {
    static func downsample(
        _ samples: [SystemStatusHUDChartSample],
        limit: Int
    ) -> [SystemStatusHUDChartSample] {
        guard limit > 0 else {
            return []
        }
        guard samples.count > limit else {
            return samples
        }
        guard limit > 1 else {
            return samples.last.map { [$0] } ?? []
        }

        let stride = Double(samples.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            if index == 0 { return samples[0] }
            if index == limit - 1 { return samples[samples.count - 1] }
            let start = 1 + (index - 1) * (samples.count - 2) / (limit - 2)
            let end = 1 + index * (samples.count - 2) / (limit - 2)
            if let gap = samples[start..<end].first(where: { !$0.isAvailable || $0.startsNewSegment }) { return gap }
            return samples[Int((Double(index) * stride).rounded())]
        }
    }
}

enum SystemStatusMetricDetailRange: String, CaseIterable, Hashable, Identifiable, Sendable {
    case thirtyMinutes
    case twoHours
    case twentyFourHours

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .twoHours: 2 * 60 * 60
        case .twentyFourHours: 24 * 60 * 60
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .thirtyMinutes:
            localization.string("chart.range30Minutes", defaultValue: "30 分钟")
        case .twoHours:
            localization.string("chart.range2Hours", defaultValue: "2 小时")
        case .twentyFourHours:
            localization.string("chart.range24Hours", defaultValue: "24 小时")
        }
    }
}

struct SystemStatusDashboardView: View {
    let snapshot: SystemStatusSnapshot
    let visibleKinds: [SystemStatusMetricKind]
    let processSort: SystemStatusProcessSort
    let processLimit: SystemStatusProcessLimit
    var configuration = SystemStatusConfiguration.default
    let onProcessSortChange: (SystemStatusProcessSort) -> Void
    let localization: PluginLocalization
    let onMetricDetail: (SystemStatusMetricKind) -> Void

    @Environment(\.pluginComponentTheme) private var theme

    private var metricColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: SystemStatusHUDLayout.metricSpacing),
            GridItem(.flexible(), spacing: SystemStatusHUDLayout.metricSpacing)
        ]
    }

    var body: some View {
        let rows = visibleRows
        let visibleHistory = chartHistory

        Group {
            if rows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: SystemStatusHUDLayout.sectionSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        rowView(row, history: visibleHistory)
                    }
                }
            }
        }
        .padding(SystemStatusHUDLayout.outerPadding)
        .frame(
            height: SystemStatusComponentLayout.contentHeight(for: visibleKinds, processLimit: processLimit),
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var visibleRows: [SystemStatusComponentRow] {
        SystemStatusComponentLayout.rows(for: visibleKinds)
    }

    @ViewBuilder
    private func rowView(
        _ row: SystemStatusComponentRow,
        history: [SystemStatusHistoryPoint]
    ) -> some View {
        switch row {
        case let .metrics(kinds):
            metricRow(kinds, history: history)
        case .topProcesses:
            topProcessesSection
        }
    }

    private func metricRow(
        _ kinds: [SystemStatusMetricKind],
        history: [SystemStatusHistoryPoint]
    ) -> some View {
        LazyVGrid(columns: metricColumns, spacing: SystemStatusHUDLayout.metricSpacing) {
            ForEach(kinds) { kind in
                Button {
                    onMetricDetail(kind)
                } label: {
                    metricTile(kind, history: history)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(
                    localization.format(
                        "component.metric.openDetailFormat",
                        defaultValue: "打开%@详情",
                        kind.title(localization: localization)
                    )
                )
            }
        }
        .frame(height: SystemStatusComponentLayout.dashboardMetricTileHeight, alignment: .top)
    }

    @ViewBuilder
    private func metricTile(_ kind: SystemStatusMetricKind, history: [SystemStatusHistoryPoint]) -> some View {
        switch kind {
        case .cpu:
            cpuTile(history: history)
        case .gpu:
            gpuTile(history: history)
        case .network:
            networkTile(history: history)
        case .disk:
            diskTile(history: history)
        case .memory:
            memoryTile(history: history)
        case .battery:
            batteryTile(history: history)
        case .topProcesses:
            EmptyView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.text.secondary)

            Text(localization.string("component.empty.title", defaultValue: "未选择显示内容"))
                .font(PluginTypography.detail.font.weight(.semibold))
                .foregroundStyle(theme.text.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: SystemStatusComponentLayout.emptyContentHeight)
        .background(PluginComponentCardBackground(cornerRadius: 10))
    }

    private func cpuTile(history: [SystemStatusHistoryPoint]) -> some View {
        scalarTile(.cpu, history: history, accent: theme.dataSeries.tertiary,
            chip: temperatureChip(snapshot.cpu.temperatureCelsius), footnote: cpuFootnote)
    }

    private func gpuTile(history: [SystemStatusHistoryPoint]) -> some View {
        scalarTile(.gpu, history: history, accent: theme.dataSeries.secondary,
            chip: temperatureChip(snapshot.gpu.temperatureCelsius), footnote: gpuFootnote)
    }

    private func memoryTile(history: [SystemStatusHistoryPoint]) -> some View {
        scalarTile(.memory, history: history, accent: theme.dataSeries.senary, chip: memoryChip, footnote: memoryFootnote)
    }

    @ViewBuilder
    private func scalarTile(
        _ kind: SystemStatusMetricKind, history: [SystemStatusHistoryPoint], accent: Color,
        chip: String?, footnote: String
    ) -> some View {
        let metric = configuration.chartMetric(for: kind)
        let value = metric.parts(metric.value(in: snapshot, kind: kind), localization: localization)
        let title = metric == .defaultMetric(for: kind)
            ? kind.title(localization: localization)
            : kind.title(localization: localization) + " · " + metric.title(localization: localization)
        if metric == .pressure {
            SystemStatusHUDMetricTile(
                title: title, glyph: kind.symbolName,
                accent: snapshot.memory.pressure?.color(theme: theme) ?? theme.text.secondary,
                value: value.value, unit: value.unit,
                chip: snapshot.memory.pressure?.title(localization: localization),
                footnote: footnote
            ) {
                SystemStatusHUDPressureChart(samples: SystemStatusMemoryPressureHistory.samples(history), localization: localization)
            }
        } else {
            let samples = SystemStatusMetricDetailChartData(
                history: history, kind: kind, range: .thirtyMinutes, chartMetric: metric
            ).singleSamples
            SystemStatusHUDValueTile(
                eyebrow: title, glyph: kind.symbolName, accent: accent, chartColor: accent,
                value: value.value, unit: value.unit, chip: chip, samples: samples,
                valueFormatter: { metric.format($0, localization: localization) }, rangeLabel: chartRangeLabel,
                chartStyle: metric == .usage && (kind == .cpu || kind == .gpu) ? .bars : .area,
                footnote: footnote
            )
        }
    }

    private func diskTile(history: [SystemStatusHistoryPoint]) -> some View {
        let rate = rateParts(totalDiskBytesPerSecond)
        let free = bytesParts(diskFreeBytes)
        let samples = diskRateHistory(history)
        return SystemStatusHUDDiskTile(
            title: SystemStatusMetricKind.disk.title(localization: localization),
            freeValue: free.value,
            freeUnit: diskAvailableUnit(free.unit),
            totalText: SystemStatusFormatter.bytes(snapshot.disk.totalBytes),
            readText: SystemStatusFormatter.speed(snapshot.disk.readBytesPerSecond),
            writeText: SystemStatusFormatter.speed(snapshot.disk.writeBytesPerSecond),
            samples: samples,
            readLabel: diskReadLabel,
            writeLabel: diskWriteLabel,
            rangeLabel: chartRangeLabel,
            readColor: theme.dataSeries.primary,
            writeColor: theme.dataSeries.quaternary
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            localization.format(
                "accessibility.diskFormat",
                defaultValue: "磁盘 %@%@，%@",
                rate.value,
                rate.unit,
                diskFootnote
            )
        )
    }

    private func networkTile(history: [SystemStatusHistoryPoint]) -> some View {
        let rate = rateParts(totalNetworkBytesPerSecond)
        let samples = networkRateHistory(history)
        return SystemStatusHUDMetricTile(
            title: SystemStatusMetricKind.network.title(localization: localization),
            glyph: "network",
            accent: theme.dataSeries.quinary,
            value: rate.value,
            unit: rate.unit,
            chip: networkChip,
            footnote: nil,
            footer: {
                SystemStatusHUDRateFooter(
                    firstLabel: "↓",
                    firstText: SystemStatusFormatter.speed(snapshot.network.downloadBytesPerSecond),
                    firstColor: theme.dataSeries.primary,
                    secondLabel: "↑",
                    secondText: SystemStatusFormatter.speed(snapshot.network.uploadBytesPerSecond),
                    secondColor: theme.dataSeries.secondary
                )
            }
        ) {
            SystemStatusHUDRateChart(
                samples: samples,
                firstColor: theme.dataSeries.primary,
                secondColor: theme.dataSeries.secondary,
                firstLabel: "↓",
                secondLabel: "↑",
                valueFormatter: { SystemStatusChartMetric.activity.format($0, localization: localization) },
                rangeLabel: chartRangeLabel
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            localization.format(
                "accessibility.networkFormat",
                defaultValue: "网络 %@%@，%@",
                rate.value,
                rate.unit,
                networkFootnote
            )
        )
    }

    private func batteryTile(history: [SystemStatusHistoryPoint]) -> some View {
        scalarTile(.battery, history: history, accent: batteryColor,
            chip: temperatureChip(snapshot.battery.temperatureCelsius), footnote: batteryFootnote)
    }

    private var topProcessesSection: some View {
        VStack(alignment: .leading, spacing: SystemStatusHUDLayout.metricInternalSpacing) {
            HStack(spacing: 8) {
                SystemStatusHUDEyebrow(
                    text: SystemStatusMetricKind.topProcesses.title(localization: localization),
                    glyph: "list.bullet",
                    color: theme.text.secondary
                )

                Spacer(minLength: 6)

                processSortButton(.cpu, title: "CPU", width: 46)
                processSortButton(
                    .memory,
                    title: SystemStatusMetricKind.memory.title(localization: localization),
                    width: 52
                )
            }
            .frame(height: SystemStatusHUDLayout.metricTitleHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            if snapshot.topProcesses.isEmpty {
                Text(localization.string("topProcesses.collecting", defaultValue: "采集中…"))
                    .font(PluginTypography.caption.font.monospacedDigit())
                    .foregroundStyle(theme.text.secondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SystemStatusComponentLayout.processListHeight(limit: processLimit),
                        alignment: .center
                    )
            } else {
                VStack(spacing: SystemStatusHUDLayout.processListSpacing) {
                    ForEach(sortedTopProcesses) { process in
                        SystemStatusHUDProcessRow(process: process, localization: localization)
                    }
                }
                .frame(
                    height: SystemStatusComponentLayout.processListHeight(limit: processLimit),
                    alignment: .topLeading
                )
            }
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(height: SystemStatusComponentLayout.processTileHeight(limit: processLimit), alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(PluginComponentCardBackground(cornerRadius: 10))
    }

    private var sortedTopProcesses: [SystemStatusTopProcess] {
        let sorted = snapshot.topProcesses.sorted {
            SystemStatusProcessAccounting.ordered($0, before: $1, by: processSort)
        }
        return Array(sorted.prefix(processLimit.rawValue))
    }

    private func processSortButton(
        _ sort: SystemStatusProcessSort,
        title: String,
        width: CGFloat
    ) -> some View {
        Button {
            onProcessSortChange(sort)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if processSort == sort {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                }
            }
            .font(PluginTypography.caption.font.weight(processSort == sort ? .semibold : .regular))
            .foregroundStyle(processSort == sort ? theme.text.primary : theme.text.secondary)
            .frame(width: width, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .help(localization.format(
            "topProcesses.sortHelpFormat",
            defaultValue: "按%@排序",
            title
        ))
    }

    private var diskFreeBytes: UInt64? {
        guard let totalBytes = snapshot.disk.totalBytes, let usedBytes = snapshot.disk.usedBytes else {
            return nil
        }

        return totalBytes >= usedBytes ? totalBytes - usedBytes : 0
    }

    private var totalNetworkBytesPerSecond: UInt64? {
        guard snapshot.network.downloadBytesPerSecond != nil || snapshot.network.uploadBytesPerSecond != nil else {
            return nil
        }

        return (snapshot.network.downloadBytesPerSecond ?? 0) + (snapshot.network.uploadBytesPerSecond ?? 0)
    }

    private var totalDiskBytesPerSecond: UInt64? {
        guard snapshot.disk.readBytesPerSecond != nil || snapshot.disk.writeBytesPerSecond != nil else {
            return nil
        }

        return (snapshot.disk.readBytesPerSecond ?? 0) + (snapshot.disk.writeBytesPerSecond ?? 0)
    }

    private var memoryChip: String {
        SystemStatusFormatter.bytes(snapshot.memory.totalBytes)
    }

    private var networkChip: String? {
        guard let name = snapshot.network.interfaceName, !name.isEmpty else {
            return nil
        }

        return name
    }

    private var cpuFootnote: String {
        let powerText = localization.format(
            "metric.powerFormat",
            defaultValue: "功率 %@",
            SystemStatusFormatter.power(snapshot.cpu.cpuPowerWatts)
        )
        guard let load = snapshot.cpu.loadAverage1Minute else {
            return localization.format(
                "cpu.footnote.loadUnavailableFormat",
                defaultValue: "负载 — · %@",
                powerText
            )
        }

        return localization.format(
            "cpu.footnote.loadFormat",
            defaultValue: "负载 %.2f · %@",
            load,
            powerText
        )
    }

    private var gpuFootnote: String {
        if let name = snapshot.gpu.name, !name.isEmpty {
            return name
        }

        return snapshot.gpu.isAvailable
            ? localization.string("gpu.footnote.graphicsLoad", defaultValue: "图形负载")
            : localization.string("metric.unavailable", defaultValue: "不可用")
    }

    private var memoryFootnote: String {
        localization.format(
            "memory.footnote.usedSwapFormat",
            defaultValue: "已用 %@ · 交换 %@",
            SystemStatusFormatter.bytes(snapshot.memory.usedBytes),
            SystemStatusFormatter.bytes(snapshot.memory.swapUsedBytes)
        )
    }

    private var networkFootnote: String {
        "↓ \(SystemStatusFormatter.speed(snapshot.network.downloadBytesPerSecond)) ↑ \(SystemStatusFormatter.speed(snapshot.network.uploadBytesPerSecond))"
    }

    private var chartRangeLabel: String {
        localization.string("chart.range30Minutes", defaultValue: "30 分钟")
    }

    private var diskReadLabel: String {
        localization.string("chart.disk.readCompact", defaultValue: "读")
    }

    private var diskWriteLabel: String {
        localization.string("chart.disk.writeCompact", defaultValue: "写")
    }

    private var diskFootnote: String {
        "\(diskReadLabel) \(SystemStatusFormatter.speed(snapshot.disk.readBytesPerSecond)) \(diskWriteLabel) \(SystemStatusFormatter.speed(snapshot.disk.writeBytesPerSecond))"
    }

    private var batteryFootnote: String {
        guard snapshot.battery.isAvailable else {
            return snapshot.battery.state.title(localization: localization)
        }

        var parts: [String] = []

        if let batteryPowerText {
            parts.append(batteryPowerText)
        }

        if let batteryHealthText {
            parts.append(batteryHealthText)
        }

        if let cycleCount = snapshot.battery.cycleCount {
            parts.append(
                localization.format(
                    "battery.cyclesFormat",
                    defaultValue: "%d 次循环",
                    cycleCount
                )
            )
        }

        return parts.isEmpty ? snapshot.battery.state.title(localization: localization) : parts.joined(separator: " · ")
    }

    private var batteryPowerText: String? {
        guard let batteryPowerWatts = snapshot.battery.batteryPowerWatts else {
            return nil
        }

        let absoluteWatts = abs(batteryPowerWatts)
        guard absoluteWatts >= 0.1 else {
            return nil
        }

        if batteryPowerWatts < 0 {
            return localization.format(
                "battery.chargePowerFormat",
                defaultValue: "充电 %@",
                SystemStatusFormatter.power(absoluteWatts)
            )
        }

        return localization.format(
            "battery.dischargePowerFormat",
            defaultValue: "放电 %@",
            SystemStatusFormatter.power(absoluteWatts)
        )
    }

    private var batteryHealthText: String? {
        guard let healthPercent = snapshot.battery.healthPercent else {
            return nil
        }

        return localization.format("battery.healthFormat", defaultValue: "健康度 %d%%", healthPercent)
    }

    private func diskAvailableUnit(_ unit: String) -> String {
        guard !unit.isEmpty else {
            return localization.string("disk.availableSuffix", defaultValue: "可用")
        }

        return localization.format("disk.availableUnitFormat", defaultValue: "%@可用", unit)
    }

    private var batteryColor: Color {
        guard snapshot.battery.isAvailable else {
            return theme.text.tertiary
        }

        if snapshot.battery.state == .charging || snapshot.battery.state == .charged || snapshot.battery.state == .acPower {
            return theme.status.success
        }

        let level = snapshot.battery.level ?? 0
        if level < 0.15 {
            return theme.status.critical
        }

        if level < 0.35 {
            return theme.status.warning
        }

        return theme.status.success
    }

    private func temperatureChip(_ temperature: Double?) -> String? {
        guard let temperature, temperature > 0 else {
            return nil
        }

        return SystemStatusFormatter.temperature(temperature)
    }

    private func rateParts(_ bytesPerSecond: UInt64?) -> (value: String, unit: String) {
        guard let bytesPerSecond else {
            return ("—", "")
        }

        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSecond)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let fractionDigits = unitIndex == 0 || value >= 100 ? 0 : 1
        return (format(value, fractionDigits: fractionDigits), units[unitIndex])
    }

    private func bytesParts(_ bytes: UInt64?) -> (value: String, unit: String) {
        guard let bytes else {
            return ("—", "")
        }

        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let fractionDigits = unitIndex == 0 || value >= 100 ? 0 : 1
        return (format(value, fractionDigits: fractionDigits), units[unitIndex])
    }

    private func networkRateHistory(_ history: [SystemStatusHistoryPoint]) -> [SystemStatusHUDRateChartSample] {
        SystemStatusMetricDetailChartData(history: history, kind: .network, range: .thirtyMinutes).rateSamples
    }

    private func diskRateHistory(_ history: [SystemStatusHistoryPoint]) -> [SystemStatusHUDRateChartSample] {
        SystemStatusMetricDetailChartData(history: history, kind: .disk, range: .thirtyMinutes).rateSamples
    }

    private var chartHistory: [SystemStatusHistoryPoint] {
        guard let latestTimestamp = snapshot.history.last?.timestamp else {
            return []
        }

        let cutoff = latestTimestamp - SystemStatusHUDLayout.chartDisplayInterval
        return snapshot.history.filter { point in
            point.timestamp >= cutoff && point.timestamp <= latestTimestamp
        }
    }

    private func format(_ value: Double, fractionDigits: Int) -> String {
        if fractionDigits == 0 {
            return String(Int(value.rounded()))
        }

        return String(format: "%.\(fractionDigits)f", value)
    }
}

private struct SystemStatusHUDEyebrow: View {
    let text: String
    let glyph: String
    let color: Color

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 11, height: 11)

            Text(text)
                .font(PluginTypography.caption.font.weight(.semibold))
                .foregroundStyle(theme.text.secondary)
                .lineLimit(1)
                .layoutPriority(0)
        }
    }
}

private struct SystemStatusHUDChip: View {
    let text: String

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Text(text)
            .font(PluginTypography.caption.font.weight(.medium).monospacedDigit())
            .foregroundStyle(theme.text.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 7)
            .frame(height: 18, alignment: .center)
            .background(
                Capsule(style: .continuous)
                    .fill(theme.surfaces.chip)
            )
            .help(text)
    }
}

private struct SystemStatusHUDValueTile: View {
    let eyebrow: String
    let glyph: String
    let accent: Color
    let chartColor: Color
    let value: String
    var unit: String = ""
    var chip: String? = nil
    let samples: [SystemStatusHUDChartSample]
    let valueFormatter: (Double) -> String
    let rangeLabel: String
    var chartStyle: SystemStatusHUDMiniChart.Style = .area
    var footnote: String? = nil

    var body: some View {
        SystemStatusHUDMetricTile(
            title: eyebrow,
            glyph: glyph,
            accent: accent,
            value: value,
            unit: unit,
            chip: chip,
            footnote: footnote
        ) {
            SystemStatusHUDMiniChart(
                samples: samples,
                color: chartColor,
                style: chartStyle,
                valueFormatter: valueFormatter,
                rangeLabel: rangeLabel
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(eyebrow) \(value)\(unit)")
    }
}

private struct SystemStatusHUDMetricTile<Visual: View, Footer: View>: View {
    let title: String
    let glyph: String
    let accent: Color
    let value: String
    let unit: String
    let chip: String?
    let footnote: String?
    @ViewBuilder let footer: Footer
    @ViewBuilder let visual: Visual

    @Environment(\.pluginComponentTheme) private var theme

    init(
        title: String,
        glyph: String,
        accent: Color,
        value: String,
        unit: String,
        chip: String?,
        footnote: String?,
        @ViewBuilder footer: () -> Footer,
        @ViewBuilder visual: () -> Visual
    ) {
        self.title = title
        self.glyph = glyph
        self.accent = accent
        self.value = value
        self.unit = unit
        self.chip = chip
        self.footnote = footnote
        self.footer = footer()
        self.visual = visual()
    }
}

private extension SystemStatusHUDMetricTile where Footer == EmptyView {
    init(
        title: String,
        glyph: String,
        accent: Color,
        value: String,
        unit: String,
        chip: String?,
        footnote: String?,
        @ViewBuilder visual: () -> Visual
    ) {
        self.init(
            title: title,
            glyph: glyph,
            accent: accent,
            value: value,
            unit: unit,
            chip: chip,
            footnote: footnote,
            footer: { EmptyView() },
            visual: visual
        )
    }
}

private extension SystemStatusHUDMetricTile {
    var body: some View {
        VStack(alignment: .leading, spacing: SystemStatusHUDLayout.metricInternalSpacing) {
            HStack(spacing: 4) {
                SystemStatusHUDEyebrow(text: title, glyph: glyph, color: accent)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                if let chip {
                    SystemStatusHUDChip(text: chip)
                }
            }
                .frame(height: SystemStatusHUDLayout.metricTitleHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                PluginMetricValue(value, unit: unit, unitColor: theme.text.secondary)
                    .foregroundStyle(theme.text.primary)

                Spacer(minLength: 0)
            }
            .frame(height: SystemStatusHUDLayout.metricValueHeight, alignment: .leading)

            visual
                .frame(height: SystemStatusHUDLayout.metricVisualHeight)
                .frame(maxWidth: .infinity)

            if Footer.self != EmptyView.self {
                footer
                    .frame(height: SystemStatusHUDLayout.metricFootnoteHeight, alignment: .leading)
            } else {
                Text(footnote ?? "")
                    .font(PluginTypography.caption.font.monospacedDigit())
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(footnote ?? "")
                    .frame(height: SystemStatusHUDLayout.metricFootnoteHeight, alignment: .leading)
            }
        }
        .padding(SystemStatusHUDLayout.metricCardPadding)
        .frame(height: SystemStatusHUDLayout.metricTileHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(PluginComponentCardBackground(cornerRadius: 10))
    }
}

private struct SystemStatusHUDDiskTile: View {
    let title: String
    let freeValue: String
    let freeUnit: String
    let totalText: String
    let readText: String
    let writeText: String
    let samples: [SystemStatusHUDRateChartSample]
    let readLabel: String
    let writeLabel: String
    let rangeLabel: String
    let readColor: Color
    let writeColor: Color

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        SystemStatusHUDMetricTile(
            title: title,
            glyph: "internaldrive",
            accent: readColor,
            value: freeValue,
            unit: freeUnit,
            chip: totalText,
            footnote: nil,
            footer: {
                SystemStatusHUDRateFooter(
                    firstLabel: readLabel,
                    firstText: readText,
                    firstColor: readColor,
                    secondLabel: writeLabel,
                    secondText: writeText,
                    secondColor: writeColor
                )
            }
        ) {
            SystemStatusHUDRateChart(
                samples: samples,
                firstColor: readColor,
                secondColor: writeColor,
                firstLabel: readLabel,
                secondLabel: writeLabel,
                valueFormatter: { SystemStatusFormatter.speed(UInt64(max($0, 0))) },
                rangeLabel: rangeLabel
            )
        }
    }
}

private struct SystemStatusHUDProcessRow: View {
    let process: SystemStatusTopProcess
    let localization: PluginLocalization
    @State private var cachedIcon: NSImage?
    @State private var cachedIconKey: String?
    @Environment(\.pluginComponentTheme) private var theme

    private var iconKey: String {
        "\(process.id)|\(process.command)"
    }

    var body: some View {
        Button(action: SystemStatusProcessActions.openActivityMonitor) {
            HStack(spacing: 8) {
            if let icon = cachedIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.surfaces.chip)
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.text.tertiary)
                }
                .frame(width: 15, height: 15)
            }

            Text(process.displayName)
                .font(PluginTypography.detail.font)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            HStack(spacing: 10) {
                processMetricText(SystemStatusFormatter.wholePercent(process.cpuPercent, fractionDigits: 1))
                    .frame(width: 46, alignment: .trailing)

                processMetricText(processMemoryText)
                    .frame(width: 52, alignment: .trailing)
            }
            .frame(alignment: .trailing)
            }
        }
        .buttonStyle(.plain)
        .frame(height: SystemStatusHUDLayout.processRowHeight)
        .contentShape(Rectangle())
        .help(processHelpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            localization.format(
                "accessibility.processFormat",
                defaultValue: "%@ CPU %@，内存 %@",
                process.displayName,
                SystemStatusFormatter.wholePercent(process.cpuPercent, fractionDigits: 1),
                processMemoryText
            )
        )
        .onAppear(perform: resolveIconIfNeeded)
        .onChange(of: iconKey) {
            resolveIconIfNeeded()
        }
    }

    private func processMetricText(_ text: String) -> some View {
        Text(text)
            .font(PluginTypography.caption.font.monospacedDigit())
            .foregroundStyle(theme.text.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func resolveIconIfNeeded() {
        guard cachedIconKey != iconKey else {
            return
        }

        cachedIconKey = iconKey
        cachedIcon = Self.processIcon(for: process)
    }

    private static func processIcon(for process: SystemStatusTopProcess) -> NSImage? {
        if let appPath = SystemStatusProcessAccounting.applicationPath(for: process.command) {
            return NSWorkspace.shared.icon(forFile: appPath)
        }
        return NSRunningApplication(processIdentifier: pid_t(process.pid))?.icon
    }

    private var processMemoryText: String {
        SystemStatusFormatter.bytes(process.memoryBytes)
    }

    private var processHelpText: String {
        let count = localization.format("topProcesses.memberCount", defaultValue: "%d 个进程", process.processCount)
        let accounting = localization.string(
            "topProcesses.accounting",
            defaultValue: "按应用汇总；CPU 以单核 100% 计，内存为应用内存占用。无法完整读取时显示 —。"
        )
        return "\(process.displayName) · \(count)\n\(process.command)\n\(accounting)\n\(localization.string("topProcesses.openActivityMonitor", defaultValue: "打开‘活动监视器’"))"
    }
}

enum SystemStatusProcessActions {
    static let activityMonitorURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app",
        isDirectory: true
    )

    static func openActivityMonitor() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: activityMonitorURL,
            configuration: configuration
        )
    }
}

private struct SystemStatusHUDRateFooter: View {
    private enum Layout {
        static let itemSpacing: CGFloat = 6
        static let labelWidth: CGFloat = 11
        static let labelSpacing: CGFloat = 2
    }

    let firstLabel: String
    let firstText: String
    let firstColor: Color
    let secondLabel: String
    let secondText: String
    let secondColor: Color

    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = max((geometry.size.width - Layout.itemSpacing) / 2, 0)
            HStack(spacing: Layout.itemSpacing) {
                rateItem(label: firstLabel, text: firstText, color: firstColor, width: itemWidth)
                rateItem(label: secondLabel, text: secondText, color: secondColor, width: itemWidth)
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
    }

    private func rateItem(label: String, text: String, color: Color, width: CGFloat) -> some View {
        HStack(spacing: Layout.labelSpacing) {
            Text(label)
                .font(PluginTypography.caption.font.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: Layout.labelWidth, alignment: .leading)

            Text(text)
                .font(PluginTypography.caption.font.monospacedDigit())
                .foregroundStyle(theme.text.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    width: max(width - Layout.labelWidth - Layout.labelSpacing, 0),
                    alignment: .leading
                )
                .help(text)
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct SystemStatusHUDPressureChart: View {
    let samples: [SystemStatusHUDChartSample]
    let localization: PluginLocalization
    var isInteractive = false
    var pinRetentionRange: ClosedRange<TimeInterval>?
    @Environment(\.pluginComponentTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let range = pinRetentionRange ?? SystemStatusHUDChartGeometry.timeRange(timestamps: samples.map(\.timestamp))
            func point(_ sample: SystemStatusHUDChartSample) -> CGPoint {
                CGPoint(x: SystemStatusHUDChartGeometry.x(for: sample.timestamp, in: range, width: size.width),
                    y: (1 - min(max(sample.value, 0), 100) / 100) * max(size.height - 2, 0) + 1)
            }
            for index in samples.indices {
                let sample = samples[index]
                guard sample.isAvailable else { continue }
                let start = point(sample)
                let color = sample.pressure?.color(theme: theme) ?? theme.text.secondary
                if index + 1 < samples.count, samples[index + 1].isAvailable, !samples[index + 1].startsNewSegment {
                    let end = point(samples[index + 1])
                    var area = Path()
                    area.move(to: CGPoint(x: start.x, y: size.height))
                    area.addLine(to: start); area.addLine(to: end)
                    area.addLine(to: CGPoint(x: end.x, y: size.height)); area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(0.18)))
                    var line = Path()
                    line.move(to: start); line.addLine(to: end)
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                // Keep isolated observations visible without filling an unknown interval.
                context.fill(Path(ellipseIn: CGRect(x: start.x - 0.75, y: start.y - 0.75, width: 1.5, height: 1.5)),
                    with: .color(color))
            }
        }
        .overlay {
            if isInteractive {
                SystemStatusHUDChartContextOverlay(
                    timestamps: samples.map(\.timestamp), series: [samples.map(\.value)], labels: [""],
                    valueFormatter: { SystemStatusChartMetric.pressure.format($0, localization: localization) },
                    rangeLabel: "", pinRetentionRange: pinRetentionRange, availability: samples.map(\.isAvailable),
                    breaksBefore: samples.map(\.startsNewSegment)
                )
            }
        }
        .help(SystemStatusMemoryPressure.estimateDescription(localization: localization))
    }
}

private struct SystemStatusHUDMiniChart: View {
    enum Style {
        case area
        case bars
    }

    let samples: [SystemStatusHUDChartSample]
    let color: Color
    var style: Style = .area
    let valueFormatter: (Double) -> String
    let rangeLabel: String
    var isInteractive = false
    var pinRetentionRange: ClosedRange<TimeInterval>?

    private var visibleSamples: [SystemStatusHUDChartSample] {
        samples.count > 120 ? Array(samples.suffix(120)) : samples
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let bounds = bounds()
            let denominator = max(bounds.high - bounds.low, 0.0001)

            if visibleSamples.count < 2 {
                baseline(width: width, height: height)
            } else {
                switch style {
                case .area:
                    area(width: width, height: height, low: bounds.low, denominator: denominator)
                case .bars:
                    bars(width: width, height: height, low: bounds.low, denominator: denominator)
                }
            }
        }
        .overlay {
            if isInteractive {
                SystemStatusHUDChartContextOverlay(
                    timestamps: visibleSamples.map(\.timestamp),
                    series: [visibleSamples.map(\.value)],
                    labels: [""],
                    valueFormatter: valueFormatter,
                    rangeLabel: rangeLabel,
                    pinRetentionRange: pinRetentionRange, availability: visibleSamples.map(\.isAvailable), breaksBefore: visibleSamples.map(\.startsNewSegment)
                )
            }
        }
    }

    private func y(_ value: Double, height: CGFloat, low: Double, denominator: Double) -> CGFloat {
        (1.0 - CGFloat((value - low) / denominator)) * height
    }

    private func baseline(width: CGFloat, height: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: height - 1))
            path.addLine(to: CGPoint(x: width, y: height - 1))
        }
        .stroke(color.opacity(0.25), lineWidth: 1)
    }

    private func area(width: CGFloat, height: CGFloat, low: Double, denominator: Double) -> some View {
        SystemStatusHUDChartArea(
            segments: SystemStatusHUDChartGeometry.segments(samples: visibleSamples, width: width, domain: pinRetentionRange) {
                y($0, height: height, low: low, denominator: denominator)
            }, height: height, color: color
        )
        .overlay {
            if low < 0 {
                Path { path in
                    let zero = y(0, height: height, low: low, denominator: denominator)
                    path.move(to: CGPoint(x: 0, y: zero))
                    path.addLine(to: CGPoint(x: width, y: zero))
                }
                .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
        }
    }

    private func bars(width: CGFloat, height: CGFloat, low: Double, denominator: Double) -> some View {
        let count = max(visibleSamples.count, 1)
        let slot = width / CGFloat(count)
        let barWidth = max(1.5, slot * 0.62)
        let timeRange = pinRetentionRange ?? SystemStatusHUDChartGeometry.timeRange(
            timestamps: visibleSamples.map(\.timestamp)
        )

        return Path { path in
            for sample in visibleSamples where sample.isAvailable {
                let barHeight = max(1.5, CGFloat((sample.value - low) / denominator) * height)
                let centerX = SystemStatusHUDChartGeometry.x(
                    for: sample.timestamp,
                    in: timeRange,
                    width: width
                )
                let x = min(max(centerX - barWidth / 2, 0), max(width - barWidth, 0))
                path.addRoundedRect(
                    in: CGRect(x: x, y: height - barHeight, width: barWidth, height: barHeight),
                    cornerSize: CGSize(width: 1, height: 1),
                    style: .continuous
                )
            }
        }
        // The bar itself carries the history, so keep the resolved functional
        // color opaque. Its theme token is guaranteed to contrast with the card.
        .fill(color)
    }

    private func bounds() -> (low: Double, high: Double) {
        let values = visibleSamples.filter(\.isAvailable).map(\.value)
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 1, 0)
        if high - low < 0.001 {
            return (low, high + 1)
        }

        return (low, high)
    }
}

enum SystemStatusHUDDualLineChart {
    static func downsamplePeaks(
        _ values: [Double],
        limit: Int
    ) -> [Double] {
        guard limit > 0 else {
            return []
        }

        guard values.count > limit else {
            return values.map { max($0, 0) }
        }

        guard limit > 1 else {
            return [max(values.max() ?? 0, 0)]
        }

        let bucketSize = Double(values.count) / Double(limit)
        return (0..<limit).map { index in
            let start = Int((Double(index) * bucketSize).rounded(.down))
            let proposedEnd = Int((Double(index + 1) * bucketSize).rounded(.down))
            let end = min(values.count, max(start + 1, proposedEnd))
            return max(values[start..<end].max() ?? 0, 0)
        }
    }

    static func downsamplePeakSamples(
        _ samples: [SystemStatusHUDRateChartSample],
        limit: Int
    ) -> [SystemStatusHUDRateChartSample] {
        guard limit > 0 else {
            return []
        }

        guard samples.count > limit else {
            return samples
        }

        guard limit > 1 else {
            return samples.max(by: { peakMagnitude($0) < peakMagnitude($1) }).map { [$0] } ?? []
        }

        // Each bucket can contribute both series' peaks at their actual timestamps.
        // Reserve two points per bucket so drawing and hover remain bounded by limit.
        let bucketCount = max(limit / 2, 1)
        let bucketSize = Double(samples.count) / Double(bucketCount)
        var result: [SystemStatusHUDRateChartSample] = []
        result.reserveCapacity(limit)
        for index in 0..<bucketCount {
            let start = Int((Double(index) * bucketSize).rounded(.down))
            let proposedEnd = Int((Double(index + 1) * bucketSize).rounded(.down))
            let end = min(samples.count, max(start + 1, proposedEnd))
            if let gap = samples[start..<end].first(where: { !$0.isAvailable || $0.startsNewSegment }) {
                result.append(gap)
                continue
            }
            var firstPeak = start
            var secondPeak = start
            for sampleIndex in (start + 1)..<end {
                if samples[sampleIndex].firstValue > samples[firstPeak].firstValue {
                    firstPeak = sampleIndex
                }
                if samples[sampleIndex].secondValue > samples[secondPeak].secondValue {
                    secondPeak = sampleIndex
                }
            }
            result.append(samples[min(firstPeak, secondPeak)])
            if firstPeak != secondPeak {
                result.append(samples[max(firstPeak, secondPeak)])
            }
        }
        return result
    }

    static func points(
        values: [Double],
        width: CGFloat,
        height: CGFloat,
        maximumValue: Double? = nil
    ) -> [CGPoint] {
        let samples = values.map { max($0, 0) }
        guard !samples.isEmpty else {
            return []
        }

        let maximumValue = max(maximumValue ?? (samples.max() ?? 0), 0.0001)
        return samples.enumerated().map { index, sample in
            let x = width * CGFloat(index) / CGFloat(max(samples.count - 1, 1))
            let ratio = scaledRatio(value: sample, maximumValue: maximumValue)
            let y = (1 - ratio) * height
            return CGPoint(x: x, y: y)
        }
    }

    static func points(
        samples: [SystemStatusHUDChartSample],
        width: CGFloat,
        height: CGFloat,
        maximumValue: Double? = nil
    ) -> [CGPoint] {
        guard !samples.isEmpty else {
            return []
        }

        let maximumValue = max(maximumValue ?? (samples.map(\.value).max() ?? 0), 0.0001)
        let timeRange = SystemStatusHUDChartGeometry.timeRange(
            timestamps: samples.map(\.timestamp)
        )
        return samples.map { sample in
            let ratio = scaledRatio(value: sample.value, maximumValue: maximumValue)
            return CGPoint(
                x: SystemStatusHUDChartGeometry.x(
                    for: sample.timestamp,
                    in: timeRange,
                    width: width
                ),
                y: (1 - ratio) * height
            )
        }
    }

    static func scaledRatio(value: Double, maximumValue: Double) -> CGFloat {
        let normalized = min(max(value / max(maximumValue, 0.0001), 0), 1)
        return CGFloat(sqrt(normalized))
    }

    private static func peakMagnitude(_ sample: SystemStatusHUDRateChartSample) -> Double {
        max(max(sample.firstValue, sample.secondValue), 0)
    }
}

enum SystemStatusHUDChartGeometry {
    static func segments(
        samples: [SystemStatusHUDChartSample], width: CGFloat,
        domain: ClosedRange<TimeInterval>? = nil, y: (Double) -> CGFloat
    ) -> [[CGPoint]] {
        let range = domain ?? timeRange(timestamps: samples.map(\.timestamp))
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for sample in samples {
            if sample.startsNewSegment, !current.isEmpty {
                segments.append(current)
                current = []
            }
            if sample.isAvailable, sample.value.isFinite {
                current.append(CGPoint(x: x(for: sample.timestamp, in: range, width: width), y: y(sample.value)))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    static func timeRange(timestamps: [TimeInterval]) -> ClosedRange<TimeInterval>? {
        guard let start = timestamps.first, let end = timestamps.last else {
            return nil
        }
        return start ... end
    }

    static func x(
        for timestamp: TimeInterval,
        in timeRange: ClosedRange<TimeInterval>?,
        width: CGFloat
    ) -> CGFloat {
        guard let timeRange else {
            return 0
        }
        let duration = timeRange.upperBound - timeRange.lowerBound
        guard duration > 0 else {
            return width / 2
        }
        let fraction = min(max((timestamp - timeRange.lowerBound) / duration, 0), 1)
        return CGFloat(fraction) * width
    }

    static func nearestIndex(
        to fraction: CGFloat,
        timestamps: [TimeInterval],
        selectsPrecedingSample: Bool = false,
        domain: ClosedRange<TimeInterval>? = nil,
        breaksBefore: [Bool] = []
    ) -> Int? {
        guard !timestamps.isEmpty, let timeRange = domain ?? timeRange(timestamps: timestamps) else {
            return nil
        }
        let clampedFraction = min(max(fraction, 0), 1)
        let target = timeRange.lowerBound
            + (timeRange.upperBound - timeRange.lowerBound) * Double(clampedFraction)

        var lowerBound = timestamps.startIndex
        var upperBound = timestamps.endIndex
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if timestamps[middle] < target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        if lowerBound > timestamps.startIndex, lowerBound < timestamps.endIndex,
           breaksBefore.indices.contains(lowerBound), breaksBefore[lowerBound],
           target > timestamps[lowerBound - 1], target < timestamps[lowerBound] { return nil }

        guard lowerBound < timestamps.endIndex else {
            return timestamps.index(before: timestamps.endIndex)
        }
        guard lowerBound > timestamps.startIndex else {
            return lowerBound
        }

        let previous = timestamps.index(before: lowerBound)
        if selectsPrecedingSample {
            return timestamps[lowerBound] == target ? lowerBound : previous
        }
        return abs(timestamps[previous] - target) <= abs(timestamps[lowerBound] - target)
            ? previous
            : lowerBound
    }

    static func fraction(at index: Int, timestamps: [TimeInterval]) -> CGFloat? {
        guard timestamps.indices.contains(index), let timeRange = timeRange(timestamps: timestamps) else {
            return nil
        }
        let duration = timeRange.upperBound - timeRange.lowerBound
        guard duration > 0 else {
            return 0.5
        }
        return CGFloat((timestamps[index] - timeRange.lowerBound) / duration)
    }
}

private struct SystemStatusHUDRateChart: View {
    let samples: [SystemStatusHUDRateChartSample]
    let firstColor: Color
    let secondColor: Color
    let firstLabel: String
    let secondLabel: String
    let valueFormatter: (Double) -> String
    let rangeLabel: String
    var isInteractive = false
    var pinRetentionRange: ClosedRange<TimeInterval>?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let firstSeries = samples.map { max($0.firstValue, 0) }
            let secondSeries = samples.map { max($0.secondValue, 0) }
            let firstMaximum = firstSeries.max() ?? 0
            let secondMaximum = secondSeries.max() ?? 0

            if max(firstMaximum, secondMaximum) <= 0 || (firstSeries.count < 2 && secondSeries.count < 2) {
                Color.clear
            } else {
                ZStack {
                    series(
                        samples: zip(samples, firstSeries).map {
                            SystemStatusHUDChartSample(timestamp: $0.0.timestamp, value: $0.1, isAvailable: $0.0.isAvailable, startsNewSegment: $0.0.startsNewSegment)
                        },
                        width: width,
                        height: height,
                        maximumValue: firstMaximum,
                        color: firstColor
                    )
                    series(
                        samples: zip(samples, secondSeries).map {
                            SystemStatusHUDChartSample(timestamp: $0.0.timestamp, value: $0.1, isAvailable: $0.0.isAvailable, startsNewSegment: $0.0.startsNewSegment)
                        },
                        width: width,
                        height: height,
                        maximumValue: secondMaximum,
                        color: secondColor
                    )
                }
            }
        }
        .overlay {
            if isInteractive {
                SystemStatusHUDChartContextOverlay(
                    timestamps: samples.map(\.timestamp),
                    series: [samples.map(\.firstValue), samples.map(\.secondValue)],
                    labels: [firstLabel, secondLabel],
                    valueFormatter: valueFormatter,
                    rangeLabel: rangeLabel,
                    pinRetentionRange: pinRetentionRange, availability: samples.map(\.isAvailable), breaksBefore: samples.map(\.startsNewSegment)
                )
            }
        }
    }

    private func series(
        samples: [SystemStatusHUDChartSample], width: CGFloat, height: CGFloat,
        maximumValue: Double, color: Color
    ) -> some View {
        SystemStatusHUDChartArea(
            segments: SystemStatusHUDChartGeometry.segments(samples: samples, width: width, domain: pinRetentionRange) {
                (1 - SystemStatusHUDDualLineChart.scaledRatio(value: $0, maximumValue: maximumValue)) * height
            }, height: height, color: color
        )
    }
}

private struct SystemStatusHUDChartArea: View {
    let segments: [[CGPoint]]
    let height: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Path { path in
                for segment in segments {
                    guard let first = segment.first, let last = segment.last else { continue }
                    path.move(to: CGPoint(x: first.x, y: height))
                    for point in segment { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: last.x, y: height))
                    path.closeSubpath()
                }
            }
            .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Path { path in
                for segment in segments {
                    guard let first = segment.first else { continue }
                    path.move(to: first)
                    for point in segment.dropFirst() { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SystemStatusChartStatistics: Equatable, Sendable {
    var usesSampleIntervals = false
    private(set) var minimum: Double?
    private(set) var maximum: Double?
    private(set) var count = 0
    private var integral: Double = 0
    private var weight: Double = 0
    private var previousValue: Double?
    private var previousTimestamp: TimeInterval?

    // Gauges interpolate between valid observations. Counter rates instead use
    // their measured intervals; legacy history cannot supply missing durations.
    var average: Double? { weight > 0 ? integral / weight : !usesSampleIntervals && count == 1 ? minimum : nil }

    mutating func record(_ value: Double?, at timestamp: TimeInterval, startsNewSegment: Bool) {
        guard let value, value.isFinite, timestamp.isFinite else {
            previousValue = nil; previousTimestamp = nil
            return
        }
        if !usesSampleIntervals, !startsNewSegment, let previousValue, let previousTimestamp, timestamp > previousTimestamp {
            let interval = timestamp - previousTimestamp
            integral += (previousValue / 2 + value / 2) * interval
            weight += interval
        }
        minimum = min(minimum ?? value, value)
        maximum = max(maximum ?? value, value)
        count += 1
        previousValue = value
        previousTimestamp = timestamp
    }

    mutating func record(_ sample: SystemStatusRateAggregate?, within range: ClosedRange<TimeInterval>) {
        guard let sample, sample.isValid else { return }
        let overlap = min(sample.endTimestamp, range.upperBound) - max(sample.startTimestamp, range.lowerBound)
        guard overlap > 0 else { return }
        // An interval is represented by its measured mean. Boundary clipping
        // applies the same mean only to the portion inside the selected range.
        let fraction = min(overlap / (sample.endTimestamp - sample.startTimestamp), 1)
        integral += sample.integral * fraction
        weight += sample.weight * fraction
        minimum = min(minimum ?? sample.minimum, sample.minimum)
        maximum = max(maximum ?? sample.maximum, sample.maximum)
    }
}

struct SystemStatusMetricDetailChartData: Equatable, Sendable {
    let range: SystemStatusMetricDetailRange
    let startTimestamp: TimeInterval?
    let endTimestamp: TimeInterval?
    let singleSamples: [SystemStatusHUDChartSample]
    let rateSamples: [SystemStatusHUDRateChartSample]
    let statistics: SystemStatusChartStatistics

    var timeRange: ClosedRange<TimeInterval>? {
        guard let startTimestamp, let endTimestamp else { return nil }
        return startTimestamp...endTimestamp
    }

    init(
        history: [SystemStatusHistoryPoint], kind: SystemStatusMetricKind, range: SystemStatusMetricDetailRange,
        chartMetric: SystemStatusChartMetric? = nil, sampleLimit: Int = SystemStatusHUDLayout.chartSampleLimit
    ) {
        self.range = range
        let metric = chartMetric ?? .defaultMetric(for: kind)
        guard let latest = history.last?.timestamp else {
            startTimestamp = nil; endTimestamp = nil
            singleSamples = []; rateSamples = []; statistics = SystemStatusChartStatistics()
            return
        }
        let visible = history.filter { $0.timestamp >= latest - range.interval && $0.timestamp <= latest }
        startTimestamp = visible.first?.timestamp
        endTimestamp = visible.last?.timestamp
        let usesSampleIntervals = kind == .cpu || metric == .activity
        var aggregate = SystemStatusChartStatistics(usesSampleIntervals: usesSampleIntervals)
        let breaks = visible.indices.map { index in
            index > 0 && visible[index].collectionID != visible[index - 1].collectionID
        }
        for (index, point) in visible.enumerated() {
            aggregate.record(metric.value(in: point, kind: kind), at: point.timestamp, startsNewSegment: breaks[index])
            if usesSampleIntervals {
                aggregate.record(point.rates?.value(for: kind), within: (latest - range.interval)...latest)
            }
        }
        if kind == .memory, metric == .pressure {
            singleSamples = SystemStatusMemoryPressureHistory.samples(visible, limit: sampleLimit)
            rateSamples = []
        } else if metric == .activity, kind == .network || kind == .disk {
            let raw = visible.enumerated().map { index, point in
                let first = kind == .network ? point.networkDownloadBytesPerSecond : point.diskReadBytesPerSecond
                let second = kind == .network ? point.networkUploadBytesPerSecond : point.diskWriteBytesPerSecond
                return SystemStatusHUDRateChartSample(timestamp: point.timestamp,
                    firstValue: Double(first ?? 0), secondValue: Double(second ?? 0),
                    isAvailable: first != nil || second != nil, startsNewSegment: breaks[index])
            }
            rateSamples = SystemStatusHUDDualLineChart.downsamplePeakSamples(raw, limit: sampleLimit)
            singleSamples = []
        } else {
            let raw = visible.enumerated().map { index, point in
                let value = metric.value(in: point, kind: kind)
                return SystemStatusHUDChartSample(timestamp: point.timestamp, value: value ?? 0,
                    isAvailable: value != nil, startsNewSegment: breaks[index])
            }
            singleSamples = SystemStatusHUDSingleLineChart.downsample(raw, limit: sampleLimit)
            rateSamples = []
        }
        statistics = aggregate
    }
}

struct SystemStatusMetricDetailChartCache: Equatable, Sendable {
    private let thirtyMinutes: SystemStatusMetricDetailChartData
    private let twoHours: SystemStatusMetricDetailChartData
    private let twentyFourHours: SystemStatusMetricDetailChartData

    init(
        history: [SystemStatusHistoryPoint],
        kind: SystemStatusMetricKind,
        chartMetric: SystemStatusChartMetric? = nil,
        sampleLimit: Int = SystemStatusHUDLayout.chartSampleLimit
    ) {
        thirtyMinutes = SystemStatusMetricDetailChartData(
            history: history,
            kind: kind,
            range: .thirtyMinutes,
            chartMetric: chartMetric,
            sampleLimit: sampleLimit
        )
        twoHours = SystemStatusMetricDetailChartData(
            history: history,
            kind: kind,
            range: .twoHours,
            chartMetric: chartMetric,
            sampleLimit: sampleLimit
        )
        twentyFourHours = SystemStatusMetricDetailChartData(
            history: history,
            kind: kind,
            range: .twentyFourHours,
            chartMetric: chartMetric,
            sampleLimit: sampleLimit
        )
    }

    func data(for range: SystemStatusMetricDetailRange) -> SystemStatusMetricDetailChartData {
        switch range {
        case .thirtyMinutes:
            thirtyMinutes
        case .twoHours:
            twoHours
        case .twentyFourHours:
            twentyFourHours
        }
    }
}

enum SystemStatusMetricDetailAxis {
    static let labelCount = 5

    static func timestamps(
        start: TimeInterval?,
        end: TimeInterval?,
        count: Int = labelCount
    ) -> [TimeInterval] {
        guard
            let start,
            let end,
            end >= start,
            count > 0
        else {
            return []
        }
        guard count > 1, end > start else {
            return [start]
        }

        let stride = (end - start) / Double(count - 1)
        return (0..<count).map { index in
            index == count - 1 ? end : start + Double(index) * stride
        }
    }
}

private struct SystemStatusMetricDetailChartTaskID: Hashable {
    let kind: SystemStatusMetricKind
    let chartMetric: SystemStatusChartMetric
    let historyCount: Int
    let firstTimestamp: TimeInterval?
    let lastTimestamp: TimeInterval?
    let localeIdentifier: String
}

@MainActor
private final class SystemStatusMetricDetailChartStore: ObservableObject {
    @Published private(set) var chartCache: SystemStatusMetricDetailChartCache
    @Published private(set) var axisLabelsByRange: [SystemStatusMetricDetailRange: [String]]
    private(set) var sourceID: SystemStatusMetricDetailChartTaskID

    init(
        history: [SystemStatusHistoryPoint],
        kind: SystemStatusMetricKind,
        sourceID: SystemStatusMetricDetailChartTaskID
    ) {
        let chartCache = SystemStatusMetricDetailChartCache(
            history: history, kind: kind, chartMetric: sourceID.chartMetric
        )
        self.chartCache = chartCache
        axisLabelsByRange = SystemStatusMetricDetailAxisLabelFormatter.labelsByRange(chartCache)
        self.sourceID = sourceID
    }

    func replace(
        chartCache: SystemStatusMetricDetailChartCache,
        sourceID: SystemStatusMetricDetailChartTaskID
    ) {
        self.chartCache = chartCache
        axisLabelsByRange = SystemStatusMetricDetailAxisLabelFormatter.labelsByRange(chartCache)
        self.sourceID = sourceID
    }
}

@MainActor
private enum SystemStatusMetricDetailAxisLabelFormatter {
    static func labelsByRange(
        _ chartCache: SystemStatusMetricDetailChartCache
    ) -> [SystemStatusMetricDetailRange: [String]] {
        Dictionary(uniqueKeysWithValues: SystemStatusMetricDetailRange.allCases.map { range in
            (range, labels(chartCache.data(for: range)))
        })
    }

    private static func labels(
        _ chartData: SystemStatusMetricDetailChartData
    ) -> [String] {
        let timestamps = SystemStatusMetricDetailAxis.timestamps(
            start: chartData.startTimestamp,
            end: chartData.endTimestamp
        )
        guard !timestamps.isEmpty else {
            return ["—"]
        }
        let formatter = chartData.range == .twentyFourHours
            ? axisDayTimeFormatter
            : axisTimeFormatter
        formatter.locale = PluginRuntimeLocalization.locale
        if chartData.range == .twentyFourHours {
            formatter.setLocalizedDateFormatFromTemplate("Ejm")
        }
        return timestamps.map {
            formatter.string(from: Date(timeIntervalSince1970: $0))
        }
    }

    private static let axisTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let axisDayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Ejm")
        return formatter
    }()
}

struct SystemStatusMetricDetailView: View {
    @ObservedObject var viewModel: SystemStatusViewModel
    @ObservedObject var settingsController: SystemStatusSettingsController
    let kind: SystemStatusMetricKind
    let localization: PluginLocalization

    @Environment(\.pluginComponentTheme) private var theme
    @State private var samplingConsumerID = UUID()
    @State private var selectedRange = SystemStatusMetricDetailRange.thirtyMinutes
    @StateObject private var chartStore: SystemStatusMetricDetailChartStore

    private var snapshot: SystemStatusSnapshot { viewModel.snapshot }

    init(
        viewModel: SystemStatusViewModel,
        settingsController: SystemStatusSettingsController,
        kind: SystemStatusMetricKind,
        localization: PluginLocalization
    ) {
        self.settingsController = settingsController
        self.viewModel = viewModel
        self.kind = kind
        self.localization = localization
        let history = viewModel.snapshot.history
        let sourceID = SystemStatusMetricDetailChartTaskID(
            kind: kind,
            chartMetric: settingsController.configuration.chartMetric(for: kind),
            historyCount: history.count,
            firstTimestamp: history.first?.timestamp,
            lastTimestamp: history.last?.timestamp,
            localeIdentifier: PluginRuntimeLocalization.locale.identifier
        )
        _chartStore = StateObject(
            wrappedValue: SystemStatusMetricDetailChartStore(
                history: history,
                kind: kind,
                sourceID: sourceID
            )
        )
    }

    var body: some View {
        // Never format the previous metric's cached values as the newly selected metric.
        let hasMatchingMetric = chartStore.sourceID.chartMetric == chartTaskID.chartMetric
        let chartData = hasMatchingMetric
            ? chartStore.chartCache.data(for: selectedRange)
            : SystemStatusMetricDetailChartData(history: [], kind: kind, range: selectedRange)
        let axisLabels = hasMatchingMetric ? chartStore.axisLabelsByRange[selectedRange] ?? ["—"] : ["—"]

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chartMetric.title(localization: localization))
                        .font(PluginTypography.caption.font)
                        .foregroundStyle(theme.text.secondary)
                    Text(currentValue)
                    .font(PluginTypography.prominentMetric.font)
                    .foregroundStyle(theme.text.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Picker(
                    localization.string("chart.timeline", defaultValue: "时间范围"),
                    selection: $selectedRange
                ) {
                    ForEach(SystemStatusMetricDetailRange.allCases) { range in
                        Text(range.title(localization: localization)).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 174)
            }

            VStack(alignment: .leading, spacing: 4) {
                detailChart(chartData)
                    .frame(height: 112)
                    .id("\(kind.rawValue):\(chartData.range.rawValue):\(chartTaskID.chartMetric.rawValue)")
                    .transaction { transaction in
                        transaction.animation = nil
                    }

                HStack(spacing: 0) {
                    ForEach(Array(axisLabels.enumerated()), id: \.offset) { index, label in
                        Text(label)
                            .lineLimit(1)
                            .frame(
                                maxWidth: .infinity,
                                alignment: index == 0
                                    ? .leading
                                    : index == axisLabels.count - 1 ? .trailing : .center
                            )
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(theme.text.secondary)
                .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaces.chip.opacity(0.55))
            )

            if chartMetric == .activity {
                rateLegend
            } else if showsMemoryPressure {
                HStack(spacing: 12) {
                    ForEach(SystemStatusMemoryPressure.allCases, id: \.rawValue) { pressure in
                        legendItem(color: pressure.color(theme: theme), label: pressure.title(localization: localization))
                    }
                    Spacer(minLength: 0)
                    Text("0–100%")
                        .font(PluginTypography.caption.font)
                        .foregroundStyle(theme.text.secondary)
                }
            }

            HStack(spacing: 6) {
                statistic(
                    title: localization.string("detail.minimum", defaultValue: "最低"),
                    value: chartData.statistics.minimum
                )
                statistic(
                    title: localization.string("detail.average", defaultValue: "平均"),
                    value: chartData.statistics.average
                )
                statistic(
                    title: localization.string("detail.maximum", defaultValue: "最高"),
                    value: chartData.statistics.maximum
                )
            }

            if showsMemoryPressure {
                Text(SystemStatusMemoryPressure.estimateDescription(localization: localization))
                    .font(PluginTypography.caption.font)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !supportingDetails.isEmpty {
                Text(supportingDetails.joined(separator: " · "))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onAppear { viewModel.startForeground(for: .detail(samplingConsumerID, kind)) }
        .onDisappear { viewModel.returnToBackground(from: .detail(samplingConsumerID, kind)) }
        .task(id: chartTaskID) {
            let sourceID = chartTaskID
            guard chartStore.sourceID != sourceID else {
                return
            }
            let history = snapshot.history
            let kind = kind
            let chartMetric = sourceID.chartMetric
            let preparedCache = await Task.detached(priority: .userInitiated) {
                SystemStatusMetricDetailChartCache(
                    history: history,
                    kind: kind,
                    chartMetric: chartMetric
                )
            }.value
            guard !Task.isCancelled else {
                return
            }
            chartStore.replace(chartCache: preparedCache, sourceID: sourceID)
        }
    }

    @ViewBuilder
    private func detailChart(_ chartData: SystemStatusMetricDetailChartData) -> some View {
        switch kind {
        case .memory where showsMemoryPressure:
            SystemStatusHUDPressureChart(
                samples: chartData.singleSamples, localization: localization,
                isInteractive: true, pinRetentionRange: chartData.timeRange
            )
        case .network:
            SystemStatusHUDRateChart(
                samples: chartData.rateSamples,
                firstColor: theme.dataSeries.primary,
                secondColor: theme.dataSeries.secondary,
                firstLabel: "↓",
                secondLabel: "↑",
                valueFormatter: rateFormatter,
                rangeLabel: "",
                isInteractive: true,
                pinRetentionRange: chartData.timeRange
            )
        case .disk:
            SystemStatusHUDRateChart(
                samples: chartData.rateSamples,
                firstColor: theme.dataSeries.primary,
                secondColor: theme.dataSeries.quaternary,
                firstLabel: localization.string("chart.disk.readCompact", defaultValue: "读"),
                secondLabel: localization.string("chart.disk.writeCompact", defaultValue: "写"),
                valueFormatter: rateFormatter,
                rangeLabel: "",
                isInteractive: true,
                pinRetentionRange: chartData.timeRange
            )
        case .cpu, .gpu, .memory, .battery:
            SystemStatusHUDMiniChart(
                samples: chartData.singleSamples,
                color: accentColor,
                style: chartMetric == .usage && (kind == .cpu || kind == .gpu) ? .bars : .area,
                valueFormatter: statisticFormatter,
                rangeLabel: "",
                isInteractive: true,
                pinRetentionRange: chartData.timeRange
            )
        case .topProcesses:
            Color.clear
        }
    }

    private func statistic(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.text.secondary)
            Text(value.map(statisticFormatter) ?? "—")
                .font(PluginTypography.caption.font.monospacedDigit())
                .foregroundStyle(theme.text.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.surfaces.chip.opacity(0.7))
        )
    }

    private var chartTaskID: SystemStatusMetricDetailChartTaskID {
        SystemStatusMetricDetailChartTaskID(
            kind: kind,
            chartMetric: settingsController.configuration.chartMetric(for: kind),
            historyCount: snapshot.history.count,
            firstTimestamp: snapshot.history.first?.timestamp,
            lastTimestamp: snapshot.history.last?.timestamp,
            localeIdentifier: PluginRuntimeLocalization.locale.identifier
        )
    }

    private var rateLegend: some View {
        HStack(spacing: 12) {
            legendItem(
                color: theme.dataSeries.primary,
                label: kind == .network
                    ? "↓"
                    : localization.string("chart.disk.readCompact", defaultValue: "读")
            )
            legendItem(
                color: kind == .network ? theme.dataSeries.secondary : theme.dataSeries.quaternary,
                label: kind == .network
                    ? "↑"
                    : localization.string("chart.disk.writeCompact", defaultValue: "写")
            )
            Spacer(minLength: 0)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.text.secondary)
        }
    }

    private var chartMetric: SystemStatusChartMetric { settingsController.configuration.chartMetric(for: kind) }

    private var currentValue: String {
        chartMetric.format(chartMetric.value(in: snapshot, kind: kind), localization: localization)
    }

    private var supportingDetails: [String] {
        switch kind {
        case .cpu:
            return [
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(snapshot.cpu.temperatureCelsius)
                ),
                localization.format(
                    "metric.powerFormat",
                    defaultValue: "功率 %@",
                    SystemStatusFormatter.power(snapshot.cpu.cpuPowerWatts)
                ),
                "\(SystemStatusMenuBarValueKind.load.title(localization: localization)) \(formatDecimal(snapshot.cpu.loadAverage1Minute))"
            ]
        case .gpu:
            return [
                snapshot.gpu.name ?? localization.string("metric.unavailable", defaultValue: "不可用"),
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(snapshot.gpu.temperatureCelsius)
                )
            ]
        case .memory:
            let status = showsMemoryPressure ? [localization.format("memory.pressure.systemLevel", defaultValue: "系统压力 %@",
                snapshot.memory.pressure?.title(localization: localization) ?? "—")] : []
            return status + [
                localization.format(
                    "metric.usedFormat",
                    defaultValue: "已用 %@",
                    SystemStatusFormatter.bytes(snapshot.memory.usedBytes)
                ),
                localization.format(
                    "metric.totalFormat",
                    defaultValue: "总量 %@",
                    SystemStatusFormatter.bytes(snapshot.memory.totalBytes)
                ),
                "\(SystemStatusMenuBarValueKind.swap.title(localization: localization)) \(SystemStatusFormatter.bytes(snapshot.memory.swapUsedBytes))"
            ]
        case .disk:
            return [
                "\(localization.string("chart.disk.readCompact", defaultValue: "读")) \(SystemStatusFormatter.speed(snapshot.disk.readBytesPerSecond))",
                "\(localization.string("chart.disk.writeCompact", defaultValue: "写")) \(SystemStatusFormatter.speed(snapshot.disk.writeBytesPerSecond))",
                localization.format(
                    "metric.totalFormat",
                    defaultValue: "总量 %@",
                    SystemStatusFormatter.bytes(snapshot.disk.totalBytes)
                )
            ]
        case .battery:
            return [
                snapshot.battery.state.title(localization: localization),
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(snapshot.battery.temperatureCelsius)
                ),
                snapshot.battery.healthPercent.map {
                    localization.format("battery.healthFormat", defaultValue: "健康度 %d%%", $0)
                } ?? localization.string("battery.healthUnavailable", defaultValue: "健康度不可用")
            ]
        case .network:
            return [
                "↓ \(SystemStatusFormatter.speed(snapshot.network.downloadBytesPerSecond))",
                "↑ \(SystemStatusFormatter.speed(snapshot.network.uploadBytesPerSecond))",
                snapshot.network.interfaceName ?? localization.string("metric.unavailable", defaultValue: "不可用")
            ]
        case .topProcesses:
            return []
        }
    }

    private var accentColor: Color {
        switch kind {
        case .cpu: return theme.dataSeries.tertiary
        case .gpu: return theme.dataSeries.secondary
        case .memory: return theme.dataSeries.senary
        case .battery: return theme.dataSeries.tertiary
        case .network: return theme.dataSeries.quinary
        case .disk: return theme.dataSeries.primary
        case .topProcesses: return theme.text.secondary
        }
    }

    private var showsMemoryPressure: Bool {
        kind == .memory && chartMetric == .pressure
    }

    private var statisticFormatter: (Double) -> String {
        { chartMetric.format($0, localization: localization) }
    }

    private var rateFormatter: (Double) -> String {
        { SystemStatusChartMetric.activity.format($0, localization: localization) }
    }

    private func formatDecimal(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", locale: PluginRuntimeLocalization.locale, value)
    }

}

struct SystemStatusChartSelection: Equatable {
    struct Reading: Equatable {
        let timestamp: TimeInterval
        let values: [Double]
    }

    private(set) var pinned: Reading?

    mutating func toggle(_ reading: Reading) {
        pinned = pinned?.timestamp == reading.timestamp ? nil : reading
    }

    mutating func expire(outside timeRange: ClosedRange<TimeInterval>?) {
        guard let pinned else { return }
        if timeRange?.contains(pinned.timestamp) != true {
            self.pinned = nil
        }
    }

    mutating func clear() {
        pinned = nil
    }
}

private struct SystemStatusHUDChartContextOverlay: View {
    let timestamps: [TimeInterval]
    let series: [[Double]]
    let labels: [String]
    let valueFormatter: (Double) -> String
    let rangeLabel: String
    let pinRetentionRange: ClosedRange<TimeInterval>?
    var selectsPrecedingSample = false
    var availability: [Bool]?
    var breaksBefore: [Bool] = []

    @State private var hoverIndex: Int?
    @State private var selection = SystemStatusChartSelection()
    @Environment(\.pluginComponentTheme) private var theme

    private var activeReading: SystemStatusChartSelection.Reading? {
        hoverIndex.flatMap(reading(at:)) ?? selection.pinned
    }

    private var retainedTimeRange: ClosedRange<TimeInterval>? {
        pinRetentionRange ?? SystemStatusHUDChartGeometry.timeRange(timestamps: timestamps)
    }

    private func reading(at index: Int) -> SystemStatusChartSelection.Reading? {
        guard timestamps.indices.contains(index), series.allSatisfy({ $0.indices.contains(index) }),
              availability.map({ $0.indices.contains(index) && $0[index] }) ?? true else {
            return nil
        }
        return .init(timestamp: timestamps[index], values: series.map { $0[index] })
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if
                    let activeReading,
                    let timeRange = retainedTimeRange
                {
                    let x = SystemStatusHUDChartGeometry.x(
                        for: activeReading.timestamp,
                        in: timeRange,
                        width: proxy.size.width
                    )
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                    .stroke(theme.text.secondary.opacity(0.55), lineWidth: 0.75)

                    HStack(spacing: 0) {
                        if x > proxy.size.width / 2 {
                            Spacer(minLength: 0)
                        }

                        Text(contextText(for: activeReading))
                            .font(PluginTypography.caption.font.monospacedDigit())
                            .foregroundStyle(theme.text.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.surfaces.control.opacity(0.98))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(theme.text.tertiary.opacity(0.22), lineWidth: 0.5)
                            )

                        if x <= proxy.size.width / 2 {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.leading, x <= proxy.size.width / 2 ? min(x + 6, 18) : 4)
                    .padding(.trailing, x > proxy.size.width / 2 ? min(proxy.size.width - x + 6, 18) : 4)
                    .padding(.top, 4)
                }

                SystemStatusChartTrackingView(
                    onHoverFractionChange: { fraction in
                        let nextIndex = fraction.flatMap {
                            SystemStatusHUDChartGeometry.nearestIndex(
                                to: $0,
                                timestamps: timestamps,
                                selectsPrecedingSample: selectsPrecedingSample, domain: retainedTimeRange, breaksBefore: breaksBefore
                            )
                        }
                        if hoverIndex != nextIndex {
                            hoverIndex = nextIndex
                        }
                    },
                    onSelectFraction: { fraction in
                        guard let selectedIndex = SystemStatusHUDChartGeometry.nearestIndex(
                            to: fraction,
                            timestamps: timestamps,
                            selectsPrecedingSample: selectsPrecedingSample, domain: retainedTimeRange, breaksBefore: breaksBefore
                        ) else {
                            return
                        }
                        guard let reading = reading(at: selectedIndex) else { return }
                        selection.toggle(reading)
                    }
                )
            }
            .contentShape(Rectangle())
        }
        .allowsHitTesting(true)
        .onChange(of: retainedTimeRange) { expirePinIfNeeded() }
        .onExitCommand { selection.clear() }
    }

    private func expirePinIfNeeded() {
        var updatedSelection = selection
        updatedSelection.expire(outside: retainedTimeRange)
        if updatedSelection != selection {
            selection = updatedSelection
        }
    }

    private func contextText(for reading: SystemStatusChartSelection.Reading) -> String {
        Self.timeFormatter.locale = PluginRuntimeLocalization.locale
        var parts = [Self.timeFormatter.string(from: Date(timeIntervalSince1970: reading.timestamp))]
        for (seriesIndex, value) in reading.values.enumerated() {
            let label = labels.indices.contains(seriesIndex) ? labels[seriesIndex] : ""
            parts.append("\(label)\(valueFormatter(value))")
        }
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SystemStatusChartTrackingView: NSViewRepresentable {
    let onHoverFractionChange: (CGFloat?) -> Void
    let onSelectFraction: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverFractionChange = onHoverFractionChange
        view.onSelectFraction = onSelectFraction
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHoverFractionChange = onHoverFractionChange
        view.onSelectFraction = onSelectFraction
    }

    final class TrackingView: NSView {
        var onHoverFractionChange: ((CGFloat?) -> Void)?
        var onSelectFraction: ((CGFloat) -> Void)?
        private var trackingArea: NSTrackingArea?

        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseEntered(with event: NSEvent) {
            publishHover(event)
        }

        override func mouseMoved(with event: NSEvent) {
            publishHover(event)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverFractionChange?(nil)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onSelectFraction?(fraction(for: event))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        private func publishHover(_ event: NSEvent) {
            onHoverFractionChange?(fraction(for: event))
        }

        private func fraction(for event: NSEvent) -> CGFloat {
            guard bounds.width > 0 else { return 0 }
            let location = convert(event.locationInWindow, from: nil)
            return min(max(location.x / bounds.width, 0), 1)
        }
    }
}
