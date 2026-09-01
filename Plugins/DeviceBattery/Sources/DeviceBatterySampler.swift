import Foundation
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.ps
import MacToolsPluginKit

protocol DeviceBatterySampling: Sendable {
    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem]

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem]

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem]
}

struct DeviceBatteryBluetoothSamplingOptions: Equatable, Sendable {
    let forceProfileRefresh: Bool
    let performActiveScan: Bool
    let revalidateSupplementalState: Bool

    init(
        forceProfileRefresh: Bool,
        performActiveScan: Bool,
        revalidateSupplementalState: Bool = false
    ) {
        self.forceProfileRefresh = forceProfileRefresh
        self.performActiveScan = performActiveScan
        self.revalidateSupplementalState = revalidateSupplementalState
    }
}

private struct DeviceBatteryIncrementalLogItems: Sendable {
    let items: [DeviceBatteryItem]
    let completion: DeviceBatteryCommandCompletion
}

struct DeviceBatteryBluetoothProfileSnapshot: Sendable {
    let output: String
    let observedAt: Date
}

struct DeviceBatteryBluetoothProfileCache: Sendable {
    private(set) var snapshot: DeviceBatteryBluetoothProfileSnapshot? = nil

    func reusableSnapshot(
        at referenceDate: Date,
        maximumAge: TimeInterval
    ) -> DeviceBatteryBluetoothProfileSnapshot? {
        guard let snapshot else {
            return nil
        }
        let age = referenceDate.timeIntervalSince(snapshot.observedAt)
        return age >= 0 && age < maximumAge ? snapshot : nil
    }

    mutating func store(output: String, observedAt: Date) -> DeviceBatteryBluetoothProfileSnapshot {
        let snapshot = DeviceBatteryBluetoothProfileSnapshot(
            output: output,
            observedAt: observedAt
        )
        self.snapshot = snapshot
        return snapshot
    }
}

struct DeviceBatteryIncrementalLogState: Equatable, Sendable {
    private(set) var cursorDate: Date?
    private(set) var lastAttemptDate: Date?

    func shouldRefresh(at referenceDate: Date, interval: TimeInterval) -> Bool {
        guard let lastAttemptDate else { return true }
        return referenceDate.timeIntervalSince(lastAttemptDate) >= interval
    }

    mutating func recordAttempt(
        at referenceDate: Date,
        completion: DeviceBatteryCommandCompletion?,
        cursorOverlap: TimeInterval = 2
    ) {
        lastAttemptDate = referenceDate
        if completion == .completed {
            cursorDate = referenceDate.addingTimeInterval(-cursorOverlap)
        }
    }
}

