import Foundation

enum SystemStatusMetricKind: String, CaseIterable, Equatable, Sendable {
    case cpu
    case memory
    case disk
    case battery
    case network
    case topProcesses

    var title: String {
        switch self {
        case .cpu:
            return "CPU"
        case .memory:
            return "内存"
        case .disk:
            return "磁盘"
        case .battery:
            return "电量"
        case .network:
            return "网络"
        case .topProcesses:
            return "进程"
        }
    }
}

struct SystemStatusGridPosition: Equatable, Sendable {
    let row: Int
    let column: Int
}

enum SystemStatusComponentLayout {
    static let columns = 4
    static let rows = 2
    static let orderedMetricKinds: [SystemStatusMetricKind] = [
        .cpu,
        .memory,
        .disk,
        .battery,
        .network,
        .topProcesses
    ]

    static func position(for metric: SystemStatusMetricKind) -> SystemStatusGridPosition? {
        guard let index = orderedMetricKinds.firstIndex(of: metric) else {
            return nil
        }

        return SystemStatusGridPosition(
            row: index < columns ? 0 : 1,
            column: index < columns ? index : (index - columns) * 2
        )
    }
}

struct SystemStatusSnapshot: Equatable, Sendable {
    var cpu: SystemStatusCPUSnapshot
    var memory: SystemStatusMemorySnapshot
    var disk: SystemStatusDiskSnapshot
    var battery: SystemStatusBatterySnapshot
    var network: SystemStatusNetworkSnapshot
    var topProcesses: [SystemStatusTopProcess]

    static let empty = SystemStatusSnapshot(
        cpu: .empty,
        memory: .empty,
        disk: .empty,
        battery: .empty,
        network: .empty,
        topProcesses: []
    )
}

struct SystemStatusFastSample: Equatable, Sendable {
    let cpu: SystemStatusCPUSnapshot
    let memory: SystemStatusMemorySnapshot
    let network: SystemStatusNetworkSnapshot
}

struct SystemStatusSlowSample: Equatable, Sendable {
    let disk: SystemStatusDiskSnapshot
    let battery: SystemStatusBatterySnapshot
}

struct SystemStatusCPUSnapshot: Equatable, Sendable {
    let usage: Double?
    let temperatureCelsius: Double?
    let systemPowerWatts: Double?
    let isCollecting: Bool

    static let empty = SystemStatusCPUSnapshot(
        usage: nil,
        temperatureCelsius: nil,
        systemPowerWatts: nil,
        isCollecting: true
    )
}

struct SystemStatusMemorySnapshot: Equatable, Sendable {
    let usedBytes: UInt64?
    let totalBytes: UInt64?

    var usage: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else {
            return nil
        }

        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static let empty = SystemStatusMemorySnapshot(
        usedBytes: nil,
        totalBytes: nil
    )
}

struct SystemStatusDiskSnapshot: Equatable, Sendable {
    let usedBytes: UInt64?
    let totalBytes: UInt64?

    var usage: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else {
            return nil
        }

        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static let empty = SystemStatusDiskSnapshot(
        usedBytes: nil,
        totalBytes: nil
    )
}

enum SystemStatusBatteryState: Equatable, Sendable {
    case charging
    case charged
    case unplugged
    case acPower
    case unavailable
    case unknown

    var title: String {
        switch self {
        case .charging:
            return "充电中"
        case .charged:
            return "已充满"
        case .unplugged:
            return "使用电池"
        case .acPower:
            return "外接电源"
        case .unavailable:
            return "无电池"
        case .unknown:
            return "未知"
        }
    }
}

struct SystemStatusBatterySnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let level: Double?
    let state: SystemStatusBatteryState
    let timeRemainingMinutes: Int?
    let adapterWatts: Int?
    let temperatureCelsius: Double?
    let healthPercent: Int?

    static let empty = SystemStatusBatterySnapshot(
        isAvailable: false,
        level: nil,
        state: .unknown,
        timeRemainingMinutes: nil,
        adapterWatts: nil,
        temperatureCelsius: nil,
        healthPercent: nil
    )
}

struct SystemStatusNetworkSnapshot: Equatable, Sendable {
    let interfaceName: String?
    let ipAddress: String?
    let publicIPAddress: String?
    let downloadBytesPerSecond: UInt64?
    let uploadBytesPerSecond: UInt64?
    let isConnected: Bool
    let isCollecting: Bool

    static let empty = SystemStatusNetworkSnapshot(
        interfaceName: nil,
        ipAddress: nil,
        publicIPAddress: nil,
        downloadBytesPerSecond: nil,
        uploadBytesPerSecond: nil,
        isConnected: false,
        isCollecting: true
    )

