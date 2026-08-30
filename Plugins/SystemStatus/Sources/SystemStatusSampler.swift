import Darwin
import Foundation
import IOKit
import IOKit.ps
import MacToolsPluginKit
import SystemConfiguration

protocol SystemStatusSampling: Sendable {
    func collectFast(referenceDate: Date) async -> SystemStatusFastSample
    func collectSlow() async -> SystemStatusSlowSample
    func collectTopProcesses(limit: Int) async -> [SystemStatusTopProcess]
    func collectPublicIPAddress() async -> String?
}

actor SystemStatusSampler: SystemStatusSampling {
    private let localization: PluginLocalization
    private var previousCPUTicks: SystemStatusCPUTicks?
    private var previousCPUPowerEnergy: SystemStatusPowerEnergySample?
    private var cachedCPUTemperature: Double?
    private var cachedGPUTemperature: Double?
    private var lastCPUTemperatureDate: Date?
    private var lastGPUTemperatureDate: Date?
    private var cachedHardware: SystemStatusHardwareSnapshot?
    private lazy var smcReader = SystemStatusSMCReader()
    private lazy var cpuPowerReader = SystemStatusCPUPowerReader()
    private var previousNetworkCounter: SystemStatusNetworkCounter?
    private var previousNetworkDate: Date?
    private var previousDiskIOCounter: SystemStatusDiskIOCounter?
    private var previousDiskIODate: Date?
    private var cachedSystemPowerHealthPercent: Int?
    private var lastSystemPowerHealthDate: Date?
    private var didCacheSystemPowerHealth = false
    private var cachedNetworkMetadata: [String: NetworkInterfaceMetadata]?
    private var lastNetworkMetadataDate: Date?
    private var cachedPrimaryInterfaceName: String?
    private var lastPrimaryInterfaceDate: Date?
    private var didCachePrimaryInterfaceName = false

    private static let systemPowerHealthCacheInterval: TimeInterval = 60 * 60
    private static let networkMetadataCacheInterval: TimeInterval = 10

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    private var networkInterfaceDisplayNames: NetworkInterfaceDisplayNames {
        NetworkInterfaceDisplayNames(
            wired: localization.string("network.interface.wired", defaultValue: "有线"),
            generic: localization.string("network.interface.generic", defaultValue: "网络"),
            multiple: localization.string("network.interface.multiple", defaultValue: "多接口")
        )
    }

    func collectFast(referenceDate: Date) async -> SystemStatusFastSample {
        let cpu = await collectCPU(referenceDate: referenceDate)
        return SystemStatusFastSample(
            cpu: cpu,
            memory: Self.collectMemory(),
            network: collectNetwork(referenceDate: referenceDate),
            disk: collectDiskIO(referenceDate: referenceDate)
        )
    }

    func collectSlow() async -> SystemStatusSlowSample {
        SystemStatusSlowSample(
            disk: Self.collectDiskCapacity(),
            battery: collectBattery(),
            gpu: collectGPU(),
            hardware: collectHardware()
        )
    }

    func collectTopProcesses(limit: Int = 3) async -> [SystemStatusTopProcess] {
        Self.collectTopProcesses(limit: limit)
    }

    func collectPublicIPAddress() async -> String? {
        await Self.collectPublicIPAddress()
    }

    private func collectCPU(referenceDate: Date) async -> SystemStatusCPUSnapshot {
        let temperature = collectCPUTemperature(referenceDate: referenceDate)
        var currentDate = referenceDate
        var currentTicks = Self.readCPUTicks()
        var currentPowerEnergy = cpuPowerReader.readCPUEnergySample(referenceDate: currentDate)

        if previousCPUTicks == nil, let initialTicks = currentTicks {
            let initialPowerEnergy = currentPowerEnergy
            try? await Task.sleep(for: .milliseconds(200))
            currentDate = Date()
            currentTicks = Self.readCPUTicks()
            currentPowerEnergy = cpuPowerReader.readCPUEnergySample(referenceDate: currentDate)
            previousCPUTicks = initialTicks
            previousCPUPowerEnergy = initialPowerEnergy
        }

        guard let currentTicks else {
            return SystemStatusCPUSnapshot(
                usage: nil,
                loadAverage1Minute: Self.collectCPULoadAverage(),
                temperatureCelsius: temperature,
                systemPowerWatts: collectPowerWatts(currentPowerEnergy: currentPowerEnergy),
                isCollecting: false
            )
        }

        let usage = previousCPUTicks.flatMap { previousTicks in
            SystemStatusCPUUsageCalculator.usage(current: currentTicks, previous: previousTicks)
        }
        previousCPUTicks = currentTicks

        return SystemStatusCPUSnapshot(
            usage: usage,
            loadAverage1Minute: Self.collectCPULoadAverage(),
            temperatureCelsius: temperature,
            systemPowerWatts: collectPowerWatts(currentPowerEnergy: currentPowerEnergy),
            isCollecting: usage == nil
        )
    }

    private func collectPowerWatts(currentPowerEnergy: SystemStatusPowerEnergySample?) -> Double? {
        let cpuPowerWatts = currentPowerEnergy.flatMap { currentPowerEnergy in
            defer { previousCPUPowerEnergy = currentPowerEnergy }
            return previousCPUPowerEnergy.flatMap { previousPowerEnergy in
                SystemStatusPowerCalculator.watts(current: currentPowerEnergy, previous: previousPowerEnergy)
            }
        }

        return cpuPowerWatts
    }

    private func collectCPUTemperature(referenceDate: Date) -> Double? {
        if let lastCPUTemperatureDate, referenceDate.timeIntervalSince(lastCPUTemperatureDate) < 5 {
            return cachedCPUTemperature
        }

        let temperature = Self.collectCPUTemperature(smcReader: smcReader)
        cachedCPUTemperature = temperature
        lastCPUTemperatureDate = referenceDate
        return temperature
    }

    private func collectGPUTemperature(referenceDate: Date) -> Double? {
        if let lastGPUTemperatureDate, referenceDate.timeIntervalSince(lastGPUTemperatureDate) < 5 {
            return cachedGPUTemperature
        }

        let temperature = Self.collectGPUTemperature(smcReader: smcReader)
        cachedGPUTemperature = temperature
        lastGPUTemperatureDate = referenceDate
        return temperature
    }

    private func collectHardware() -> SystemStatusHardwareSnapshot {
        if let cachedHardware {
            return cachedHardware.replacingUptime(Self.collectUptimeSeconds())
        }

        let hardware = SystemStatusHardwareSnapshot(
            modelName: Self.collectHardwareString("hw.model"),
            chipName: Self.collectHardwareString("machdep.cpu.brand_string"),
            macOSVersion: Self.collectMacOSVersionString(),
            uptimeSeconds: Self.collectUptimeSeconds(),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        cachedHardware = hardware
        return hardware
    }

    private func collectNetwork(referenceDate: Date) -> SystemStatusNetworkSnapshot {
        guard let currentCounter = currentNetworkCounter(referenceDate: referenceDate) else {
            previousNetworkCounter = nil
            previousNetworkDate = referenceDate
            return SystemStatusNetworkSnapshot(
                interfaceName: nil,
                ipAddress: nil,
                publicIPAddress: nil,
                downloadBytesPerSecond: nil,
                uploadBytesPerSecond: nil,
                isConnected: false,
                isCollecting: false
            )
        }

        let rate: SystemStatusNetworkRate?
        if
            let previousNetworkCounter,
            let previousNetworkDate,
            previousNetworkCounter.key == currentCounter.key
        {
            rate = SystemStatusNetworkRateCalculator.rate(
                current: currentCounter,
                previous: previousNetworkCounter,
                elapsedSeconds: referenceDate.timeIntervalSince(previousNetworkDate)
            )
        } else {
            rate = nil
        }

        previousNetworkCounter = currentCounter
        previousNetworkDate = referenceDate

        return SystemStatusNetworkSnapshot(
            interfaceName: currentCounter.displayName,
            ipAddress: currentCounter.ipAddress,
            publicIPAddress: nil,
            downloadBytesPerSecond: rate?.downloadBytesPerSecond ?? 0,
            uploadBytesPerSecond: rate?.uploadBytesPerSecond ?? 0,
            isConnected: currentCounter.isUp,
            isCollecting: rate == nil
        )
    }

    private static func readCPUTicks() -> SystemStatusCPUTicks? {
        let count = MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var info = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: count) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &size)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return SystemStatusCPUTicks(
            user: tickValue(info.cpu_ticks.0),
            system: tickValue(info.cpu_ticks.1),
            idle: tickValue(info.cpu_ticks.2),
            nice: tickValue(info.cpu_ticks.3)
        )
    }

    private static func tickValue(_ value: natural_t) -> UInt64 {
        UInt64(value)
    }

    private static func collectCPULoadAverage() -> Double? {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, Int32(averages.count)) > 0 else {
            return nil
        }

        let load = averages[0]
        guard load >= 0, load.isFinite else {
            return nil
        }

        return load
    }

    private static func collectCPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        if let smcTemperature = collectSMCCPUTemperature(smcReader: smcReader) {
            return smcTemperature
        }

        let values = collectHIDSensorTemperatures(
            keyPrefixes: ["pACC MTR Temp", "eACC MTR Temp"]
        )

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private static func collectSMCCPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        guard let smcReader else {
            return nil
        }

        let directKeys = ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TCAD"]
        for key in directKeys {
            if let value = smcReader.value(for: key), isValidTemperature(value) {
                return value
            }
        }

        let appleSiliconKeys = [
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
            "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
            "Te05", "Te09", "Te0H", "Te0L", "Te0P", "Te0S",
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
            "Tp0V", "Tp0Y", "Tp0e",
            "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0a", "Tp0d", "Tp0g", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
        ]
        let values = appleSiliconKeys.compactMap { key in
            smcReader.value(for: key)
        }.filter(isValidTemperature)

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private static func collectGPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        if let smcTemperature = collectSMCGPUTemperature(smcReader: smcReader) {
            return smcTemperature
        }

        let values = collectHIDSensorTemperatures(
            keyPrefixes: ["GPU MTR Temp", "SOC MTR Temp"]
        )

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private static func collectSMCGPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        guard let smcReader else {
            return nil
        }

        let keys = [
            "TCGC", "TG0D", "TGDD", "TG0H", "TG0P", "TG0T", "TG1D", "TG1P", "TG1H", "TG1T",
            "Tg05", "Tg0D", "Tg0L", "Tg0T",
            "Tg0f", "Tg0j",
            "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
            "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0U", "Tg0X", "Tg0g", "Tg1Y", "Tg1c", "Tg1g"
        ]
        let values = keys.compactMap { smcReader.value(for: $0) }.filter(isValidTemperature)
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    nonisolated static func hidSensorTemperatures(output: String, keyPrefixes: [String]) -> [Double] {
        let lines = output.components(separatedBy: .newlines)
        var isMatchingSensor = false
        var values: [Double] = []

        for line in lines {
            if line.contains("+-o ") || line.contains("| +-o ") {
                isMatchingSensor = keyPrefixes.contains { line.localizedCaseInsensitiveContains($0) }
            } else if keyPrefixes.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                isMatchingSensor = true
            }

            guard isMatchingSensor else {
                continue
            }

            let celsiusValues = regexCaptures(#"temperature[^=]*=\s*([0-9]+(?:\.[0-9]+)?)"#, in: line)
                .compactMap(Double.init)
                .map(normalizedTemperatureCelsius)
                .filter(isValidTemperature)

            values.append(contentsOf: celsiusValues)
        }

        return values
    }

    private static func collectHIDSensorTemperatures(keyPrefixes: [String]) -> [Double] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var values: [Double] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var rawProperties: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = rawProperties?.takeRetainedValue() as? [String: Any],
                hidSensorMatches(properties: properties, keyPrefixes: keyPrefixes)
            else {
                continue
            }

            for key in ["temperature", "Temperature"] {
                if
                    let rawTemperature = numberValue(properties[key]),
                    isValidTemperature(normalizedTemperatureCelsius(rawTemperature))
                {
                    values.append(normalizedTemperatureCelsius(rawTemperature))
                    break
                }
            }
        }

        return values
    }

    private static func hidSensorMatches(properties: [String: Any], keyPrefixes: [String]) -> Bool {
        let candidates = ["Product", "product", "name", "Name", "IOName"].compactMap { key in
            stringValue(properties[key] as Any)
        }

        return candidates.contains { candidate in
            keyPrefixes.contains { candidate.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func isValidTemperature(_ value: Double) -> Bool {
        value > 0 && value < 110
    }

    private static func collectMemory() -> SystemStatusMemorySnapshot {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return .empty
        }

        let pageSize = Double(memoryPageSize())
        let active = Double(stats.active_count) * pageSize
        let speculative = Double(stats.speculative_count) * pageSize
        let inactive = Double(stats.inactive_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let purgeable = Double(stats.purgeable_count) * pageSize
        let external = Double(stats.external_page_count) * pageSize
        let rawUsed = active + inactive + speculative + wired + compressed - purgeable - external
        let total = ProcessInfo.processInfo.physicalMemory
        let used = UInt64(min(max(rawUsed, 0), Double(total)))
        let swapUsage = collectSwapUsage()

        return SystemStatusMemorySnapshot(
            usedBytes: used,
            totalBytes: total,
            swapUsedBytes: swapUsage.used,
            swapTotalBytes: swapUsage.total
        )
    }

    private func collectGPU() -> SystemStatusGPUSnapshot {
        let temperature = collectGPUTemperature(referenceDate: Date())
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            let isAvailable = temperature != nil
            return SystemStatusGPUSnapshot(
                usage: isAvailable ? 0 : nil,
                name: nil,
                temperatureCelsius: temperature,
                isAvailable: isAvailable,
                isCollecting: false
            )
        }
        defer { IOObjectRelease(iterator) }

        var usages: [Double] = []
        var names: [String] = []
        var performanceTemperatures: [Double] = []
        var didFindAccelerator = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            didFindAccelerator = true

            if let name = Self.gpuName(service: service) {
                names.append(name)
            }

            let performance = Self.registryPerformanceStatistics(service: service)
            if
                let performance,
                let usage = Self.gpuUtilization(from: performance)
            {
                usages.append(usage)
            }

            if
                let performance,
                let temperature = Self.gpuPerformanceTemperature(from: performance)
            {
                performanceTemperatures.append(temperature)
            }
        }

        let usage = usages.isEmpty ? nil : min(max(usages.max() ?? 0, 0), 1)
        let name = names.first
        let resolvedTemperature = temperature ?? performanceTemperatures.max()
        let isAvailable = didFindAccelerator || name != nil || resolvedTemperature != nil

        guard !usages.isEmpty else {
            return SystemStatusGPUSnapshot(
                usage: isAvailable ? 0 : nil,
                name: name,
                temperatureCelsius: resolvedTemperature,
                isAvailable: isAvailable,
                isCollecting: false
            )
        }

        return SystemStatusGPUSnapshot(
            usage: usage,
            name: name,
            temperatureCelsius: resolvedTemperature,
            isAvailable: true,
            isCollecting: false
        )
    }

    private static func collectHardwareString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname(key, pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return nil
        }

        let nullIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let value = String(decoding: buffer[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func collectMacOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.patchVersion > 0 {
            return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        return "macOS \(version.majorVersion).\(version.minorVersion)"
    }

    private static func collectUptimeSeconds() -> TimeInterval? {
        var bootTime = timeval()
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, UInt32(mib.count), &bootTime, &size, nil, 0) == 0 else {
            return nil
        }

        let bootDate = Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
        return max(0, Date().timeIntervalSince(bootDate))
    }

    nonisolated static func gpuUtilization(from performanceStatistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            guard let value = gpuUtilizationValue(performanceStatistics[key]) else {
                continue
            }

            return value
        }

        return nil
    }

    private static func gpuUtilizationValue(_ rawValue: Any?) -> Double? {
        let value: Double
        let isPercentValue: Bool

        switch rawValue {
        case let intValue as Int:
            value = Double(intValue)
            isPercentValue = true
        case let doubleValue as Double:
            value = doubleValue
            isPercentValue = doubleValue > 1
        case let floatValue as Float:
            value = Double(floatValue)
            isPercentValue = value > 1
        case let numberValue as NSNumber:
            value = numberValue.doubleValue
            isPercentValue = !CFNumberIsFloatType(numberValue) || value > 1
        case let stringValue as String:
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedValue = Double(trimmed) else {
                return nil
            }
            value = parsedValue
            isPercentValue = parsedValue > 1
        default:
            return nil
        }

        guard value.isFinite else {
            return nil
        }

        let fraction = isPercentValue ? value / 100 : value
        return min(max(fraction, 0), 1)
    }

    nonisolated static func gpuPerformanceTemperature(from performanceStatistics: [String: Any]) -> Double? {
        guard let value = numberValue(performanceStatistics["Temperature(C)"]), isValidTemperature(value) else {
            return nil
        }

        return value
    }

    nonisolated static func gpuName(from properties: [String: Any]) -> String? {
        gpuName { key in
            properties[key]
        }
    }

    private static func gpuName(service: io_registry_entry_t) -> String? {
        gpuName { key in
            registryRawValue(service: service, key: key)
        }
    }

    private static func gpuName(rawValueForKey: (String) -> Any?) -> String? {
        for key in ["model", "IOName", "name"] {
            guard let rawValue = rawValueForKey(key) else {
                continue
            }

            if let value = stringValue(rawValue), isUserVisibleGPUName(value) {
                return normalizedGPUName(value)
            }
        }

        return nil
    }

    private static func isUserVisibleGPUName(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return !value.isEmpty
            && !lowercased.contains("ioaccelerator")
            && !lowercased.contains("accelerator")
            && !lowercased.contains("controller")
    }

    private static func normalizedGPUName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Apple ", with: "")
    }

    private static func memoryPageSize() -> vm_size_t {
        var pageSize: vm_size_t = 0
        let result = host_page_size(mach_host_self(), &pageSize)
        guard result == KERN_SUCCESS, pageSize > 0 else {
            return 16_384
        }

        return pageSize
    }

    private static func collectSwapUsage() -> (used: UInt64?, total: UInt64?) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        guard sysctl(&mib, UInt32(mib.count), &usage, &size, nil, 0) == 0 else {
            return (nil, nil)
        }

        let total = usage.xsu_total > 0 ? usage.xsu_total : nil
        let used = usage.xsu_used > 0 ? usage.xsu_used : UInt64(0)
        return (used, total)
    }

    private static func collectDiskCapacity() -> SystemStatusDiskSnapshot {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        var totalBytes: UInt64?
        var availableBytes: UInt64?

        do {
            let values = try homeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            if let totalCapacity = values.volumeTotalCapacity, totalCapacity > 0 {
                totalBytes = UInt64(totalCapacity)
            }
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage, importantCapacity >= 0 {
                availableBytes = UInt64(importantCapacity)
            }
        } catch {
            totalBytes = nil
            availableBytes = nil
        }

        if totalBytes == nil || availableBytes == nil {
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: homeURL.path) {
                if totalBytes == nil, let total = attributes[.systemSize] as? NSNumber {
                    totalBytes = total.uint64Value
                }
                if availableBytes == nil, let free = attributes[.systemFreeSize] as? NSNumber {
                    availableBytes = free.uint64Value
                }
            }
        }

        guard let totalBytes, totalBytes > 0, let availableBytes else {
            return .empty
        }

        let clampedAvailable = min(availableBytes, totalBytes)
        return SystemStatusDiskSnapshot(
            usedBytes: totalBytes - clampedAvailable,
            totalBytes: totalBytes,
            readBytesPerSecond: nil,
            writeBytesPerSecond: nil
        )
    }

    private func collectDiskIO(referenceDate: Date) -> SystemStatusDiskSnapshot {
        guard let currentCounter = Self.readDiskIOCounter() else {
            previousDiskIOCounter = nil
            previousDiskIODate = referenceDate
            return SystemStatusDiskSnapshot(
                usedBytes: nil,
                totalBytes: nil,
                readBytesPerSecond: nil,
                writeBytesPerSecond: nil
            )
        }

        let rate: SystemStatusDiskIORate?
        if let previousDiskIOCounter, let previousDiskIODate {
            rate = SystemStatusDiskIORateCalculator.rate(
                current: currentCounter,
                previous: previousDiskIOCounter,
                elapsedSeconds: referenceDate.timeIntervalSince(previousDiskIODate)
            )
        } else {
            rate = nil
        }

        previousDiskIOCounter = currentCounter
        previousDiskIODate = referenceDate

        return SystemStatusDiskSnapshot(
            usedBytes: nil,
            totalBytes: nil,
            readBytesPerSecond: rate?.readBytesPerSecond ?? 0,
            writeBytesPerSecond: rate?.writeBytesPerSecond ?? 0
        )
    }

    private static func readDiskIOCounter() -> SystemStatusDiskIOCounter? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        var foundCounter = false
        var service = IOIteratorNext(iterator)

        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var rawProperties: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = rawProperties?.takeRetainedValue() as? [String: Any],
                let statistics = properties["Statistics"] as? [String: Any]
            else {
                continue
            }

            if let bytes = statistics["Bytes (Read)"] as? NSNumber {
                readBytes &+= bytes.uint64Value
                foundCounter = true
            }

            if let bytes = statistics["Bytes (Write)"] as? NSNumber {
                writeBytes &+= bytes.uint64Value
                foundCounter = true
            }
        }

        guard foundCounter else {
            return nil
        }

        return SystemStatusDiskIOCounter(readBytes: readBytes, writeBytes: writeBytes)
    }

    private func collectBattery() -> SystemStatusBatterySnapshot {
        guard
            let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let powerSources = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [CFTypeRef],
            !powerSources.isEmpty
        else {
            return SystemStatusBatterySnapshot(
                isAvailable: false,
                level: nil,
                state: .unavailable,
                timeRemainingMinutes: nil,
                adapterWatts: Self.adapterWatts(),
                batteryPowerWatts: nil,
                temperatureCelsius: nil,
                healthPercent: nil,
                cycleCount: nil
            )
        }

        var fallbackDescription: [String: Any]?
        var batteryDescription: [String: Any]?

        for source in powerSources {
            guard let description = IOPSGetPowerSourceDescription(powerSourcesInfo, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            fallbackDescription = fallbackDescription ?? description
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                batteryDescription = description
                break
            }
        }

        guard let description = batteryDescription ?? fallbackDescription else {
            return SystemStatusBatterySnapshot(
                isAvailable: false,
                level: nil,
                state: .unavailable,
                timeRemainingMinutes: nil,
                adapterWatts: Self.adapterWatts(),
                batteryPowerWatts: nil,
                temperatureCelsius: nil,
                healthPercent: nil,
                cycleCount: nil
            )
        }

        let maxCapacity = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let currentCapacity = min(max(description[kIOPSCurrentCapacityKey] as? Int ?? 0, 0), maxCapacity)
        let level = min(max(Double(currentCapacity) / Double(maxCapacity), 0), 1)
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        let powerSource = description[kIOPSPowerSourceStateKey] as? String ?? ""
        let state = Self.batteryState(
            level: level,
            isCharging: isCharging,
            isCharged: isCharged,
            powerSource: powerSource
        )
        let timeKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let registryInfo = Self.collectBatteryRegistryInfo()

        return SystemStatusBatterySnapshot(
            isAvailable: true,
            level: level,
            state: state,
            timeRemainingMinutes: Self.validBatteryMinutes(description[timeKey]),
            adapterWatts: Self.adapterWatts(),
            batteryPowerWatts: registryInfo.batteryPowerWatts,
            temperatureCelsius: registryInfo.temperatureCelsius,
            healthPercent: registryInfo.healthPercent ?? systemPowerHealthPercent(referenceDate: Date()),
            cycleCount: registryInfo.cycleCount
        )
    }

    private func systemPowerHealthPercent(referenceDate: Date) -> Int? {
        if didCacheSystemPowerHealth,
           let lastSystemPowerHealthDate,
           referenceDate.timeIntervalSince(lastSystemPowerHealthDate) < Self.systemPowerHealthCacheInterval {
            return cachedSystemPowerHealthPercent
        }

        let healthPercent: Int?
        if let output = Self.runCommand(
            path: "/usr/sbin/system_profiler",
            arguments: ["SPPowerDataType", "-json"],
            timeout: 3
        ) {
            healthPercent = Self.systemPowerBatteryHealthPercent(fromSystemProfilerJSON: output)
        } else {
            healthPercent = nil
        }

        cachedSystemPowerHealthPercent = healthPercent
        lastSystemPowerHealthDate = referenceDate
        didCacheSystemPowerHealth = true
        return healthPercent
    }

    private static func batteryState(
        level: Double,
        isCharging: Bool,
        isCharged: Bool,
        powerSource: String
    ) -> SystemStatusBatteryState {
        if isCharged || level >= 0.999 {
            return .charged
        }
        if isCharging {
            return .charging
        }
        if powerSource == "AC Power" {
            return .acPower
        }
        if powerSource == "Battery Power" {
            return .unplugged
        }
        return .unknown
    }

    private static func validBatteryMinutes(_ value: Any?) -> Int? {
        guard let minutes = value as? Int, minutes >= 0 else {
            return nil
        }

        return minutes
    }

    private static func adapterWatts() -> Int? {
        guard
            let adapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
            let watts = adapterDetails[kIOPSPowerAdapterWattsKey] as? Int,
            watts > 0
        else {
            return nil
        }

        return watts
    }

    private static func collectBatteryRegistryInfo() -> (
        temperatureCelsius: Double?,
        healthPercent: Int?,
        cycleCount: Int?,
        batteryPowerWatts: Double?
    ) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return (nil, nil, nil, nil)
        }
        defer { IOObjectRelease(service) }

        let batteryData = registryDictionaryValue(service: service, key: "BatteryData")
        let batteryPackService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBatteryPack")
        )
        defer {
            if batteryPackService != 0 {
                IOObjectRelease(batteryPackService)
            }
        }
        let batteryPackData = batteryPackService == 0
            ? nil
            : registryDictionaryValue(service: batteryPackService, key: "BatteryData")
        let temperature = batteryTemperatureCelsius(rawValues: [
            registryIntValue(service: service, key: "Temperature"),
            dictionaryIntValue(batteryData, key: "Temperature"),
            batteryPackService == 0 ? nil : registryIntValue(service: batteryPackService, key: "Temperature"),
            dictionaryIntValue(batteryPackData, key: "Temperature"),
            registryIntValue(service: service, key: "VirtualTemperature"),
            dictionaryIntValue(batteryData, key: "VirtualTemperature"),
            batteryPackService == 0 ? nil : registryIntValue(service: batteryPackService, key: "VirtualTemperature"),
            dictionaryIntValue(batteryPackData, key: "VirtualTemperature"),
        ])

        let healthPercent = optionalBatteryHealthPercent(
            designCapacity: registryIntValue(service: service, key: "DesignCapacity"),
            nominalChargeCapacity: registryIntValue(service: service, key: "NominalChargeCapacity"),
            appleRawMaxCapacity: registryIntValue(service: service, key: "AppleRawMaxCapacity")
        )

        return (
            temperature,
            healthPercent,
            registryIntValue(service: service, key: "CycleCount"),
            batteryPowerWatts(service: service)
        )
    }

    private static func batteryPowerWatts(service: io_registry_entry_t) -> Double? {
        if
            let telemetry = registryDictionaryValue(service: service, key: "PowerTelemetryData"),
            let watts = SystemStatusBatteryPowerNormalizer.telemetryWatts(
                fromRawMilliwatts: telemetry["BatteryPower"]
            )
        {
            return watts
        }

        if
            let watts = SystemStatusBatteryPowerNormalizer.telemetryWatts(
                fromRawMilliwatts: registryRawValue(service: service, key: "BatteryPower")
            )
        {
            return watts
        }

        let voltageMillivolts = registryNumberValue(service: service, key: "AppleRawBatteryVoltage")
            ?? registryNumberValue(service: service, key: "Voltage")
        let amperageMilliamps = nonzeroNumberValue(service: service, key: "InstantAmperage")
            ?? nonzeroNumberValue(service: service, key: "Amperage")

        return SystemStatusBatteryPowerNormalizer.derivedWatts(
            voltageMillivolts: voltageMillivolts,
            amperageMilliamps: amperageMilliamps
        )
    }

    nonisolated static func batteryHealthPercent(
        designCapacity: Int?,
        nominalChargeCapacity: Int?,
        appleRawMaxCapacity: Int?
    ) -> Int {
        // ioreg fallback matching Mole status: prefer NominalChargeCapacity, then AppleRawMaxCapacity.
        optionalBatteryHealthPercent(
            designCapacity: designCapacity,
            nominalChargeCapacity: nominalChargeCapacity,
            appleRawMaxCapacity: appleRawMaxCapacity
        ) ?? 0
    }

    nonisolated static func systemPowerBatteryHealthPercent(fromSystemProfilerJSON output: String) -> Int? {
        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = json["SPPowerDataType"] as? [[String: Any]]
        else {
            return nil
        }

        for section in sections {
            guard
                let info = section["sppower_battery_health_info"] as? [String: Any],
                let rawCapacity = info["sppower_battery_health_maximum_capacity"] as? String,
                let percent = batteryHealthPercent(fromSystemProfilerValue: rawCapacity)
            else {
                continue
            }

            return percent
        }

        return nil
    }

    nonisolated static func batteryHealthPercent(fromSystemProfilerValue rawValue: String) -> Int? {
        let normalized = rawValue
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(normalized), value > 0 else {
            return nil
        }

        return min(max(value, 0), 100)
    }

    private nonisolated static func optionalBatteryHealthPercent(
        designCapacity: Int?,
        nominalChargeCapacity: Int?,
        appleRawMaxCapacity: Int?
    ) -> Int? {
        guard let designCapacity, designCapacity > 0 else {
            return nil
        }

        let capacity = positiveCapacity(nominalChargeCapacity)
            ?? positiveCapacity(appleRawMaxCapacity)
        guard let capacity else {
            return nil
        }

        let percent = (Double(capacity) * 100 / Double(designCapacity)).rounded()
        guard percent > 0 else {
            return nil
        }

        return min(max(Int(percent), 0), 100)
    }

    private nonisolated static func positiveCapacity(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }

        return value
    }

    private static func registryIntValue(service: io_registry_entry_t, key: String) -> Int? {
        guard let rawValue = registryRawValue(service: service, key: key) else {
            return nil
        }

        if let intValue = rawValue as? Int {
            return intValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func dictionaryIntValue(_ dictionary: NSDictionary?, key: String) -> Int? {
        guard let rawValue = dictionary?[key] else {
            return nil
        }

        if let intValue = rawValue as? Int {
            return intValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    nonisolated static func batteryTemperatureCelsius(rawValues: [Int?]) -> Double? {
        for rawValue in rawValues.compactMap({ $0 }) {
            let celsius = Double(rawValue) / 100
            if celsius.isFinite, (0 ... 100).contains(celsius) {
                return celsius
            }
        }
        return nil
    }

    private static func registryNumberValue(service: io_registry_entry_t, key: String) -> Double? {
        guard let rawValue = registryRawValue(service: service, key: key) else {
            return nil
        }

        return numberValue(rawValue)
    }

    private static func nonzeroNumberValue(service: io_registry_entry_t, key: String) -> Double? {
        guard let value = registryNumberValue(service: service, key: key), value != 0 else {
            return nil
        }

        return value
    }

    private static func registryRawValue(service: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func registryDictionaryValue(service: io_registry_entry_t, key: String) -> NSDictionary? {
        guard let rawValue = registryRawValue(service: service, key: key) else {
            return nil
        }

        return rawValue as? NSDictionary
    }

    private static func registryPerformanceStatistics(service: io_registry_entry_t) -> [String: Any]? {
        guard let rawValue = registryRawValue(service: service, key: "PerformanceStatistics") else {
            return nil
        }

        if let value = rawValue as? [String: Any] {
            return value
        }
        if let value = rawValue as? NSDictionary {
            return value as? [String: Any]
        }
        return nil
    }

    private static func dictionaryNumberValue(_ dictionary: NSDictionary, key: String) -> Double? {
        numberValue(dictionary[key])
    }

    private static func numberValue(_ rawValue: Any?) -> Double? {
        if let intValue = rawValue as? Int {
            return Double(intValue)
        }
        if let doubleValue = rawValue as? Double {
            return doubleValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.doubleValue
        }
        if let stringValue = rawValue as? String {
            return Double(stringValue)
        }
        return nil
    }

    private static func stringValue(_ rawValue: Any) -> String? {
        if let value = rawValue as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = rawValue as? Data {
            let trimmed = String(decoding: value, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func currentNetworkCounter(referenceDate: Date) -> SystemStatusNetworkCounter? {
        let interfaceMetadata = networkInterfaceMetadata(referenceDate: referenceDate)
        let displayNames = networkInterfaceDisplayNames
        let counters = Self.readNetworkCounters(interfaceMetadata: interfaceMetadata, displayNames: displayNames)
        let aggregateCounter = Self.readAggregateNetworkCounter(
            interfaceMetadata: interfaceMetadata,
            displayNames: displayNames
        )
        guard !counters.isEmpty else {
            return aggregateCounter
        }

        if
            let primaryInterface = primaryInterfaceName(referenceDate: referenceDate),
            let primaryCounter = counters[primaryInterface]
        {
            return primaryCounter.replacingCounters(from: aggregateCounter)
        }

        let candidates = counters.values
            .filter { $0.isUp && !Self.isNoiseInterface($0.key) }
            .sorted { lhs, rhs in
                if lhs.receivedBytes + lhs.sentBytes == rhs.receivedBytes + rhs.sentBytes {
                    return lhs.key < rhs.key
                }

                return lhs.receivedBytes + lhs.sentBytes > rhs.receivedBytes + rhs.sentBytes
            }

        guard !candidates.isEmpty else {
            return aggregateCounter
        }

        return aggregateNetworkCounters(candidates, displayNames: displayNames).replacingCounters(from: aggregateCounter)
    }

    private func networkInterfaceMetadata(referenceDate: Date) -> [String: NetworkInterfaceMetadata] {
        if
            let cachedNetworkMetadata,
            let lastNetworkMetadataDate,
            referenceDate.timeIntervalSince(lastNetworkMetadataDate) < Self.networkMetadataCacheInterval
        {
            return cachedNetworkMetadata
        }

        let metadata = Self.networkInterfaceMetadata()
        cachedNetworkMetadata = metadata
        lastNetworkMetadataDate = referenceDate
        return metadata
    }

    private func primaryInterfaceName(referenceDate: Date) -> String? {
        if didCachePrimaryInterfaceName,
           let lastPrimaryInterfaceDate,
           referenceDate.timeIntervalSince(lastPrimaryInterfaceDate) < Self.networkMetadataCacheInterval {
            return cachedPrimaryInterfaceName
        }

        let name = Self.primaryInterfaceName()
        cachedPrimaryInterfaceName = name
        lastPrimaryInterfaceDate = referenceDate
        didCachePrimaryInterfaceName = true
        return name
    }

    private static func primaryInterfaceName() -> String? {
        guard
            let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let name = global["PrimaryInterface"] as? String,
            !name.isEmpty
        else {
            return nil
        }

        return name
    }

    private static func readNetworkCounters(
        interfaceMetadata: [String: NetworkInterfaceMetadata],
        displayNames: NetworkInterfaceDisplayNames = .default
    ) -> [String: SystemStatusNetworkCounter] {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
            return [:]
        }
        defer { freeifaddrs(interfaceAddresses) }

        var accumulators: [String: NetworkCounterAccumulator] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let currentPointer = pointer {
            defer { pointer = currentPointer.pointee.ifa_next }

            let name = String(cString: currentPointer.pointee.ifa_name)
            var accumulator = accumulators[name] ?? NetworkCounterAccumulator(name: name)
            accumulator.isUp = accumulator.isUp || (currentPointer.pointee.ifa_flags & UInt32(IFF_UP)) != 0

            guard let address = currentPointer.pointee.ifa_addr else {
                accumulators[name] = accumulator
                continue
            }

            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                if let rawData = currentPointer.pointee.ifa_data {
                    let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                    accumulator.receivedBytes = UInt64(data.ifi_ibytes)
                    accumulator.sentBytes = UInt64(data.ifi_obytes)
                }
            case AF_INET:
                if let address = numericAddress(from: address), !address.hasPrefix("127.") {
                    accumulator.ipv4Address = address
                }
            case AF_INET6:
                if let address = numericAddress(from: address), !address.hasPrefix("fe80") {
                    accumulator.ipv6Address = address
                }
            default:
                break
            }

            accumulators[name] = accumulator
        }

        return Dictionary(uniqueKeysWithValues: accumulators.map { key, value in
            (
                key,
                value.counter(
                    displayName: friendlyNetworkInterfaceName(
                        for: key,
                        metadata: interfaceMetadata[key],
                        displayNames: displayNames
                    )
                )
            )
        })
    }

    private static func readAggregateNetworkCounter(
        interfaceMetadata: [String: NetworkInterfaceMetadata],
        displayNames: NetworkInterfaceDisplayNames = .default
    ) -> SystemStatusNetworkCounter? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            return nil
        }

        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var interfaceNames: [String] = []

        buffer.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let messageLength = Int(rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength > 0 else {
                    break
                }

                let messageType = rawBuffer.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
                if Int32(messageType) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = rawBuffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                    let name = if_indextoname(UInt32(message.ifm_index), &nameBuffer)
                        .map { String(cString: $0) } ?? ""

                    if !name.isEmpty && !isNoiseInterface(name) {
                        receivedBytes &+= message.ifm_data.ifi_ibytes
                        sentBytes &+= message.ifm_data.ifi_obytes
                        interfaceNames.append(name)
                    }
                }

                offset += messageLength
            }
        }

        guard !interfaceNames.isEmpty else {
            return nil
        }

        return SystemStatusNetworkCounter(
            key: "iflist2:\(interfaceNames.sorted().joined(separator: ","))",
            displayName: interfaceNames.count == 1
                ? friendlyNetworkInterfaceName(
                    for: interfaceNames[0],
                    metadata: interfaceMetadata[interfaceNames[0]],
                    displayNames: displayNames
                )
                : displayNames.multiple,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes,
            ipAddress: nil,
            isUp: true
        )
    }

    private func aggregateNetworkCounters(
        _ counters: [SystemStatusNetworkCounter],
        displayNames: NetworkInterfaceDisplayNames
    ) -> SystemStatusNetworkCounter {
        guard counters.count > 1 else {
            return counters[0]
        }

        let sortedKeys = counters.map(\.key).sorted()
        let receivedBytes = counters.reduce(UInt64(0)) { $0 + $1.receivedBytes }
        let sentBytes = counters.reduce(UInt64(0)) { $0 + $1.sentBytes }
        let ipAddress = counters.first(where: { $0.ipAddress != nil })?.ipAddress

        return SystemStatusNetworkCounter(
            key: "aggregate:\(sortedKeys.joined(separator: ","))",
            displayName: displayNames.multiple,
            receivedBytes: receivedBytes,
            sentBytes: sentBytes,
            ipAddress: ipAddress,
            isUp: counters.contains(where: \.isUp)
        )
    }

    private static func numericAddress(from pointer: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            pointer,
            socklen_t(pointer.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else {
            return nil
        }

        let nullIndex = host.firstIndex(of: 0) ?? host.endIndex
        let bytes = host[..<nullIndex].map { UInt8(bitPattern: $0) }
        let address = String(decoding: bytes, as: UTF8.self)
        return address.isEmpty ? nil : address
    }

    private static func isNoiseInterface(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        let noisePrefixes = ["lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"]
        return noisePrefixes.contains { lowercasedName.hasPrefix($0) }
    }

    private static func networkInterfaceMetadata() -> [String: NetworkInterfaceMetadata] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }

        var metadata: [String: NetworkInterfaceMetadata] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?, !bsdName.isEmpty else {
                continue
            }

            metadata[bsdName] = NetworkInterfaceMetadata(
                localizedName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                interfaceType: SCNetworkInterfaceGetInterfaceType(interface) as String?
            )
        }

        return metadata
    }

    private static func friendlyNetworkInterfaceName(
        for name: String,
        metadata: NetworkInterfaceMetadata?,
        displayNames: NetworkInterfaceDisplayNames = .default
    ) -> String {
        friendlyNetworkInterfaceName(
            for: name,
            localizedName: metadata?.localizedName,
            interfaceType: metadata?.interfaceType,
            wiredDisplayName: displayNames.wired,
            genericDisplayName: displayNames.generic
        )
    }

    nonisolated static func friendlyNetworkInterfaceName(
        for name: String,
        localizedName: String? = nil,
        interfaceType: String? = nil,
        wiredDisplayName: String = "Ethernet",
        genericDisplayName: String = "Network"
    ) -> String {
        let rawName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedName = rawName.lowercased()
        let localizedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localizedDisplayName = localizedName?.isEmpty == false ? localizedName : nil
        let lowercasedLocalizedName = localizedDisplayName?.lowercased() ?? ""
        let lowercasedInterfaceType = interfaceType?.lowercased() ?? ""

        if isVPNInterfaceName(lowercasedName)
            || lowercasedInterfaceType == (kSCNetworkInterfaceTypePPP as String).lowercased()
            || lowercasedInterfaceType == (kSCNetworkInterfaceTypeIPSec as String).lowercased()
            || lowercasedLocalizedName.contains("vpn")
            || lowercasedLocalizedName.contains("tunnel")
        {
            return "VPN"
        }

        if lowercasedInterfaceType == (kSCNetworkInterfaceTypeIEEE80211 as String).lowercased()
            || lowercasedLocalizedName.contains("wi-fi")
            || lowercasedLocalizedName.contains("wifi")
            || lowercasedLocalizedName.contains("airport")
            || lowercasedLocalizedName.contains("无线")
        {
            return "Wi-Fi"
        }

        if lowercasedInterfaceType == (kSCNetworkInterfaceTypeEthernet as String).lowercased()
            || lowercasedName.hasPrefix("eth")
            || lowercasedLocalizedName.contains("ethernet")
            || lowercasedLocalizedName.contains("以太网")
            || lowercasedLocalizedName.contains("有线")
            || lowercasedLocalizedName.contains("lan")
            || lowercasedLocalizedName.contains("thunderbolt")
            || lowercasedLocalizedName.contains("usb")
        {
            return wiredDisplayName
        }

        return localizedDisplayName ?? (rawName.isEmpty ? genericDisplayName : rawName)
    }

    private static func isVPNInterfaceName(_ lowercasedName: String) -> Bool {
        let vpnPrefixes = ["utun", "tun", "tap", "ppp", "ipsec"]
        return vpnPrefixes.contains { lowercasedName.hasPrefix($0) }
    }

    private static func collectTopProcesses(limit: Int) -> [SystemStatusTopProcess] {
        guard let output = runCommand(path: "/bin/ps", arguments: ["-ww", "-Aceo", "pid=,pcpu=,pmem=,rss=,command=", "-r"]) else {
            return []
        }

        return SystemStatusProcessParser.parsePSOutputCandidates(output, limitPerSort: limit)
    }

    private static func runCommand(path: String, arguments: [String], timeout: TimeInterval = 1) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard !process.isRunning else {
            process.terminate()
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            return nil
        }

        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        outputPipe.fileHandleForReading.closeFile()
        errorPipe.fileHandleForReading.closeFile()

        guard let output = String(data: outputData, encoding: .utf8), !output.isEmpty else {
            return nil
        }

        return output
    }

    private static func regexCaptures(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: value) else {
                return nil
            }

            return String(value[captureRange])
        }
    }

    private static func normalizedTemperatureCelsius(_ value: Double) -> Double {
        if value > 1_000 {
            return value / 100
        }
        return value
    }

    private static func collectPublicIPAddress() async -> String? {
        let endpoints = [
            URL(string: "https://api.ipify.org")!,
            URL(string: "https://ifconfig.me/ip")!
        ]

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 2
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode),
                    let rawValue = String(data: data, encoding: .utf8)
                else {
                    continue
                }

                let ipAddress = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPublicIPAddressCandidate(ipAddress) {
                    return ipAddress
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private static func isPublicIPAddressCandidate(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else {
            return false
        }

        let allowedCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
        return value.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }

    private struct NetworkInterfaceMetadata {
        let localizedName: String?
        let interfaceType: String?
    }

    private struct NetworkInterfaceDisplayNames {
        let wired: String
        let generic: String
        let multiple: String

        static let `default` = NetworkInterfaceDisplayNames(
            wired: "Ethernet",
            generic: "Network",
            multiple: "Multiple Interfaces"
        )
    }

    private struct NetworkCounterAccumulator {
        let name: String
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var ipv4Address: String?
        var ipv6Address: String?
        var isUp = false

        func counter(displayName: String) -> SystemStatusNetworkCounter {
            SystemStatusNetworkCounter(
                key: name,
                displayName: displayName,
                receivedBytes: receivedBytes,
                sentBytes: sentBytes,
                ipAddress: ipv4Address ?? ipv6Address,
                isUp: isUp
            )
        }
    }
}

