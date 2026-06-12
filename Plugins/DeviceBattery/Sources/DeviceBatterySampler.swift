import Foundation
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.ps
import MacToolsPluginKit

protocol DeviceBatterySampling: Sendable {
    func collectSystemDevices(referenceDate: Date) async -> [DeviceBatteryItem]
}

struct DeviceBatterySampler: DeviceBatterySampling {
    private static let bluetoothPowerLogLookback = "1m"
    private static let bluetoothPowerLogTimeout: TimeInterval = 1.5
    private static let batteryCenterLogLookback = "2m"
    private static let batteryCenterLogTimeout: TimeInterval = 1.0
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    func collectSystemDevices(referenceDate: Date) async -> [DeviceBatteryItem] {
        let localization = localization
        let baseSample = await Task.detached(priority: .utility) {
            var items: [DeviceBatteryItem] = []
            items.append(contentsOf: Self.collectInternalBattery(referenceDate: referenceDate, localization: localization))
            let bluetoothData = Self.collectBluetoothProfile()
            items.append(contentsOf: Self.collectBluetoothDevices(
                from: bluetoothData,
                referenceDate: referenceDate,
                localization: localization
            ))
            items.append(contentsOf: Self.collectBluetoothPowerLogDevices(
                from: bluetoothData,
                existingItems: items,
                referenceDate: referenceDate,
                localization: localization
            ))
            items.append(contentsOf: Self.collectBatteryCenterLogDevices(
                from: bluetoothData,
                referenceDate: referenceDate
            ))
            items.append(contentsOf: Self.collectMagicAccessoryDevices(
                from: bluetoothData,
                referenceDate: referenceDate,
                localization: localization
            ))
            return DeviceBatteryBaseSample(
                items: Self.deduplicated(items),
                bluetoothBatteryTargets: Self.bluetoothBatteryTargets(from: bluetoothData)
            )
        }.value

        let appleHeadphoneAdvertisementItems = await DeviceBatteryAppleHeadphoneAdvertisementReader.collectBatteryDevices(
            targets: baseSample.bluetoothBatteryTargets,
            referenceDate: referenceDate,
            localization: localization
        )
        let bluetoothBatteryItems = await DeviceBatteryBLEBatteryReader.collectBatteryDevices(
            targets: baseSample.bluetoothBatteryTargets,
            referenceDate: referenceDate,
            localization: localization
        )
        return Self.deduplicated(baseSample.items + appleHeadphoneAdvertisementItems + bluetoothBatteryItems)
    }