actor DeviceBatterySampler: DeviceBatterySampling {
    private static let bluetoothProfileCacheInterval: TimeInterval = 5 * 60
    private static let bluetoothPowerLogRefreshInterval: TimeInterval = 5 * 60
    private static let batteryCenterLogRefreshInterval: TimeInterval = 60
    private static let bluetoothPowerLogLookback = "5m"
    private static let bluetoothPowerLogTimeout: TimeInterval = 2
    private static let batteryCenterLogLookback = "5m"
    private static let batteryCenterLogTimeout: TimeInterval = 2
    private static let visibleSupplementalRevalidationInterval: TimeInterval = 15
    private let localization: PluginLocalization
    private let mobileDeviceReader: any DeviceBatteryMobileDeviceSampling
    private var bluetoothProfileCache = DeviceBatteryBluetoothProfileCache()
    private var bluetoothPowerLogState = DeviceBatteryIncrementalLogState()
    private var batteryCenterLogState = DeviceBatteryIncrementalLogState()
    private var supplementalItemCache = DeviceBatterySupplementalItemCache()

    init(
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        mobileDeviceReader: any DeviceBatteryMobileDeviceSampling = DeviceBatteryMobileDeviceReader()
    ) {
        self.localization = localization
        self.mobileDeviceReader = mobileDeviceReader
    }

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        Self.readInternalBattery(
            referenceDate: referenceDate,
            localization: localization
        )
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        let localization = localization
        if options.forceProfileRefresh {
            supplementalItemCache.removeAll()
        }
        guard let profileSnapshot = await bluetoothProfileOutput(
            referenceDate: referenceDate,
            forceRefresh: options.forceProfileRefresh
        ) else {
            return []
        }

        let bluetoothData = Self.bluetoothProfile(fromSystemProfilerOutput: profileSnapshot.output)
        var baseItems = Self.collectBluetoothDevices(
            from: bluetoothData,
            profileReferenceDate: profileSnapshot.observedAt,
            liveReferenceDate: referenceDate,
            localization: localization
        )
        baseItems.append(contentsOf: Self.collectMagicAccessoryDevices(
            from: bluetoothData,
            referenceDate: referenceDate,
            localization: localization
        ))
        baseItems = Self.deduplicated(baseItems)
        let targets = Self.bluetoothBatteryTargets(from: bluetoothData)
        let shouldReadBatteryCenterLog = !targets.isEmpty
            || !bluetoothData.connectedDevices.isEmpty
            || !bluetoothData.batteryDevices.isEmpty

        let shouldRevalidatePowerLog = options.revalidateSupplementalState
            && bluetoothPowerLogState.shouldRefresh(
                at: referenceDate,
                interval: Self.visibleSupplementalRevalidationInterval
            )
        let shouldRevalidateBatteryCenterLog = options.revalidateSupplementalState
            && batteryCenterLogState.shouldRefresh(
                at: referenceDate,
                interval: Self.visibleSupplementalRevalidationInterval
            )
        let shouldRefreshPowerLog = options.forceProfileRefresh
            || shouldRevalidatePowerLog
            || bluetoothPowerLogState.shouldRefresh(
                at: referenceDate,
                interval: Self.bluetoothPowerLogRefreshInterval
            )
        let shouldRefreshBatteryCenterLog = options.forceProfileRefresh
            || shouldRevalidateBatteryCenterLog
            || batteryCenterLogState.shouldRefresh(
                at: referenceDate,
                interval: Self.batteryCenterLogRefreshInterval
            )
        async let bluetoothPowerLogResult: DeviceBatteryIncrementalLogItems? = shouldRefreshPowerLog
            ? Self.collectBluetoothPowerLogDevices(
                targets: targets,
                existingItems: baseItems,
                referenceDate: referenceDate,
                startDate: bluetoothPowerLogState.cursorDate,
                localization: localization
            )
            : DeviceBatteryIncrementalLogItems(items: [], completion: .completed)
        async let batteryCenterLogResult: DeviceBatteryIncrementalLogItems? = shouldRefreshBatteryCenterLog
            ? Self.collectBatteryCenterLogDevices(
                shouldReadLog: shouldReadBatteryCenterLog,
                targets: targets,
                referenceDate: referenceDate,
                startDate: batteryCenterLogState.cursorDate,
                localization: localization
            )
            : DeviceBatteryIncrementalLogItems(items: [], completion: .completed)
        async let activeScanItems = options.performActiveScan
            ? DeviceBatteryBluetoothScanner.collectBatteryDevices(
                targets: targets,
                referenceDate: referenceDate,
                localization: localization
            )
            : []

        let powerLogItems = await bluetoothPowerLogResult
        let batteryLogItems = await batteryCenterLogResult
        let scannedItems = await activeScanItems
        guard !Task.isCancelled else { return [] }

        if shouldRefreshPowerLog {
            bluetoothPowerLogState.recordAttempt(
                at: referenceDate,
                completion: powerLogItems?.completion
            )
        }
        if shouldRefreshBatteryCenterLog {
            batteryCenterLogState.recordAttempt(
                at: referenceDate,
                completion: batteryLogItems?.completion
            )
        }

        let connectedTargets = targets.filter(\.isConnected)
        supplementalItemCache.update(
            with: (powerLogItems?.items ?? []) + (batteryLogItems?.items ?? []) + scannedItems,
            knownTargetIdentities: Set(targets.map(\.deviceIdentity)),
            connectedTargetIdentities: Set(connectedTargets.map(\.deviceIdentity)),
            referenceDate: referenceDate
        )
        let singleBatteryDevices = Set(targets.compactMap { target in
            Self.batteryTopology(for: target) == .single
                ? target.deviceIdentity
                : nil
        })
        let topologySafeItems = DeviceBatteryItemNormalizer.removingComponentItems(
            baseItems + supplementalItemCache.items,
            forSingleBatteryDevices: singleBatteryDevices
        )
        return Self.deduplicated(topologySafeItems)
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        await mobileDeviceReader.collectDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: minimumRefreshInterval
        )
    }

    private func bluetoothProfileOutput(
        referenceDate: Date,
        forceRefresh: Bool
    ) async -> DeviceBatteryBluetoothProfileSnapshot? {
        if !forceRefresh,
           let snapshot = bluetoothProfileCache.reusableSnapshot(
               at: referenceDate,
               maximumAge: Self.bluetoothProfileCacheInterval
           ) {
            return snapshot
        }

        let commandResult = await Self.runCommand(
            path: "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType", "-json"],
            timeout: 3
        )
        guard !Task.isCancelled else { return nil }

        if let commandResult,
           commandResult.completion == .completed,
           !commandResult.output.isEmpty {
            return bluetoothProfileCache.store(
                output: commandResult.output,
                observedAt: referenceDate
            )
        }
        return bluetoothProfileCache.snapshot
    }

    private static func readInternalBattery(
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        guard
            let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let powerSources = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [CFTypeRef],
            !powerSources.isEmpty
        else {
            return []
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
            return []
        }

        let maxCapacity = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        let currentCapacity = min(max(description[kIOPSCurrentCapacityKey] as? Int ?? 0, 0), maxCapacity)
        let level = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = (description[kIOPSIsChargedKey] as? Bool) ?? (level >= 100)
        let powerSource = description[kIOPSPowerSourceStateKey] as? String ?? ""
        let chargeState = batteryChargeState(
            level: level,
            isCharging: isCharging,
            isCharged: isCharged,
            powerSource: powerSource
        )
        let name = internalBatteryDisplayName(
            rawName: description[kIOPSNameKey] as? String,
            localization: localization
        )

        return [
            DeviceBatteryItem(
                id: "internal-battery",
                deviceIdentity: .internalBattery,
                name: name,
                model: nil,
                kind: .internalBattery,
                level: level,
                chargeState: chargeState,
                parentName: nil,
                source: "IOPowerSources",
                lastUpdated: referenceDate,
                isConnected: true,
                detail: internalBatteryDetail(
                    description: description,
                    chargeState: chargeState,
                    localization: localization
                ),
                componentIdentity: nil
            )
        ]
    }

    private static func batteryChargeState(
        level: Int,
        isCharging: Bool,
        isCharged: Bool,
        powerSource: String
    ) -> DeviceBatteryChargeState {
        if isCharged || level >= 100 {
            return .charged
        }
        if isCharging {
            return .charging
        }
        if powerSource == "AC Power" {
            return .plugged
        }
        return .normal
    }

    private static func internalBatteryDetail(
        description: [String: Any],
        chargeState: DeviceBatteryChargeState,
        localization: PluginLocalization
    ) -> String {
        let timeKey = chargeState == .charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        guard let minutes = description[timeKey] as? Int, minutes > 0 else {
            return chargeState.title(localization: localization)
        }

        return localization.format(
            "batteryDetail.remainingTime",
            defaultValue: "%@ %d小时%d分",
            chargeState.title(localization: localization),
            minutes / 60,
            minutes % 60
        )
    }

    private static func internalBatteryDisplayName(
        rawName: String?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        let cleanedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowercasedName = cleanedName.lowercased()
        let isSystemIdentifier = cleanedName.isEmpty
            || lowercasedName.contains("internal")
            || lowercasedName == "battery"
            || lowercasedName.contains("battery-")

        if !isSystemIdentifier {
            return cleanedName
        }

        let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hostName.isEmpty
            ? localization.string("deviceName.internalBattery", defaultValue: "Mac 电池")
            : hostName
    }

    private static func bluetoothProfile(
        fromSystemProfilerOutput output: String
    ) -> BluetoothProfile {
        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawSections = json["SPBluetoothDataType"] as? [[String: Any]],
            let section = rawSections.first
        else {
            return BluetoothProfile(connectedDevices: [], batteryDevices: [])
        }

        let connectedDevices = parseBluetoothDevices(
            from: section["device_connected"],
            isConnected: true
        )
        let disconnectedBatteryDevices = parseBluetoothDevices(
            from: section["device_not_connected"],
            isConnected: false
        )
            .filter { hasBluetoothBatteryFields($0.info) || isAppleHeadphoneBatteryCandidate($0) }
        let connectedBatteryDevices = mergingConnectedBLEShadows(in: connectedDevices)

        return BluetoothProfile(
            connectedDevices: connectedDevices,
            batteryDevices: mergedBatteryDevices(
                connectedDevices: connectedBatteryDevices,
                disconnectedBatteryDevices: disconnectedBatteryDevices
            )
        )
    }

    static func bluetoothProfileBatteryItems(
        fromSystemProfilerOutput output: String,
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        collectBluetoothProfileBatteryItems(
            from: bluetoothProfile(fromSystemProfilerOutput: output),
            referenceDate: referenceDate
        )
    }

    static func bluetoothPowerLogBatteryItems(
        fromSystemProfilerOutput profileOutput: String,
        powerLogOutput: String,
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        let targets = bluetoothBatteryTargets(
            from: bluetoothProfile(fromSystemProfilerOutput: profileOutput)
        )
        let items = bluetoothPowerLogItems(
            from: DeviceBatteryBluetoothPowerLogParser.readings(from: powerLogOutput),
            targets: targets,
            referenceDate: referenceDate,
            localization: PluginLocalization(bundle: .main)
        )
        return DeviceBatteryItemNormalizer.preferringDetailedComponents(items)
    }

    static func batteryCenterLogBatteryItems(
        fromSystemProfilerOutput profileOutput: String,
        batteryCenterLogOutput: String,
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        let targets = bluetoothBatteryTargets(
            from: bluetoothProfile(fromSystemProfilerOutput: profileOutput)
        )
        let items = batteryCenterLogItems(
            from: DeviceBatteryBatteryCenterLogParser.readings(from: batteryCenterLogOutput),
            targets: targets,
            referenceDate: referenceDate,
            localization: PluginLocalization(bundle: .main)
        )
        return DeviceBatteryItemNormalizer.preferringDetailedComponents(items)
    }

    private static func parseBluetoothDevices(
        from value: Any?,
        isConnected: Bool
    ) -> [BluetoothProfileDevice] {
        guard let rawDevices = value as? [[String: Any]] else {
            return []
        }

        return rawDevices.enumerated().compactMap { index, rawDevice in
            guard let name = rawDevice.keys.first,
                  let info = rawDevice[name] as? [String: Any]
            else {
                return nil
            }

            return BluetoothProfileDevice(
                sourceRecordID: "\(isConnected ? "connected" : "paired"):\(index)",
                name: name,
                info: info,
                isConnected: isConnected
            )
        }
    }

    private static func hasBluetoothBatteryFields(_ info: [String: Any]) -> Bool {
        [
            "device_batteryLevelMain",
            "device_batteryLevelCase",
            "device_batteryLevelLeft",
            "device_batteryLevelRight"
        ]
            .contains { batteryValue(from: info[$0]) != nil }
    }

    private static func isAppleHeadphoneBatteryCandidate(_ device: BluetoothProfileDevice) -> Bool {
        guard normalizedHexIdentifier(stringValue(device.info["device_vendorID"])) == "004C" else {
            return false
        }

        let productID = stringValue(device.info["device_productID"])
        let model = productID.flatMap { AppleBluetoothProductCatalog.modelName(forProductID: $0) }
        let haystack = [
            device.name,
            model,
            device.info["device_minorType"] as? String
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return haystack.contains("airpods")
            || haystack.contains("beats")
            || haystack.contains("headphone")
            || haystack.contains("headset")
    }

    private static func mergedBatteryDevices(
        connectedDevices: [BluetoothProfileDevice],
        disconnectedBatteryDevices: [BluetoothProfileDevice]
    ) -> [BluetoothProfileDevice] {
        var unusedConnectedIndices = Set(connectedDevices.indices)
        var unusedDisconnectedIndices = Set(disconnectedBatteryDevices.indices)
        var pairedIndexByConnectedIndex = mutualUniqueDeviceMatches(
            connectedIndices: unusedConnectedIndices,
            disconnectedIndices: unusedDisconnectedIndices
        ) { connectedIndex, disconnectedIndex in
            guard let connectedAddress = normalizedIdentifier(
                connectedDevices[connectedIndex].info["device_address"]
            ) else {
                return false
            }
            return normalizedIdentifier(
                disconnectedBatteryDevices[disconnectedIndex].info["device_address"]
            ) == connectedAddress
        }
        unusedConnectedIndices.subtract(pairedIndexByConnectedIndex.keys)
        unusedDisconnectedIndices.subtract(pairedIndexByConnectedIndex.values)

        let corroboratedMatches = mutualUniqueDeviceMatches(
            connectedIndices: unusedConnectedIndices,
            disconnectedIndices: unusedDisconnectedIndices
        ) { connectedIndex, disconnectedIndex in
            canAliasConnectedAppleHeadphone(
                connectedDevices[connectedIndex],
                to: disconnectedBatteryDevices[disconnectedIndex]
            )
        }
        pairedIndexByConnectedIndex.merge(corroboratedMatches) { existing, _ in existing }
        unusedDisconnectedIndices.subtract(corroboratedMatches.values)

        let connectedResults = connectedDevices.indices.map { connectedIndex in
            guard let pairedIndex = pairedIndexByConnectedIndex[connectedIndex] else {
                return connectedDevices[connectedIndex]
            }
            return mergingConnectedDevice(
                connectedDevices[connectedIndex],
                withPairedDevice: disconnectedBatteryDevices[pairedIndex]
            )
        }
        return connectedResults + unusedDisconnectedIndices.sorted().map {
            disconnectedBatteryDevices[$0]
        }
    }

    private static func mergingConnectedBLEShadows(
        in devices: [BluetoothProfileDevice]
    ) -> [BluetoothProfileDevice] {
        let shadowIndices = Set(devices.indices.filter {
            isMetadataPoorConnectedBLEShadow(devices[$0])
        })
        let stableIndices = Set(devices.indices.filter {
            isStableConnectedSplitAppleHeadphone(devices[$0])
        })
        guard !shadowIndices.isEmpty, !stableIndices.isEmpty else {
            return devices
        }

        let stableIndexByShadowIndex = mutualUniqueDeviceMatches(
            connectedIndices: shadowIndices,
            disconnectedIndices: stableIndices
        ) { shadowIndex, stableIndex in
            normalizedDeviceName(devices[shadowIndex].name)
                == normalizedDeviceName(devices[stableIndex].name)
        }
        let shadowIndexByStableIndex = Dictionary(
            uniqueKeysWithValues: stableIndexByShadowIndex.map { ($0.value, $0.key) }
        )

        return devices.indices.compactMap { index in
            if stableIndexByShadowIndex[index] != nil {
                return nil
            }
            guard let shadowIndex = shadowIndexByStableIndex[index] else {
                return devices[index]
            }
            return mergingConnectedBLEShadow(
                devices[shadowIndex],
                into: devices[index]
            )
        }
    }

    private static func isStableConnectedSplitAppleHeadphone(
        _ device: BluetoothProfileDevice
    ) -> Bool {
        guard device.isConnected,
              isAppleHeadphoneBatteryCandidate(device),
              bluetoothGroupSerialIdentifier(in: device.info) != nil,
              let productID = normalizedProductIdentifier(
                  stringValue(device.info["device_productID"])
              )
        else {
            return false
        }
        return AppleBluetoothProductCatalog.batteryTopology(forProductID: productID) == .split
    }

    private static func mergingConnectedBLEShadow(
        _ shadow: BluetoothProfileDevice,
        into stableDevice: BluetoothProfileDevice
    ) -> BluetoothProfileDevice {
        var info = stableDevice.info
        let batteryFields = [
            "device_batteryLevelMain",
            "device_batteryLevelLeft",
            "device_batteryLevelRight",
            "device_batteryLevelCase"
        ]
        for field in batteryFields where info[field] == nil {
            info[field] = shadow.info[field]
        }

        return BluetoothProfileDevice(
            sourceRecordID: stableDevice.sourceRecordID,
            name: stableDevice.name,
            info: info,
            isConnected: true
        )
    }

    private static func mutualUniqueDeviceMatches(
        connectedIndices: Set<Int>,
        disconnectedIndices: Set<Int>,
        matches: (Int, Int) -> Bool
    ) -> [Int: Int] {
        let candidatesByConnected = Dictionary(
            uniqueKeysWithValues: connectedIndices.map { connectedIndex in
                (
                    connectedIndex,
                    disconnectedIndices.filter { matches(connectedIndex, $0) }
                )
            }
        )
        let candidatesByDisconnected = Dictionary(
            uniqueKeysWithValues: disconnectedIndices.map { disconnectedIndex in
                (
                    disconnectedIndex,
                    connectedIndices.filter { matches($0, disconnectedIndex) }
                )
            }
        )

        return candidatesByConnected.reduce(into: [:]) { result, entry in
            guard entry.value.count == 1,
                  let disconnectedIndex = entry.value.first,
                  candidatesByDisconnected[disconnectedIndex] == [entry.key]
            else {
                return
            }
            result[entry.key] = disconnectedIndex
        }
    }

    private static func canAliasConnectedAppleHeadphone(
        _ connectedDevice: BluetoothProfileDevice,
        to pairedDevice: BluetoothProfileDevice
    ) -> Bool {
        guard isAppleHeadphoneBatteryCandidate(pairedDevice),
              hasBluetoothComponentBatteryFields(connectedDevice.info)
                || isAppleHeadphoneBatteryCandidate(connectedDevice)
        else {
            return false
        }

        let connectedVendorID = normalizedHexIdentifier(
            stringValue(connectedDevice.info["device_vendorID"])
        )
        let pairedVendorID = normalizedHexIdentifier(
            stringValue(pairedDevice.info["device_vendorID"])
        )
        if let connectedVendorID, let pairedVendorID, connectedVendorID != pairedVendorID {
            return false
        }

        let connectedProductID = normalizedProductIdentifier(
            stringValue(connectedDevice.info["device_productID"])
        )
        let pairedProductID = normalizedProductIdentifier(
            stringValue(pairedDevice.info["device_productID"])
        )
        if let connectedProductID, let pairedProductID, connectedProductID != pairedProductID {
            return false
        }

        let connectedSerials = bluetoothSerialIdentifiers(in: connectedDevice.info)
        let pairedSerials = bluetoothSerialIdentifiers(in: pairedDevice.info)
        if !connectedSerials.isEmpty,
           !pairedSerials.isEmpty,
           connectedSerials.isDisjoint(with: pairedSerials) {
            return false
        }
        if !connectedSerials.isDisjoint(with: pairedSerials) {
            return true
        }

        // A metadata-poor connected AirPods record can be a live BLE shadow of
        // the stable record. Correlate it only when the source shape or a
        // complete component snapshot corroborates a single one-to-one candidate.
        guard normalizedDeviceName(connectedDevice.name) == normalizedDeviceName(pairedDevice.name),
              connectedProductID == nil,
              let pairedProductID,
              AppleBluetoothProductCatalog.batteryTopology(forProductID: pairedProductID) == .split
        else {
            return false
        }

        if isMetadataPoorConnectedBLEShadow(connectedDevice),
           bluetoothGroupSerialIdentifier(in: pairedDevice.info) != nil {
            return true
        }

        let batteryFields = [
            "device_batteryLevelLeft",
            "device_batteryLevelRight",
            "device_batteryLevelCase"
        ]
        let overlappingLevels = batteryFields.compactMap { field -> (Int, Int)? in
            guard let connectedLevel = batteryLevel(from: connectedDevice.info[field]),
                  let pairedLevel = batteryLevel(from: pairedDevice.info[field])
            else {
                return nil
            }
            return (connectedLevel, pairedLevel)
        }
        guard overlappingLevels.count == batteryFields.count,
              overlappingLevels.allSatisfy({ $0.0 == $0.1 })
        else {
            return false
        }

        let connectedLevels = Set(overlappingLevels.map(\.0))
        guard connectedLevels.count > 1,
              let connectedFirmware = bluetoothFirmwareIdentifier(in: connectedDevice.info),
              connectedFirmware == bluetoothFirmwareIdentifier(in: pairedDevice.info)
        else {
            return false
        }
        return true
    }

    private static func isMetadataPoorConnectedBLEShadow(
        _ device: BluetoothProfileDevice
    ) -> Bool {
        guard device.isConnected,
              normalizedProductIdentifier(
                  stringValue(device.info["device_productID"])
              ) == nil,
              bluetoothSerialIdentifiers(in: device.info).isEmpty,
              batteryValue(from: device.info["device_batteryLevelMain"]) == nil,
              hasBluetoothComponentBatteryFields(device.info),
              let serviceDescription = stringValue(device.info["device_services"])?
                .lowercased()
        else {
            return false
        }

        let normalizedServiceDescription = serviceDescription
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalizedServiceDescription == "0x400000 < ble >"
    }

    private static func bluetoothFirmwareIdentifier(in info: [String: Any]) -> String? {
        [
            "device_firmwareVersion",
            "device_firmware",
            "device_firmware_version"
        ]
            .lazy
            .compactMap { normalizedIdentifier(info[$0]) }
            .first
    }

    private static func bluetoothSerialIdentifiers(in info: [String: Any]) -> Set<String> {
        let serialKeys = [
            "device_serialNumber",
            "device_serialNumberMain",
            "device_serialNumberLeft",
            "device_serialNumberRight",
            "device_serialNumberCase"
        ]
        return Set(serialKeys.compactMap { validBluetoothSerialIdentifier(info[$0]) })
    }

    private static func mergingConnectedDevice(
        _ connectedDevice: BluetoothProfileDevice,
        withPairedDevice pairedDevice: BluetoothProfileDevice
    ) -> BluetoothProfileDevice {
        var info = pairedDevice.info.merging(connectedDevice.info) { _, connectedValue in
            connectedValue
        }
        if let pairedAddress = pairedDevice.info["device_address"] {
            info["device_address"] = pairedAddress
        }

        return BluetoothProfileDevice(
            sourceRecordID: connectedDevice.sourceRecordID,
            name: connectedDevice.name,
            info: info,
            isConnected: true
        )
    }

    private static func collectBluetoothPowerLogDevices(
        targets allTargets: [BluetoothBatteryTarget],
        existingItems: [DeviceBatteryItem],
        referenceDate: Date,
        startDate: Date?,
        localization: PluginLocalization
    ) async -> DeviceBatteryIncrementalLogItems? {
        let targets = allTargets.filter { target in
            needsBluetoothPowerLogFallback(target: target, existingItems: existingItems)
        }
        guard !targets.isEmpty else {
            return DeviceBatteryIncrementalLogItems(items: [], completion: .completed)
        }

        let componentTargets = targets.filter { supportsComponentPowerLog(target: $0) }
        let regularTargets = targets.filter { !supportsComponentPowerLog(target: $0) }
        guard let commandResult = await collectBluetoothPowerLogOutput(
            targets: targets,
            startDate: startDate,
            lookback: bluetoothPowerLogLookback,
            timeout: bluetoothPowerLogTimeout
        ) else {
            return nil
        }
        let recentReadings = DeviceBatteryBluetoothPowerLogParser.readings(
            from: commandResult.output
        )

        var items: [DeviceBatteryItem] = []
        if !componentTargets.isEmpty {
            let componentReadings = recentReadings.filter { reading in
                matchingBluetoothPowerLogTarget(reading, in: componentTargets) != nil
            }
            items.append(contentsOf: bluetoothPowerLogItems(
                from: componentReadings,
                targets: componentTargets,
                referenceDate: referenceDate,
                localization: localization
            ))
        }

        if !regularTargets.isEmpty {
            let regularReadings = recentReadings.filter { reading in
                matchingBluetoothPowerLogTarget(reading, in: regularTargets) != nil
            }

            let regularItems = bluetoothPowerLogItems(
                from: regularReadings,
                targets: regularTargets,
                referenceDate: referenceDate,
                localization: localization
            )
            if !regularItems.isEmpty {
                items.append(contentsOf: regularItems)
            }
        }

        return DeviceBatteryIncrementalLogItems(
            items: DeviceBatteryItemNormalizer.preferringDetailedComponents(items),
            completion: commandResult.completion
        )
    }

    private static let bluetoothPowerLogPredicate = #"subsystem == "com.apple.bluetooth" AND category == "CBPowerSource" AND eventMessage CONTAINS "Power source updated" AND eventMessage CONTAINS "Battery""#

    private static func collectBluetoothPowerLogOutput(
        targets: [BluetoothBatteryTarget],
        startDate: Date?,
        lookback: String,
        timeout: TimeInterval
    ) async -> DeviceBatteryCommandResult? {
        let arguments = bluetoothPowerLogCommandArguments(
            targets: targets,
            startDate: startDate,
            lookback: lookback
        )
        return await runCommand(
            path: "/usr/bin/nice",
            arguments: arguments,
            timeout: timeout,
            outputLineFilter: { line in
                isBluetoothPowerLogLine(line, matching: targets)
            }
        )
    }

    static func bluetoothPowerLogCommandArguments(
        targets: [BluetoothBatteryTarget],
        startDate: Date?,
        lookback: String
    ) -> [String] {
        [
            "-n",
            "19",
            "/usr/bin/log",
            "show",
            "--info"
        ] + logWindowArguments(startDate: startDate, fallbackLookback: lookback) + [
            "--style",
            "compact",
            "--predicate",
            bluetoothPowerLogPredicate(for: targets)
        ]
    }

    private static func collectBatteryCenterLogDevices(
        shouldReadLog: Bool,
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        startDate: Date?,
        localization: PluginLocalization
    ) async -> DeviceBatteryIncrementalLogItems? {
        guard shouldReadLog else {
            return DeviceBatteryIncrementalLogItems(items: [], completion: .completed)
        }

        guard let commandResult = await collectBatteryCenterLogOutput(
            startDate: startDate,
            lookback: batteryCenterLogLookback,
            timeout: batteryCenterLogTimeout
        ) else {
            return nil
        }
        let recentReadings = DeviceBatteryBatteryCenterLogParser.readings(
            from: commandResult.output
        )

        return DeviceBatteryIncrementalLogItems(
            items: batteryCenterLogItems(
                from: recentReadings,
                targets: targets,
                referenceDate: referenceDate,
                localization: localization
            ),
            completion: commandResult.completion
        )
    }

    private static func collectBatteryCenterLogOutput(
        startDate: Date?,
        lookback: String,
        timeout: TimeInterval
    ) async -> DeviceBatteryCommandResult? {
        let arguments = [
            "-n",
            "19",
            "/usr/bin/log",
            "show",
            "--info"
        ] + logWindowArguments(startDate: startDate, fallbackLookback: lookback) + [
            "--style",
            "compact",
            "--predicate",
            #"subsystem == "com.apple.BatteryCenter" AND eventMessage CONTAINS "BCBatteryDevice" AND eventMessage CONTAINS "percentCharge""#
        ]
        return await runCommand(
            path: "/usr/bin/nice",
            arguments: arguments,
            timeout: timeout,
            outputLineFilter: { line in
                line.contains("BCBatteryDevice") && line.contains("percentCharge")
            }
        )
    }

    static func logWindowArguments(
        startDate: Date?,
        fallbackLookback: String,
        referenceDate: Date = Date()
    ) -> [String] {
        guard let startDate else {
            return ["--last", fallbackLookback]
        }

        let cappedStartDate = max(
            startDate,
            referenceDate.addingTimeInterval(-10 * 60)
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return ["--start", formatter.string(from: cappedStartDate)]
    }

    private static func batteryCenterLogItems(
        from readings: [DeviceBatteryBatteryCenterLogReading],
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        let groupedTargets = batteryCenterTargetsByGroupID(
            readings: readings,
            targets: targets,
            localization: localization
        )

        return readings.compactMap { reading in
            let readingGroupID = batteryCenterReadingGroupID(reading)
            let stableSourceDeviceIdentity = batteryCenterStableSourceDeviceIdentity(reading)
            let matchedTarget = matchingBatteryCenterLogTarget(
                reading,
                in: targets,
                localization: localization
            )
                ?? readingGroupID.flatMap { groupedTargets[$0] }
            if let target = matchedTarget {
                let role = batteryCenterComponentRole(reading)
                let isSingleBatteryDevice = batteryTopology(for: target) == .single
                    || batteryTopology(productID: reading.productID) == .single
                guard !isSingleBatteryDevice || role?.isPart != true else {
                    return nil
                }
                let identity = batteryCenterComponentIdentity(
                    groupID: target.deviceIdentity.key,
                    kind: target.kind,
                    role: role
                )
                let presentation = batteryCenterPresentation(
                    targetName: target.name,
                    role: role,
                    localization: localization
                )
                return DeviceBatteryItem(
                    id: batteryCenterItemID(
                        groupID: target.deviceIdentity.key,
                        role: identity?.role
                    ),
                    deviceIdentity: target.deviceIdentity,
                    name: presentation.name,
                    model: firstNonEmpty(reading.model, target.model),
                    kind: target.kind,
                    level: reading.level,
                    chargeState: reading.chargeState,
                    parentName: presentation.parentName,
                    source: "BatteryCenter",
                    lastUpdated: reading.observedAt ?? referenceDate,
                    isConnected: reading.isConnected ?? target.isConnected,
                    detail: firstNonEmpty(reading.category, target.detail),
                    componentIdentity: identity,
                    alternateDeviceIdentities: Set(stableSourceDeviceIdentity.map { [$0] } ?? [])
                )
            }

            guard !batteryCenterReadingConflictsWithKnownTarget(
                reading,
                targets: targets
            ) else {
                return nil
            }
            guard canUseUnmatchedBatteryCenterReading(reading),
                  let name = firstNonEmptyOptional(reading.name, reading.groupName),
                  let deviceIdentity = stableSourceDeviceIdentity
            else {
                return nil
            }

            let kind = batteryCenterKind(reading: reading)
            // Apple mobile devices have a dedicated reader with a stable MobileDevice
            // identifier. BatteryCenter exposes a different identifier domain, so
            // presenting unmatched mobile log records would create stale duplicates.
            guard !kind.isAppleMobileDevice else {
                return nil
            }
            let role = batteryCenterComponentRole(reading)
            let topology = batteryTopology(productID: reading.productID)
            guard topology != .single || role?.isPart != true else {
                return nil
            }
            let identity = batteryCenterComponentIdentity(
                groupID: deviceIdentity.key,
                kind: kind,
                role: role
            )
            return DeviceBatteryItem(
                id: batteryCenterItemID(groupID: deviceIdentity.key, role: identity?.role),
                deviceIdentity: deviceIdentity,
                name: name,
                model: reading.model,
                kind: kind,
                level: reading.level,
                chargeState: reading.chargeState,
                parentName: nil,
                source: "BatteryCenter",
                lastUpdated: reading.observedAt ?? referenceDate,
                isConnected: reading.isConnected ?? true,
                detail: firstNonEmpty(reading.category, reading.transportType),
                componentIdentity: identity
            )
        }
    }

    private static func batteryCenterStableSourceDeviceIdentity(
        _ reading: DeviceBatteryBatteryCenterLogReading
    ) -> DeviceBatteryDeviceIdentity? {
        let identifier = batteryCenterReadingGroupID(reading)
            ?? normalizedIdentifier(reading.identifier)
            ?? normalizedIdentifier(reading.accessoryID)
        return identifier.map(DeviceBatteryDeviceIdentity.batteryCenter)
    }

    private static func batteryCenterTargetsByGroupID(
        readings: [DeviceBatteryBatteryCenterLogReading],
        targets: [BluetoothBatteryTarget],
        localization: PluginLocalization
    ) -> [String: BluetoothBatteryTarget] {
        var candidatesByGroupID: [String: [BluetoothBatteryTarget]] = [:]
        for reading in readings {
            guard let groupID = batteryCenterReadingGroupID(reading),
                  let target = matchingBatteryCenterLogTarget(
                      reading,
                      in: targets,
                      localization: localization
                  )
            else {
                continue
            }
            candidatesByGroupID[groupID, default: []].append(target)
        }

        return candidatesByGroupID.reduce(into: [:]) { result, entry in
            let targetsByID = Dictionary(
                entry.value.map { ($0.id, $0) },
                uniquingKeysWith: { existing, _ in existing }
            )
            guard targetsByID.count == 1, let target = targetsByID.values.first else {
                return
            }
            result[entry.key] = target
        }
    }

    private static func batteryCenterReadingGroupID(
        _ reading: DeviceBatteryBatteryCenterLogReading
    ) -> String? {
        normalizedIdentifier(reading.matchIdentifier)
    }

    private static func batteryCenterComponentRole(
        _ reading: DeviceBatteryBatteryCenterLogReading
    ) -> DeviceBatteryComponentRole? {
        guard let parts = reading.parts?.lowercased() else {
            return nil
        }

        let hasLeft = parts.contains("left")
        let hasRight = parts.contains("right")
        if hasLeft && hasRight {
            return .earbuds
        }
        if hasLeft {
            return .left
        }
        if hasRight {
            return .right
        }
        if parts.contains("case") {
            return .chargingCase
        }
        return nil
    }

    private static func batteryCenterComponentIdentity(
        groupID: String,
        kind: DeviceBatteryKind,
        role: DeviceBatteryComponentRole?
    ) -> DeviceBatteryComponentIdentity? {
        guard kind == .airPodsPart else {
            return nil
        }
        return DeviceBatteryComponentIdentity(
            groupID: groupID,
            role: role ?? .aggregate
        )
    }

    private static func batteryCenterPresentation(
        targetName: String,
        role: DeviceBatteryComponentRole?,
        localization: PluginLocalization
    ) -> (name: String, parentName: String?) {
        switch role {
        case .chargingCase:
            return (
                bluetoothPartName(
                    deviceName: targetName,
                    component: .chargingCase,
                    localization: localization
                ),
                targetName
            )
        case .left:
            let caseName = bluetoothPartName(
                deviceName: targetName,
                component: .chargingCase,
                localization: localization
            )
            return (
                bluetoothPartName(
                    deviceName: targetName,
                    component: .left,
                    localization: localization
                ),
                caseName
            )
        case .right:
            let caseName = bluetoothPartName(
                deviceName: targetName,
                component: .chargingCase,
                localization: localization
            )
            return (
                bluetoothPartName(
                    deviceName: targetName,
                    component: .right,
                    localization: localization
                ),
                caseName
            )
        case .earbuds, .aggregate, nil:
            return (targetName, nil)
        }
    }

    private static func batteryCenterItemID(
        groupID: String,
        role: DeviceBatteryComponentRole?
    ) -> String {
        "batterycenter-\(groupID)-\(role?.rawValue ?? "device")"
    }

    private static func batteryCenterKind(reading: DeviceBatteryBatteryCenterLogReading) -> DeviceBatteryKind {
        if let productID = reading.productID,
           let isHeadphone = AppleBluetoothProductCatalog.isHeadphoneProduct(
               forProductID: productID
           ) {
            return isHeadphone ? .airPodsPart : .bluetooth
        }

        let haystack = [
            reading.name,
            reading.groupName,
            reading.model,
            reading.category
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if haystack.contains("iphone") || haystack.contains("mobilephone") || haystack.contains("phone") {
            return .phone
        }
        if haystack.contains("ipad") || haystack.contains("tablet") {
            return .tablet
        }
        if haystack.contains("ipod") {
            return .mediaPlayer
        }
        if haystack.contains("watch") {
            return .watch
        }
        if haystack.contains("vision") || haystack.contains("realitydevice") {
            return .spatialComputer
        }
        if haystack.contains("airpods")
            || haystack.contains("beats")
            || haystack.contains("headphone")
            || haystack.contains("headset") {
            return .airPodsPart
        }
        if haystack.contains("magic")
            || haystack.contains("keyboard")
            || haystack.contains("mouse")
            || haystack.contains("trackpad") {
            return .magicAccessory
        }
        return .bluetooth
    }

    private static func firstNonEmptyOptional(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    fileprivate static func canUseUnmatchedBatteryCenterReading(
        _ reading: DeviceBatteryBatteryCenterLogReading
    ) -> Bool {
        reading.isInternal != true && firstNonEmptyOptional(reading.name, reading.groupName) != nil
    }

    static func matchingBatteryCenterLogTarget(
        _ reading: DeviceBatteryBatteryCenterLogReading,
        in targets: [BluetoothBatteryTarget],
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> BluetoothBatteryTarget? {
        let nameMatchedTargets = targets.filter { target in
            batteryCenterNamesMatch(reading: reading, target: target)
                && batteryCenterProductIdentifiersMatch(reading: reading, target: target)
        }
        if nameMatchedTargets.count == 1 {
            return nameMatchedTargets[0]
        }

        let componentNameMatchedTargets = targets.filter { target in
            batteryCenterComponentNameMatches(
                reading: reading,
                target: target,
                localization: localization
            )
        }
        if componentNameMatchedTargets.count == 1 {
            return componentNameMatchedTargets[0]
        }

        guard firstNonEmptyOptional(reading.name, reading.groupName) == nil,
              let readingProductID = normalizedProductIdentifier(reading.productID) else {
            return nil
        }

        let productMatchedTargets = targets.filter { target in
            normalizedProductIdentifier(target.productID) == readingProductID
        }
        return productMatchedTargets.count == 1 ? productMatchedTargets[0] : nil
    }

    private static func batteryCenterNamesMatch(
        reading: DeviceBatteryBatteryCenterLogReading,
        target: BluetoothBatteryTarget
    ) -> Bool {
        let readingNames = [reading.name, reading.groupName]
            .compactMap { $0 }
            .map(normalizedDeviceName)
        return readingNames.contains(normalizedDeviceName(target.name))
    }

    private static func batteryCenterComponentNameMatches(
        reading: DeviceBatteryBatteryCenterLogReading,
        target: BluetoothBatteryTarget,
        localization: PluginLocalization
    ) -> Bool {
        guard let role = batteryCenterComponentRole(reading),
              let acceptedSuffixes = batteryCenterComponentSuffixes(
                  for: role,
                  localization: localization
              ),
              let readingProductID = normalizedProductIdentifier(reading.productID),
              let targetProductID = normalizedProductIdentifier(target.productID),
              readingProductID == targetProductID
        else {
            return false
        }

        let targetName = normalizedDeviceName(target.name)
        guard !targetName.isEmpty else {
            return false
        }

        return [reading.name, reading.groupName]
            .compactMap { $0 }
            .map(normalizedDeviceName)
            .contains { readingName in
                guard readingName.count > targetName.count,
                      readingName.hasPrefix(targetName)
                else {
                    return false
                }
                let suffix = String(readingName.dropFirst(targetName.count))
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines.union(.punctuationCharacters)
                    )
                return acceptedSuffixes.contains(suffix)
            }
    }

    private static func batteryCenterComponentSuffixes(
        for role: DeviceBatteryComponentRole,
        localization: PluginLocalization
    ) -> Set<String>? {
        let component: DeviceBatteryBluetoothPowerLogComponent
        let observedSuffixes: [String]
        switch role {
        case .left:
            component = .left
            observedSuffixes = ["left", "left ear", "左耳"]
        case .right:
            component = .right
            observedSuffixes = ["right", "right ear", "右耳"]
        case .chargingCase:
            component = .chargingCase
            observedSuffixes = ["case", "charging case", "充电盒"]
        case .aggregate, .earbuds:
            return nil
        }

        return Set(
            (observedSuffixes + [component.title(localization: localization)])
                .map(normalizedDeviceName)
        )
    }

    private static func batteryCenterProductIdentifiersMatch(
        reading: DeviceBatteryBatteryCenterLogReading,
        target: BluetoothBatteryTarget
    ) -> Bool {
        guard let readingProductID = normalizedProductIdentifier(reading.productID),
              let targetProductID = normalizedProductIdentifier(target.productID)
        else {
            return true
        }

        return readingProductID == targetProductID
    }

    private static func batteryCenterReadingConflictsWithKnownTarget(
        _ reading: DeviceBatteryBatteryCenterLogReading,
        targets: [BluetoothBatteryTarget]
    ) -> Bool {
        guard firstNonEmptyOptional(reading.name, reading.groupName) != nil,
              let readingProductID = normalizedProductIdentifier(reading.productID)
        else {
            return false
        }

        return targets.contains { target in
            normalizedProductIdentifier(target.productID) == readingProductID
        }
    }

    private static func bluetoothPowerLogPredicate(for targets: [BluetoothBatteryTarget]) -> String {
        let targetPredicates = targets.flatMap { target -> [String] in
            var predicates: [String] = []

            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                predicates.append(#"eventMessage CONTAINS[c] "\#(escapedPredicateString(name))""#)
            }

            let vendorID = target.vendorID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let productID = target.productID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let vendorID, !vendorID.isEmpty, let productID, !productID.isEmpty {
                predicates.append(
                    #"(eventMessage CONTAINS "\#(escapedPredicateString(vendorID))" AND eventMessage CONTAINS "\#(escapedPredicateString(productID))")"#
                )
            } else if let productID, !productID.isEmpty {
                predicates.append(#"eventMessage CONTAINS "\#(escapedPredicateString(productID))""#)
            }

            return predicates
        }

        guard !targetPredicates.isEmpty else {
            return bluetoothPowerLogPredicate
        }

        return "\(bluetoothPowerLogPredicate) AND (\(targetPredicates.joined(separator: " OR ")))"
    }

    private static func escapedPredicateString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isBluetoothPowerLogLine(
        _ line: String,
        matching targets: [BluetoothBatteryTarget]
    ) -> Bool {
        guard line.contains("CBPowerSource"),
              line.contains("Power source updated"),
              line.contains("Battery")
        else {
            return false
        }

        return targets.contains { target in
            bluetoothPowerLogLine(line, matches: target)
        }
    }

    static func isBluetoothPowerLogLine(
        _ line: String,
        matchingName name: String,
        vendorID: String?,
        productID: String?
    ) -> Bool {
        guard line.contains("CBPowerSource"),
              line.contains("Power source updated"),
              line.contains("Battery")
        else {
            return false
        }

        if line.localizedCaseInsensitiveContains(name) {
            return true
        }

        let normalizedLine = line.uppercased()
        if let vendorID = normalizedHexIdentifier(vendorID),
           let productID = normalizedHexIdentifier(productID),
           normalizedLine.contains("0X\(vendorID)"),
           normalizedLine.contains("0X\(productID)") {
            return true
        }

        return false
    }

    private static func bluetoothPowerLogLine(
        _ line: String,
        matches target: BluetoothBatteryTarget
    ) -> Bool {
        isBluetoothPowerLogLine(
            line,
            matchingName: target.name,
            vendorID: target.vendorID,
            productID: target.productID
        )
    }

    private static func bluetoothPowerLogItems(
        from readings: [DeviceBatteryBluetoothPowerLogReading],
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        readings.compactMap { reading in
            guard let target = matchingBluetoothPowerLogTarget(reading, in: targets) else {
                return nil
            }

            return DeviceBatteryItem(
                id: powerLogItemID(reading: reading, target: target),
                deviceIdentity: target.deviceIdentity,
                name: powerLogItemName(reading: reading, target: target, localization: localization),
                model: target.model,
                kind: reading.component == nil ? target.kind : .airPodsPart,
                level: reading.level,
                chargeState: reading.chargeState,
                parentName: powerLogParentName(reading: reading, target: target, localization: localization),
                source: "BluetoothPowerLog",
                lastUpdated: reading.observedAt ?? referenceDate,
                isConnected: target.isConnected,
                detail: reading.deviceType ?? target.detail,
                componentIdentity: powerLogComponentIdentity(reading: reading, target: target)
            )
        }
    }

    static func needsBluetoothPowerLogFallback(
        target: BluetoothBatteryTarget,
        existingItems: [DeviceBatteryItem]
    ) -> Bool {
        guard target.isConnected else {
            return false
        }

        if supportsComponentPowerLog(target: target) {
            return true
        }

        let hasExistingBattery = existingItems.contains { item in
            item.deviceIdentity == target.deviceIdentity
                && item.batterySlot == .aggregate
                && item.clampedLevel != nil
        }
        if batteryTopology(for: target) == .single {
            return !hasExistingBattery
        }

        if normalizedHexIdentifier(target.vendorID) == "004C" {
            return false
        }

        return !hasExistingBattery
    }

    private static func powerLogItemName(
        reading: DeviceBatteryBluetoothPowerLogReading,
        target: BluetoothBatteryTarget,
        localization: PluginLocalization
    ) -> String {
        guard let component = reading.component else {
            return target.name
        }

        return localization.format(
            "deviceName.withPart",
            defaultValue: "%@ %@",
            target.name,
            component.title(localization: localization)
        )
    }

    private static func powerLogItemID(
        reading: DeviceBatteryBluetoothPowerLogReading,
        target: BluetoothBatteryTarget
    ) -> String {
        let baseID = target.address ?? target.id
        guard let component = reading.component else {
            return "bluetooth-powerlog-\(baseID)"
        }

        return "bluetooth-powerlog-\(baseID)-\(component.idSuffix)"
    }

    private static func powerLogParentName(
        reading: DeviceBatteryBluetoothPowerLogReading,
        target: BluetoothBatteryTarget,
        localization: PluginLocalization
    ) -> String? {
        switch reading.component {
        case nil:
            return nil
        case .chargingCase:
            return target.name
        case .left, .right:
            return localization.format(
                "deviceName.withPart",
                defaultValue: "%@ %@",
                target.name,
                DeviceBatteryBluetoothPowerLogComponent.chargingCase.title(localization: localization)
            )
        }
    }

    fileprivate static func powerLogItemNameForReader(
        component: DeviceBatteryBluetoothPowerLogComponent,
        targetName: String,
        localization: PluginLocalization
    ) -> String {
        localization.format(
            "deviceName.withPart",
            defaultValue: "%@ %@",
            targetName,
            component.title(localization: localization)
        )
    }

    fileprivate static func powerLogParentNameForReader(
        component: DeviceBatteryBluetoothPowerLogComponent,
        targetName: String,
        localization: PluginLocalization
    ) -> String? {
        switch component {
        case .chargingCase:
            return targetName
        case .left, .right:
            return localization.format(
                "deviceName.withPart",
                defaultValue: "%@ %@",
                targetName,
                DeviceBatteryBluetoothPowerLogComponent.chargingCase.title(localization: localization)
            )
        }
    }

    private static func powerLogComponentIdentity(
        reading: DeviceBatteryBluetoothPowerLogReading,
        target: BluetoothBatteryTarget
    ) -> DeviceBatteryComponentIdentity? {
        guard supportsComponentPowerLog(target: target) || reading.component != nil else {
            return nil
        }

        return DeviceBatteryComponentIdentity(
            groupID: target.deviceIdentity.key,
            role: reading.component?.componentRole ?? .aggregate
        )
    }

    private static func supportsComponentPowerLog(target: BluetoothBatteryTarget) -> Bool {
        guard normalizedHexIdentifier(target.vendorID) == "004C" else {
            return false
        }

        if let topology = batteryTopology(for: target) {
            return topology == .split
        }

        let haystack = [
            target.name,
            target.model,
            target.detail
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return target.kind == .airPodsPart
            || haystack.contains("airpods")
            || haystack.contains("beats")
            || haystack.contains("headphone")
            || haystack.contains("headset")
    }

    private static func collectBluetoothDevices(
        from profile: BluetoothProfile,
        profileReferenceDate: Date,
        liveReferenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        var items = collectBluetoothProfileBatteryItems(
            from: profile,
            referenceDate: profileReferenceDate,
            localization: localization
        )
        items.append(contentsOf: collectIOBluetoothBattery(
            from: profile,
            referenceDate: liveReferenceDate
        ))
        return items
    }

    private static func collectBluetoothProfileBatteryItems(
        from profile: BluetoothProfile,
        referenceDate: Date,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> [DeviceBatteryItem] {
        var items: [DeviceBatteryItem] = []

        for device in profile.batteryDevices {
            let productID = stringValue(device.info["device_productID"])
            let model = productID.flatMap { AppleBluetoothProductCatalog.modelName(forProductID: $0) }
            let deviceIdentity = bluetoothDeviceIdentity(
                for: device,
                among: profile.batteryDevices
            )
            let parentID = deviceIdentity.key
            let topology = batteryTopology(for: device)

            appendBluetoothLevel(
                to: &items,
                name: device.name,
                suffix: nil,
                fieldName: "device_batteryLevelMain",
                device: device,
                id: parentID,
                deviceIdentity: deviceIdentity,
                kind: inferredKind(device: device, field: "main"),
                model: model,
                parentName: nil,
                componentRole: topology == .single
                    ? nil
                    : (topology == .split || hasBluetoothComponentBatteryFields(device.info) ? .aggregate : nil),
                referenceDate: referenceDate
            )
            guard topology != .single else {
                continue
            }
            let caseName = bluetoothPartName(
                deviceName: device.name,
                component: .chargingCase,
                localization: localization
            )
            appendBluetoothLevel(
                to: &items,
                name: caseName,
                suffix: "case",
                fieldName: "device_batteryLevelCase",
                device: device,
                id: parentID,
                deviceIdentity: deviceIdentity,
                kind: .airPodsPart,
                model: model,
                parentName: device.name,
                componentRole: .chargingCase,
                referenceDate: referenceDate
            )
            appendBluetoothLevel(
                to: &items,
                name: bluetoothPartName(deviceName: device.name, component: .left, localization: localization),
                suffix: "left",
                fieldName: "device_batteryLevelLeft",
                device: device,
                id: parentID,
                deviceIdentity: deviceIdentity,
                kind: .airPodsPart,
                model: model,
                parentName: caseName,
                componentRole: .left,
                referenceDate: referenceDate
            )
            appendBluetoothLevel(
                to: &items,
                name: bluetoothPartName(deviceName: device.name, component: .right, localization: localization),
                suffix: "right",
                fieldName: "device_batteryLevelRight",
                device: device,
                id: parentID,
                deviceIdentity: deviceIdentity,
                kind: .airPodsPart,
                model: model,
                parentName: caseName,
                componentRole: .right,
                referenceDate: referenceDate
            )
        }

        return DeviceBatteryItemNormalizer.preferringDetailedComponents(items)
    }

    private static func bluetoothPartName(
        deviceName: String,
        component: DeviceBatteryBluetoothPowerLogComponent,
        localization: PluginLocalization
    ) -> String {
        localization.format(
            "deviceName.withPart",
            defaultValue: "%@ %@",
            deviceName,
            component.title(localization: localization)
        )
    }

    private static func appendBluetoothLevel(
        to items: inout [DeviceBatteryItem],
        name: String,
        suffix: String?,
        fieldName: String,
        device: BluetoothProfileDevice,
        id: String,
        deviceIdentity: DeviceBatteryDeviceIdentity,
        kind: DeviceBatteryKind,
        model: String?,
        parentName: String?,
        componentRole: DeviceBatteryComponentRole?,
        referenceDate: Date
    ) {
        guard let batteryValue = batteryValue(from: device.info[fieldName]) else {
            return
        }

        let itemID = suffix.map { "\(id)-\($0)" } ?? id
        items.append(
            DeviceBatteryItem(
                id: "bluetooth-\(itemID)",
                deviceIdentity: deviceIdentity,
                name: name,
                model: model,
                kind: kind,
                level: batteryValue.level,
                chargeState: batteryValue.chargeState,
                parentName: parentName,
                source: "system_profiler",
                lastUpdated: referenceDate,
                isConnected: device.isConnected,
                detail: device.info["device_minorType"] as? String,
                componentIdentity: componentRole.map {
                    DeviceBatteryComponentIdentity(groupID: deviceIdentity.key, role: $0)
                }
            )
        )
    }

    private static func hasBluetoothComponentBatteryFields(_ info: [String: Any]) -> Bool {
        [
            "device_batteryLevelCase",
            "device_batteryLevelLeft",
            "device_batteryLevelRight"
        ]
            .contains { batteryValue(from: info[$0]) != nil }
    }

    private static func bluetoothDeviceIdentity(
        for device: BluetoothProfileDevice,
        among devices: [BluetoothProfileDevice]
    ) -> DeviceBatteryDeviceIdentity {
        if let serial = bluetoothGroupSerialIdentifier(in: device.info),
           devices.filter({ bluetoothGroupSerialIdentifier(in: $0.info) == serial }).count == 1 {
            return .bluetooth("serial:\(serial)")
        }

        if let address = normalizedIdentifier(device.info["device_address"]) {
            return .bluetooth(address)
        }

        let productID = normalizedProductIdentifier(
            stringValue(device.info["device_productID"])
        ) ?? "unknown-product"
        let sourceRecordID = [
            device.sourceRecordID,
            productID,
            normalizedDeviceName(device.name)
        ].joined(separator: "|")
        return .source("system_profiler:\(sourceRecordID)")
    }

    private static func bluetoothGroupSerialIdentifier(
        in info: [String: Any]
    ) -> String? {
        ["device_serialNumber", "device_serialNumberMain"]
            .lazy
            .compactMap { validBluetoothSerialIdentifier(info[$0]) }
            .first
    }

    private static func validBluetoothSerialIdentifier(_ value: Any?) -> String? {
        guard let identifier = normalizedIdentifier(value) else {
            return nil
        }
        let compactIdentifier = identifier.filter { $0.isLetter || $0.isNumber }
        guard !compactIdentifier.isEmpty,
              compactIdentifier.contains(where: { $0 != "0" }),
              !["UNKNOWN", "NULL", "NA"].contains(compactIdentifier)
        else {
            return nil
        }
        return identifier
    }

    private static func collectIOBluetoothBattery(
        from profile: BluetoothProfile,
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        return devices.enumerated().compactMap { index, device in
            guard device.isConnected(),
                  let level = device.pluginBatteryPercentSingle,
                  level > 0,
                  let name = device.name,
                  !name.isEmpty
            else {
                return nil
            }

            let address = normalizedIdentifier(device.addressString)
            let profileDevice = uniqueProfileDevice(
                matchingAddress: address,
                in: profile.batteryDevices
            )
            let deviceIdentity = profileDevice.map {
                bluetoothDeviceIdentity(for: $0, among: profile.batteryDevices)
            }
                ?? address.map(DeviceBatteryDeviceIdentity.bluetooth)
                ?? .source("iobluetooth:\(index):\(normalizedDeviceName(name))")
            let kind = profileDevice.map { inferredKind(device: $0, field: "single") } ?? .bluetooth
            let displayName = profileDevice?.name ?? name
            let productID = profileDevice.flatMap { stringValue($0.info["device_productID"]) }
            return DeviceBatteryItem(
                id: "iobluetooth-\(deviceIdentity.key)",
                deviceIdentity: deviceIdentity,
                name: displayName,
                model: productID.flatMap(AppleBluetoothProductCatalog.modelName),
                kind: kind,
                level: level,
                chargeState: .unknown,
                parentName: nil,
                source: "IOBluetooth",
                lastUpdated: referenceDate,
                isConnected: true,
                detail: profileDevice?.info["device_minorType"] as? String,
                componentIdentity: componentAggregateIdentity(
                    groupID: deviceIdentity.key,
                    kind: kind
                )
            )
        }
    }

    private static func collectMagicAccessoryDevices(
        from profile: BluetoothProfile,
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        let classes = [
            "AppleDeviceManagementHIDEventService",
            "AppleBluetoothHIDKeyboard",
            "BNBTrackpadDevice",
            "BNBMouseDevice"
        ]

        return classes.flatMap { serviceClass in
            collectIORegistryBatteryDevices(
                matchingService: serviceClass,
                profile: profile,
                referenceDate: referenceDate,
                localization: localization
            )
        }
    }

    private static func collectIORegistryBatteryDevices(
        matchingService serviceClass: String,
        profile: BluetoothProfile,
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        var iterator = io_iterator_t()
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(serviceClass),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var items: [DeviceBatteryItem] = []
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else {
                break
            }
            defer { IOObjectRelease(object) }

            guard let item = makeIORegistryBatteryItem(
                object: object,
                serviceClass: serviceClass,
                profile: profile,
                referenceDate: referenceDate,
                localization: localization
            ) else {
                continue
            }

            items.append(item)
        }

        return items
    }

    private static func makeIORegistryBatteryItem(
        object: io_object_t,
        serviceClass: String,
        profile: BluetoothProfile,
        referenceDate: Date,
        localization: PluginLocalization
    ) -> DeviceBatteryItem? {
        guard let level = intProperty("BatteryPercent", object: object),
              (0...100).contains(level)
        else {
            return nil
        }

        let rawAddress = stringProperty("DeviceAddress", object: object)
        let address = normalizedIdentifier(rawAddress)
        let productName = stringProperty("Product", object: object)
        guard productName?.localizedCaseInsensitiveContains("Internal") != true else {
            return nil
        }

        let matchedProfileDevice = uniqueProfileDevice(
            matchingAddress: address,
            in: profile.batteryDevices
        )
        let name = firstNonEmpty(
            matchedProfileDevice?.name,
            productName,
            serviceClass,
            localization: localization
        )
        let statusFlags = intProperty("BatteryStatusFlags", object: object)
        let chargeState: DeviceBatteryChargeState
        if let statusFlags {
            chargeState = statusFlags == 4 || statusFlags == 0 ? .normal : .charging
        } else {
            chargeState = .unknown
        }
        let kind = inferredMagicKind(productName: productName, profileDevice: matchedProfileDevice)
        let deviceIdentity = matchedProfileDevice.map {
            bluetoothDeviceIdentity(for: $0, among: profile.batteryDevices)
        }
            ?? address.map(DeviceBatteryDeviceIdentity.bluetooth)
            ?? ioRegistryEntryIdentifier(object).map {
                .source("ioregistry:\(serviceClass):\($0)")
            }
            ?? .source("ioregistry:\(serviceClass):\(normalizedDeviceName(name))")

        return DeviceBatteryItem(
            id: "ioregistry-\(deviceIdentity.key)-\(serviceClass)",
            deviceIdentity: deviceIdentity,
            name: name,
            model: productName,
            kind: kind,
            level: level,
            chargeState: chargeState,
            parentName: nil,
            source: "IORegistry",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: matchedProfileDevice?.info["device_minorType"] as? String,
            componentIdentity: nil
        )
    }

    fileprivate static func componentAggregateIdentity(
        groupID: String,
        kind: DeviceBatteryKind
    ) -> DeviceBatteryComponentIdentity? {
        guard kind == .airPodsPart else {
            return nil
        }

        return DeviceBatteryComponentIdentity(groupID: groupID, role: .aggregate)
    }

    private static func uniqueProfileDevice(
        matchingAddress address: String?,
        in devices: [BluetoothProfileDevice]
    ) -> BluetoothProfileDevice? {
        guard let address else {
            return nil
        }
        let matches = devices.filter {
            normalizedIdentifier($0.info["device_address"]) == address
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func inferredKind(
        device: BluetoothProfileDevice,
        field: String
    ) -> DeviceBatteryKind {
        inferredBluetoothKind(
            name: device.name,
            minorType: device.info["device_minorType"] as? String,
            vendorID: device.info["device_vendorID"] as? String,
            productID: stringValue(device.info["device_productID"]),
            field: field
        )
    }

    static func inferredBluetoothKind(
        name: String,
        minorType: String?,
        vendorID: String?,
        productID: String? = nil,
        field: String
    ) -> DeviceBatteryKind {
        let name = name.lowercased()
        let type = (minorType ?? "").lowercased()
        let vendorID = (vendorID ?? "").lowercased()

        if field == "case" || field == "left" || field == "right" {
            return .airPodsPart
        }
        if let productID,
           let isHeadphone = AppleBluetoothProductCatalog.isHeadphoneProduct(
               forProductID: productID
           ) {
            return isHeadphone ? .airPodsPart : .bluetooth
        }
        if name.contains("airpods")
            || name.contains("beats")
            || type.contains("headphone")
            || type.contains("headset") {
            return .airPodsPart
        }
        if normalizedHexIdentifier(vendorID) == "004C" {
            return .magicAccessory
        }
        return .bluetooth
    }

    private static func inferredMagicKind(
        productName: String?,
        profileDevice: BluetoothProfileDevice?
    ) -> DeviceBatteryKind {
        let combined = [productName, profileDevice?.info["device_minorType"] as? String]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if combined.contains("mouse") || combined.contains("keyboard") || combined.contains("trackpad") {
            if combined.contains("apple") || combined.contains("magic") {
                return .magicAccessory
            }
            if profileDevice?.info["device_vendorID"] as? String == "0x004c" {
                return .magicAccessory
            }
            return .bluetooth
        }
        if combined.contains("magic") {
            return .magicAccessory
        }
        return .bluetooth
    }

    private static func bluetoothBatteryTargets(from profile: BluetoothProfile) -> [BluetoothBatteryTarget] {
        profile.batteryDevices.map { device in
            let productID = stringValue(device.info["device_productID"])
            let vendorID = stringValue(device.info["device_vendorID"])
            let model = productID.flatMap { AppleBluetoothProductCatalog.modelName(forProductID: $0) }
            let deviceIdentity = bluetoothDeviceIdentity(
                for: device,
                among: profile.batteryDevices
            )
            return BluetoothBatteryTarget(
                id: deviceIdentity.key,
                name: device.name,
                address: normalizedIdentifier(device.info["device_address"]),
                vendorID: vendorID,
                productID: productID,
                model: model,
                kind: inferredKind(device: device, field: "single"),
                detail: device.info["device_minorType"] as? String,
                isConnected: device.isConnected,
                deviceIdentity: deviceIdentity
            )
        }
    }

    static func matchingBluetoothPowerLogTarget(
        _ reading: DeviceBatteryBluetoothPowerLogReading,
        in targets: [BluetoothBatteryTarget]
    ) -> BluetoothBatteryTarget? {
        let compatibleTargets = targets.filter { target in
            bluetoothIdentifiersMatch(reading: reading, target: target)
                && bluetoothBatteryTopologyMatches(reading: reading, target: target)
        }
        let nameMatchedTargets = compatibleTargets.filter { target in
            normalizedDeviceName(target.name) == normalizedDeviceName(reading.name)
        }

        if nameMatchedTargets.count == 1 {
            return nameMatchedTargets[0]
        }
        guard nameMatchedTargets.isEmpty,
              normalizedDeviceName(reading.name).isEmpty,
              normalizedProductIdentifier(reading.productID) != nil,
              compatibleTargets.count == 1
        else {
            return nil
        }

        return compatibleTargets[0]
    }

    private static func bluetoothBatteryTopologyMatches(
        reading: DeviceBatteryBluetoothPowerLogReading,
        target: BluetoothBatteryTarget
    ) -> Bool {
        let isSingleBatteryDevice = batteryTopology(for: target) == .single
            || batteryTopology(productID: reading.productID) == .single
        return !isSingleBatteryDevice || reading.component == nil
    }

    private static func batteryTopology(
        for target: BluetoothBatteryTarget
    ) -> AppleBluetoothBatteryTopology? {
        if let topology = batteryTopology(productID: target.productID) {
            return topology
        }
        guard normalizedHexIdentifier(target.vendorID) == "004C",
              AppleBluetoothProductCatalog.isVerifiedSingleBatteryModelName(target.name)
                || AppleBluetoothProductCatalog.isVerifiedSingleBatteryModelName(target.model)
        else {
            return nil
        }
        return .single
    }

    private static func batteryTopology(
        for device: BluetoothProfileDevice
    ) -> AppleBluetoothBatteryTopology? {
        if let topology = batteryTopology(
            productID: stringValue(device.info["device_productID"])
        ) {
            return topology
        }
        guard normalizedHexIdentifier(stringValue(device.info["device_vendorID"])) == "004C",
              AppleBluetoothProductCatalog.isVerifiedSingleBatteryModelName(device.name)
        else {
            return nil
        }
        return .single
    }

    private static func batteryTopology(
        productID: String?
    ) -> AppleBluetoothBatteryTopology? {
        if let productID,
           let topology = AppleBluetoothProductCatalog.batteryTopology(forProductID: productID) {
            return topology
        }
        return nil
    }

    private static func bluetoothIdentifiersMatch(
        reading: DeviceBatteryBluetoothPowerLogReading,
        target: BluetoothBatteryTarget
    ) -> Bool {
        if let readingVendorID = normalizedHexIdentifier(reading.vendorID),
           let targetVendorID = normalizedHexIdentifier(target.vendorID),
           readingVendorID != targetVendorID {
            return false
        }

        if let readingProductID = normalizedHexIdentifier(reading.productID),
           let targetProductID = normalizedHexIdentifier(target.productID),
           readingProductID != targetProductID {
            return false
        }

        return true
    }

    private static func normalizedDeviceName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func normalizedHexIdentifier(_ value: String?) -> String? {
        let cleaned = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty else {
            return nil
        }

        return cleaned.uppercased()
    }

    fileprivate static func normalizedHexIdentifierForReader(_ value: String?) -> String? {
        normalizedHexIdentifier(value)
    }

    private static func normalizedProductIdentifier(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }

        let rawValue = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if rawValue.hasPrefix("0x") || rawValue.hasPrefix("0X") {
            return normalizedHexIdentifier(rawValue)
        }
        if let decimal = Int(rawValue) {
            return String(decimal, radix: 16).uppercased()
        }
        return normalizedHexIdentifier(rawValue)
    }

    static func deduplicated(_ items: [DeviceBatteryItem]) -> [DeviceBatteryItem] {
        var itemsByIdentity: [String: [DeviceBatteryItem]] = [:]
        var orderedKeys: [String] = []

        for item in DeviceBatteryItemNormalizer.preferringDetailedComponents(items) {
            let key = item.stableBatteryIdentityKey
            if itemsByIdentity[key] == nil {
                orderedKeys.append(key)
            }
            itemsByIdentity[key, default: []].append(item)
        }

        return orderedKeys.compactMap { key in
            preferredItem(in: itemsByIdentity[key, default: []])
        }
    }

    fileprivate static func preferredItem(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> DeviceBatteryItem {
        preferredItem(in: [left, right]) ?? left
    }

    private static func preferredItem(
        in items: [DeviceBatteryItem]
    ) -> DeviceBatteryItem? {
        guard !items.isEmpty else {
            return nil
        }

        let newestBySource: [DeviceBatteryItem] = Dictionary(
            grouping: items,
            by: \.source
        ).values.compactMap { readings in
            guard let newestReading = readings.sorted(by: observationPrecedes).first else {
                return nil
            }
            let explicitStateReading = readings
                .filter { hasUsableChargeState($0.chargeState) }
                .sorted(by: chargeStateReadingPrecedes)
                .first
            guard let explicitStateReading,
                  shouldBridgeChargeState(
                    from: explicitStateReading,
                    into: newestReading
                  ) else {
                return newestReading
            }
            return replacingChargeState(
                in: newestReading,
                with: explicitStateReading
            )
        }
        let advertisement = newestBySource
            .filter { $0.source == "AppleHeadphoneAdvertisement" }
            .sorted(by: observationPrecedes)
            .first
        let precise = newestBySource
            .filter { $0.source != "AppleHeadphoneAdvertisement" }
            .sorted(by: preciseReadingPrecedes)
            .first
        let chargeStateReading = newestBySource
            .filter { hasUsableChargeState($0.chargeState) }
            .sorted(by: chargeStateReadingPrecedes)
            .first

        let selected: DeviceBatteryItem
        switch (precise, advertisement) {
        case let (precise?, advertisement?):
            selected = mergingAdvertisement(advertisement, into: precise)
        case let (precise?, nil):
            selected = precise
        case let (nil, advertisement?):
            selected = advertisement
        case (nil, nil):
            return nil
        }

        let selectedWithChargeState = chargeStateReading.map {
            replacingChargeState(in: selected, with: $0)
        } ?? selected

        return items.reduce(selectedWithChargeState) { result, item in
            result.mergingDeviceIdentityAliases(from: item)
        }
    }

    private static func hasUsableChargeState(_ chargeState: DeviceBatteryChargeState) -> Bool {
        chargeState != .unknown && chargeState != .invalid
    }

    private static func shouldBridgeChargeState(
        from stateReading: DeviceBatteryItem,
        into newestReading: DeviceBatteryItem
    ) -> Bool {
        guard let stateDate = stateReading.chargeStateLastUpdated
                ?? stateReading.lastUpdated,
              let newestDate = newestReading.lastUpdated else {
            return true
        }
        return newestDate.timeIntervalSince(stateDate) <= 3 * 60
    }

    private static func chargeStateReadingPrecedes(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> Bool {
        let leftDate = left.chargeStateLastUpdated ?? left.lastUpdated ?? .distantPast
        let rightDate = right.chargeStateLastUpdated ?? right.lastUpdated ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }

        let sourceRank = [
            "IOPowerSources": 0,
            "IORegistry": 0,
            "MobileDevice": 0,
            "Rapoo HID": 0,
            "MCHOSE HID": 0,
            "AppleHeadphoneAdvertisement": 1,
            "BatteryCenter": 2,
            "BluetoothPowerLog": 3,
            "system_profiler": 4
        ]
        let leftRank = sourceRank[left.source] ?? 10
        let rightRank = sourceRank[right.source] ?? 10
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return deterministicObservationKey(left) < deterministicObservationKey(right)
    }

    private static func replacingChargeState(
        in item: DeviceBatteryItem,
        with reading: DeviceBatteryItem
    ) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: item.id,
            deviceIdentity: item.deviceIdentity,
            name: item.name,
            model: item.model,
            kind: item.kind,
            level: item.level,
            chargeState: reading.chargeState,
            parentName: item.parentName,
            source: item.source,
            lastUpdated: item.lastUpdated,
            chargeStateLastUpdated: reading.chargeStateLastUpdated ?? reading.lastUpdated,
            isConnected: item.isConnected,
            detail: item.detail,
            componentIdentity: item.componentIdentity,
            alternateDeviceIdentities: item.alternateDeviceIdentities
        )
    }

    private static func observationPrecedes(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> Bool {
        let leftDate = left.lastUpdated ?? .distantPast
        let rightDate = right.lastUpdated ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        if left.batterySlot != right.batterySlot,
           Set([left.batterySlot, right.batterySlot]) == Set([.aggregate, .earbuds]) {
            return left.batterySlot == .earbuds
        }
        let leftChargeDate = left.chargeStateLastUpdated ?? .distantPast
        let rightChargeDate = right.chargeStateLastUpdated ?? .distantPast
        if leftChargeDate != rightChargeDate {
            return leftChargeDate > rightChargeDate
        }
        return deterministicObservationKey(left) < deterministicObservationKey(right)
    }

    private static func preciseReadingPrecedes(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> Bool {
        let leftDate = left.lastUpdated ?? .distantPast
        let rightDate = right.lastUpdated ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }

        let sourceRank = [
            "IORegistry": 0,
            "IOPowerSources": 0,
            "MobileDevice": 0,
            "CoreBluetooth": 1,
            "BatteryCenter": 2,
            "BluetoothPowerLog": 3,
            "IOBluetooth": 4,
            "system_profiler": 5
        ]
        let leftRank = sourceRank[left.source] ?? 10
        let rightRank = sourceRank[right.source] ?? 10
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if left.chargeState.isActiveChargingState != right.chargeState.isActiveChargingState {
            return left.chargeState.isActiveChargingState
        }
        if left.source != right.source {
            return left.source < right.source
        }
        return deterministicObservationKey(left) < deterministicObservationKey(right)
    }

    private static func deterministicObservationKey(_ item: DeviceBatteryItem) -> String {
        let chargeState: Int
        switch item.chargeState {
        case .unknown:
            chargeState = 0
        case .normal:
            chargeState = 1
        case .charging:
            chargeState = 2
        case .charged:
            chargeState = 3
        case .plugged:
            chargeState = 4
        case .invalid:
            chargeState = 5
        }
        return [
            item.source,
            item.id,
            item.deviceIdentity.key,
            item.batterySlot.rawValue,
            item.name,
            item.model ?? "",
            item.parentName ?? "",
            item.detail ?? "",
            String(item.level ?? -1),
            String(chargeState),
            item.isConnected ? "1" : "0"
        ].joined(separator: "\u{0}")
    }

    private static func mergingAdvertisement(
        _ advertisement: DeviceBatteryItem,
        into preferred: DeviceBatteryItem
    ) -> DeviceBatteryItem {
        let preferredDate = preferred.lastUpdated ?? .distantPast
        let advertisementDate = advertisement.lastUpdated ?? .distantPast
        let advertisementHasUsableChargeState = advertisement.chargeState != .unknown
            && advertisement.chargeState != .invalid
        let preferredChargeStateIsUnavailable = preferred.chargeState == .unknown
            || preferred.chargeState == .invalid
        let chargeState: DeviceBatteryChargeState
        let chargeStateLastUpdated: Date?
        if advertisementHasUsableChargeState,
           advertisementDate > preferredDate
            || (advertisementDate == preferredDate
                && (preferredChargeStateIsUnavailable
                    || (advertisement.chargeState.isActiveChargingState
                        && !preferred.chargeState.isActiveChargingState))) {
            chargeState = advertisement.chargeState
            chargeStateLastUpdated = advertisement.chargeStateLastUpdated
                ?? advertisement.lastUpdated
        } else {
            chargeState = preferred.chargeState
            chargeStateLastUpdated = preferred.chargeStateLastUpdated
        }
        let retainsPreferredLevel = preferred.level != nil
        return DeviceBatteryItem(
            id: preferred.id,
            deviceIdentity: preferred.deviceIdentity,
            name: preferred.name,
            model: preferred.model,
            kind: preferred.kind,
            level: preferred.level ?? advertisement.level,
            chargeState: chargeState,
            parentName: preferred.parentName,
            source: preferred.source,
            lastUpdated: retainsPreferredLevel
                ? preferred.lastUpdated
                : [preferred.lastUpdated, advertisement.lastUpdated]
                    .compactMap { $0 }
                    .max(),
            chargeStateLastUpdated: chargeStateLastUpdated,
            isConnected: preferred.isConnected || advertisement.isConnected,
            detail: preferred.detail,
            componentIdentity: preferred.componentIdentity,
            alternateDeviceIdentities: preferred.alternateDeviceIdentities
                .union(advertisement.alternateDeviceIdentities)
                .union(
                    advertisement.deviceIdentity == preferred.deviceIdentity
                        ? []
                        : [advertisement.deviceIdentity]
                )
        )
    }

    private static func batteryLevel(from value: Any?) -> Int? {
        batteryValue(from: value)?.level
    }

    private static func batteryValue(from value: Any?) -> (level: Int, chargeState: DeviceBatteryChargeState)? {
        if let number = value as? NSNumber {
            let level = abs(number.intValue)
            guard (0...100).contains(level) else {
                return nil
            }
            return (level, .unknown)
        }

        guard let string = value as? String else {
            return nil
        }

        let encodedValue = string
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawLevel = Int(encodedValue) else {
            return nil
        }
        let level = abs(rawLevel)
        guard (0...100).contains(level) else { return nil }

        let chargeState: DeviceBatteryChargeState
        if encodedValue.hasPrefix("+") {
            chargeState = .charging
        } else if encodedValue.hasPrefix("-") {
            chargeState = .normal
        } else {
            chargeState = .unknown
        }
        return (level, chargeState)
    }

    private static func normalizedIdentifier(_ value: Any?) -> String? {
        guard let rawValue = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }

        return rawValue
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func firstNonEmpty(
        _ values: String?...,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }

        return localization.string("deviceName.bluetoothFallback", defaultValue: "蓝牙设备")
    }

    private static func intProperty(_ key: String, object: io_object_t) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(object, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }

        return value.takeRetainedValue() as? Int
    }

    private static func ioRegistryEntryIdentifier(_ object: io_object_t) -> String? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(object, &identifier) == KERN_SUCCESS else {
            return nil
        }
        return String(identifier, radix: 16, uppercase: true)
    }

    private static func stringProperty(_ key: String, object: io_object_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(object, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }

        return value.takeRetainedValue() as? String
    }

    private static func runCommand(
        path: String,
        arguments: [String],
        timeout: TimeInterval,
        outputLineFilter: ((String) -> Bool)? = nil
    ) async -> DeviceBatteryCommandResult? {
        await DeviceBatteryCommandRunner.run(
            path: path,
            arguments: arguments,
            timeout: timeout,
            outputLineFilter: outputLineFilter
        )
    }
}

struct DeviceBatterySupplementalItemCache {
    private enum Association: Equatable {
        case target
        case selfReported
        case ephemeral
    }

    private struct Entry {
        let item: DeviceBatteryItem
        let association: Association
    }

    private struct Candidate {
        let item: DeviceBatteryItem
        let isIncoming: Bool
        let order: Int
        let cachedAssociation: Association?
    }

    private let itemLifetime: TimeInterval
    private var entriesByKey: [String: Entry] = [:]

    init(itemLifetime: TimeInterval = 15 * 60) {
        self.itemLifetime = itemLifetime
    }

    var items: [DeviceBatteryItem] {
        DeviceBatterySampler.deduplicated(
            entriesByKey.sorted(by: { $0.key < $1.key }).map(\.value.item)
        )
    }

    mutating func update(
        with items: [DeviceBatteryItem],
        knownTargetIdentities: Set<DeviceBatteryDeviceIdentity>,
        connectedTargetIdentities: Set<DeviceBatteryDeviceIdentity>,
        referenceDate: Date
    ) {
        let cachedCandidates = entriesByKey
            .sorted { $0.key < $1.key }
            .compactMap { _, entry -> Candidate? in
                guard entry.association != .ephemeral,
                      entry.item.isConnected,
                      let lastUpdated = entry.item.lastUpdated,
                      referenceDate.timeIntervalSince(lastUpdated)
                        <= retentionInterval(for: entry.item) else {
                    return nil
                }
                return Candidate(
                    item: entry.item,
                    isIncoming: false,
                    order: 0,
                    cachedAssociation: entry.association
                )
            }
        let incomingCandidates = items.enumerated().map { index, item in
            Candidate(
                item: item,
                isIncoming: true,
                order: index,
                cachedAssociation: nil
            )
        }
        let candidates = cachedCandidates + incomingCandidates

        entriesByKey.removeAll(keepingCapacity: true)
        for originalComponent in identityComponents(in: candidates) {
            let originalIdentities = originalComponent.reduce(
                into: Set<DeviceBatteryDeviceIdentity>()
            ) { identities, candidate in
                identities.formUnion(candidate.item.allDeviceIdentities)
            }
            let originalKnownIdentities = originalIdentities
                .intersection(knownTargetIdentities)
            let component = originalKnownIdentities.isEmpty
                ? originalComponent.filter { $0.cachedAssociation != .target }
                : originalComponent
            guard !component.isEmpty else {
                continue
            }

            let componentIdentities = component.reduce(
                into: Set<DeviceBatteryDeviceIdentity>()
            ) { identities, candidate in
                identities.formUnion(candidate.item.allDeviceIdentities)
            }
            let connectedIdentities = componentIdentities
                .intersection(connectedTargetIdentities)
            let knownIdentities = componentIdentities
                .intersection(knownTargetIdentities)
            let canonicalIdentity: DeviceBatteryDeviceIdentity?
            if knownIdentities.count > 1 {
                canonicalIdentity = nil
            } else if knownIdentities.count == 1 {
                canonicalIdentity = knownIdentities.first
            } else if connectedIdentities.count > 1 {
                canonicalIdentity = nil
            } else if connectedIdentities.count == 1 {
                canonicalIdentity = connectedIdentities.first
            } else if strongPhysicalIdentities(in: component).count > 1 {
                canonicalIdentity = nil
            } else {
                canonicalIdentity = preferredCanonicalIdentity(in: component)
            }

            if let canonicalIdentity {
                insertResolvedComponent(
                    component,
                    canonicalIdentity: canonicalIdentity,
                    knownTargetIdentities: knownTargetIdentities
                )
            } else {
                insertAmbiguousComponent(
                    component,
                    knownTargetIdentities: knownTargetIdentities
                )
            }
        }

        entriesByKey = entriesByKey.filter { _, entry in
            let item = entry.item
            guard item.isConnected,
                  let lastUpdated = item.lastUpdated,
                  referenceDate.timeIntervalSince(lastUpdated)
                    <= retentionInterval(for: item) else {
                return false
            }

            guard entry.association == .target else { return true }
            return belongsToTarget(
                item,
                identities: connectedTargetIdentities
            )
        }
    }

    mutating func removeAll() {
        entriesByKey.removeAll()
    }

    private func identityComponents(
        in candidates: [Candidate]
    ) -> [[Candidate]] {
        var remainingIndices = Set(candidates.indices)
        var components: [[Candidate]] = []

        while let seedIndex = remainingIndices.first {
            remainingIndices.remove(seedIndex)
            var componentIndices = [seedIndex]
            var identities = candidates[seedIndex].item.allDeviceIdentities
            var didExpand = true

            while didExpand {
                didExpand = false
                for index in remainingIndices.sorted() {
                    guard !candidates[index].item.allDeviceIdentities
                        .isDisjoint(with: identities) else {
                        continue
                    }
                    remainingIndices.remove(index)
                    componentIndices.append(index)
                    identities.formUnion(candidates[index].item.allDeviceIdentities)
                    didExpand = true
                }
            }

            components.append(componentIndices.sorted().map { candidates[$0] })
        }

        return components
    }

    private func preferredCanonicalIdentity(
        in candidates: [Candidate]
    ) -> DeviceBatteryDeviceIdentity? {
        let incomingIdentities = Set(
            candidates.filter(\.isIncoming).map { $0.item.deviceIdentity }
        )
        let identities = incomingIdentities.isEmpty
            ? Set(candidates.map { $0.item.deviceIdentity })
            : incomingIdentities
        return identities.sorted(by: identityPrecedes).first
    }

    private func strongPhysicalIdentities(
        in candidates: [Candidate]
    ) -> Set<DeviceBatteryDeviceIdentity> {
        Set(candidates.map(\.item.deviceIdentity).filter { identity in
            switch identity.namespace {
            case .internalBattery, .bluetooth, .mobileDevice, .vendorHID:
                return true
            case .batteryCenter, .source:
                return false
            }
        })
    }

    private func identityPrecedes(
        _ left: DeviceBatteryDeviceIdentity,
        _ right: DeviceBatteryDeviceIdentity
    ) -> Bool {
        let namespaceRank: [DeviceBatteryDeviceIdentity.Namespace: Int] = [
            .internalBattery: 0,
            .bluetooth: 1,
            .mobileDevice: 1,
            .vendorHID: 1,
            .batteryCenter: 2,
            .source: 3
        ]
        let leftRank = namespaceRank[left.namespace] ?? 10
        let rightRank = namespaceRank[right.namespace] ?? 10
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return left.key < right.key
    }

    private mutating func insertResolvedComponent(
        _ candidates: [Candidate],
        canonicalIdentity: DeviceBatteryDeviceIdentity,
        knownTargetIdentities: Set<DeviceBatteryDeviceIdentity>
    ) {
        let orderedCandidates = candidates.sorted { left, right in
            let leftIsCanonical = left.item.deviceIdentity == canonicalIdentity
            let rightIsCanonical = right.item.deviceIdentity == canonicalIdentity
            if leftIsCanonical != rightIsCanonical {
                return !leftIsCanonical
            }
            if left.isIncoming != right.isIncoming {
                return !left.isIncoming
            }
            return left.order < right.order
        }

        var resolvedEntries: [String: Entry] = [:]
        for candidate in orderedCandidates {
            let resolvedItem = candidate.item.resolvingDeviceIdentity(
                to: canonicalIdentity
            )
            upsert(
                resolvedItem,
                into: &resolvedEntries,
                knownTargetIdentities: knownTargetIdentities
            )
        }

        for entry in resolvedEntries.values {
            upsert(
                entry.item,
                into: &entriesByKey,
                knownTargetIdentities: knownTargetIdentities
            )
        }
    }

    private mutating func insertAmbiguousComponent(
        _ candidates: [Candidate],
        knownTargetIdentities: Set<DeviceBatteryDeviceIdentity>
    ) {
        let componentKnownIdentities = candidates.reduce(
            into: Set<DeviceBatteryDeviceIdentity>()
        ) { result, candidate in
            result.formUnion(
                candidate.item.allDeviceIdentities.intersection(knownTargetIdentities)
            )
        }
        var ownersByAlias: [
            DeviceBatteryDeviceIdentity: Set<DeviceBatteryDeviceIdentity>
        ] = [:]
        for candidate in candidates {
            let knownOwners = candidate.item.allDeviceIdentities
                .intersection(knownTargetIdentities)
            for identity in candidate.item.allDeviceIdentities {
                ownersByAlias[identity, default: []].formUnion(knownOwners)
            }
        }
        let ambiguousAliases = Set(
            ownersByAlias.compactMap { alias, owners in
                owners.count > 1 ? alias : nil
            }
        )

        let sanitizedCandidates = candidates.compactMap { candidate -> Candidate? in
            let knownOwners = candidate.item.allDeviceIdentities
                .intersection(knownTargetIdentities)
            if componentKnownIdentities.count > 1, knownOwners.isEmpty {
                return nil
            }
            guard !ambiguousAliases.contains(candidate.item.deviceIdentity)
                    || knownTargetIdentities.contains(candidate.item.deviceIdentity) else {
                return nil
            }
            let item = candidate.item.removingDeviceIdentityAliases(ambiguousAliases)
            if candidate.cachedAssociation == .target,
               item.allDeviceIdentities.isDisjoint(with: knownTargetIdentities) {
                return nil
            }
            return Candidate(
                item: item,
                isIncoming: candidate.isIncoming,
                order: candidate.order,
                cachedAssociation: candidate.cachedAssociation
            )
        }

        for component in identityComponents(in: sanitizedCandidates) {
            let identities = component.reduce(
                into: Set<DeviceBatteryDeviceIdentity>()
            ) { result, candidate in
                result.formUnion(candidate.item.allDeviceIdentities)
            }
            let knownIdentities = identities.intersection(knownTargetIdentities)
            if knownIdentities.count == 1, let canonicalIdentity = knownIdentities.first {
                insertResolvedComponent(
                    component,
                    canonicalIdentity: canonicalIdentity,
                    knownTargetIdentities: knownTargetIdentities
                )
            } else if knownIdentities.isEmpty,
                      strongPhysicalIdentities(in: component).count <= 1,
                      let canonicalIdentity = preferredCanonicalIdentity(in: component) {
                insertResolvedComponent(
                    component,
                    canonicalIdentity: canonicalIdentity,
                    knownTargetIdentities: knownTargetIdentities
                )
            } else {
                for candidate in component where candidate.isIncoming
                    || entriesByKey[cacheKey(for: candidate.item)] == nil {
                    upsertWithinPrimaryIdentity(
                        candidate.item,
                        knownTargetIdentities: knownTargetIdentities
                    )
                }
            }
        }
    }

    private mutating func upsertWithinPrimaryIdentity(
        _ item: DeviceBatteryItem,
        knownTargetIdentities: Set<DeviceBatteryDeviceIdentity>
    ) {
        let overlappingKeys: [String] = entriesByKey.compactMap { element -> String? in
            let (key, entry) = element
            guard entry.item.deviceIdentity == item.deviceIdentity,
                  entry.item.source == item.source,
                  batterySlotsAreEquivalent(entry.item, item) else {
                return nil
            }
            return key
        }
        let overlappingItems = overlappingKeys.compactMap { entriesByKey[$0]?.item }
        for key in overlappingKeys {
            entriesByKey.removeValue(forKey: key)
        }

        let preferredItem = overlappingItems.reduce(item) { preferred, existing in
            DeviceBatterySampler.preferredItem(preferred, existing)
                .mergingDeviceIdentityAliases(from: preferred)
                .mergingDeviceIdentityAliases(from: existing)
        }
        entriesByKey[cacheKey(for: preferredItem)] = Entry(
            item: preferredItem,
            association: association(
                for: preferredItem,
                knownTargetIdentities: knownTargetIdentities
            )
        )
    }

    private func batterySlotsAreEquivalent(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> Bool {
        if left.batterySlot == right.batterySlot {
            return true
        }
        guard left.kind == .airPodsPart, right.kind == .airPodsPart else {
            return false
        }
        return Set([left.batterySlot, right.batterySlot])
            == Set([.aggregate, .earbuds])
    }

    private func upsert(
        _ item: DeviceBatteryItem,
        into entries: inout [String: Entry],
        knownTargetIdentities: Set<DeviceBatteryDeviceIdentity>
    ) {
        let overlappingKeys: [String] = entries.compactMap { element -> String? in
            let (key, entry) = element
            guard entry.item.source == item.source else {
                return nil
            }
            return entry.item.allEquivalentBatteryIdentityKeys.isDisjoint(
                with: item.allEquivalentBatteryIdentityKeys
            ) ? nil : key
        }
        let overlappingItems = overlappingKeys.compactMap { entries[$0]?.item }
        for key in overlappingKeys {
            entries.removeValue(forKey: key)
        }

        let preferredItem = overlappingItems.reduce(item) { preferred, existing in
            DeviceBatterySampler.preferredItem(preferred, existing)
                .mergingDeviceIdentityAliases(from: preferred)
                .mergingDeviceIdentityAliases(from: existing)
        }
        entries[cacheKey(for: preferredItem)] = Entry(
            item: preferredItem,
            association: association(
                for: preferredItem,
                knownTargetIdentities: knownTargetIdentities
            )
        )
    }

    private func association(
        for item: DeviceBatteryItem,
        knownTargetIdentities: Set<DeviceBatteryDeviceIdentity>
    ) -> Association {
        if belongsToTarget(item, identities: knownTargetIdentities) {
            return .target
        }
        if item.deviceIdentity.namespace == .source,
           item.deviceIdentity.value.hasPrefix("batterycenter:") {
            return .ephemeral
        }
        return .selfReported
    }

    private func retentionInterval(for item: DeviceBatteryItem) -> TimeInterval {
        let sourceLimit: TimeInterval
        switch item.source {
        case "BatteryCenter", "AppleHeadphoneAdvertisement":
            sourceLimit = 2 * 60
        case "BluetoothPowerLog":
            sourceLimit = 6 * 60
        default:
            sourceLimit = itemLifetime
        }
        return min(itemLifetime, sourceLimit)
    }

    private func belongsToTarget(
        _ item: DeviceBatteryItem,
        identities: Set<DeviceBatteryDeviceIdentity>
    ) -> Bool {
        !item.allDeviceIdentities.isDisjoint(with: identities)
    }

    private func cacheKey(for item: DeviceBatteryItem) -> String {
        "\(item.stableBatteryIdentityKey)|source:\(item.source)"
    }
}

private struct BluetoothProfile {
    let connectedDevices: [BluetoothProfileDevice]
    let batteryDevices: [BluetoothProfileDevice]
}

private struct BluetoothProfileDevice {
    let sourceRecordID: String
    let name: String
    let info: [String: Any]
    let isConnected: Bool
}

struct BluetoothBatteryTarget: Sendable {
    let id: String
    let name: String
    let address: String?
    let vendorID: String?
    let productID: String?
    let model: String?
    let kind: DeviceBatteryKind
    let detail: String?
    let isConnected: Bool
    let deviceIdentity: DeviceBatteryDeviceIdentity

    init(
        id: String,
        name: String,
        address: String?,
        vendorID: String?,
        productID: String?,
        model: String?,
        kind: DeviceBatteryKind,
        detail: String?,
        isConnected: Bool,
        deviceIdentity: DeviceBatteryDeviceIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.vendorID = vendorID
        self.productID = productID
        self.model = model
        self.kind = kind
        self.detail = detail
        self.isConnected = isConnected
        self.deviceIdentity = deviceIdentity
            ?? address.map(DeviceBatteryDeviceIdentity.bluetooth)
            ?? .source("bluetooth-target:\(id)")
    }

    var componentGroupID: String {
        deviceIdentity.key
    }
}

struct DeviceBatteryBluetoothPowerLogReading: Equatable, Sendable {
    let name: String
    let vendorID: String?
    let productID: String?
    let deviceType: String?
    let component: DeviceBatteryBluetoothPowerLogComponent?
    let level: Int
    let chargeState: DeviceBatteryChargeState
    let observedAt: Date?

    init(
        name: String,
        vendorID: String?,
        productID: String?,
        deviceType: String?,
        component: DeviceBatteryBluetoothPowerLogComponent?,
        level: Int,
        chargeState: DeviceBatteryChargeState,
        observedAt: Date? = nil
    ) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.deviceType = deviceType
        self.component = component
        self.level = level
        self.chargeState = chargeState
        self.observedAt = observedAt
    }
}

enum DeviceBatteryBluetoothPowerLogComponent: String, Sendable {
    case left
    case right
    case chargingCase

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .left:
            return localization.string("component.left", defaultValue: "左耳")
        case .right:
            return localization.string("component.right", defaultValue: "右耳")
        case .chargingCase:
            return localization.string("component.chargingCase", defaultValue: "充电盒")
        }
    }

    var idSuffix: String {
        switch self {
        case .left:
            return "left"
        case .right:
            return "right"
        case .chargingCase:
            return "case"
        }
    }

    var componentRole: DeviceBatteryComponentRole {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        case .chargingCase:
            return .chargingCase
        }
    }
}