enum SystemStatusProcessParser {
    static func parsePSOutputCandidates(
        _ rawOutput: String,
        limitPerSort: Int
    ) -> [SystemStatusTopProcess] {
        guard limitPerSort > 0 else {
            return []
        }

        let processes = parsedProcesses(rawOutput)
        let cpuLeaders = processes.sorted(by: cpuSort).prefix(limitPerSort)
        let memoryLeaders = processes.sorted(by: memorySort).prefix(limitPerSort)
        let candidatesByPID = (Array(cpuLeaders) + Array(memoryLeaders)).reduce(
            into: [Int: SystemStatusTopProcess]()
        ) { result, process in
            result[process.pid] = process
        }
        return candidatesByPID.values.sorted(by: cpuSort)
    }

    static func parsePSOutput(_ rawOutput: String, limit: Int) -> [SystemStatusTopProcess] {
        guard limit > 0 else {
            return []
        }

        return Array(parsedProcesses(rawOutput).sorted(by: cpuSort).prefix(limit))
    }

    private static func parsedProcesses(_ rawOutput: String) -> [SystemStatusTopProcess] {
        rawOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private static func cpuSort(_ lhs: SystemStatusTopProcess, _ rhs: SystemStatusTopProcess) -> Bool {
        if lhs.cpuPercent != rhs.cpuPercent {
            return lhs.cpuPercent > rhs.cpuPercent
        }
        if lhs.memoryBytes != rhs.memoryBytes {
            return (lhs.memoryBytes ?? 0) > (rhs.memoryBytes ?? 0)
        }
        return lhs.pid < rhs.pid
    }

    private static func memorySort(_ lhs: SystemStatusTopProcess, _ rhs: SystemStatusTopProcess) -> Bool {
        if lhs.memoryBytes != rhs.memoryBytes {
            return (lhs.memoryBytes ?? 0) > (rhs.memoryBytes ?? 0)
        }
        if lhs.cpuPercent != rhs.cpuPercent {
            return lhs.cpuPercent > rhs.cpuPercent
        }
        return lhs.pid < rhs.pid
    }

    private static func parseLine(_ line: String) -> SystemStatusTopProcess? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 5 else {
            return nil
        }

        guard
            let pid = Int(fields[0]),
            pid > 0,
            let cpuPercent = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
            let memoryPercent = Double(fields[2].replacingOccurrences(of: ",", with: ".")),
            let residentKilobytes = UInt64(fields[3])
        else {
            return nil
        }

        let command = fields[4...].joined(separator: " ")
        guard !command.isEmpty else {
            return nil
        }

        return SystemStatusTopProcess(
            pid: pid,
            displayName: displayName(for: command),
            command: command,
            cpuPercent: cpuPercent,
            memoryPercent: memoryPercent,
            memoryBytes: residentKilobytes * 1_024
        )
    }

    private static func displayName(for command: String) -> String {
        let displayCommand = appBundlePath(in: command) ?? executablePath(from: command)
        let lastPathComponent = URL(fileURLWithPath: displayCommand).lastPathComponent
        guard !lastPathComponent.isEmpty else {
            return command
        }

        return lastPathComponent.replacingOccurrences(of: ".app", with: "")
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
}
