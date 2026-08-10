import Foundation
import AppKit
import SwiftUI
import MacToolsPluginKit

private enum SystemStatusHUDLayout {
    static let outerPadding: CGFloat = 0
    static let sectionSpacing: CGFloat = SystemStatusComponentLayout.dashboardSectionSpacing
    static let metricSpacing: CGFloat = SystemStatusComponentLayout.cardSpacing
    static let metricTileHeight: CGFloat = SystemStatusComponentLayout.dashboardMetricTileHeight
    static let metricInternalSpacing: CGFloat = 3
    static let metricTitleHeight: CGFloat = 20
    static let metricValueHeight: CGFloat = 19
    static let metricVisualHeight: CGFloat = 22
    static let metricFootnoteHeight: CGFloat = 11
    static let lowerTileHeight: CGFloat = SystemStatusComponentLayout.dashboardLowerTileHeight
    static let processRowHeight: CGFloat = 17
    static let processListSpacing: CGFloat = metricInternalSpacing
    static let processLimit = 3
    static let processListHeight = CGFloat(processLimit) * processRowHeight
        + CGFloat(max(processLimit - 1, 0)) * processListSpacing
    static let chartDisplayInterval: TimeInterval = 30 * 60
    static let chartSampleLimit = 120
}

struct SystemStatusDashboardView: View {
    let snapshot: SystemStatusSnapshot
    let visibleKinds: [SystemStatusMetricKind]
    let localization: PluginLocalization

