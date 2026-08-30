import Foundation
import MacToolsPluginKit

enum SystemStatusMetricKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case cpu
    case gpu
    case memory
    case disk
    case battery
    case network
    case topProcesses

    var id: String { rawValue }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .memory:
            return localization.string("metric.memory", defaultValue: "内存")
        case .disk:
            return localization.string("metric.disk", defaultValue: "磁盘")
        case .battery:
            return localization.string("metric.battery", defaultValue: "电量")
        case .network:
            return localization.string("metric.network", defaultValue: "网络")
        case .topProcesses:
            return localization.string("metric.topProcesses", defaultValue: "进程")
        }
    }

    var symbolName: String {
        switch self {
        case .cpu:
            return "cpu"
        case .gpu:
            return "display"
        case .memory:
            return "memorychip"
        case .disk:
            return "internaldrive"
        case .battery:
            return "battery.75percent"
        case .network:
            return "wifi"
        case .topProcesses:
            return "list.bullet.rectangle"
        }
    }
}

enum SystemStatusMenuBarValueKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case usage
    case temperature
    case power
    case load
    case used
    case swap
    case free
    case read
    case write
    case activity
    case download
    case upload
    case throughput
    case level
    case timeRemaining
    case state

    var id: String { rawValue }

    static func availableValues(for metric: SystemStatusMetricKind) -> [SystemStatusMenuBarValueKind] {
        switch metric {
        case .cpu:
            return [.usage, .temperature, .power, .load]
        case .gpu:
            return [.usage, .temperature]
        case .memory:
            return [.usage, .used, .swap]
        case .disk:
            return [.free, .usage, .read, .write, .activity]
        case .battery:
            return [.level, .power, .timeRemaining, .temperature, .state]
        case .network:
            return [.download, .upload, .throughput]
        case .topProcesses:
            return []
        }
    }

    static func defaultValues(for metric: SystemStatusMetricKind) -> [SystemStatusMenuBarValueKind] {
        switch metric {
        case .cpu, .gpu:
            return [.usage, .temperature]
        case .memory:
            return [.usage, .used]
        case .disk:
            return [.free, .activity]
        case .battery:
            return [.level, .power]
        case .network:
            return [.download, .upload]
        case .topProcesses:
            return []
        }
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .usage:
            return localization.string("settings.menuBarValue.usage", defaultValue: "使用率")
        case .temperature:
            return localization.string("settings.menuBarValue.temperature", defaultValue: "温度")
        case .power:
            return localization.string("settings.menuBarValue.power", defaultValue: "功率")
        case .load:
            return localization.string("settings.menuBarValue.load", defaultValue: "1 分钟负载")
        case .used:
            return localization.string("settings.menuBarValue.used", defaultValue: "已用")
        case .swap:
            return localization.string("settings.menuBarValue.swap", defaultValue: "交换空间")
        case .free:
            return localization.string("settings.menuBarValue.free", defaultValue: "可用空间")
        case .read:
            return localization.string("settings.menuBarValue.read", defaultValue: "读取速率")
        case .write:
            return localization.string("settings.menuBarValue.write", defaultValue: "写入速率")
        case .activity:
            return localization.string("settings.menuBarValue.activity", defaultValue: "读写活动")
        case .download:
            return localization.string("settings.menuBarValue.download", defaultValue: "下载速率")
        case .upload:
            return localization.string("settings.menuBarValue.upload", defaultValue: "上传速率")
        case .throughput:
            return localization.string("settings.menuBarValue.throughput", defaultValue: "总速率")
        case .level:
            return localization.string("settings.menuBarValue.level", defaultValue: "电量")
        case .timeRemaining:
            return localization.string("settings.menuBarValue.timeRemaining", defaultValue: "剩余时间")
        case .state:
            return localization.string("settings.menuBarValue.state", defaultValue: "电源状态")
        }
    }
}

enum SystemStatusProcessSort: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case cpu
    case memory

    var id: String { rawValue }
}

struct SystemStatusGridPosition: Equatable, Sendable {
    let row: Int
    let column: Int
}

enum SystemStatusComponentRow: Equatable, Sendable {
    case metrics([SystemStatusMetricKind])
    case topProcesses
}

enum SystemStatusComponentLayout {
    static let cardCornerRadius = PluginComponentPanelLayoutMetrics.cardCornerRadius
    static let cardSpacing: CGFloat = 6
    static let cardContentPadding: CGFloat = 8
    static let columns = 2
    static let metricRows = 3