enum DeviceBatteryBluetoothPowerLogParser {
    static func readings(from output: String) -> [DeviceBatteryBluetoothPowerLogReading] {
        var latestByIdentity: [String: DeviceBatteryBluetoothPowerLogReading] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            for reading in readings(fromLine: String(line)) {
                latestByIdentity[identityKey(for: reading)] = reading
            }
        }

        return latestByIdentity.keys.sorted().compactMap { latestByIdentity[$0] }
    }

    static func reading(from line: String) -> DeviceBatteryBluetoothPowerLogReading? {
        readings(fromLine: line).first { $0.component == nil }
    }

    static func readings(fromLine line: String) -> [DeviceBatteryBluetoothPowerLogReading] {
        guard line.contains("CBPowerSource"),
              line.contains("Power source updated"),
              let name = stringValue(after: "Nm '", before: "'", in: line)
        else {
            return []
        }

        let vendorID = stringValue(after: "VID ", before: " ", in: line)
        let productID = stringValue(after: "PID ", before: " ", in: line)
        let deviceType = stringValue(after: "AcCa ", before: ",", in: line)
        let observedAt = DeviceBatteryCompactLogTimestampParser.date(from: line)
        var readings: [DeviceBatteryBluetoothPowerLogReading] = []

        if let batteryValue = batteryPercentValue(after: "Battery ", in: line)
            ?? batteryPercentValue(after: "Battery M ", in: line) {
            readings.append(DeviceBatteryBluetoothPowerLogReading(
                name: name,
                vendorID: vendorID,
                productID: productID,
                deviceType: deviceType,
                component: nil,
                level: min(max(abs(batteryValue.level), 0), 100),
                chargeState: batteryValue.chargeState,
                observedAt: observedAt
            ))
        }

        readings.append(contentsOf: componentBatteryValues(in: line).map { component, batteryValue in
            DeviceBatteryBluetoothPowerLogReading(
                name: name,
                vendorID: vendorID,
                productID: productID,
                deviceType: deviceType,
                component: component,
                level: min(max(abs(batteryValue.level), 0), 100),
                chargeState: batteryValue.chargeState,
                observedAt: observedAt
            )
        })

        return readings
    }

    private static func componentBatteryValues(
        in line: String
    ) -> [(DeviceBatteryBluetoothPowerLogComponent, (level: Int, chargeState: DeviceBatteryChargeState))] {
        [
            (.left, "Left "),
            (.right, "Right "),
            (.chargingCase, "Case ")
        ]
            .compactMap { component, prefix in
                guard let batteryValue = batteryPercentValue(after: prefix, in: line) else {
                    return nil
                }
                return (component, batteryValue)
            }
    }

    private static func identityKey(for reading: DeviceBatteryBluetoothPowerLogReading) -> String {
        [
            reading.name,
            reading.vendorID ?? "",
            reading.productID ?? "",
            reading.component?.rawValue ?? "main"
        ]
            .joined(separator: "|")
            .lowercased()
    }

    private static func stringValue(
        after prefix: String,
        before suffix: Character,
        in text: String
    ) -> String? {
        guard let startRange = text.range(of: prefix) else {
            return nil
        }

        let start = startRange.upperBound
        guard let end = text[start...].firstIndex(of: suffix) else {
            return nil
        }

        let value = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func batteryPercentValue(
        after prefix: String,
        in text: String
    ) -> (level: Int, chargeState: DeviceBatteryChargeState)? {
        guard let startRange = text.range(of: prefix) else {
            return nil
        }

        let remainder = text[startRange.upperBound...]
        var value = ""
        for character in remainder {
            if character == "+" || character == "-" || character.isNumber {
                value.append(character)
                continue
            }
            break
        }

        guard !value.isEmpty else {
            return nil
        }

        guard let level = Int(value) else {
            return nil
        }

        let chargeState: DeviceBatteryChargeState
        if value.hasPrefix("+") {
            chargeState = .charging
        } else if value.hasPrefix("-") {
            chargeState = .normal
        } else {
            chargeState = .unknown
        }
        return (level: level, chargeState: chargeState)
    }
}

