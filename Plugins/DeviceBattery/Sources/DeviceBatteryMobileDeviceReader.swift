import Darwin
import Foundation

protocol DeviceBatteryMobileDeviceSampling: Sendable {
    func collectDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem]
}

actor DeviceBatteryMobileDeviceReader: DeviceBatteryMobileDeviceSampling {
    typealias RecordReader = @Sendable () -> DeviceBatteryMobileDeviceReadResult

    private struct CachedChargeState {
        let value: DeviceBatteryChargeState
        let observedAt: Date
    }

    private static let transientReadingGraceInterval: TimeInterval = 3 * 60

    private var cachedItems: [DeviceBatteryItem] = []
    private var cachedChargeStates: [String: CachedChargeState] = [:]
    private var lastCollectionDate: Date?
    private let recordReader: RecordReader
    private var inFlightTask: (
        id: UUID,
        task: Task<DeviceBatteryMobileDeviceReadResult, Never>
    )?

    init() {
        recordReader = {
            DeviceBatteryMobileDeviceBridge.readRecords()
        }
    }

    init(recordReader: @escaping RecordReader) {
        self.recordReader = recordReader
    }

    func collectDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        if let lastCollectionDate,
           referenceDate.timeIntervalSince(lastCollectionDate) < minimumRefreshInterval {
            return cachedItems
        }

        let requestID: UUID
        let task: Task<DeviceBatteryMobileDeviceReadResult, Never>
        if let inFlightTask {
            requestID = inFlightTask.id
            task = inFlightTask.task
        } else {
            requestID = UUID()
            let recordReader = self.recordReader
            let newTask = Task.detached(priority: .utility) {
                recordReader()
            }
            inFlightTask = (requestID, newTask)
            task = newTask
        }

        let result = await task.value
        if inFlightTask?.id == requestID {
            inFlightTask = nil
        }

        lastCollectionDate = referenceDate
        if result.didEnumerateDevices, result.connectedDeviceCount == 0 {
            cachedItems.removeAll()
            cachedChargeStates.removeAll()
            return []
        }

        let records = DeviceBatteryMobileDeviceRecord.preferredRecords(in: result.records)
        guard !records.isEmpty else {
            guard result.hasTransientFailure else {
                cachedItems.removeAll()
                return []
            }
            cachedItems = cachedItems.compactMap {
                retainedItem($0, referenceDate: referenceDate)
            }
            return cachedItems
        }

        var items = records.map { record in
            let resolved = resolvedRecord(record, referenceDate: referenceDate)
            return resolved.record.batteryItem(
                referenceDate: referenceDate,
                chargeStateReferenceDate: resolved.chargeStateObservedAt
            )
        }
        if result.hasTransientFailure {
            let currentIdentities = Set(items.map(\.deviceIdentity))
            items.append(contentsOf: cachedItems.compactMap { item in
                guard !currentIdentities.contains(item.deviceIdentity) else {
                    return nil
                }
                return retainedItem(item, referenceDate: referenceDate)
            })
        }

        cachedItems = items
        return items
    }

    private func resolvedRecord(
        _ record: DeviceBatteryMobileDeviceRecord,
        referenceDate: Date
    ) -> (record: DeviceBatteryMobileDeviceRecord, chargeStateObservedAt: Date?) {
        if Self.hasUsableChargeState(record.chargeState) {
            cachedChargeStates[record.identifier] = CachedChargeState(
                value: record.chargeState,
                observedAt: referenceDate
            )
            return (record, referenceDate)
        }

        guard let cachedState = cachedChargeStates[record.identifier],
              referenceDate.timeIntervalSince(cachedState.observedAt)
                <= Self.transientReadingGraceInterval else {
            cachedChargeStates.removeValue(forKey: record.identifier)
            return (record, nil)
        }
        return (
            record.replacingChargeState(cachedState.value),
            cachedState.observedAt
        )
    }

    private func retainedItem(
        _ item: DeviceBatteryItem,
        referenceDate: Date
    ) -> DeviceBatteryItem? {
        guard let lastUpdated = item.lastUpdated,
              referenceDate.timeIntervalSince(lastUpdated)
                <= Self.transientReadingGraceInterval else {
            return nil
        }

        let identifier = item.deviceIdentity.value
        guard item.deviceIdentity.namespace == .mobileDevice,
              let cachedState = cachedChargeStates[identifier],
              referenceDate.timeIntervalSince(cachedState.observedAt)
                <= Self.transientReadingGraceInterval else {
            cachedChargeStates.removeValue(forKey: identifier)
            return item.replacingChargeState(.unknown, observedAt: nil)
        }
        return item.replacingChargeState(
            cachedState.value,
            observedAt: cachedState.observedAt
        )
    }

    private static func hasUsableChargeState(
        _ chargeState: DeviceBatteryChargeState
    ) -> Bool {
        chargeState != .unknown && chargeState != .invalid
    }
}