    static let dashboardSectionSpacing: CGFloat = cardSpacing
    static let dashboardMetricTileHeight: CGFloat = 82
    static let dashboardLowerTileHeight: CGFloat = 96
    static let dashboardMetricGridHeight = CGFloat(metricRows) * dashboardMetricTileHeight
        + CGFloat(max(metricRows - 1, 0)) * cardSpacing
    static let emptyContentHeight = dashboardLowerTileHeight
    static let dashboardContentHeight = contentHeight(for: defaultPanelMetricKinds)

    static let defaultPanelMetricKinds: [SystemStatusMetricKind] = [
        .cpu,
        .gpu,
        .network,
        .disk,
        .memory,
        .battery,
        .topProcesses
    ]

    static let defaultMenuBarMetricKinds: [SystemStatusMetricKind] = [
        .cpu,
        .gpu,
        .network,
        .disk,
        .memory,
        .battery
    ]

    static func position(for metric: SystemStatusMetricKind) -> SystemStatusGridPosition? {
        let metricKinds = defaultPanelMetricKinds.filter { $0 != .topProcesses }
        guard let index = metricKinds.firstIndex(of: metric) else {
            return nil
        }

        return SystemStatusGridPosition(
            row: index / columns,
            column: index % columns
        )
    }

    static func rows(for kinds: [SystemStatusMetricKind]) -> [SystemStatusComponentRow] {
        var rows: [SystemStatusComponentRow] = []
        var pendingMetrics: [SystemStatusMetricKind] = []

        func flushPendingMetrics() {
            guard !pendingMetrics.isEmpty else {
                return
            }

            rows.append(.metrics(pendingMetrics))
            pendingMetrics.removeAll(keepingCapacity: true)
        }

        for kind in kinds {
            if kind == .topProcesses {
                flushPendingMetrics()
                rows.append(.topProcesses)
                continue
            }

            pendingMetrics.append(kind)
            if pendingMetrics.count == columns {
                flushPendingMetrics()
            }
        }

        flushPendingMetrics()
        return rows
    }

    static func contentHeight(for kinds: [SystemStatusMetricKind]) -> CGFloat {
        let rows = rows(for: kinds)
        guard !rows.isEmpty else {
            return emptyContentHeight
        }

        let rowHeight = rows.reduce(CGFloat(0)) { partialResult, row in
            switch row {
            case .metrics:
                return partialResult + dashboardMetricTileHeight
            case .topProcesses:
                return partialResult + dashboardLowerTileHeight
            }
        }
        let spacing = CGFloat(max(rows.count - 1, 0)) * dashboardSectionSpacing
        return rowHeight + spacing
    }
}

struct SystemStatusSnapshot: Equatable, Sendable {
    var cpu: SystemStatusCPUSnapshot
    var gpu: SystemStatusGPUSnapshot
    var memory: SystemStatusMemorySnapshot
    var disk: SystemStatusDiskSnapshot
    var battery: SystemStatusBatterySnapshot
    var network: SystemStatusNetworkSnapshot
    var topProcesses: [SystemStatusTopProcess]
    var hardware: SystemStatusHardwareSnapshot
    var history: [SystemStatusHistoryPoint]

    static let empty = SystemStatusSnapshot(
        cpu: .empty,
        gpu: .empty,
        memory: .empty,
        disk: .empty,
        battery: .empty,
        network: .empty,
        topProcesses: [],
        hardware: .empty,
        history: []
    )
}

struct SystemStatusFastSample: Equatable, Sendable {
    let cpu: SystemStatusCPUSnapshot
    let memory: SystemStatusMemorySnapshot
    let network: SystemStatusNetworkSnapshot
    let disk: SystemStatusDiskSnapshot
}

struct SystemStatusSlowSample: Equatable, Sendable {
    let disk: SystemStatusDiskSnapshot
    let battery: SystemStatusBatterySnapshot
    let gpu: SystemStatusGPUSnapshot
    let hardware: SystemStatusHardwareSnapshot
}

struct SystemStatusCPUSnapshot: Equatable, Sendable {
    let usage: Double?
    let loadAverage1Minute: Double?
    let temperatureCelsius: Double?
    let systemPowerWatts: Double?
    let isCollecting: Bool

    static let empty = SystemStatusCPUSnapshot(
        usage: nil,
        loadAverage1Minute: nil,
        temperatureCelsius: nil,
        systemPowerWatts: nil,
        isCollecting: true
    )
}

struct SystemStatusGPUSnapshot: Equatable, Sendable {
    let usage: Double?
    let name: String?
    let temperatureCelsius: Double?
    let isAvailable: Bool
    let isCollecting: Bool