struct DeviceBatteryBatteryCenterLogReading: Equatable, Sendable {
    let name: String?
    let groupName: String?
    let productID: String?
    let parts: String?
    let identifier: String?
    let matchIdentifier: String?
    let model: String?
    let category: String?
    let accessoryID: String?
    let transportType: String?
    let level: Int
    let chargeState: DeviceBatteryChargeState
    let isConnected: Bool?
    let isInternal: Bool?
    let observedAt: Date?

    init(
        name: String?,
        groupName: String?,
        productID: String?,
        parts: String?,
        identifier: String?,
        matchIdentifier: String?,
        model: String?,
        category: String?,
        accessoryID: String?,
        transportType: String?,
        level: Int,
        chargeState: DeviceBatteryChargeState,
        isConnected: Bool?,
        isInternal: Bool?,
        observedAt: Date? = nil
    ) {
        self.name = name
        self.groupName = groupName
        self.productID = productID
        self.parts = parts
        self.identifier = identifier
        self.matchIdentifier = matchIdentifier
        self.model = model
        self.category = category
        self.accessoryID = accessoryID
        self.transportType = transportType
        self.level = level
        self.chargeState = chargeState
        self.isConnected = isConnected
        self.isInternal = isInternal
        self.observedAt = observedAt
    }
}