    func replacingPublicIPAddress(_ publicIPAddress: String?) -> SystemStatusNetworkSnapshot {
        SystemStatusNetworkSnapshot(
            interfaceName: interfaceName,
            ipAddress: ipAddress,
            publicIPAddress: publicIPAddress,
            downloadBytesPerSecond: downloadBytesPerSecond,
            uploadBytesPerSecond: uploadBytesPerSecond,
            isConnected: isConnected,
            isCollecting: isCollecting
        )
    }
}

struct SystemStatusTopProcess: Identifiable, Equatable, Sendable {
    let pid: Int
    let displayName: String
    let command: String
    let cpuPercent: Double
    let memoryPercent: Double

    var id: Int { pid }

    func replacingDisplayName(_ displayName: String) -> SystemStatusTopProcess {
        SystemStatusTopProcess(
            pid: pid,
            displayName: displayName,
            command: command,
            cpuPercent: cpuPercent,
            memoryPercent: memoryPercent
        )
    }
}

struct SystemStatusCPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

enum SystemStatusCPUUsageCalculator {
    static func usage(current: SystemStatusCPUTicks, previous: SystemStatusCPUTicks) -> Double? {
        let user = positiveDelta(current.user, previous.user)
        let system = positiveDelta(current.system, previous.system)
        let idle = positiveDelta(current.idle, previous.idle)
        let nice = positiveDelta(current.nice, previous.nice)
        let active = user + system + nice
        let total = active + idle

        guard total > 0 else {
            return nil
        }

        return min(max(Double(active) / Double(total), 0), 1)
    }

    private static func positiveDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

enum SystemStatusPowerNormalizer {
    static func systemPowerWatts(fromMilliwatts milliwatts: Double) -> Double? {
        guard milliwatts >= 0, milliwatts < 1_000_000 else {
            return nil
        }

        return milliwatts / 1_000
    }
}

struct SystemStatusNetworkCounter: Equatable, Sendable {
    let key: String
    let displayName: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let ipAddress: String?
    let isUp: Bool
}

struct SystemStatusNetworkRate: Equatable, Sendable {
    let downloadBytesPerSecond: UInt64
    let uploadBytesPerSecond: UInt64
}

enum SystemStatusNetworkRateCalculator {
    static func rate(
        current: SystemStatusNetworkCounter,
        previous: SystemStatusNetworkCounter,
        elapsedSeconds: TimeInterval
    ) -> SystemStatusNetworkRate? {
        guard elapsedSeconds > 0 else {
            return nil
        }

        let receivedDelta = positiveDelta(current.receivedBytes, previous.receivedBytes)
        let sentDelta = positiveDelta(current.sentBytes, previous.sentBytes)

        return SystemStatusNetworkRate(
            downloadBytesPerSecond: UInt64(Double(receivedDelta) / elapsedSeconds),
            uploadBytesPerSecond: UInt64(Double(sentDelta) / elapsedSeconds)
        )
    }

    private static func positiveDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

enum SystemStatusFormatter {
    static func percent(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value else {
            return "—"
        }

        return numericPercent(value * 100, fractionDigits: fractionDigits)
    }

    static func wholePercent(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value else {
            return "—"
        }

        return numericPercent(value, fractionDigits: fractionDigits)
    }

    static func bytes(_ bytes: UInt64?) -> String {
        guard let bytes else {
            return "—"
        }

        return scaledBytes(bytes)
    }

    static func speed(_ bytesPerSecond: UInt64?) -> String {
        guard let bytesPerSecond else {
            return "—"
        }

        return "\(scaledBytes(bytesPerSecond))/s"
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else {
            return "—℃"
        }

        return "\(format(celsius, fractionDigits: 0))℃"
    }

    static func power(_ watts: Double?) -> String {
        guard let watts else {
            return "—W"
        }

        let fractionDigits = watts < 10 ? 1 : 0
        return "\(format(watts, fractionDigits: fractionDigits))W"
    }

    static func timeRemaining(minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else {
            return "估算中"
        }

        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        guard remainingMinutes > 0 else {
            return "\(hours)h"
        }

        return "\(hours)h \(remainingMinutes)m"
    }

    private static func numericPercent(_ value: Double, fractionDigits: Int) -> String {
        let clampedFractionDigits = max(fractionDigits, 0)
        return "\(format(value, fractionDigits: clampedFractionDigits))%"
    }

    private static func scaledBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let fractionDigits = unitIndex == 0 || value >= 100 ? 0 : 1
        return "\(format(value, fractionDigits: fractionDigits)) \(units[unitIndex])"
    }

    private static func format(_ value: Double, fractionDigits: Int) -> String {
        if fractionDigits == 0 {
            return String(Int(value.rounded()))
        }

        return String(format: "%.\(fractionDigits)f", value)
    }
}
