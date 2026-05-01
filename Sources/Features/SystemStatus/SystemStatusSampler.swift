import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

actor SystemStatusSampler {
    private var previousCPUTicks: SystemStatusCPUTicks?
    private var cachedCPUTemperature: Double?
    private var lastCPUTemperatureDate: Date?
    private lazy var smcReader = SystemStatusSMCReader()
    private var previousNetworkCounter: SystemStatusNetworkCounter?
    private var previousNetworkDate: Date?

    func collectFast(referenceDate: Date) -> SystemStatusFastSample {
        SystemStatusFastSample(
            cpu: collectCPU(referenceDate: referenceDate),
            memory: Self.collectMemory(),
            network: collectNetwork(referenceDate: referenceDate)
        )
    }

    func collectSlow() -> SystemStatusSlowSample {
        SystemStatusSlowSample(
            disk: Self.collectDiskCapacity(),
            battery: Self.collectBattery()
        )
    }

    func collectTopProcesses(limit: Int = 3) -> [SystemStatusTopProcess] {
        Self.collectTopProcesses(limit: limit)
    }

    func collectPublicIPAddress() async -> String? {
        await Self.collectPublicIPAddress()
    }

    private func collectCPU(referenceDate: Date) -> SystemStatusCPUSnapshot {
        let temperature = collectCPUTemperature(referenceDate: referenceDate)
        let systemPowerWatts = Self.collectSystemPowerWatts()
        guard let currentTicks = Self.readCPUTicks() else {
            return SystemStatusCPUSnapshot(
                usage: nil,
                temperatureCelsius: temperature,
                systemPowerWatts: systemPowerWatts,
                isCollecting: false
            )
        }

        let usage = previousCPUTicks.flatMap { previousTicks in
            SystemStatusCPUUsageCalculator.usage(current: currentTicks, previous: previousTicks)
        }
        previousCPUTicks = currentTicks

        return SystemStatusCPUSnapshot(
            usage: usage,
            temperatureCelsius: temperature,
            systemPowerWatts: systemPowerWatts,
            isCollecting: usage == nil
        )
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

    private func collectNetwork(referenceDate: Date) -> SystemStatusNetworkSnapshot {
        guard let currentCounter = Self.currentNetworkCounter() else {
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

    private static func collectSystemPowerWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        if
            let telemetry = registryDictionaryValue(service: service, key: "PowerTelemetryData"),
            let milliwatts = dictionaryNumberValue(telemetry, key: "SystemPowerIn"),
            let watts = SystemStatusPowerNormalizer.systemPowerWatts(fromMilliwatts: milliwatts)
        {
            return watts
        }

        if
            let milliwatts = registryNumberValue(service: service, key: "SystemPowerIn"),
            let watts = SystemStatusPowerNormalizer.systemPowerWatts(fromMilliwatts: milliwatts)
        {
            return watts
        }

        return nil
    }

    private static func collectCPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        if let smcTemperature = collectSMCCPUTemperature(smcReader: smcReader) {
            return smcTemperature
        }

        guard let output = runCommand(path: "/usr/sbin/ioreg", arguments: ["-r", "-c", "IOHIDEventService", "-w0"]) else {
            return nil
        }
        let pattern = #"temperature[^=]*=\s*([0-9]+(?:\.[0-9]+)?)"#
        let values = regexCaptures(pattern, in: output).compactMap(Double.init)
        let celsiusValues = values
            .map(normalizedTemperatureCelsius)
            .filter { $0 >= 10 && $0 <= 130 }

        guard !celsiusValues.isEmpty else {
            return nil
        }

        return celsiusValues.max()
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

        return SystemStatusMemorySnapshot(
            usedBytes: used,
            totalBytes: total
        )
    }

    private static func memoryPageSize() -> vm_size_t {
        var pageSize: vm_size_t = 0
        let result = host_page_size(mach_host_self(), &pageSize)
        guard result == KERN_SUCCESS, pageSize > 0 else {
            return 16_384
        }

        return pageSize
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
            totalBytes: totalBytes
        )
    }

    private static func collectBattery() -> SystemStatusBatterySnapshot {
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
            adapterWatts: adapterWatts(),
            temperatureCelsius: nil,
            healthPercent: nil
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
                adapterWatts: adapterWatts(),
                temperatureCelsius: nil,
                healthPercent: nil
            )
        }

        let maxCapacity = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let currentCapacity = min(max(description[kIOPSCurrentCapacityKey] as? Int ?? 0, 0), maxCapacity)
        let level = min(max(Double(currentCapacity) / Double(maxCapacity), 0), 1)
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        let powerSource = description[kIOPSPowerSourceStateKey] as? String ?? ""
        let state = batteryState(
            level: level,
            isCharging: isCharging,
            isCharged: isCharged,
            powerSource: powerSource
        )
        let timeKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        let registryInfo = collectBatteryRegistryInfo()

        return SystemStatusBatterySnapshot(
            isAvailable: true,
            level: level,
            state: state,
            timeRemainingMinutes: validBatteryMinutes(description[timeKey]),
            adapterWatts: adapterWatts(),
            temperatureCelsius: registryInfo.temperatureCelsius,
            healthPercent: registryInfo.healthPercent
        )
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

    private static func collectBatteryRegistryInfo() -> (temperatureCelsius: Double?, healthPercent: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return (nil, nil)
        }
        defer { IOObjectRelease(service) }

        let temperature = registryIntValue(service: service, key: "Temperature")
            .map { Double($0) / 100 }

        let maxCapacity = registryIntValue(service: service, key: isAppleSilicon ? "AppleRawMaxCapacity" : "MaxCapacity")
            ?? registryIntValue(service: service, key: "MaxCapacity")
        let designCapacity = registryIntValue(service: service, key: "DesignCapacity")
        let healthPercent: Int?
        if let maxCapacity, let designCapacity, designCapacity > 0 {
            healthPercent = Int((Double(maxCapacity) * 100 / Double(designCapacity)).rounded())
        } else {
            healthPercent = nil
        }

        return (temperature, healthPercent)
    }

    private static var isAppleSilicon: Bool {
        var size = 0
        guard sysctlbyname("hw.optional.arm64", nil, &size, nil, 0) == 0 else {
            return false
        }

        var value: Int32 = 0
        size = MemoryLayout<Int32>.stride
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else {
            return false
        }

        return value == 1
    }

    private static func registryIntValue(service: io_registry_entry_t, key: String) -> Int? {
        guard let rawValue = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
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

    private static func registryNumberValue(service: io_registry_entry_t, key: String) -> Double? {
        guard let rawValue = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }

        return numberValue(rawValue)
    }

    private static func registryDictionaryValue(service: io_registry_entry_t, key: String) -> NSDictionary? {
        guard let rawValue = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }

        return rawValue as? NSDictionary
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
        return nil
    }

    private static func currentNetworkCounter() -> SystemStatusNetworkCounter? {
        let counters = readNetworkCounters()
        guard !counters.isEmpty else {
            return nil
        }

        if
            let primaryInterface = primaryInterfaceName(),
            let primaryCounter = counters[primaryInterface]
        {
            return primaryCounter
        }

        let candidates = counters.values
            .filter { $0.isUp && !isNoiseInterface($0.key) }
            .sorted { lhs, rhs in
                if lhs.receivedBytes + lhs.sentBytes == rhs.receivedBytes + rhs.sentBytes {
                    return lhs.key < rhs.key
                }

                return lhs.receivedBytes + lhs.sentBytes > rhs.receivedBytes + rhs.sentBytes
            }

        guard !candidates.isEmpty else {
            return nil
        }

        return aggregateNetworkCounters(candidates)
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

    private static func readNetworkCounters() -> [String: SystemStatusNetworkCounter] {
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
            (key, value.counter)
        })
    }

    private static func aggregateNetworkCounters(_ counters: [SystemStatusNetworkCounter]) -> SystemStatusNetworkCounter {
        guard counters.count > 1 else {
            return counters[0]
        }

        let sortedKeys = counters.map(\.key).sorted()
        let receivedBytes = counters.reduce(UInt64(0)) { $0 + $1.receivedBytes }
        let sentBytes = counters.reduce(UInt64(0)) { $0 + $1.sentBytes }
        let ipAddress = counters.first(where: { $0.ipAddress != nil })?.ipAddress

        return SystemStatusNetworkCounter(
            key: "aggregate:\(sortedKeys.joined(separator: ","))",
            displayName: "多接口",
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

    private static func collectTopProcesses(limit: Int) -> [SystemStatusTopProcess] {
        guard let output = runCommand(path: "/bin/ps", arguments: ["-Aceo", "pid=,pcpu=,pmem=,comm=", "-r"]) else {
            return []
        }

        return SystemStatusProcessParser.parsePSOutput(output, limit: limit)
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

    private struct NetworkCounterAccumulator {
        let name: String
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var ipv4Address: String?
        var ipv6Address: String?
        var isUp = false

        var counter: SystemStatusNetworkCounter {
            SystemStatusNetworkCounter(
                key: name,
                displayName: name,
                receivedBytes: receivedBytes,
                sentBytes: sentBytes,
                ipAddress: ipv4Address ?? ipv6Address,
                isUp: isUp
            )
        }
    }
}

enum SystemStatusProcessParser {
    static func parsePSOutput(_ rawOutput: String, limit: Int) -> [SystemStatusTopProcess] {
        guard limit > 0 else {
            return []
        }

        let processes = rawOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
            .sorted { lhs, rhs in
                if lhs.cpuPercent != rhs.cpuPercent {
                    return lhs.cpuPercent > rhs.cpuPercent
                }
                if lhs.memoryPercent != rhs.memoryPercent {
                    return lhs.memoryPercent > rhs.memoryPercent
                }
                return lhs.pid < rhs.pid
            }

        return Array(processes.prefix(limit))
    }

    private static func parseLine(_ line: String) -> SystemStatusTopProcess? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4 else {
            return nil
        }

        guard
            let pid = Int(fields[0]),
            pid > 0,
            let cpuPercent = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
            let memoryPercent = Double(fields[2].replacingOccurrences(of: ",", with: "."))
        else {
            return nil
        }

        let command = fields[3...].joined(separator: " ")
        guard !command.isEmpty else {
            return nil
        }

        return SystemStatusTopProcess(
            pid: pid,
            displayName: displayName(for: command),
            command: command,
            cpuPercent: cpuPercent,
            memoryPercent: memoryPercent
        )
    }

    private static func displayName(for command: String) -> String {
        let lastPathComponent = URL(fileURLWithPath: command).lastPathComponent
        guard !lastPathComponent.isEmpty else {
            return command
        }

        return lastPathComponent
    }
}