    static let empty = SystemStatusGPUSnapshot(
        usage: nil,
        name: nil,
        temperatureCelsius: nil,
        isAvailable: false,
        isCollecting: true
    )
}

struct SystemStatusMemorySnapshot: Equatable, Sendable {
    let usedBytes: UInt64?
    let totalBytes: UInt64?
    let swapUsedBytes: UInt64?
    let swapTotalBytes: UInt64?

    var usage: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else {
            return nil
        }

        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static let empty = SystemStatusMemorySnapshot(
        usedBytes: nil,
        totalBytes: nil,
        swapUsedBytes: nil,
        swapTotalBytes: nil
    )
}

struct SystemStatusDiskSnapshot: Equatable, Sendable {
    let usedBytes: UInt64?
    let totalBytes: UInt64?
    let readBytesPerSecond: UInt64?
    let writeBytesPerSecond: UInt64?

    var usage: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else {
            return nil
        }

        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static let empty = SystemStatusDiskSnapshot(
        usedBytes: nil,
        totalBytes: nil,
        readBytesPerSecond: nil,
        writeBytesPerSecond: nil
    )

    func replacingActivity(from disk: SystemStatusDiskSnapshot) -> SystemStatusDiskSnapshot {
        SystemStatusDiskSnapshot(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            readBytesPerSecond: disk.readBytesPerSecond,
            writeBytesPerSecond: disk.writeBytesPerSecond
        )
    }

    func replacingCapacity(from disk: SystemStatusDiskSnapshot) -> SystemStatusDiskSnapshot {
        SystemStatusDiskSnapshot(
            usedBytes: disk.usedBytes,
            totalBytes: disk.totalBytes,
            readBytesPerSecond: readBytesPerSecond,
            writeBytesPerSecond: writeBytesPerSecond
        )
    }
}

enum SystemStatusBatteryState: Equatable, Sendable {
    case charging
    case charged
    case unplugged
    case acPower
    case unavailable
    case unknown

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .charging:
            return localization.string("battery.state.charging", defaultValue: "充电中")
        case .charged:
            return localization.string("battery.state.charged", defaultValue: "已充满")
        case .unplugged:
            return localization.string("battery.state.unplugged", defaultValue: "使用电池")
        case .acPower:
            return localization.string("battery.state.acPower", defaultValue: "外接电源")
        case .unavailable:
            return localization.string("battery.state.unavailable", defaultValue: "无电池")
        case .unknown:
            return localization.string("battery.state.unknown", defaultValue: "未知")
        }
    }
}

struct SystemStatusBatterySnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let level: Double?
    let state: SystemStatusBatteryState
    let timeRemainingMinutes: Int?
    let adapterWatts: Int?
    let batteryPowerWatts: Double?
    let temperatureCelsius: Double?
    let healthPercent: Int?
    let cycleCount: Int?

    static let empty = SystemStatusBatterySnapshot(
        isAvailable: false,
        level: nil,
        state: .unknown,
        timeRemainingMinutes: nil,
        adapterWatts: nil,
        batteryPowerWatts: nil,
        temperatureCelsius: nil,
        healthPercent: nil,
        cycleCount: nil
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
    let memoryBytes: UInt64?

    var id: Int { pid }

    func replacingDisplayName(_ displayName: String) -> SystemStatusTopProcess {
        SystemStatusTopProcess(
            pid: pid,
            displayName: displayName,
            command: command,
            cpuPercent: cpuPercent,
            memoryPercent: memoryPercent,
            memoryBytes: memoryBytes
        )
    }
}

struct SystemStatusHardwareSnapshot: Equatable, Sendable {
    let modelName: String?
    let chipName: String?
    let macOSVersion: String
    let uptimeSeconds: TimeInterval?
    let totalMemoryBytes: UInt64?

    static let empty = SystemStatusHardwareSnapshot(
        modelName: nil,
        chipName: nil,
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        uptimeSeconds: nil,
        totalMemoryBytes: nil
    )

    func replacingUptime(_ uptimeSeconds: TimeInterval?) -> SystemStatusHardwareSnapshot {
        SystemStatusHardwareSnapshot(
            modelName: modelName,
            chipName: chipName,
            macOSVersion: macOSVersion,
            uptimeSeconds: uptimeSeconds,
            totalMemoryBytes: totalMemoryBytes
        )
    }
}