enum DeviceBatteryMobileDeviceCategory: Equatable, Sendable {
    case phone
    case tablet
    case mediaPlayer
    case watch
    case spatialComputer
    case other

    var itemKind: DeviceBatteryKind {
        switch self {
        case .phone:
            return .phone
        case .tablet:
            return .tablet
        case .mediaPlayer:
            return .mediaPlayer
        case .watch:
            return .watch
        case .spatialComputer:
            return .spatialComputer
        case .other:
            return .other
        }
    }

    static func resolve(deviceClass: String?, productType: String) -> Self {
        let value = [deviceClass, productType]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if value.contains("iphone") || value.contains("mobilephone") {
            return .phone
        }
        if value.contains("ipad") || value.contains("tablet") {
            return .tablet
        }
        if value.contains("ipod") {
            return .mediaPlayer
        }
        if value.contains("watch") {
            return .watch
        }
        if value.contains("reality") || value.contains("vision") {
            return .spatialComputer
        }
        return .other
    }
}

struct DeviceBatteryMobileDeviceRecord: Equatable, Sendable {
    let identifier: String
    let bluetoothAddress: String?
    let name: String
    let productType: String
    let category: DeviceBatteryMobileDeviceCategory
    let level: Int
    let chargeState: DeviceBatteryChargeState
    let connectionType: String
    let parentName: String?

    init(
        identifier: String,
        bluetoothAddress: String? = nil,
        name: String,
        productType: String,
        category: DeviceBatteryMobileDeviceCategory,
        level: Int,
        chargeState: DeviceBatteryChargeState,
        connectionType: String,
        parentName: String?
    ) {
        self.identifier = identifier
        self.bluetoothAddress = bluetoothAddress
        self.name = name
        self.productType = productType
        self.category = category
        self.level = level
        self.chargeState = chargeState
        self.connectionType = connectionType
        self.parentName = parentName
    }

    func replacingChargeState(
        _ chargeState: DeviceBatteryChargeState
    ) -> DeviceBatteryMobileDeviceRecord {
        DeviceBatteryMobileDeviceRecord(
            identifier: identifier,
            bluetoothAddress: bluetoothAddress,
            name: name,
            productType: productType,
            category: category,
            level: level,
            chargeState: chargeState,
            connectionType: connectionType,
            parentName: parentName
        )
    }

    static func preferredRecords(
        in records: [DeviceBatteryMobileDeviceRecord]
    ) -> [DeviceBatteryMobileDeviceRecord] {
        var identifiers: [String] = []
        var recordsByIdentifier: [String: DeviceBatteryMobileDeviceRecord] = [:]
        for record in records {
            if recordsByIdentifier[record.identifier] == nil {
                identifiers.append(record.identifier)
                recordsByIdentifier[record.identifier] = record
                continue
            }
            if let existing = recordsByIdentifier[record.identifier] {
                recordsByIdentifier[record.identifier] = mergingDuplicateRecords(
                    existing,
                    record
                )
            }
        }
        return identifiers.compactMap { recordsByIdentifier[$0] }
    }