enum DeviceBatteryBatteryCenterLogParser {
    static func readings(from output: String) -> [DeviceBatteryBatteryCenterLogReading] {
        var latestByIdentity: [String: DeviceBatteryBatteryCenterLogReading] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let reading = reading(fromLine: String(line)) else {
                continue
            }
            latestByIdentity[identityKey(for: reading)] = reading
        }
        return latestByIdentity.keys.sorted().compactMap { latestByIdentity[$0] }
    }

    static func reading(fromLine line: String) -> DeviceBatteryBatteryCenterLogReading? {
        guard line.contains("BCBatteryDevice"),
              let payload = stringValue(after: "<BCBatteryDevice:", before: ">", in: line),
              let level = intField("percentCharge", in: payload),
              (0...100).contains(level)
        else {
            return nil
        }

        return DeviceBatteryBatteryCenterLogReading(
            name: field("name", in: payload),
            groupName: field("groupName", in: payload),
            productID: field("productIdentifier", in: payload),
            parts: field("parts", in: payload),
            identifier: field("identifier", in: payload),
            matchIdentifier: field("matchIdentifier", in: payload),
            model: field("modelNumber", in: payload),
            category: field("accessoryCategory", in: payload),
            accessoryID: field("accessoryIdentifier", in: payload),
            transportType: field("transportType", in: payload),
            level: level,
            chargeState: batteryCenterChargeState(in: payload),
            isConnected: boolField("connected", in: payload),
            isInternal: boolField("internal", in: payload),
            observedAt: DeviceBatteryCompactLogTimestampParser.date(from: line)
        )
    }

    private static func field(_ key: String, in text: String) -> String? {
        for segment in text.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else {
                continue
            }

            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "(null)" else {
                return nil
            }
            return value
        }

        return nil
    }

    private static func intField(_ key: String, in text: String) -> Int? {
        field(key, in: text).flatMap(Int.init)
    }

    private static func boolField(_ key: String, in text: String) -> Bool? {
        switch field(key, in: text)?.uppercased() {
        case "YES":
            return true
        case "NO":
            return false
        default:
            return nil
        }
    }

    private static func batteryCenterChargeState(in payload: String) -> DeviceBatteryChargeState {
        switch boolField("charging", in: payload) {
        case true:
            return .charging
        case false:
            return .normal
        case nil:
            return .unknown
        }
    }

    private static func identityKey(
        for reading: DeviceBatteryBatteryCenterLogReading
    ) -> String {
        [
            reading.matchIdentifier ?? "",
            reading.parts ?? "aggregate",
            reading.accessoryID ?? reading.identifier ?? "",
            reading.productID ?? "",
            reading.name ?? reading.groupName ?? ""
        ]
            .joined(separator: "|")
            .lowercased()
    }

    private static func stringValue(
        after prefix: String,
        before suffix: Character,
        in text: String
    ) -> String? {
        guard let startRange = text.range(of: prefix) else {
            return nil
        }

        let start = startRange.upperBound
        guard let end = text[start...].firstIndex(of: suffix) else {
            return nil
        }

        let value = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private enum DeviceBatteryCompactLogTimestampParser {
    static func date(from line: String) -> Date? {
        let bytes = Array(line.utf8.prefix(23))
        guard bytes.count == 23,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 32,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes[19] == 46,
              let year = number(in: 0..<4, bytes: bytes),
              let month = number(in: 5..<7, bytes: bytes),
              let day = number(in: 8..<10, bytes: bytes),
              let hour = number(in: 11..<13, bytes: bytes),
              let minute = number(in: 14..<16, bytes: bytes),
              let second = number(in: 17..<19, bytes: bytes),
              let millisecond = number(in: 20..<23, bytes: bytes)
        else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            nanosecond: millisecond * 1_000_000
        ))
    }

    private static func number(in range: Range<Int>, bytes: [UInt8]) -> Int? {
        var result = 0
        for byte in bytes[range] {
            guard (48...57).contains(byte) else {
                return nil
            }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }
}