struct SystemStatusHistoryPoint: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let cpuUsage: Double?
    let gpuUsage: Double?
    let memoryUsage: Double?
    let diskUsage: Double?
    let diskReadBytesPerSecond: UInt64?
    let diskWriteBytesPerSecond: UInt64?
    let networkDownloadBytesPerSecond: UInt64?
    let networkUploadBytesPerSecond: UInt64?
    let batteryLevel: Double?

    init(timestamp: TimeInterval, snapshot: SystemStatusSnapshot) {
        self.timestamp = timestamp
        self.cpuUsage = snapshot.cpu.usage
        self.gpuUsage = snapshot.gpu.usage
        self.memoryUsage = snapshot.memory.usage
        self.diskUsage = snapshot.disk.usage
        self.diskReadBytesPerSecond = snapshot.disk.readBytesPerSecond
        self.diskWriteBytesPerSecond = snapshot.disk.writeBytesPerSecond
        self.networkDownloadBytesPerSecond = snapshot.network.downloadBytesPerSecond
        self.networkUploadBytesPerSecond = snapshot.network.uploadBytesPerSecond
        self.batteryLevel = snapshot.battery.level
    }

    init(
        timestamp: TimeInterval,
        cpuUsage: Double? = nil,
        gpuUsage: Double? = nil,
        memoryUsage: Double? = nil,
        diskUsage: Double? = nil,
        diskReadBytesPerSecond: UInt64? = nil,
        diskWriteBytesPerSecond: UInt64? = nil,
        networkDownloadBytesPerSecond: UInt64? = nil,
        networkUploadBytesPerSecond: UInt64? = nil,
        batteryLevel: Double? = nil
    ) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsage = memoryUsage
        self.diskUsage = diskUsage
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkDownloadBytesPerSecond = networkDownloadBytesPerSecond
        self.networkUploadBytesPerSecond = networkUploadBytesPerSecond
        self.batteryLevel = batteryLevel
    }
}

struct SystemStatusHistoryDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var samples: [SystemStatusHistoryPoint]
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
    static func energyJoules(from value: Double, unit: String) -> Double? {
        switch unit {
        case "mJ":
            return value / 1_000
        case "uJ":
            return value / 1_000_000
        case "nJ":
            return value / 1_000_000_000
        default:
            return nil
        }
    }
}

enum SystemStatusBatteryPowerNormalizer {
    static func telemetryWatts(fromRawMilliwatts rawValue: Any?) -> Double? {
        telemetryWatts(fromMilliwatts: signedNumberValue(rawValue))
    }

    static func telemetryWatts(fromMilliwatts milliwatts: Double?) -> Double? {
        guard let milliwatts, milliwatts.isFinite else {
            return nil
        }

        let signedMilliwatts = twosComplementSignedValueIfNeeded(milliwatts)
        return validBatteryWatts(signedMilliwatts / 1_000)
    }

    static func derivedWatts(voltageMillivolts: Double?, amperageMilliamps: Double?) -> Double? {
        guard
            let voltageMillivolts,
            let amperageMilliamps,
            voltageMillivolts > 0,
            amperageMilliamps != 0
        else {
            return nil
        }

        return validBatteryWatts(-(voltageMillivolts * amperageMilliamps) / 1_000_000)
    }

    private static func signedNumberValue(_ rawValue: Any?) -> Double? {
        if let intValue = rawValue as? Int {
            return Double(intValue)
        }
        if let int64Value = rawValue as? Int64 {
            return Double(int64Value)
        }
        if let uint64Value = rawValue as? UInt64 {
            return signedDoubleValue(fromUnsigned: uint64Value)
        }
        if let doubleValue = rawValue as? Double {
            return doubleValue
        }
        if let numberValue = rawValue as? NSNumber {
            if numberValue.doubleValue > Double(Int64.max) {
                return signedDoubleValue(fromUnsigned: numberValue.uint64Value)
            }
            return numberValue.doubleValue
        }
        if let stringValue = rawValue as? String {
            if let int64Value = Int64(stringValue) {
                return Double(int64Value)
            }
            if let uint64Value = UInt64(stringValue) {
                return signedDoubleValue(fromUnsigned: uint64Value)
            }
            return Double(stringValue)
        }
        return nil
    }

    private static func signedDoubleValue(fromUnsigned value: UInt64) -> Double {
        guard value > UInt64(Int64.max) else {
            return Double(value)
        }

        let magnitude = ~value &+ 1
        return -Double(magnitude)
    }

    private static func twosComplementSignedValueIfNeeded(_ value: Double) -> Double {
        guard value > Double(Int64.max) else {
            return value
        }

        return value - pow(2, 64)
    }