    private static func mergingDuplicateRecords(
        _ left: DeviceBatteryMobileDeviceRecord,
        _ right: DeviceBatteryMobileDeviceRecord
    ) -> DeviceBatteryMobileDeviceRecord {
        let preferred: DeviceBatteryMobileDeviceRecord
        let supplemental: DeviceBatteryMobileDeviceRecord
        if recordPrecedes(left, right) {
            preferred = left
            supplemental = right
        } else {
            preferred = right
            supplemental = left
        }

        guard !hasUsableChargeState(preferred.chargeState),
              hasUsableChargeState(supplemental.chargeState) else {
            return preferred
        }
        return preferred.replacingChargeState(supplemental.chargeState)
    }

    private static func recordPrecedes(
        _ left: DeviceBatteryMobileDeviceRecord,
        _ right: DeviceBatteryMobileDeviceRecord
    ) -> Bool {
        let connectionRank = ["USB": 0, "Wi-Fi": 1, "": 2]
        let leftConnectionRank = connectionRank[left.connectionType] ?? 3
        let rightConnectionRank = connectionRank[right.connectionType] ?? 3
        if leftConnectionRank != rightConnectionRank {
            return leftConnectionRank < rightConnectionRank
        }

        let leftHasState = left.chargeState != .unknown && left.chargeState != .invalid
        let rightHasState = right.chargeState != .unknown && right.chargeState != .invalid
        if leftHasState != rightHasState {
            return leftHasState
        }

        return [
            left.name,
            left.productType,
            left.parentName ?? "",
            String(left.level)
        ].joined(separator: "\u{0}") < [
            right.name,
            right.productType,
            right.parentName ?? "",
            String(right.level)
        ].joined(separator: "\u{0}")
    }

    private static func hasUsableChargeState(
        _ chargeState: DeviceBatteryChargeState
    ) -> Bool {
        chargeState != .unknown && chargeState != .invalid
    }

    func batteryItem(
        referenceDate: Date,
        chargeStateReferenceDate: Date? = nil
    ) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: "mobile-device-\(identifier)",
            deviceIdentity: .mobileDevice(identifier),
            name: name,
            model: productType.isEmpty ? nil : productType,
            kind: category.itemKind,
            level: level,
            chargeState: chargeState,
            parentName: parentName,
            source: "MobileDevice",
            lastUpdated: referenceDate,
            chargeStateLastUpdated: chargeStateReferenceDate,
            isConnected: true,
            detail: connectionType.isEmpty ? nil : connectionType,
            componentIdentity: nil,
            alternateDeviceIdentities: Set(
                bluetoothAddress.map { [.bluetooth($0)] } ?? []
            )
        )
    }
}

private extension DeviceBatteryItem {
    func replacingChargeState(
        _ chargeState: DeviceBatteryChargeState,
        observedAt: Date? = nil
    ) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: id,
            deviceIdentity: deviceIdentity,
            name: name,
            model: model,
            kind: kind,
            level: level,
            chargeState: chargeState,
            parentName: parentName,
            source: source,
            lastUpdated: lastUpdated,
            chargeStateLastUpdated: observedAt,
            isConnected: isConnected,
            detail: detail,
            componentIdentity: componentIdentity,
            alternateDeviceIdentities: alternateDeviceIdentities
        )
    }
}

struct DeviceBatteryMobileDeviceReadResult: Sendable {
    let records: [DeviceBatteryMobileDeviceRecord]
    let didEnumerateDevices: Bool
    let connectedDeviceCount: Int
    let failedDeviceCount: Int

    var hasTransientFailure: Bool {
        !didEnumerateDevices || failedDeviceCount > 0
    }
}

enum DeviceBatteryMobileBatteryParser {
    private static let chargeStateKeys: Set<String> = [
        "BatteryIsFullyCharged",
        "FullyCharged",
        "IsFullyCharged",
        "BatteryIsCharging",
        "IsCharging",
        "ExternalConnected",
        "AppleRawExternalConnected"
    ]