struct DeviceBatteryBluetoothScanPlan {
    let eligibleTargets: [BluetoothBatteryTarget]
    let advertisementTargetIDs: Set<String>
    let gattTargetIDs: Set<String>

    init(targets: [BluetoothBatteryTarget]) {
        let gattTargets = targets.filter { target in
            target.isConnected && (target.kind == .bluetooth || target.kind == .magicAccessory)
        }
        let advertisementTargets = targets.filter { target in
            target.isConnected
                && target.vendorID.flatMap(DeviceBatterySampler.normalizedHexIdentifierForReader) == "004C"
                && Self.supportsAdvertisementBattery(target: target)
        }
        let eligibleTargetIDs = Set((gattTargets + advertisementTargets).map(\.id))

        eligibleTargets = targets.filter {
            $0.isConnected && eligibleTargetIDs.contains($0.id)
        }
        advertisementTargetIDs = Set(advertisementTargets.map(\.id))
        gattTargetIDs = Set(gattTargets.map(\.id))
    }

    private static func supportsAdvertisementBattery(target: BluetoothBatteryTarget) -> Bool {
        if let productID = target.productID,
           let supportsSplitBattery = AppleBluetoothProductCatalog.supportsSplitBattery(
               forProductID: productID
           ) {
            return supportsSplitBattery
        }

        let haystack = [target.name, target.model, target.detail]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains("airpods") || haystack.contains("beats")
    }
}