    private static func collectInternalBattery(
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

    private static func collectBluetoothProfile() -> BluetoothProfile {
        guard let output = runCommand(
            path: "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType", "-json"],
            timeout: 3
        ) else {
            return BluetoothProfile(connectedDevices: [], batteryDevices: [])
        }

        return bluetoothProfile(fromSystemProfilerOutput: output)
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

        return BluetoothProfile(
            connectedDevices: connectedDevices,
            batteryDevices: mergedBatteryDevices(
                connectedDevices + disconnectedBatteryDevices
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

    private static func parseBluetoothDevices(
        from value: Any?,
        isConnected: Bool
    ) -> [BluetoothProfileDevice] {
        guard let rawDevices = value as? [[String: Any]] else {
            return []
        }

        return rawDevices.compactMap { rawDevice in
            guard let name = rawDevice.keys.first,
                  let info = rawDevice[name] as? [String: Any]
            else {
                return nil
            }

            return BluetoothProfileDevice(
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
        let model = productID.flatMap { HeadphoneModelCatalog.modelName(forProductID: $0) }
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

    private static func mergedBatteryDevices(_ devices: [BluetoothProfileDevice]) -> [BluetoothProfileDevice] {
        var mergedByKey: [String: BluetoothProfileDevice] = [:]
        var orderedKeys: [String] = []

        for device in devices {
            let key = normalizedIdentifier(device.info["device_address"])
                ?? normalizedDeviceName(device.name)
            if let existing = mergedByKey[key] {
                if !existing.isConnected, device.isConnected {
                    mergedByKey[key] = device
                }
            } else {
                mergedByKey[key] = device
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { mergedByKey[$0] }
    }

    private static func collectBluetoothPowerLogDevices(
        from profile: BluetoothProfile,
        existingItems: [DeviceBatteryItem],
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        let targets = bluetoothBatteryTargets(from: profile).filter { target in
            needsBluetoothPowerLogFallback(target: target, existingItems: existingItems)
        }
        guard !targets.isEmpty else {
            return []
        }

        let componentTargets = targets.filter { supportsComponentPowerLog(target: $0) }
        let regularTargets = targets.filter { !supportsComponentPowerLog(target: $0) }
        let recentReadings = collectBluetoothPowerLogReadings(
            targets: targets,
            lookback: bluetoothPowerLogLookback,
            timeout: bluetoothPowerLogTimeout
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

        return DeviceBatteryItemNormalizer.removingRedundantComponentAggregates(items)
    }

    private static let bluetoothPowerLogPredicate = #"subsystem == "com.apple.bluetooth" AND category == "CBPowerSource" AND eventMessage CONTAINS "Battery""#

    private static func collectBluetoothPowerLogReadings(
        targets: [BluetoothBatteryTarget],
        lookback: String,
        timeout: TimeInterval
    ) -> [DeviceBatteryBluetoothPowerLogReading] {
        guard let output = runCommand(
            path: "/usr/bin/nice",
            // Keep upstream's low-priority `nice -n 19` wrapper; route the log
            // args through the macOS-27 helper that drops `--process` (the beta
            // ignores `--predicate` when `--process` is also passed, returning the
            // unfiltered firehose). The predicate alone pins the bluetooth subsystem.
            arguments: ["-n", "19", "/usr/bin/log"] + bluetoothPowerLogShowArguments(
                lookback: lookback,
                predicate: bluetoothPowerLogPredicate(for: targets)
            ),
            timeout: timeout,
            outputLineFilter: { line in
                isBluetoothPowerLogLine(line, matching: targets)
            }
        ) else {
            return []
        }

        return DeviceBatteryBluetoothPowerLogParser.readings(from: output)
    }

    private static func collectBatteryCenterLogDevices(
        from profile: BluetoothProfile,
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        let targets = bluetoothBatteryTargets(from: profile)
        guard !targets.isEmpty || !profile.connectedDevices.isEmpty || !profile.batteryDevices.isEmpty else {
            return []
        }

        let recentReadings = collectBatteryCenterLogReadings(
            lookback: batteryCenterLogLookback,
            timeout: batteryCenterLogTimeout
        )

        return batteryCenterLogItems(
            from: recentReadings,
            targets: targets,
            referenceDate: referenceDate
        )
    }

    private static func collectBatteryCenterLogReadings(
        lookback: String,
        timeout: TimeInterval
    ) -> [DeviceBatteryBatteryCenterLogReading] {
        guard let output = runCommand(
            path: "/usr/bin/nice",
            arguments: [
                "-n",
                "19",
                "/usr/bin/log",
                "show",
                "--info",
                "--last",
                lookback,
                "--style",
                "compact",
                "--predicate",
                #"subsystem == "com.apple.BatteryCenter" AND eventMessage CONTAINS "BCBatteryDevice" AND eventMessage CONTAINS "percentCharge""#
            ],
            timeout: timeout,
            outputLineFilter: { line in
                line.contains("BCBatteryDevice") && line.contains("percentCharge")
            }
        ) else {
            return []
        }

        return DeviceBatteryBatteryCenterLogParser.readings(from: output)
    }

    private static func batteryCenterLogItems(
        from readings: [DeviceBatteryBatteryCenterLogReading],
        targets: [BluetoothBatteryTarget],
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        readings.compactMap { reading in
            if let target = matchingBatteryCenterLogTarget(reading, in: targets) {
                return DeviceBatteryItem(
                    id: "batterycenter-\(target.address ?? target.id)",
                    name: target.name,
                    model: firstNonEmpty(reading.model, target.model),
                    kind: target.kind,
                    level: reading.level,
                    chargeState: reading.chargeState,
                    parentName: nil,
                    source: "BatteryCenter",
                    lastUpdated: referenceDate,
                    isConnected: reading.isConnected ?? target.isConnected,
                    detail: firstNonEmpty(reading.category, target.detail),
                    componentIdentity: componentAggregateIdentity(
                        groupID: target.componentGroupID,
                        kind: target.kind
                    )
                )
            }

            guard reading.isInternal != true,
                  let name = firstNonEmptyOptional(reading.name, reading.groupName)
            else {
                return nil
            }

            let kind = batteryCenterKind(reading: reading)
            return DeviceBatteryItem(
                id: "batterycenter-\(reading.accessoryID ?? normalizedDeviceName(name))",
                name: name,
                model: reading.model,
                kind: kind,
                level: reading.level,
                chargeState: reading.chargeState,
                parentName: nil,
                source: "BatteryCenter",
                lastUpdated: referenceDate,
                isConnected: reading.isConnected ?? true,
                detail: firstNonEmpty(reading.category, reading.transportType),
                componentIdentity: componentAggregateIdentity(
                    groupID: reading.accessoryID ?? normalizedDeviceName(name),
                    kind: kind
                )
            )
        }
    }

    private static func batteryCenterKind(reading: DeviceBatteryBatteryCenterLogReading) -> DeviceBatteryKind {
        let haystack = [
            reading.name,
            reading.groupName,
            reading.model,
            reading.category
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

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

    fileprivate static func matchingBatteryCenterLogTarget(
        _ reading: DeviceBatteryBatteryCenterLogReading,
        in targets: [BluetoothBatteryTarget]
    ) -> BluetoothBatteryTarget? {
        let nameMatchedTargets = targets.filter { target in
            batteryCenterNamesMatch(reading: reading, target: target)
                && batteryCenterProductIdentifiersMatch(reading: reading, target: target)
        }
        if nameMatchedTargets.count == 1 {
            return nameMatchedTargets[0]
        }

        guard let readingProductID = normalizedProductIdentifier(reading.productID) else {
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

    /// Builds the `log show` argument vector. macOS 27 beta drops the
    /// `--predicate` when `--process` is also passed (verified on 26A5353q:
    /// `--process bluetoothd --predicate …` returns ~the unfiltered firehose),
    /// which produces a CPU spike and timeout-truncated output. The predicate
    /// already pins `subsystem == "com.apple.bluetooth"`, so it fully replaces
    /// the process filter; dropping `--process` is correct on every macOS
    /// (the predicate works standalone on all systems) and needs no OS gate.
    static func bluetoothPowerLogShowArguments(
        lookback: String,
        predicate: String
    ) -> [String] {
        [
            "show",
            "--info",
            "--last",
            lookback,
            "--style",
            "compact",
            "--predicate",
            predicate
        ]
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
                name: powerLogItemName(reading: reading, target: target, localization: localization),
                model: target.model,
                kind: reading.component == nil ? target.kind : .airPodsPart,
                level: reading.level,
                chargeState: reading.chargeState,
                parentName: powerLogParentName(reading: reading, target: target, localization: localization),
                source: "BluetoothPowerLog",
                lastUpdated: referenceDate,
                isConnected: target.isConnected,
                detail: reading.deviceType ?? target.detail,
                componentIdentity: powerLogComponentIdentity(reading: reading, target: target)
            )
        }
    }

    private static func needsBluetoothPowerLogFallback(
        target: BluetoothBatteryTarget,
        existingItems: [DeviceBatteryItem]
    ) -> Bool {
        if supportsComponentPowerLog(target: target) {
            return true
        }

        guard target.isConnected else {
            return false
        }

        if normalizedHexIdentifier(target.vendorID) == "004C" {
            return false
        }

        let targetName = normalizedDeviceName(target.name)
        return !existingItems.contains { item in
            item.parentName == nil
                && normalizedDeviceName(item.name) == targetName
                && item.clampedLevel != nil
        }
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
            groupID: target.componentGroupID,
            role: reading.component?.componentRole ?? .aggregate
        )
    }

    private static func supportsComponentPowerLog(target: BluetoothBatteryTarget) -> Bool {
        guard normalizedHexIdentifier(target.vendorID) == "004C" else {
            return false
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
        referenceDate: Date,
        localization: PluginLocalization
    ) -> [DeviceBatteryItem] {
        var items = collectBluetoothProfileBatteryItems(
            from: profile,
            referenceDate: referenceDate,
            localization: localization
        )
        items.append(contentsOf: collectIOBluetoothBattery(from: profile, referenceDate: referenceDate))
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
            let model = productID.flatMap { HeadphoneModelCatalog.modelName(forProductID: $0) }
            let parentID = normalizedIdentifier(device.info["device_address"]) ?? normalizedIdentifier(productID) ?? device.name

            appendBluetoothLevel(
                to: &items,
                name: device.name,
                suffix: nil,
                fieldName: "device_batteryLevelMain",
                device: device,
                id: parentID,
                kind: inferredKind(device: device, field: "main"),
                model: model,
                parentName: nil,
                componentRole: hasBluetoothComponentBatteryFields(device.info) ? .aggregate : nil,
                referenceDate: referenceDate
            )
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
                kind: .airPodsPart,
                model: model,
                parentName: caseName,
                componentRole: .right,
                referenceDate: referenceDate
            )
        }

        return DeviceBatteryItemNormalizer.removingRedundantComponentAggregates(items)
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
                    DeviceBatteryComponentIdentity(groupID: id, role: $0)
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

    private static func collectIOBluetoothBattery(
        from profile: BluetoothProfile,
        referenceDate: Date
    ) -> [DeviceBatteryItem] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        return devices.compactMap { device in
            guard device.isConnected(),
                  let level = device.pluginBatteryPercentSingle,
                  level > 0,
                  let name = device.name,
                  !name.isEmpty
            else {
                return nil
            }

            let address = normalizedIdentifier(device.addressString) ?? name
            let profileDevice = profile.connectedDevices.first { normalizedIdentifier($0.info["device_address"]) == address }
            let kind = profileDevice.map { inferredKind(device: $0, field: "single") } ?? .bluetooth
            return DeviceBatteryItem(
                id: "iobluetooth-\(address)",
                name: name,
                model: nil,
                kind: kind,
                level: level,
                chargeState: .normal,
                parentName: nil,
                source: "IOBluetooth",
                lastUpdated: referenceDate,
                isConnected: true,
                detail: profileDevice?.info["device_minorType"] as? String,
                componentIdentity: componentAggregateIdentity(groupID: address, kind: kind)
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

        let matchedProfileDevice = profile.connectedDevices.first { profileDevice in
            normalizedIdentifier(profileDevice.info["device_address"]) == address
        }
        let name = firstNonEmpty(
            matchedProfileDevice?.name,
            productName,
            serviceClass,
            localization: localization
        )
        let statusFlags = intProperty("BatteryStatusFlags", object: object)
        let chargeState: DeviceBatteryChargeState = statusFlags == 4 ? .normal : (statusFlags ?? 0) > 0 ? .charging : .normal
        let kind = inferredMagicKind(productName: productName, profileDevice: matchedProfileDevice)

        return DeviceBatteryItem(
            id: "ioregistry-\(address ?? name)-\(serviceClass)",
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

    private static func inferredKind(
        device: BluetoothProfileDevice,
        field: String
    ) -> DeviceBatteryKind {
        inferredBluetoothKind(
            name: device.name,
            minorType: device.info["device_minorType"] as? String,
            vendorID: device.info["device_vendorID"] as? String,
            field: field
        )
    }

    static func inferredBluetoothKind(
        name: String,
        minorType: String?,
        vendorID: String?,
        field: String
    ) -> DeviceBatteryKind {
        let name = name.lowercased()
        let type = (minorType ?? "").lowercased()
        let vendorID = (vendorID ?? "").lowercased()

        if field == "case" || field == "left" || field == "right" {
            return .airPodsPart
        }
        if field != "main" || name.contains("airpods") || name.contains("beats") {
            if name.contains("airpods")
                || name.contains("beats")
                || type.contains("headphone")
                || type.contains("headset") {
                return .airPodsPart
            }
        }
        if vendorID == "0x004c" {
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
            let model = productID.flatMap { HeadphoneModelCatalog.modelName(forProductID: $0) }
            return BluetoothBatteryTarget(
                id: normalizedIdentifier(device.info["device_address"]) ?? device.name,
                name: device.name,
                address: normalizedIdentifier(device.info["device_address"]),
                vendorID: vendorID,
                productID: productID,
                model: model,
                kind: inferredKind(device: device, field: "single"),
                detail: device.info["device_minorType"] as? String,
                isConnected: device.isConnected
            )
        }
    }

    fileprivate static func matchingBluetoothPowerLogTarget(
        _ reading: DeviceBatteryBluetoothPowerLogReading,
        in targets: [BluetoothBatteryTarget]
    ) -> BluetoothBatteryTarget? {
        let candidates = targets.filter { target in
            normalizedDeviceName(target.name) == normalizedDeviceName(reading.name)
                && bluetoothIdentifiersMatch(reading: reading, target: target)
        }

        if candidates.count == 1 {
            return candidates[0]
        }

        return candidates.first { target in
            normalizedHexIdentifier(target.vendorID) == normalizedHexIdentifier(reading.vendorID)
                && normalizedHexIdentifier(target.productID) == normalizedHexIdentifier(reading.productID)
        }
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

    private static func deduplicated(_ items: [DeviceBatteryItem]) -> [DeviceBatteryItem] {
        var bestByNameAndKind: [String: DeviceBatteryItem] = [:]
        var orderedKeys: [String] = []

        for item in DeviceBatteryItemNormalizer.removingRedundantComponentAggregates(items) {
            let key = "\(item.kind)-\(item.name.lowercased())-\(item.parentName ?? "")"
            if let existing = bestByNameAndKind[key] {
                bestByNameAndKind[key] = preferredItem(existing, item)
            } else {
                bestByNameAndKind[key] = item
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { bestByNameAndKind[$0] }
    }

    private static func preferredItem(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> DeviceBatteryItem {
        if left.chargeState.isActiveChargingState != right.chargeState.isActiveChargingState {
            return left.chargeState.isActiveChargingState ? left : right
        }

        let sourceRank = [
            "IORegistry": 0,
            "IOPowerSources": 0,
            "CoreBluetooth": 1,
            "AppleHeadphoneAdvertisement": 2,
            "BatteryCenter": 3,
            "BluetoothPowerLog": 4,
            "IOBluetooth": 5,
            "system_profiler": 6
        ]
        let leftRank = sourceRank[left.source] ?? 10
        let rightRank = sourceRank[right.source] ?? 10
        if leftRank != rightRank {
            return leftRank < rightRank ? left : right
        }

        return left.lastUpdated ?? .distantPast >= right.lastUpdated ?? .distantPast ? left : right
    }

    private static func batteryLevel(from value: Any?) -> Int? {
        batteryValue(from: value)?.level
    }

    private static func batteryValue(from value: Any?) -> (level: Int, chargeState: DeviceBatteryChargeState)? {
        if let number = value as? NSNumber {
            let level = number.intValue
            guard (0...100).contains(level) else {
                return nil
            }
            return (level, .normal)
        }

        guard let string = value as? String else {
            return nil
        }

        let digits = string
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let level = Int(digits), (0...100).contains(level) else {
            return nil
        }

        return (level, digits.hasPrefix("+") ? .charging : .normal)
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
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputAccumulator = CommandOutputAccumulator(lineFilter: outputLineFilter)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            outputAccumulator.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }

        guard !process.isRunning else {
            process.terminate()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputAccumulator.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            let partialOutput = outputAccumulator.output()
            return outputLineFilter == nil || partialOutput.isEmpty ? nil : partialOutput
        }

        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        outputAccumulator.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        _ = errorPipe.fileHandleForReading.readDataToEndOfFile()
        outputPipe.fileHandleForReading.closeFile()
        errorPipe.fileHandleForReading.closeFile()

        return outputAccumulator.output()
    }
}

private final class CommandOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let lineFilter: ((String) -> Bool)?
    private var bufferedOutput = ""
    private var pendingLine = ""

    init(lineFilter: ((String) -> Bool)?) {
        self.lineFilter = lineFilter
    }

    func append(_ data: Data) {
        guard !data.isEmpty,
              let chunk = String(data: data, encoding: .utf8)
        else {
            return
        }

        lock.lock()
        if let lineFilter {
            appendFiltered(chunk, lineFilter: lineFilter)
        } else {
            bufferedOutput.append(chunk)
        }
        lock.unlock()
    }

    func output() -> String {
        lock.lock()
        if let lineFilter,
           !pendingLine.isEmpty,
           lineFilter(pendingLine) {
            bufferedOutput.append(pendingLine)
            bufferedOutput.append("\n")
        }
        pendingLine = ""
        let currentOutput = bufferedOutput
        lock.unlock()
        return currentOutput
    }

    private func appendFiltered(
        _ chunk: String,
        lineFilter: (String) -> Bool
    ) {
        pendingLine.append(chunk)
        let lines = pendingLine.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else {
            return
        }

        for line in lines.dropLast() {
            let text = String(line)
            if lineFilter(text) {
                bufferedOutput.append(text)
                bufferedOutput.append("\n")
            }
        }

        pendingLine = String(lines.last ?? "")
    }
}

private struct BluetoothProfile {
    let connectedDevices: [BluetoothProfileDevice]
    let batteryDevices: [BluetoothProfileDevice]
}

private struct BluetoothProfileDevice {
    let name: String
    let info: [String: Any]
    let isConnected: Bool
}

private struct DeviceBatteryBaseSample: Sendable {
    let items: [DeviceBatteryItem]
    let bluetoothBatteryTargets: [BluetoothBatteryTarget]
}

fileprivate struct BluetoothBatteryTarget: Sendable {
    let id: String
    let name: String
    let address: String?
    let vendorID: String?
    let productID: String?
    let model: String?
    let kind: DeviceBatteryKind
    let detail: String?
    let isConnected: Bool

    var componentGroupID: String {
        address ?? id
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
                chargeState: batteryValue.isCharging ? .charging : .normal
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
                chargeState: batteryValue.isCharging ? .charging : .normal
            )
        })

        return readings
    }

    private static func componentBatteryValues(
        in line: String
    ) -> [(DeviceBatteryBluetoothPowerLogComponent, (level: Int, isCharging: Bool))] {
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
    ) -> (level: Int, isCharging: Bool)? {
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

        return (level: level, isCharging: value.hasPrefix("+"))
    }
}

struct DeviceBatteryBatteryCenterLogReading: Equatable, Sendable {
    let name: String?
    let groupName: String?
    let productID: String?
    let model: String?
    let category: String?
    let accessoryID: String?
    let transportType: String?
    let level: Int
    let chargeState: DeviceBatteryChargeState
    let isConnected: Bool?
    let isInternal: Bool?
}

enum DeviceBatteryBatteryCenterLogParser {
    static func readings(from output: String) -> [DeviceBatteryBatteryCenterLogReading] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { reading(fromLine: String($0)) }
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
            model: field("modelNumber", in: payload),
            category: field("accessoryCategory", in: payload),
            accessoryID: field("accessoryIdentifier", in: payload),
            transportType: field("transportType", in: payload),
            level: level,
            chargeState: boolField("charging", in: payload) == true ? .charging : .normal,
            isConnected: boolField("connected", in: payload),
            isInternal: boolField("internal", in: payload)
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

struct DeviceBatteryAppleHeadphoneAdvertisementReading: Equatable, Sendable {
    let component: DeviceBatteryBluetoothPowerLogComponent
    let level: Int
    let chargeState: DeviceBatteryChargeState
}

enum DeviceBatteryAppleHeadphoneAdvertisementParser {
    static func readings(from manufacturerData: Data) -> [DeviceBatteryAppleHeadphoneAdvertisementReading] {
        let bytes = [UInt8](manufacturerData)
        guard bytes.count >= 2, bytes[0] == 0x4C, bytes[1] == 0x00 else {
            return []
        }

        switch bytes.count {
        case 29 where bytes[2] == 0x07:
            return openCaseReadings(from: bytes)
        case 25 where bytes[2] == 0x12:
            return closedCaseReadings(from: bytes)
        default:
            return []
        }
    }

    private static func openCaseReadings(from bytes: [UInt8]) -> [DeviceBatteryAppleHeadphoneAdvertisementReading] {
        let flip = (bytes[7] & 0x02) == 0
        return [
            reading(component: .chargingCase, rawLevel: bytes[16]),
            reading(component: .left, rawLevel: bytes[flip ? 15 : 14]),
            reading(component: .right, rawLevel: bytes[flip ? 14 : 15])
        ]
            .compactMap { $0 }
    }

    private static func closedCaseReadings(from bytes: [UInt8]) -> [DeviceBatteryAppleHeadphoneAdvertisementReading] {
        [
            reading(component: .chargingCase, rawLevel: bytes[12]),
            reading(component: .left, rawLevel: bytes[13]),
            reading(component: .right, rawLevel: bytes[14])
        ]
            .compactMap { $0 }
    }

    private static func reading(
        component: DeviceBatteryBluetoothPowerLogComponent,
        rawLevel: UInt8
    ) -> DeviceBatteryAppleHeadphoneAdvertisementReading? {
        guard rawLevel != 0xFF else {
            return nil
        }

        let isCharging = rawLevel > 100
        let level = Int(rawLevel & 0x7F)
        guard (0...100).contains(level) else {
            return nil
        }

        return DeviceBatteryAppleHeadphoneAdvertisementReading(
            component: component,
            level: level,
            chargeState: isCharging ? .charging : .normal
        )
    }
}

@MainActor
private final class DeviceBatteryAppleHeadphoneAdvertisementReader: NSObject, @preconcurrency CBCentralManagerDelegate {
    private let targets: [BluetoothBatteryTarget]
    private let targetsByName: [String: BluetoothBatteryTarget]
    private let referenceDate: Date
    private let localization: PluginLocalization
    private var centralManager: CBCentralManager?
    private var continuations: [CheckedContinuation<[DeviceBatteryItem], Never>] = []
    private var readingsByTargetID: [String: [DeviceBatteryBluetoothPowerLogComponent: DeviceBatteryAppleHeadphoneAdvertisementReading]] = [:]
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    static func collectBatteryDevices(
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) async -> [DeviceBatteryItem] {
        let eligibleTargets = targets.filter { target in
            target.vendorID.flatMap(DeviceBatterySampler.normalizedHexIdentifierForReader) == "004C"
                && DeviceBatteryAppleHeadphoneAdvertisementReader.supportsAdvertisementBattery(target: target)
        }
        guard !eligibleTargets.isEmpty else {
            return []
        }

        let reader = DeviceBatteryAppleHeadphoneAdvertisementReader(
            targets: eligibleTargets,
            referenceDate: referenceDate,
            localization: localization
        )
        return await reader.collect()
    }

    init(
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) {
        self.targets = targets
        self.targetsByName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name.lowercased(), $0) })
        self.referenceDate = referenceDate
        self.localization = localization
        super.init()
    }

    private func collect() async -> [DeviceBatteryItem] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            centralManager = CBCentralManager(delegate: self, queue: .main)
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(2500))
                self?.finish()
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            finish()
            return
        }

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              let target = targetsByName[name.lowercased()],
              let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        else {
            return
        }

        let readings = DeviceBatteryAppleHeadphoneAdvertisementParser.readings(from: manufacturerData)
        guard !readings.isEmpty else {
            return
        }

        var targetReadings = readingsByTargetID[target.id] ?? [:]
        for reading in readings {
            targetReadings[reading.component] = reading
        }
        readingsByTargetID[target.id] = targetReadings

        let hasChargingState = targetReadings.values.contains { $0.chargeState == .charging }
        if hasChargingState || readingsByTargetID.count == targets.count {
            finish()
        }
    }

    private func finish() {
        guard !didFinish else {
            return
        }

        didFinish = true
        timeoutTask?.cancel()
        centralManager?.stopScan()
        let items = batteryItems()
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume(returning: items)
        }
    }

    private func batteryItems() -> [DeviceBatteryItem] {
        readingsByTargetID.flatMap { targetID, readingsByComponent -> [DeviceBatteryItem] in
            guard let target = targets.first(where: { $0.id == targetID }) else {
                return []
            }

            return readingsByComponent.values.map { reading in
                DeviceBatteryItem(
                    id: "apple-headphone-advertisement-\(target.componentGroupID)-\(reading.component.idSuffix)",
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
                        groupID: target.componentGroupID,
                        role: reading.component.componentRole
                    )
                )
            }
        }
    }

    private static func supportsAdvertisementBattery(target: BluetoothBatteryTarget) -> Bool {
        let haystack = [
            target.name,
            target.model,
            target.detail
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return haystack.contains("airpods") || haystack.contains("beats")
    }
}

@MainActor
private final class DeviceBatteryBLEBatteryReader: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let deviceInformationService = CBUUID(string: "180A")
    private static let batteryLevelCharacteristic = CBUUID(string: "2A19")
    private static let modelNumberCharacteristic = CBUUID(string: "2A24")
    private static let manufacturerNameCharacteristic = CBUUID(string: "2A29")

    private let targetsByName: [String: BluetoothBatteryTarget]
    private let referenceDate: Date
    private let localization: PluginLocalization
    private var centralManager: CBCentralManager?
    private var continuations: [CheckedContinuation<[DeviceBatteryItem], Never>] = []
    private var peripheralsByID: [UUID: CBPeripheral] = [:]
    private var pendingPeripheralIDs: Set<UUID> = []
    private var readingByID: [UUID: BluetoothBatteryReading] = [:]
    private var discoveredNames: Set<String> = []
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    static func collectBatteryDevices(
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) async -> [DeviceBatteryItem] {
        let eligibleTargets = targets.filter { target in
            target.isConnected && (target.kind == .bluetooth || target.kind == .magicAccessory)
        }
        guard !eligibleTargets.isEmpty else {
            return []
        }

        let reader = DeviceBatteryBLEBatteryReader(
            targets: eligibleTargets,
            referenceDate: referenceDate,
            localization: localization
        )
        return await reader.collect()
    }

    init(
        targets: [BluetoothBatteryTarget],
        referenceDate: Date,
        localization: PluginLocalization
    ) {
        self.targetsByName = Dictionary(
            uniqueKeysWithValues: targets.map { ($0.name.lowercased(), $0) }
        )
        self.referenceDate = referenceDate
        self.localization = localization
        super.init()
    }

    private func collect() async -> [DeviceBatteryItem] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            centralManager = CBCentralManager(delegate: self, queue: .main)
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish()
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
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

        central.scanForPeripherals(
            withServices: [Self.batteryService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        if connectedPeripherals.isEmpty {
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finish()
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        register(peripheral, central: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        discoverServices(for: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        pendingPeripheralIDs.remove(peripheral.identifier)
        finishIfSettled()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            pendingPeripheralIDs.remove(peripheral.identifier)
            finishIfSettled()
            return
        }

        let wantedServices = services.filter { service in
            service.uuid == Self.batteryService || service.uuid == Self.deviceInformationService
        }
        guard !wantedServices.isEmpty else {
            pendingPeripheralIDs.remove(peripheral.identifier)
            finishIfSettled()
            return
        }

        for service in wantedServices {
            peripheral.discoverCharacteristics(
                [
                    Self.batteryLevelCharacteristic,
                    Self.modelNumberCharacteristic,
                    Self.manufacturerNameCharacteristic
                ],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            pendingPeripheralIDs.remove(peripheral.identifier)
            finishIfSettled()
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
            finishIfSettled()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        defer {
            if readingByID[peripheral.identifier]?.level != nil {
                pendingPeripheralIDs.remove(peripheral.identifier)
                finishIfSettled()
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
        guard let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              targetsByName[name.lowercased()] != nil,
              !discoveredNames.contains(name.lowercased())
        else {
            return
        }

        discoveredNames.insert(name.lowercased())
        peripheralsByID[peripheral.identifier] = peripheral
        pendingPeripheralIDs.insert(peripheral.identifier)
        peripheral.delegate = self

        if peripheral.state == .connected {
            discoverServices(for: peripheral)
        } else {
            central.connect(peripheral, options: nil)
        }
    }

    private func discoverServices(for peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService, Self.deviceInformationService])
    }

    private func finishIfSettled() {
        if !pendingPeripheralIDs.isEmpty {
            return
        }

        finish()
    }

    private func finish() {
        guard !didFinish else {
            return
        }

        didFinish = true
        timeoutTask?.cancel()
        centralManager?.stopScan()
        let items = batteryItems()
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume(returning: items)
        }
    }

    private func batteryItems() -> [DeviceBatteryItem] {
        readingByID.compactMap { peripheralID, reading in
            guard let peripheral = peripheralsByID[peripheralID],
                  let name = peripheral.name,
                  let target = targetsByName[name.lowercased()],
                  let level = reading.level
            else {
                return nil
            }

            return DeviceBatteryItem(
                id: "corebluetooth-\(target.address ?? target.id)",
                name: target.name,
                model: firstNonEmpty(reading.model, target.model),
                kind: target.kind,
                level: level,
                chargeState: .normal,
                parentName: nil,
                source: "CoreBluetooth",
                lastUpdated: referenceDate,
                isConnected: true,
                detail: firstNonEmpty(reading.manufacturer, target.detail),
                componentIdentity: DeviceBatterySampler.componentAggregateIdentity(
                    groupID: target.componentGroupID,
                    kind: target.kind
                )
            )
        }
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

enum HeadphoneModelCatalog {
    private static let modelNamesByProductID: [String: String] = [
        "2002": "AirPods",
        "2003": "Powerbeats3",
        "2005": "BeatsX",
        "2006": "Beats Solo3",
        "200e": "AirPods Pro",
        "200a": "AirPods Max",
        "200b": "Powerbeats Pro",
        "200c": "Beats Solo Pro",
        "200d": "Powerbeats4",
        "200f": "AirPods 2",
        "2010": "Beats Flex",
        "2011": "Beats Studio Buds",
        "2012": "Beats Fit Pro",
        "2013": "AirPods 3",
        "2014": "AirPods Pro 2",
        "2016": "Beats Studio Buds+",
        "2017": "Beats Studio Pro",
        "2019": "AirPods 4",
        "201b": "AirPods 4",
        "201d": "AirPods Pro 2",
        "201f": "AirPods Max",
        "2024": "AirPods Pro 2",
        "2026": "Beats Solo Buds",
        "2027": "Powerbeats Pro 2"
    ]

    static func modelName(forProductID productID: String) -> String? {
        let normalized = productID
            .replacingOccurrences(of: "0x", with: "")
            .lowercased()
        return modelNamesByProductID[normalized]
    }
}