    private static func validBatteryWatts(_ watts: Double) -> Double? {
        guard watts.isFinite, watts > -200, watts < 200 else {
            return nil
        }

        return watts
    }
}

struct SystemStatusPowerCalculator {
    static func watts(
        current: SystemStatusPowerEnergySample,
        previous: SystemStatusPowerEnergySample
    ) -> Double? {
        let elapsedSeconds = current.date.timeIntervalSince(previous.date)
        guard elapsedSeconds > 0, current.joules >= previous.joules else {
            return nil
        }

        let watts = (current.joules - previous.joules) / elapsedSeconds
        guard watts >= 0, watts < 1_000 else {
            return nil
        }

        return watts
    }
}

struct SystemStatusNetworkCounter: Equatable, Sendable {
    let key: String
    let displayName: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let ipAddress: String?
    let isUp: Bool

    func replacingCounters(from counter: SystemStatusNetworkCounter?) -> SystemStatusNetworkCounter {
        guard let counter else {
            return self
        }

        return SystemStatusNetworkCounter(
            key: counter.key,
            displayName: displayName,
            receivedBytes: counter.receivedBytes,
            sentBytes: counter.sentBytes,
            ipAddress: ipAddress,
            isUp: isUp
        )
    }
}

struct SystemStatusNetworkRate: Equatable, Sendable {
    let downloadBytesPerSecond: UInt64
    let uploadBytesPerSecond: UInt64
}

enum SystemStatusNetworkRateCalculator {
    private static let maximumBytesPerSecond: UInt64 = 2_000_000_000

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
            downloadBytesPerSecond: clampedBytesPerSecond(receivedDelta, elapsedSeconds: elapsedSeconds),
            uploadBytesPerSecond: clampedBytesPerSecond(sentDelta, elapsedSeconds: elapsedSeconds)
        )
    }

    private static func positiveDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private static func clampedBytesPerSecond(_ delta: UInt64, elapsedSeconds: TimeInterval) -> UInt64 {
        let bytesPerSecond = UInt64(Double(delta) / elapsedSeconds)
        guard bytesPerSecond <= maximumBytesPerSecond else {
            return 0
        }

        return bytesPerSecond
    }
}

struct SystemStatusDiskIOCounter: Equatable, Sendable {
    let readBytes: UInt64
    let writeBytes: UInt64
}

struct SystemStatusDiskIORate: Equatable, Sendable {
    let readBytesPerSecond: UInt64
    let writeBytesPerSecond: UInt64
}

enum SystemStatusDiskIORateCalculator {
    private static let maximumBytesPerSecond: UInt64 = 10_000_000_000

    static func rate(
        current: SystemStatusDiskIOCounter,
        previous: SystemStatusDiskIOCounter,
        elapsedSeconds: TimeInterval
    ) -> SystemStatusDiskIORate? {
        guard elapsedSeconds > 0 else {
            return nil
        }

        let readDelta = positiveDelta(current.readBytes, previous.readBytes)
        let writeDelta = positiveDelta(current.writeBytes, previous.writeBytes)

        return SystemStatusDiskIORate(
            readBytesPerSecond: clampedBytesPerSecond(readDelta, elapsedSeconds: elapsedSeconds),
            writeBytesPerSecond: clampedBytesPerSecond(writeDelta, elapsedSeconds: elapsedSeconds)
        )
    }

    private static func positiveDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private static func clampedBytesPerSecond(_ delta: UInt64, elapsedSeconds: TimeInterval) -> UInt64 {
        let bytesPerSecond = UInt64(Double(delta) / elapsedSeconds)
        guard bytesPerSecond <= maximumBytesPerSecond else {
            return 0
        }

        return bytesPerSecond
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
            return "—°C"
        }

        return "\(format(celsius, fractionDigits: 0))°C"
    }

    static func power(_ watts: Double?) -> String {
        guard let watts else {
            return "—W"
        }

        let fractionDigits = watts < 10 ? 1 : 0
        return "\(format(watts, fractionDigits: fractionDigits))W"
    }

    static func rpm(_ rpm: Double?) -> String {
        guard let rpm else {
            return "—"
        }

        return "\(format(rpm, fractionDigits: 0)) RPM"
    }

    static func timeRemaining(
        minutes: Int?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        guard let minutes, minutes >= 0 else {
            return localization.string("battery.timeRemaining.estimating", defaultValue: "估算中")
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

    static func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else {
            return "—"
        }

        let totalHours = Int(seconds / 3_600)
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 {
            return "\(days)d \(hours)h"
        }

        return "\(max(totalHours, 0))h"
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