enum DeviceBatteryBluetoothDiscoveryMode: Equatable {
    case none
    case batteryService
    case allAdvertisements
}

enum DeviceBatteryBluetoothScanPolicy {
    static func discoveryMode(
        advertisementTargetIDs: Set<String>,
        gattTargetIDs: Set<String>,
        registeredGATTTargetIDs: Set<String>
    ) -> DeviceBatteryBluetoothDiscoveryMode {
        if !advertisementTargetIDs.isEmpty {
            return .allAdvertisements
        }
        if !gattTargetIDs.isSubset(of: registeredGATTTargetIDs) {
            return .batteryService
        }
        return .none
    }

    static func advertisementTarget(
        localName: String?,
        peripheralName: String?,
        productID: Int,
        targets: [BluetoothBatteryTarget],
        eligibleTargetIDs: Set<String>
    ) -> BluetoothBatteryTarget? {
        let names = Set([localName, peripheralName].compactMap(normalizedTargetName))
        let candidateSets = names.compactMap { name -> Set<String>? in
            let targetIDs = Set(targets.compactMap { target -> String? in
                guard eligibleTargetIDs.contains(target.id),
                      normalizedTargetName(target.name) == name
                else {
                    return nil
                }
                guard let encodedProductID = target.productID else {
                    return target.id
                }
                return AppleBluetoothProductCatalog.matches(
                    productID: productID,
                    encodedProductID: encodedProductID
                ) ? target.id : nil
            })
            return targetIDs.isEmpty ? nil : targetIDs
        }
        guard let firstCandidates = candidateSets.first else {
            return nil
        }
        let matchingTargetIDs = candidateSets.dropFirst().reduce(firstCandidates) {
            candidates, nextCandidates in
            candidates.intersection(nextCandidates)
        }
        guard matchingTargetIDs.count == 1,
              let matchingTargetID = matchingTargetIDs.first
        else {
            return nil
        }
        return targets.first { target in
            target.id == matchingTargetID
        }
    }