    static func record(
        identifier: String,
        bluetoothAddress: String? = nil,
        name: String,
        productType: String,
        deviceClass: String?,
        connectionType: String,
        parentName: String? = nil,
        battery: [String: Any]
    ) -> DeviceBatteryMobileDeviceRecord? {
        guard let level = batteryLevel(from: battery) else {
            return nil
        }

        return DeviceBatteryMobileDeviceRecord(
            identifier: identifier,
            bluetoothAddress: bluetoothAddress,
            name: name.isEmpty ? fallbackName(deviceClass: deviceClass, productType: productType) : name,
            productType: productType,
            category: DeviceBatteryMobileDeviceCategory.resolve(
                deviceClass: deviceClass,
                productType: productType
            ),
            level: level,
            chargeState: chargeState(from: battery),
            connectionType: connectionType,
            parentName: parentName
        )
    }

    static func mergingBatteryDictionaries(
        primary: [String: Any]?,
        fallback: [String: Any]?
    ) -> [String: Any]? {
        guard primary != nil || fallback != nil else {
            return nil
        }

        var merged = fallback ?? [:]
        let primaryChargeStateIsUnknown = primary.map {
            chargeState(from: $0) == .unknown
        } ?? true
        for (key, value) in primary ?? [:] {
            if primaryChargeStateIsUnknown, chargeStateKeys.contains(key) {
                continue
            }
            merged[key] = value
        }
        return merged
    }

    static func batteryLevel(from battery: [String: Any]) -> Int? {
        if let capacity = intValue(battery["BatteryCurrentCapacity"]), (0...100).contains(capacity) {
            return capacity
        }

        let current = firstPositiveInt(
            battery["AppleRawCurrentCapacity"],
            battery["CurrentCapacity"]
        )
        let maximum = firstPositiveInt(
            battery["AppleRawMaxCapacity"],
            battery["NominalChargeCapacity"],
            battery["MaxCapacity"]
        )
        guard let current, let maximum, maximum > 0 else {
            return nil
        }

        return min(max(Int((Double(current) / Double(maximum) * 100).rounded()), 0), 100)
    }

    static func chargeState(from battery: [String: Any]) -> DeviceBatteryChargeState {
        let isFullyCharged = firstBoolValue(
            battery["BatteryIsFullyCharged"],
            battery["FullyCharged"]
        )
        let isCharging = firstBoolValue(
            battery["BatteryIsCharging"],
            battery["IsCharging"]
        )
        let isExternalPowerConnected = firstBoolValue(
            battery["ExternalConnected"],
            battery["AppleRawExternalConnected"]
        )

        if isFullyCharged == true {
            return .charged
        }
        if isCharging == true {
            return .charging
        }
        if isExternalPowerConnected == true {
            return .plugged
        }
        if isCharging == false || isExternalPowerConnected == false {
            return .normal
        }
        return .unknown
    }

    private static func fallbackName(deviceClass: String?, productType: String) -> String {
        switch DeviceBatteryMobileDeviceCategory.resolve(deviceClass: deviceClass, productType: productType) {
        case .phone:
            return "iPhone"
        case .tablet:
            return "iPad"
        case .mediaPlayer:
            return "iPod touch"
        case .watch:
            return "Apple Watch"
        case .spatialComputer:
            return "Apple Vision Pro"
        case .other:
            return productType.isEmpty ? "Apple 设备" : productType
        }
    }

    private static func firstPositiveInt(_ values: Any?...) -> Int? {
        values.lazy.compactMap(intValue).first { $0 > 0 }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func firstBoolValue(_ values: Any?...) -> Bool? {
        values.lazy.compactMap(boolValue).first
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? String {
            if value.caseInsensitiveCompare("true") == .orderedSame
                || value.caseInsensitiveCompare("yes") == .orderedSame
                || value == "1" {
                return true
            }
            if value.caseInsensitiveCompare("false") == .orderedSame
                || value.caseInsensitiveCompare("no") == .orderedSame
                || value == "0" {
                return false
            }
        }
        return nil
    }
}

private enum DeviceBatteryMobileDeviceBridge {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
    private static let success: Int32 = 0
    private static let serviceTimeoutSeconds: Int = 2
    private static let lock = NSLock()

