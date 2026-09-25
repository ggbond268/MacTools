import Foundation
import MacToolsPluginKit

enum SystemStatusChartMetric: String, Codable, CaseIterable, Sendable {
    case usage, pressure, activity, level

    static func available(for kind: SystemStatusMetricKind) -> [Self] {
        switch kind {
        case .cpu, .gpu: [.usage]
        case .memory: [.usage, .pressure]
        case .disk, .network: [.activity]
        case .battery: [.level]
        case .topProcesses: []
        }
    }

    static func defaultMetric(for kind: SystemStatusMetricKind) -> Self {
        available(for: kind).first ?? .usage
    }

    func title(localization: PluginLocalization) -> String {
        if self == .pressure { return localization.string("memory.pressure.title", defaultValue: "压力") }
        if self == .activity {
            return localization.string("settings.chartMetric.transfer", defaultValue: "传输速率")
        }
        return SystemStatusMenuBarValueKind(rawValue: rawValue)?.title(localization: localization) ?? "—"
    }

    func value(in point: SystemStatusHistoryPoint, kind: SystemStatusMetricKind) -> Double? {
        let value: Double?
        switch (kind, self) {
        case (.cpu, .usage): value = point.cpuUsage.map { $0 * 100 }
        case (.gpu, .usage): value = point.gpuUsage.map { $0 * 100 }
        case (.memory, .usage): value = point.memoryUsage.map { $0 * 100 }
        case (.memory, .pressure): value = point.validMemoryPressurePercent
        case (.disk, .activity): value = Self.total(point.diskReadBytesPerSecond, point.diskWriteBytesPerSecond)
        case (.network, .activity): value = Self.total(point.networkDownloadBytesPerSecond, point.networkUploadBytesPerSecond)
        case (.battery, .level): value = point.batteryLevel.map { $0 * 100 }
        default: value = nil
        }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }

    func value(in snapshot: SystemStatusSnapshot, kind: SystemStatusMetricKind) -> Double? {
        value(in: SystemStatusHistoryPoint(timestamp: 0, snapshot: snapshot), kind: kind)
    }

    func parts(_ value: Double?, localization: PluginLocalization) -> (value: String, unit: String) {
        guard let value, value.isFinite else { return ("—", "") }
        switch self {
        case .usage, .level, .pressure: return (String(format: "%.0f", value), "%")
        case .activity:
            let bytes = UInt64(min(max(value, 0), Double(UInt64.max).nextDown))
            let formatted = SystemStatusFormatter.speed(bytes)
            let pieces = formatted.split(separator: " ")
            guard pieces.count > 1, let unit = pieces.last else { return (formatted, "") }
            return (pieces.dropLast().joined(separator: " "), String(unit))
        }
    }

    func format(_ value: Double?, localization: PluginLocalization) -> String {
        let parts = parts(value, localization: localization)
        let separator = parts.unit.isEmpty || parts.unit == "%" ? "" : " "
        return parts.value + separator + parts.unit
    }

    private static func total(_ first: UInt64?, _ second: UInt64?) -> Double? {
        guard first != nil || second != nil else { return nil }
        return Double(first ?? 0) + Double(second ?? 0)
    }
}