    private static func normalizedTargetName(_ name: String?) -> String? {
        let normalized = name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}

enum DeviceBatteryGATTBatteryPolicy {
    static func canRepresentBatteryServiceInstanceCount(_ count: Int) -> Bool {
        count <= 1
    }
}

@MainActor
private final class DeviceBatteryBluetoothScanner: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let deviceInformationService = CBUUID(string: "180A")
    private static let batteryLevelCharacteristic = CBUUID(string: "2A19")
    private static let modelNumberCharacteristic = CBUUID(string: "2A24")
    private static let manufacturerNameCharacteristic = CBUUID(string: "2A29")

    private let targets: [BluetoothBatteryTarget]
    private let targetsByName: [String: [BluetoothBatteryTarget]]
    private let advertisementTargetIDs: Set<String>
    private let gattTargetIDs: Set<String>
    private let referenceDate: Date
    private let localization: PluginLocalization
    private var centralManager: CBCentralManager?
    private var continuation: CheckedContinuation<[DeviceBatteryItem], Never>?
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var pendingPeripheralIDs: Set<UUID> = []
    private var connectionsStartedByReader: Set<UUID> = []
    private var readingByID: [UUID: BluetoothBatteryReading] = [:]
    private var advertisementReadingsByTargetID: [String: [DeviceBatteryBluetoothPowerLogComponent: DeviceBatteryAppleHeadphoneAdvertisementReading]] = [:]
    private var completedTargetIDs: Set<String> = []
    private var registeredGATTTargetIDs: Set<String> = []
    private var discoveredNames: Set<String> = []
    private var discoveryMode = DeviceBatteryBluetoothDiscoveryMode.none
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    static func collectBatteryDevices(
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) async -> [DeviceBatteryItem] {
        let plan = DeviceBatteryBluetoothScanPlan(targets: targets)
        guard !plan.eligibleTargets.isEmpty else {
            return []
        }

        let reader = DeviceBatteryBluetoothScanner(
            targets: plan.eligibleTargets,
            advertisementTargetIDs: plan.advertisementTargetIDs,
            gattTargetIDs: plan.gattTargetIDs,
            referenceDate: referenceDate,
            localization: localization
        )
        return await withTaskCancellationHandler {
            await reader.collect()
        } onCancel: {
            Task { @MainActor in
                reader.cancel()
            }
        }
    }

    init(
        targets: [BluetoothBatteryTarget],
        advertisementTargetIDs: Set<String>,
        gattTargetIDs: Set<String>,
        referenceDate: Date,
        localization: PluginLocalization
    ) {
        self.targets = targets
        self.targetsByName = Dictionary(grouping: targets) { target in
            Self.targetNameKey(target.name)
        }
        self.advertisementTargetIDs = advertisementTargetIDs
        self.gattTargetIDs = gattTargetIDs
        self.referenceDate = referenceDate
        self.localization = localization
        super.init()
    }

    private func collect() async -> [DeviceBatteryItem] {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(returning: [])
                return
            }
            self.continuation = continuation
            centralManager = CBCentralManager(delegate: self, queue: .main)
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish()
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !didFinish else { return }
        guard central.state == .poweredOn else {
            finish()
            return
        }

        let connectedPeripherals = central.retrieveConnectedPeripherals(
            withServices: [Self.batteryService]
        )
        for peripheral in connectedPeripherals {
            register(peripheral, central: central)
        }

        discoveryMode = DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: advertisementTargetIDs,
            gattTargetIDs: gattTargetIDs,
            registeredGATTTargetIDs: registeredGATTTargetIDs
        )
        switch discoveryMode {
        case .none:
            break
        case .batteryService:
            central.scanForPeripherals(
                withServices: [Self.batteryService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .allAdvertisements:
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        finishIfComplete()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !didFinish else { return }
        if discoveryMode == .batteryService || Self.advertisesBatteryService(advertisementData) {
            register(peripheral, central: central)
        }
        collectAdvertisementBattery(peripheral: peripheral, advertisementData: advertisementData)
        finishIfComplete()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !didFinish else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        discoverServices(for: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard !didFinish else { return }
        pendingPeripheralIDs.remove(peripheral.identifier)
        markCompletedTarget(for: peripheral)
        finishIfComplete()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !didFinish else { return }
        guard error == nil, let services = peripheral.services else {
            pendingPeripheralIDs.remove(peripheral.identifier)
            markCompletedTarget(for: peripheral)
            finishIfComplete()
            return
        }

        let batteryServices = services.filter { $0.uuid == Self.batteryService }
        guard DeviceBatteryGATTBatteryPolicy.canRepresentBatteryServiceInstanceCount(
            batteryServices.count
        ) else {
            // A multi-instance Battery Service needs per-instance presentation
            // descriptors to identify each physical battery. Do not collapse an
            // arbitrary instance into a misleading device-level percentage.
            readingByID.removeValue(forKey: peripheral.identifier)
            pendingPeripheralIDs.remove(peripheral.identifier)
            if let target = target(for: peripheral) {
                completedTargetIDs.insert(target.id)
            }
            finishIfComplete()
            return
        }

        let wantedServices = services.filter { service in
            service.uuid == Self.batteryService || service.uuid == Self.deviceInformationService
        }
        guard !wantedServices.isEmpty else {
            pendingPeripheralIDs.remove(peripheral.identifier)
            markCompletedTarget(for: peripheral)
            finishIfComplete()
            return
        }

        for service in wantedServices {
            let characteristicUUIDs: [CBUUID]
            if service.uuid == Self.batteryService {
                characteristicUUIDs = [Self.batteryLevelCharacteristic]
            } else {
                characteristicUUIDs = [
                    Self.modelNumberCharacteristic,
                    Self.manufacturerNameCharacteristic
                ]
            }
            peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard !didFinish else { return }
        guard error == nil, let characteristics = service.characteristics else {
            pendingPeripheralIDs.remove(peripheral.identifier)
            markCompletedTarget(for: peripheral)
            finishIfComplete()
            return
        }

        var didRead = false
        for characteristic in characteristics {
            if characteristic.uuid == Self.batteryLevelCharacteristic
                || characteristic.uuid == Self.modelNumberCharacteristic
                || characteristic.uuid == Self.manufacturerNameCharacteristic {
                didRead = true
                peripheral.readValue(for: characteristic)
            }
        }

        if !didRead, service.uuid == Self.batteryService {
            pendingPeripheralIDs.remove(peripheral.identifier)
            markCompletedTarget(for: peripheral)
            finishIfComplete()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard !didFinish else { return }
        defer {
            if readingByID[peripheral.identifier]?.level != nil {
                pendingPeripheralIDs.remove(peripheral.identifier)
                if let target = target(for: peripheral) {
                    completedTargetIDs.insert(target.id)
                }
                finishIfComplete()
            }
        }

        guard error == nil, let value = characteristic.value else {
            return
        }

        var reading = readingByID[peripheral.identifier] ?? BluetoothBatteryReading()
        switch characteristic.uuid {
        case Self.batteryLevelCharacteristic:
            guard let level = value.first, level <= 100 else {
                return
            }
            reading.level = Int(level)
        case Self.modelNumberCharacteristic:
            reading.model = String(data: value, encoding: .utf8)
        case Self.manufacturerNameCharacteristic:
            reading.manufacturer = String(data: value, encoding: .utf8)
        default:
            return
        }
        readingByID[peripheral.identifier] = reading
    }

    private func register(_ peripheral: CBPeripheral, central: CBCentralManager) {
        guard !didFinish,
              let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let target = uniqueTarget(named: name, eligibleTargetIDs: gattTargetIDs),
              !discoveredNames.contains(Self.targetNameKey(name))
        else {
            return
        }

        discoveredNames.insert(Self.targetNameKey(name))
        registeredGATTTargetIDs.insert(target.id)
        peripheralsByID[peripheral.identifier] = peripheral
        pendingPeripheralIDs.insert(peripheral.identifier)
        peripheral.delegate = self

        connectionsStartedByReader.insert(peripheral.identifier)
        central.connect(peripheral, options: nil)
    }

    private func discoverServices(for peripheral: CBPeripheral) {
        guard !didFinish else { return }
        peripheral.discoverServices([Self.batteryService, Self.deviceInformationService])
    }

    private func collectAdvertisementBattery(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        else {
            return
        }

        guard let advertisement = DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(
            from: manufacturerData
        ) else {
            return
        }
        guard AppleBluetoothProductCatalog.supportsSplitBattery(
            forProductID: advertisement.productID
        ) != false else {
            return
        }
        guard let target = DeviceBatteryBluetoothScanPolicy.advertisementTarget(
            localName: advertisedName,
            peripheralName: peripheral.name,
            productID: advertisement.productID,
            targets: targets,
            eligibleTargetIDs: advertisementTargetIDs
        ) else {
            return
        }

        var targetReadings = advertisementReadingsByTargetID[target.id] ?? [:]
        for reading in advertisement.readings {
            targetReadings[reading.component] = reading
        }
        advertisementReadingsByTargetID[target.id] = targetReadings
        completedTargetIDs.insert(target.id)
    }

    private func finishIfComplete() {
        guard pendingPeripheralIDs.isEmpty else { return }
        let expectedTargetIDs = advertisementTargetIDs.union(gattTargetIDs)
        guard completedTargetIDs.isSuperset(of: expectedTargetIDs) else { return }
        finish()
    }

    private func markCompletedTarget(for peripheral: CBPeripheral) {
        guard let target = target(for: peripheral) else { return }
        completedTargetIDs.insert(target.id)
    }

    private static func advertisesBatteryService(_ advertisementData: [String: Any]) -> Bool {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return serviceUUIDs.contains(batteryService)
    }

    private func finish() {
        guard !didFinish else { return }

        didFinish = true
        timeoutTask?.cancel()
        timeoutTask = nil
        centralManager?.stopScan()
        for peripheralID in connectionsStartedByReader {
            guard let peripheral = peripheralsByID[peripheralID] else { continue }
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        centralManager?.delegate = nil
        peripheralsByID.values.forEach { $0.delegate = nil }
        let items = batteryItems()
        let continuation = continuation
        self.continuation = nil
        centralManager = nil
        continuation?.resume(returning: items)
    }

    private func cancel() {
        finish()
    }

    private func batteryItems() -> [DeviceBatteryItem] {
        advertisementBatteryItems() + gattBatteryItems()
    }

    private func advertisementBatteryItems() -> [DeviceBatteryItem] {
        advertisementReadingsByTargetID.flatMap { targetID, readingsByComponent -> [DeviceBatteryItem] in
            guard let target = targets.first(where: { $0.id == targetID }) else { return [] }
            return readingsByComponent.values.map { reading in
                DeviceBatteryItem(
                    id: "apple-headphone-advertisement-\(target.componentGroupID)-\(reading.component.idSuffix)",
                    deviceIdentity: target.deviceIdentity,
                    name: DeviceBatterySampler.powerLogItemNameForReader(
                        component: reading.component,
                        targetName: target.name,
                        localization: localization
                    ),
                    model: target.model,
                    kind: .airPodsPart,
                    level: reading.level,
                    chargeState: reading.chargeState,
                    parentName: DeviceBatterySampler.powerLogParentNameForReader(
                        component: reading.component,
                        targetName: target.name,
                        localization: localization
                    ),
                    source: "AppleHeadphoneAdvertisement",
                    lastUpdated: referenceDate,
                    isConnected: target.isConnected,
                    detail: target.detail,
                    componentIdentity: DeviceBatteryComponentIdentity(
                        groupID: target.deviceIdentity.key,
                        role: reading.component.componentRole
                    )
                )
            }
        }
    }

    private func gattBatteryItems() -> [DeviceBatteryItem] {
        readingByID.compactMap { peripheralID, reading in
            guard let peripheral = peripheralsByID[peripheralID],
                  let name = peripheral.name,
                  let target = uniqueTarget(named: name, eligibleTargetIDs: gattTargetIDs),
                  let level = reading.level
            else {
                return nil
            }

            return DeviceBatteryItem(
                id: "corebluetooth-\(target.address ?? target.id)",
                deviceIdentity: target.deviceIdentity,
                name: target.name,
                model: firstNonEmpty(reading.model, target.model),
                kind: target.kind,
                level: level,
                chargeState: .unknown,
                parentName: nil,
                source: "CoreBluetooth",
                lastUpdated: referenceDate,
                isConnected: true,
                detail: firstNonEmpty(reading.manufacturer, target.detail),
                componentIdentity: DeviceBatterySampler.componentAggregateIdentity(
                    groupID: target.deviceIdentity.key,
                    kind: target.kind
                )
            )
        }
    }

    private func target(for peripheral: CBPeripheral) -> BluetoothBatteryTarget? {
        guard let name = peripheral.name else { return nil }
        return uniqueTarget(named: name, eligibleTargetIDs: gattTargetIDs)
    }

    private func uniqueTarget(
        named name: String,
        eligibleTargetIDs: Set<String>
    ) -> BluetoothBatteryTarget? {
        let candidates = targetsByName[Self.targetNameKey(name), default: []].filter { target in
            eligibleTargetIDs.contains(target.id)
        }
        guard candidates.count == 1 else {
            return nil
        }
        return candidates[0]
    }

    private static func targetNameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

}

private struct BluetoothBatteryReading {
    var level: Int?
    var model: String?
    var manufacturer: String?
}

private extension IOBluetoothDevice {
    var pluginBatteryPercentSingle: Int? {
        pluginValue(forKey: "batteryPercentSingle") as? Int
    }

    func pluginValue(forKey key: String) -> Any? {
        guard responds(to: Selector(key)) else {
            return nil
        }

        return value(forKey: key)
    }
}