    private var metricColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: SystemStatusHUDLayout.metricSpacing),
            GridItem(.flexible(), spacing: SystemStatusHUDLayout.metricSpacing)
        ]
    }

    var body: some View {
        Group {
            if visibleRows.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: SystemStatusHUDLayout.sectionSpacing) {
                    ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                        rowView(row)
                    }
                }
            }
        }
        .padding(SystemStatusHUDLayout.outerPadding)
        .frame(
            height: SystemStatusComponentLayout.contentHeight(for: visibleKinds),
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var visibleRows: [SystemStatusComponentRow] {
        SystemStatusComponentLayout.rows(for: visibleKinds)
    }

    @ViewBuilder
    private func rowView(_ row: SystemStatusComponentRow) -> some View {
        switch row {
        case let .metrics(kinds):
            metricRow(kinds)
        case .topProcesses:
            topProcessesSection
        }
    }

    private func metricRow(_ kinds: [SystemStatusMetricKind]) -> some View {
        let visibleHistory = chartHistory
        return LazyVGrid(columns: metricColumns, spacing: SystemStatusHUDLayout.metricSpacing) {
            ForEach(kinds) { kind in
                metricTile(kind, history: visibleHistory)
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
                .foregroundStyle(SystemStatusHUDPalette.textSecondary)

            Text(localization.string("component.empty.title", defaultValue: "未选择显示内容"))
                .font(SystemStatusHUDFont.sans(11, .semibold))
                .foregroundStyle(SystemStatusHUDPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: SystemStatusComponentLayout.emptyContentHeight)
        .background(SystemStatusHUDCardBackground())
    }

    private func cpuTile(history: [SystemStatusHistoryPoint]) -> some View {
        let value = percentParts(snapshot.cpu.usage)
        return SystemStatusHUDValueTile(
            eyebrow: "CPU",
            glyph: "cpu",
            accent: SystemStatusHUDPalette.green,
            chartColor: SystemStatusHUDPalette.green,
            value: value.value,
            unit: value.unit,
            chip: temperatureChip(snapshot.cpu.temperatureCelsius),
            values: percentHistory(\.cpuUsage, fallback: snapshot.cpu.usage, history: history),
            chartStyle: .bars,
            footnote: cpuFootnote
        )
    }

    private func gpuTile(history: [SystemStatusHistoryPoint]) -> some View {
        let value = snapshot.gpu.isAvailable
            ? percentParts(snapshot.gpu.usage)
            : (value: "—", unit: "")
        return SystemStatusHUDValueTile(
            eyebrow: "GPU",
            glyph: "cpu.fill",
            accent: SystemStatusHUDPalette.gpu,
            chartColor: SystemStatusHUDPalette.gpu,
            value: value.value,
            unit: value.unit,
            chip: temperatureChip(snapshot.gpu.temperatureCelsius),
            values: percentHistory(\.gpuUsage, fallback: snapshot.gpu.usage, history: history),
            chartStyle: .bars,
            footnote: gpuFootnote
        )
    }

    private func memoryTile(history: [SystemStatusHistoryPoint]) -> some View {
        let value = percentParts(snapshot.memory.usage)
        return SystemStatusHUDValueTile(
            eyebrow: SystemStatusMetricKind.memory.title(localization: localization),
            glyph: "memorychip",
            accent: SystemStatusHUDPalette.amber,
            chartColor: SystemStatusHUDPalette.amber,
            value: value.value,
            unit: value.unit,
            chip: memoryChip,
            values: percentHistory(\.memoryUsage, fallback: snapshot.memory.usage, history: history),
            chartStyle: .area,
            footnote: memoryFootnote
        )
    }

    private func diskTile(history: [SystemStatusHistoryPoint]) -> some View {
        let rate = rateParts(totalDiskBytesPerSecond)
        let free = bytesParts(diskFreeBytes)
        return SystemStatusHUDDiskTile(
            title: SystemStatusMetricKind.disk.title(localization: localization),
            freeValue: free.value,
            freeUnit: diskAvailableUnit(free.unit),
            totalText: SystemStatusFormatter.bytes(snapshot.disk.totalBytes),
            readText: SystemStatusFormatter.speed(snapshot.disk.readBytesPerSecond),
            writeText: SystemStatusFormatter.speed(snapshot.disk.writeBytesPerSecond),
            readValues: diskReadHistory(history),
            writeValues: diskWriteHistory(history),
            readColor: SystemStatusHUDPalette.diskRead,
            writeColor: SystemStatusHUDPalette.diskWrite
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
        return SystemStatusHUDMetricTile(
            title: SystemStatusMetricKind.network.title(localization: localization),
            glyph: "network",
            accent: SystemStatusHUDPalette.network,
            value: rate.value,
            unit: rate.unit,
            chip: networkChip,
            footnote: nil,
            footer: {
                SystemStatusHUDRateFooter(
                    firstLabel: "↓",
                    firstText: SystemStatusFormatter.speed(snapshot.network.downloadBytesPerSecond),
                    firstColor: SystemStatusHUDPalette.networkDownload,
                    secondLabel: "↑",
                    secondText: SystemStatusFormatter.speed(snapshot.network.uploadBytesPerSecond),
                    secondColor: SystemStatusHUDPalette.networkUpload
                )
            }
        ) {
            SystemStatusHUDRateChart(
                firstValues: networkDownloadHistory(history),
                secondValues: networkUploadHistory(history),
                firstColor: SystemStatusHUDPalette.networkDownload,
                secondColor: SystemStatusHUDPalette.networkUpload
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
        let color = batteryColor
        let value = snapshot.battery.isAvailable
            ? percentParts(snapshot.battery.level)
            : (value: "—", unit: "")

        return SystemStatusHUDValueTile(
            eyebrow: SystemStatusMetricKind.battery.title(localization: localization),
            glyph: "battery.100",
            accent: color,
            chartColor: color,
            value: value.value,
            unit: value.unit,
            chip: temperatureChip(snapshot.battery.temperatureCelsius),
            values: percentHistory(\.batteryLevel, fallback: snapshot.battery.level, history: history),
            chartStyle: .area,
            footnote: batteryFootnote
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            localization.format(
                "accessibility.batteryFormat",
                defaultValue: "电量 %@，%@",
                SystemStatusFormatter.percent(snapshot.battery.level),
                batteryFootnote
            )
        )
    }

    private var topProcessesSection: some View {
        VStack(alignment: .leading, spacing: SystemStatusHUDLayout.metricInternalSpacing) {
            SystemStatusHUDEyebrow(
                text: SystemStatusMetricKind.topProcesses.title(localization: localization),
                glyph: "list.bullet",
                color: SystemStatusHUDPalette.textSecondary
            )
            .frame(height: SystemStatusHUDLayout.metricTitleHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            if snapshot.topProcesses.isEmpty {
                Text(localization.string("topProcesses.collecting", defaultValue: "采集中…"))
                    .font(SystemStatusHUDFont.mono(10))
                    .foregroundStyle(SystemStatusHUDPalette.textSecondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SystemStatusHUDLayout.processListHeight,
                        alignment: .center
                    )
            } else {
                VStack(spacing: SystemStatusHUDLayout.processListSpacing) {
                    ForEach(Array(snapshot.topProcesses.prefix(SystemStatusHUDLayout.processLimit))) { process in
                        SystemStatusHUDProcessRow(process: process, localization: localization)
                    }
                }
                .frame(
                    height: SystemStatusHUDLayout.processListHeight,
                    alignment: .topLeading
                )
            }
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(height: SystemStatusHUDLayout.lowerTileHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SystemStatusHUDCardBackground())
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

    private var memoryChip: (text: String, color: Color)? {
        (SystemStatusFormatter.bytes(snapshot.memory.totalBytes), SystemStatusHUDPalette.badgeText)
    }

    private var networkChip: (text: String, color: Color)? {
        guard let name = snapshot.network.interfaceName, !name.isEmpty else {
            return nil
        }

        return (name, SystemStatusHUDPalette.badgeText)
    }

    private var cpuFootnote: String {
        let uptimeText = localization.format(
            "cpu.footnote.uptimeFormat",
            defaultValue: "开机 %@",
            SystemStatusFormatter.uptime(snapshot.hardware.uptimeSeconds)
        )
        let powerText = localization.format(
            "metric.powerFormat",
            defaultValue: "功率 %@",
            SystemStatusFormatter.power(snapshot.cpu.systemPowerWatts)
        )
        guard let load = snapshot.cpu.loadAverage1Minute else {
            return localization.format(
                "cpu.footnote.loadUnavailableWithUptimeFormat",
                defaultValue: "%@ · 负载 — · %@",
                uptimeText,
                powerText
            )
        }

        return localization.format(
            "cpu.footnote.loadWithUptimeFormat",
            defaultValue: "%@ · 负载 %.2f · %@",
            uptimeText,
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

    private var diskFootnote: String {
        "R \(SystemStatusFormatter.speed(snapshot.disk.readBytesPerSecond)) W \(SystemStatusFormatter.speed(snapshot.disk.writeBytesPerSecond))"
    }

    private var batteryFootnote: String {
        guard snapshot.battery.isAvailable else {
            return snapshot.battery.state.title(localization: localization)
        }

        var parts: [String] = []

        if let batteryPowerText = batteryPowerText {
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
            return SystemStatusHUDPalette.textTertiary
        }

        if snapshot.battery.state == .charging || snapshot.battery.state == .charged || snapshot.battery.state == .acPower {
            return SystemStatusHUDPalette.green
        }

        let level = snapshot.battery.level ?? 0
        if level < 0.15 {
            return SystemStatusHUDPalette.red
        }

        if level < 0.35 {
            return SystemStatusHUDPalette.gold
        }

        return SystemStatusHUDPalette.amber
    }

    private func temperatureChip(_ temperature: Double?) -> (text: String, color: Color)? {
        guard let temperature, temperature > 0 else {
            return nil
        }

        return (SystemStatusFormatter.temperature(temperature), SystemStatusHUDPalette.badgeText)
    }

    private func percentParts(_ value: Double?) -> (value: String, unit: String) {
        guard let value else {
            return ("—", "")
        }

        return (format(value * 100, fractionDigits: 0), "%")
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

    private func percentHistory(
        _ keyPath: KeyPath<SystemStatusHistoryPoint, Double?>,
        fallback: Double?,
        history: [SystemStatusHistoryPoint]
    ) -> [Double] {
        let values = downsample(history.compactMap { point in
            point[keyPath: keyPath].map { min(max($0 * 100, 0), 100) }
        })

        guard values.count <= 1, let fallback else {
            return values
        }

        let value = min(max(fallback * 100, 0), 100)
        return [value, value]
    }

    private func networkDownloadHistory(_ history: [SystemStatusHistoryPoint]) -> [Double] {
        SystemStatusHUDDualLineChart.downsamplePeaks(
            history.map { Double($0.networkDownloadBytesPerSecond ?? 0) },
            limit: SystemStatusHUDLayout.chartSampleLimit
        )
    }

    private func networkUploadHistory(_ history: [SystemStatusHistoryPoint]) -> [Double] {
        SystemStatusHUDDualLineChart.downsamplePeaks(
            history.map { Double($0.networkUploadBytesPerSecond ?? 0) },
            limit: SystemStatusHUDLayout.chartSampleLimit
        )
    }

    private func diskReadHistory(_ history: [SystemStatusHistoryPoint]) -> [Double] {
        SystemStatusHUDDualLineChart.downsamplePeaks(
            history.map { Double($0.diskReadBytesPerSecond ?? 0) },
            limit: SystemStatusHUDLayout.chartSampleLimit
        )
    }

    private func diskWriteHistory(_ history: [SystemStatusHistoryPoint]) -> [Double] {
        SystemStatusHUDDualLineChart.downsamplePeaks(
            history.map { Double($0.diskWriteBytesPerSecond ?? 0) },
            limit: SystemStatusHUDLayout.chartSampleLimit
        )
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

    private func downsample(_ values: [Double], limit: Int = SystemStatusHUDLayout.chartSampleLimit) -> [Double] {
        guard values.count > limit else {
            return values
        }

        let stride = Double(values.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            values[Int((Double(index) * stride).rounded())]
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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 11, height: 11)

            Text(text)
                .font(SystemStatusHUDFont.sans(10, .semibold))
                .foregroundStyle(SystemStatusHUDPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(0)
        }
    }
}

private struct SystemStatusHUDChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(SystemStatusHUDFont.mono(9, .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 7)
            .frame(height: 18, alignment: .center)
            .background(
                Capsule(style: .continuous)
                    .fill(SystemStatusHUDPalette.chipFill)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}

private struct SystemStatusHUDValueTile: View {
    let eyebrow: String
    let glyph: String
    let accent: Color
    let chartColor: Color
    let value: String
    var unit: String = ""
    var chip: (text: String, color: Color)? = nil
    let values: [Double]
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
            SystemStatusHUDMiniChart(values: values, color: chartColor, style: chartStyle)
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
    let chip: (text: String, color: Color)?
    let footnote: String?
    @ViewBuilder let footer: Footer
    @ViewBuilder let visual: Visual

    init(
        title: String,
        glyph: String,
        accent: Color,
        value: String,
        unit: String,
        chip: (text: String, color: Color)?,
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
        chip: (text: String, color: Color)?,
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
                Spacer(minLength: 2)
                if let chip {
                    SystemStatusHUDChip(text: chip.text, color: chip.color)
                        .layoutPriority(1)
                }
            }
                .frame(height: SystemStatusHUDLayout.metricTitleHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(SystemStatusHUDFont.mono(15, .semibold))
                    .foregroundStyle(SystemStatusHUDPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                if !unit.isEmpty {
                    Text(unit)
                        .font(SystemStatusHUDFont.mono(9))
                        .foregroundStyle(SystemStatusHUDPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

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
                    .font(SystemStatusHUDFont.mono(8.5))
                    .foregroundStyle(SystemStatusHUDPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.6)
                    .frame(height: SystemStatusHUDLayout.metricFootnoteHeight, alignment: .leading)
            }
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(height: SystemStatusHUDLayout.metricTileHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(SystemStatusHUDCardBackground())
    }
}

private struct SystemStatusHUDDiskTile: View {
    let title: String
    let freeValue: String
    let freeUnit: String
    let totalText: String
    let readText: String
    let writeText: String
    let readValues: [Double]
    let writeValues: [Double]
    let readColor: Color
    let writeColor: Color

    var body: some View {
        SystemStatusHUDMetricTile(
            title: title,
            glyph: "internaldrive",
            accent: readColor,
            value: freeValue,
            unit: freeUnit,
            chip: (totalText, SystemStatusHUDPalette.badgeText),
            footnote: nil,
            footer: {
                SystemStatusHUDRateFooter(
                    firstLabel: "R",
                    firstText: readText,
                    firstColor: readColor,
                    secondLabel: "W",
                    secondText: writeText,
                    secondColor: writeColor
                )
            }
        ) {
            SystemStatusHUDRateChart(
                firstValues: readValues,
                secondValues: writeValues,
                firstColor: readColor,
                secondColor: writeColor
            )
        }
    }
}

private struct SystemStatusHUDProcessRow: View {
    let process: SystemStatusTopProcess
    let localization: PluginLocalization
    @State private var cachedIcon: NSImage?
    @State private var cachedIconKey: String?

    private var iconKey: String {
        "\(process.pid)|\(process.displayName)|\(process.command)"
    }

    var body: some View {
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
                        .fill(SystemStatusHUDPalette.chipFill)
                    Image(systemName: "app.dashed")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(SystemStatusHUDPalette.textTertiary)
                }
                .frame(width: 15, height: 15)
            }

            Text(process.displayName)
                .font(SystemStatusHUDFont.sans(11))
                .foregroundStyle(SystemStatusHUDPalette.textPrimary)
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
        .frame(height: SystemStatusHUDLayout.processRowHeight)
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
            .font(SystemStatusHUDFont.mono(10))
            .foregroundStyle(SystemStatusHUDPalette.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func resolveIconIfNeeded() {
        guard cachedIconKey != iconKey else {
            return
        }

        cachedIconKey = iconKey
        cachedIcon = Self.processIcon(for: process)
    }

    private static func processIcon(for process: SystemStatusTopProcess) -> NSImage? {
        if let icon = NSRunningApplication(processIdentifier: pid_t(process.pid))?.icon {
            return icon
        }

        if let appPath = appBundlePath(in: process.command) {
            return NSWorkspace.shared.icon(forFile: appPath)
        }

        let commandPath = executablePath(from: process.command)
        if let icon = runningApplicationIcon(matching: commandPath, process: process) {
            return icon
        }

        guard
            commandPath.hasPrefix("/"),
            FileManager.default.fileExists(atPath: commandPath)
        else {
            return nil
        }

        return NSWorkspace.shared.icon(forFile: commandPath)
    }

    private static func runningApplicationIcon(matching commandPath: String, process: SystemStatusTopProcess) -> NSImage? {
        let candidates = [
            process.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            URL(fileURLWithPath: commandPath).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }

        for application in NSWorkspace.shared.runningApplications {
            guard let icon = application.icon else {
                continue
            }

            let applicationNames = [
                application.localizedName,
                application.executableURL?.lastPathComponent
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

            if applicationNames.contains(where: { applicationName in
                candidates.contains(where: { candidate in
                    candidate == applicationName || candidate.hasPrefix("\(applicationName) ")
                })
            }) {
                return icon
            }
        }

        return nil
    }

    private static func executablePath(from command: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCommand.hasPrefix("/") else {
            return trimmedCommand
        }

        if let appRange = trimmedCommand.range(of: ".app/") {
            return String(trimmedCommand[..<trimmedCommand.index(before: appRange.upperBound)])
        }

        if let whitespaceIndex = trimmedCommand.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return String(trimmedCommand[..<whitespaceIndex])
        }

        return trimmedCommand
    }

    private static func appBundlePath(in command: String) -> String? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmedCommand.hasPrefix("/"),
            let appRange = trimmedCommand.range(of: ".app", options: [.caseInsensitive])
        else {
            return nil
        }

        return String(trimmedCommand[..<appRange.upperBound])
    }

    private var processMemoryText: String {
        if let memoryBytes = process.memoryBytes, memoryBytes > 0 {
            return SystemStatusFormatter.bytes(memoryBytes)
        }

        return SystemStatusFormatter.wholePercent(process.memoryPercent, fractionDigits: 1)
    }
}

private struct SystemStatusHUDRateFooter: View {
    private enum Layout {
        static let itemSpacing: CGFloat = 6
        static let itemWidth: CGFloat = 61
        static let labelWidth: CGFloat = 9
        static let valueWidth: CGFloat = 50
    }

    let firstLabel: String
    let firstText: String
    let firstColor: Color
    let secondLabel: String
    let secondText: String
    let secondColor: Color

    var body: some View {
        HStack(spacing: Layout.itemSpacing) {
            rateItem(label: firstLabel, text: firstText, color: firstColor)
            rateItem(label: secondLabel, text: secondText, color: secondColor)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rateItem(label: String, text: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(SystemStatusHUDFont.mono(8.5, .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(width: Layout.labelWidth, alignment: .leading)

            Text(text)
                .font(SystemStatusHUDFont.mono(8.5))
                .foregroundStyle(SystemStatusHUDPalette.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: Layout.valueWidth, alignment: .leading)
        }
        .frame(width: Layout.itemWidth, alignment: .leading)
    }
}

private struct SystemStatusHUDMiniChart: View {
    enum Style {
        case area
        case bars
    }

    let values: [Double]
    let color: Color
    var style: Style = .area

    private var samples: [Double] {
        values.count > 120 ? Array(values.suffix(120)) : values
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let bounds = bounds()
            let denominator = max(bounds.high - bounds.low, 0.0001)

            if samples.count < 2 {
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
        let points = samples.enumerated().map { index, value in
            CGPoint(
                x: width * CGFloat(index) / CGFloat(samples.count - 1),
                y: y(value, height: height, low: low, denominator: denominator)
            )
        }

        return ZStack {
            Path { path in
                guard let first = points.first, let last = points.last else {
                    return
                }

                path.move(to: CGPoint(x: first.x, y: height))
                path.addLine(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.addLine(to: CGPoint(x: last.x, y: height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.30), color.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Path { path in
                guard let first = points.first else {
                    return
                }

                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func bars(width: CGFloat, height: CGFloat, low: Double, denominator: Double) -> some View {
        let count = max(samples.count, 1)
        let slot = width / CGFloat(count)
        let barWidth = max(1.5, slot * 0.62)

        return Path { path in
            for (index, value) in samples.enumerated() {
                let barHeight = max(1.5, CGFloat((value - low) / denominator) * height)
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                path.addRoundedRect(
                    in: CGRect(x: x, y: height - barHeight, width: barWidth, height: barHeight),
                    cornerSize: CGSize(width: 1, height: 1),
                    style: .continuous
                )
            }
        }
        .fill(color.opacity(0.85))
    }

    private func bounds() -> (low: Double, high: Double) {
        let low = min(samples.min() ?? 0, 0)
        let high = samples.max() ?? 1
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

    static func scaledRatio(value: Double, maximumValue: Double) -> CGFloat {
        let normalized = min(max(value / max(maximumValue, 0.0001), 0), 1)
        return CGFloat(sqrt(normalized))
    }
}

private struct SystemStatusHUDRateChart: View {
    let firstValues: [Double]
    let secondValues: [Double]
    let firstColor: Color
    let secondColor: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let firstSeries = firstValues.map { max($0, 0) }
            let secondSeries = secondValues.map { max($0, 0) }
            let firstMaximum = firstSeries.max() ?? 0
            let secondMaximum = secondSeries.max() ?? 0

            if max(firstMaximum, secondMaximum) <= 0 || (firstSeries.count < 2 && secondSeries.count < 2) {
                Color.clear
            } else {
                ZStack {
                    series(
                        values: firstSeries,
                        width: width,
                        height: height,
                        maximumValue: firstMaximum,
                        color: firstColor
                    )
                    series(
                        values: secondSeries,
                        width: width,
                        height: height,
                        maximumValue: secondMaximum,
                        color: secondColor
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func series(
        values: [Double],
        width: CGFloat,
        height: CGFloat,
        maximumValue: Double,
        color: Color
    ) -> some View {
        if values.count >= 2 {
            let points = SystemStatusHUDDualLineChart.points(
                values: values,
                width: width,
                height: height,
                maximumValue: maximumValue
            )

            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else {
                        return
                    }

                    path.move(to: CGPoint(x: first.x, y: height))
                    path.addLine(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                    path.addLine(to: CGPoint(x: last.x, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.30), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard let first = points.first else {
                        return
                    }

                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct SystemStatusHUDCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SystemStatusHUDPalette.cardFill)
    }
}

private enum SystemStatusHUDPalette {
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color.secondary.opacity(0.72)

    static let cardFill = Color.primary.opacity(0.045)
    static let chipFill = Color.primary.opacity(0.06)
    static let badgeText = textSecondary

    static let green = Color(nsColor: .systemGreen)
    static let gold = Color(nsColor: .systemYellow)
    static let amber = Color(nsColor: .systemOrange)
    static let orange = Color(nsColor: .systemOrange)
    static let blue = Color(nsColor: .systemBlue)
    static let red = Color(nsColor: .systemRed)

    static let gpu = Color(red: 0.949, green: 0.537, blue: 0.306)
    static let network = Color(red: 0.180, green: 0.690, blue: 0.659)
    static let networkDownload = Color(red: 0.204, green: 0.596, blue: 0.859)
    static let networkUpload = Color(red: 0.941, green: 0.467, blue: 0.294)
    static let diskRead = Color(red: 0.275, green: 0.588, blue: 0.941)
    static let diskWrite = Color(red: 0.608, green: 0.431, blue: 0.902)
}

private enum SystemStatusHUDFont {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
