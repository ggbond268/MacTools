import Foundation
import MacToolsPluginKit
import SwiftUI

enum SystemStatusMemoryPressure: Int, Codable, CaseIterable, Sendable {
    // The sysctl exports dispatch flags, not XNU's internal pressure enum.
    case normal = 1
    case warning = 2
    case critical = 4

    // A constrained-memory proxy, independent of the kernel's pressure verdict.
    // Count current compressor storage, never lifetime compression events or
    // the uncompressed size of pages stored in the compressor.
    static func estimatedPercentage(
        wiredPages: UInt32, compressorPages: UInt32, pageSize: UInt64, totalBytes: UInt64
    ) -> Double? {
        guard pageSize > 0, totalBytes > 0 else { return nil }
        let constrainedBytes = (Double(wiredPages) + Double(compressorPages)) * Double(pageSize)
        return min(max(constrainedBytes / Double(totalBytes) * 100, 0), 100)
    }

    static func estimateDescription(localization: PluginLocalization) -> String {
        localization.string("memory.pressure.estimateHelp",
            defaultValue: "按（联动内存 + 压缩内存实际占用）÷ 物理内存估算；颜色表示系统压力等级。")
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .normal: localization.string("memory.pressure.normal", defaultValue: "正常")
        case .warning: localization.string("memory.pressure.warning", defaultValue: "偏高")
        case .critical: localization.string("memory.pressure.critical", defaultValue: "严重")
        }
    }

    func color(theme: PluginComponentTheme) -> Color {
        switch self {
        case .normal: theme.status.success
        case .warning: theme.status.warning
        case .critical: theme.status.critical
        }
    }
}

extension SystemStatusHistoryPoint {
    var validMemoryPressurePercent: Double? {
        guard let value = memoryPressurePercent, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
}

enum SystemStatusMemoryPressureHistory {
    // Keep actual observations and their timestamps. Extrema describe the
    // percentage; the most severe native reading retains its independent color.
    static func samples(
        _ history: [SystemStatusHistoryPoint], limit: Int = 120
    ) -> [SystemStatusHUDChartSample] {
        guard limit > 0, !history.isEmpty else { return [] }
        let raw = history.enumerated().map { index, point in
            SystemStatusHUDChartSample(timestamp: point.timestamp, value: point.validMemoryPressurePercent ?? 0,
                isAvailable: point.validMemoryPressurePercent != nil,
                startsNewSegment: index > 0 && point.collectionID != history[index - 1].collectionID,
                pressure: point.memoryPressure)
        }
        guard raw.count > limit else { return raw }
        let bucketSize = max(1, Int(ceil(Double(raw.count) / Double(max(1, limit / 6)))))
        var indices: [Int] = []
        for start in stride(from: 0, to: raw.count, by: bucketSize) {
            let end = min(start + bucketSize, raw.count)
            let valid = (start..<end).filter { raw[$0].isAvailable }
            var selected = [start, end - 1]
            if let low = valid.min(by: { raw[$0].value < raw[$1].value }) { selected.append(low) }
            if let high = valid.max(by: { raw[$0].value < raw[$1].value }) { selected.append(high) }
            if let severe = valid.max(by: { (raw[$0].pressure?.rawValue ?? 0) < (raw[$1].pressure?.rawValue ?? 0) }) {
                selected.append(severe)
            }
            if let gap = (start..<end).first(where: { !raw[$0].isAvailable }) { selected.append(gap) }
            // Keep state transitions even when they exceed the value-sampling
            // budget, so a brief critical state cannot color a later normal run.
            for index in start..<end where index > 0 && raw[index].pressure != raw[index - 1].pressure {
                if index > start { selected.append(index - 1) }
                selected.append(index)
            }
            indices.append(contentsOf: Set(selected).sorted())
        }
        var previous = -1
        return indices.map { index in
            var sample = raw[index]
            // Never bridge a missing reading or session discarded by downsampling.
            if previous >= 0, index > previous {
                sample.startsNewSegment = sample.startsNewSegment
                    || raw[(previous + 1)...index].contains { $0.startsNewSegment || !$0.isAvailable }
                    || !raw[previous].isAvailable
            }
            previous = index
            return sample
        }
    }
}