    private typealias DevicePointer = UnsafeMutableRawPointer
    private typealias CreateDeviceListFunction = @convention(c) () -> Unmanaged<CFArray>?
    private typealias DeviceResultFunction = @convention(c) (DevicePointer) -> Int32
    private typealias CopyDeviceIdentifierFunction = @convention(c) (DevicePointer) -> Unmanaged<CFString>?
    private typealias CopyValueFunction = @convention(c) (DevicePointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias StartServiceFunction = @convention(c) (
        DevicePointer,
        CFString,
        CFDictionary?,
        UnsafeMutablePointer<DevicePointer?>
    ) -> Int32
    private typealias SendMessageFunction = @convention(c) (
        DevicePointer,
        CFTypeRef,
        CFPropertyListFormat
    ) -> Int32
    private typealias ReceiveMessageFunction = @convention(c) (
        DevicePointer,
        UnsafeMutablePointer<Unmanaged<CFTypeRef>?>,
        UnsafeMutablePointer<CFPropertyListFormat>
    ) -> Int32

    private struct Symbols: @unchecked Sendable {
        let createDeviceList: CreateDeviceListFunction
        let connect: DeviceResultFunction
        let disconnect: DeviceResultFunction
        let validatePairing: DeviceResultFunction
        let startSession: DeviceResultFunction
        let stopSession: DeviceResultFunction
        let interfaceType: DeviceResultFunction
        let copyDeviceIdentifier: CopyDeviceIdentifierFunction
        let copyValue: CopyValueFunction
        let startService: StartServiceFunction
        let sendMessage: SendMessageFunction
        let receiveMessage: ReceiveMessageFunction
        let invalidateConnection: DeviceResultFunction
        let connectionSocket: DeviceResultFunction
    }

    private static let symbols: Symbols? = loadSymbols()

    static func readRecords() -> DeviceBatteryMobileDeviceReadResult {
        lock.lock()
        defer { lock.unlock() }

        guard let symbols,
              let unmanagedList = symbols.createDeviceList()
        else {
            return DeviceBatteryMobileDeviceReadResult(
                records: [],
                didEnumerateDevices: false,
                connectedDeviceCount: 0,
                failedDeviceCount: 0
            )
        }

        let list = unmanagedList.takeRetainedValue()
        let connectedDeviceCount = CFArrayGetCount(list)
        var records: [DeviceBatteryMobileDeviceRecord] = []
        var failedDeviceCount = 0
        for index in 0..<connectedDeviceCount {
            guard let value = CFArrayGetValueAtIndex(list, index) else {
                failedDeviceCount += 1
                continue
            }
            let device = UnsafeMutableRawPointer(mutating: value)
            let deviceRecords = readDevice(device, symbols: symbols)
            if deviceRecords.isEmpty {
                failedDeviceCount += 1
            }
            records.append(contentsOf: deviceRecords)
        }
        return DeviceBatteryMobileDeviceReadResult(
            records: records,
            didEnumerateDevices: true,
            connectedDeviceCount: connectedDeviceCount,
            failedDeviceCount: failedDeviceCount
        )
    }

    private static func readDevice(
        _ device: DevicePointer,
        symbols: Symbols
    ) -> [DeviceBatteryMobileDeviceRecord] {
        guard symbols.connect(device) == success else {
            return []
        }
        defer { _ = symbols.disconnect(device) }

        guard symbols.validatePairing(device) == success,
              symbols.startSession(device) == success
        else {
            return []
        }
        defer { _ = symbols.stopSession(device) }

        let identifier = symbols.copyDeviceIdentifier(device)?.takeRetainedValue() as String? ?? ""
        guard !identifier.isEmpty else {
            return []
        }

        let name = copiedString("DeviceName", device: device, symbols: symbols)
        let productType = copiedString("ProductType", device: device, symbols: symbols)
        let deviceClass = copiedString("DeviceClass", device: device, symbols: symbols)
        let bluetoothAddress = normalizedBluetoothAddress(
            copiedString("BluetoothAddress", device: device, symbols: symbols)
        )
        let connectionType = connectionLabel(symbols.interfaceType(device))
        let directBattery = copiedDictionary(
            domain: "com.apple.mobile.battery",
            key: nil,
            device: device,
            symbols: symbols
        )
        let directBatteryHasLevel = directBattery.flatMap {
            DeviceBatteryMobileBatteryParser.batteryLevel(from: $0)
        } != nil
        let directChargeState = directBattery.map {
            DeviceBatteryMobileBatteryParser.chargeState(from: $0)
        } ?? .unknown
        let needsRegistryFallback = !directBatteryHasLevel
            || directChargeState == .unknown
            || directChargeState == .invalid
        let registryBattery = needsRegistryFallback
            ? readIORegistryBattery(device: device, symbols: symbols)
            : nil
        let battery = DeviceBatteryMobileBatteryParser.mergingBatteryDictionaries(
            primary: directBattery,
            fallback: registryBattery
        )

        var records: [DeviceBatteryMobileDeviceRecord] = []
        if let battery,
           let record = DeviceBatteryMobileBatteryParser.record(
               identifier: opaqueIdentifier(identifier),
               bluetoothAddress: bluetoothAddress,
               name: name,
               productType: productType,
               deviceClass: deviceClass,
               connectionType: connectionType,
               battery: battery
           ) {
            records.append(record)
        }

        if DeviceBatteryMobileDeviceCategory.resolve(
            deviceClass: deviceClass,
            productType: productType
        ) == .phone {
            records.append(contentsOf: readPairedWatches(
                device: device,
                parentName: name,
                connectionType: connectionType,
                symbols: symbols
            ))
        }
        return records
    }

    private static func normalizedBluetoothAddress(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func readPairedWatches(
        device: DevicePointer,
        parentName: String,
        connectionType: String,
        symbols: Symbols
    ) -> [DeviceBatteryMobileDeviceRecord] {
        let registryRequest: [String: Any] = ["Command": "GetDeviceRegistry"]
        guard let registry = sendServiceRequest(
            service: "com.apple.companion_proxy",
            request: registryRequest,
            format: .binaryFormat_v1_0,
            device: device,
            symbols: symbols
        ),
        let identifiers = registry["PairedDevicesArray"] as? [String]
        else {
            return []
        }

        return identifiers.compactMap { watchIdentifier in
            var values: [String: Any] = [:]
            for key in ["DeviceName", "ProductType", "BatteryCurrentCapacity", "BatteryIsCharging"] {
                if let value = companionValue(
                    watchIdentifier: watchIdentifier,
                    key: key,
                    device: device,
                    symbols: symbols
                ) {
                    values[key] = value
                }
            }

            return DeviceBatteryMobileBatteryParser.record(
                identifier: "watch-\(opaqueIdentifier(watchIdentifier))",
                name: values["DeviceName"] as? String ?? "Apple Watch",
                productType: values["ProductType"] as? String ?? "Watch",
                deviceClass: "Watch",
                connectionType: connectionType,
                parentName: parentName.isEmpty ? nil : parentName,
                battery: values
            )
        }
    }

    private static func companionValue(
        watchIdentifier: String,
        key: String,
        device: DevicePointer,
        symbols: Symbols
    ) -> Any? {
        let request: [String: Any] = [
            "Command": "GetValueFromRegistry",
            "GetValueGizmoUDIDKey": watchIdentifier,
            "GetValueKeyKey": key
        ]
        guard let response = sendServiceRequest(
            service: "com.apple.companion_proxy",
            request: request,
            format: .binaryFormat_v1_0,
            device: device,
            symbols: symbols
        ),
        let dictionary = response["RetrievedValueDictionary"] as? [String: Any]
        else {
            return nil
        }
        return dictionary[key]
    }

    private static func readIORegistryBattery(
        device: DevicePointer,
        symbols: Symbols
    ) -> [String: Any]? {
        let request: [String: Any] = [
            "Request": "IORegistry",
            "EntryClass": "AppleSmartBattery"
        ]
        guard let response = sendServiceRequest(
            service: "com.apple.mobile.diagnostics_relay",
            request: request,
            format: .xmlFormat_v1_0,
            device: device,
            symbols: symbols
        ),
        response["Status"] as? String == "Success",
        let diagnostics = response["Diagnostics"] as? [String: Any],
        let registry = diagnostics["IORegistry"] as? [String: Any]
        else {
            return nil
        }
        return registry
    }

    private static func sendServiceRequest(
        service: String,
        request: [String: Any],
        format: CFPropertyListFormat,
        device: DevicePointer,
        symbols: Symbols
    ) -> [String: Any]? {
        var connection: DevicePointer?
        guard symbols.startService(device, service as CFString, nil, &connection) == success,
              let connection
        else {
            return nil
        }
        defer { _ = symbols.invalidateConnection(connection) }

        configureTimeout(on: connection, symbols: symbols)
        guard symbols.sendMessage(connection, request as CFDictionary, format) == success else {
            return nil
        }

        var response: Unmanaged<CFTypeRef>?
        var responseFormat = format
        guard symbols.receiveMessage(connection, &response, &responseFormat) == success else {
            return nil
        }
        return response?.takeRetainedValue() as? [String: Any]
    }

    private static func configureTimeout(on connection: DevicePointer, symbols: Symbols) {
        let socket = symbols.connectionSocket(connection)
        guard socket >= 0 else {
            return
        }
        var timeout = timeval(tv_sec: serviceTimeoutSeconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func copiedString(
        _ key: String,
        device: DevicePointer,
        symbols: Symbols
    ) -> String {
        symbols.copyValue(device, nil, key as CFString)?.takeRetainedValue() as? String ?? ""
    }

    private static func copiedDictionary(
        domain: String?,
        key: String?,
        device: DevicePointer,
        symbols: Symbols
    ) -> [String: Any]? {
        symbols.copyValue(device, domain as CFString?, key as CFString?)?
            .takeRetainedValue() as? [String: Any]
    }

    private static func connectionLabel(_ type: Int32) -> String {
        switch type {
        case 1:
            return "USB"
        case 2, 3:
            return "Wi-Fi"
        default:
            return ""
        }
    }

    private static func opaqueIdentifier(_ identifier: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func loadSymbols() -> Symbols? {
        guard let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let createDeviceList = symbol("AMDCreateDeviceList", as: CreateDeviceListFunction.self),
              let connect = symbol("AMDeviceConnect", as: DeviceResultFunction.self),
              let disconnect = symbol("AMDeviceDisconnect", as: DeviceResultFunction.self),
              let validatePairing = symbol("AMDeviceValidatePairing", as: DeviceResultFunction.self),
              let startSession = symbol("AMDeviceStartSession", as: DeviceResultFunction.self),
              let stopSession = symbol("AMDeviceStopSession", as: DeviceResultFunction.self),
              let interfaceType = symbol("AMDeviceGetInterfaceType", as: DeviceResultFunction.self),
              let copyDeviceIdentifier = symbol(
                  "AMDeviceCopyDeviceIdentifier",
                  as: CopyDeviceIdentifierFunction.self
              ),
              let copyValue = symbol("AMDeviceCopyValue", as: CopyValueFunction.self),
              let startService = symbol("AMDeviceSecureStartService", as: StartServiceFunction.self),
              let sendMessage = symbol("AMDServiceConnectionSendMessage", as: SendMessageFunction.self),
              let receiveMessage = symbol("AMDServiceConnectionReceiveMessage", as: ReceiveMessageFunction.self),
              let invalidateConnection = symbol(
                  "AMDServiceConnectionInvalidate",
                  as: DeviceResultFunction.self
              ),
              let connectionSocket = symbol(
                  "AMDServiceConnectionGetSocket",
                  as: DeviceResultFunction.self
              )
        else {
            dlclose(handle)
            return nil
        }

        return Symbols(
            createDeviceList: createDeviceList,
            connect: connect,
            disconnect: disconnect,
            validatePairing: validatePairing,
            startSession: startSession,
            stopSession: stopSession,
            interfaceType: interfaceType,
            copyDeviceIdentifier: copyDeviceIdentifier,
            copyValue: copyValue,
            startService: startService,
            sendMessage: sendMessage,
            receiveMessage: receiveMessage,
            invalidateConnection: invalidateConnection,
            connectionSocket: connectionSocket
        )
    }
}
