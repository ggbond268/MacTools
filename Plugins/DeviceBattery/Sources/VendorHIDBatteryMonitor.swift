import Foundation
@preconcurrency import IOKit.hid
import MacToolsPluginKit

enum VendorHIDVendor: Equatable, Sendable {
    case rapoo
    case mchose

    var source: String {
        switch self {
        case .rapoo: return "Rapoo HID"
        case .mchose: return "MCHOSE HID"
        }
    }

    func fallbackDeviceName(localization: PluginLocalization) -> String {
        switch self {
        case .rapoo:
            return localization.string("rapoo.deviceName.fallback", defaultValue: "Rapoo 鼠标")
        case .mchose:
            return localization.string("mchose.deviceName.fallback", defaultValue: "迈从鼠标")
        }
    }
}

enum VendorHIDBatteryAccessState: Equatable, Sendable {
    case idle
    case scanning
    case waitingForReport
    case connected
    case noDevice
    case permissionDenied
    case failed(String)

    var isError: Bool {
        switch self {
        case .permissionDenied, .failed:
            return true
        case .idle, .scanning, .waitingForReport, .connected, .noDevice:
            return false
        }
    }
}

enum VendorHIDBatteryChargeState: Equatable, Sendable {
    case unknown
    case invalid
    case normal
    case charging
}

struct VendorHIDBatteryReading: Equatable, Sendable {
    let level: Int?
    let chargeState: VendorHIDBatteryChargeState
    let statusCode: UInt8
}

struct VendorHIDMouseDeviceInfo: Equatable, Sendable {
    let vendor: VendorHIDVendor
    let productID: Int
    let modelName: String
    let displayName: String
    let serialNumber: String?
    let locationID: Int?
    let registryEntryID: UInt64?

    var stableKey: String {
        let serial = serialNumber?.isEmpty == false ? serialNumber! : "no-serial"
        let location = locationID.map(String.init) ?? "no-location"
        if serial != "no-serial" || location != "no-location" {
            return "\(productID)-\(serial)-\(location)"
        }
        let registryEntry = registryEntryID.map(String.init) ?? "no-registry-entry"
        return "\(productID)-\(serial)-\(location)-\(registryEntry)"
    }
}

struct VendorHIDMouseBatterySnapshot: Equatable, Sendable {
    var accessState: VendorHIDBatteryAccessState
    var device: VendorHIDMouseDeviceInfo?
    var reading: VendorHIDBatteryReading?
    var lastUpdated: Date?

    static let idle = VendorHIDMouseBatterySnapshot(
        accessState: .idle,
        device: nil,
        reading: nil,
        lastUpdated: nil
    )

    func batteryItem(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> DeviceBatteryItem? {
        guard let device else {
            return nil
        }

        return DeviceBatteryItem(
            id: "vendorHID-\(device.vendor)-\(device.stableKey)",
            deviceIdentity: .vendorHID(device.vendor, device.stableKey),
            name: device.modelName,
            model: device.displayName == device.modelName ? nil : device.displayName,
            kind: .vendorHIDMouse,
            level: reading?.level,
            chargeState: deviceChargeState,
            parentName: nil,
            source: device.vendor.source,
            lastUpdated: lastUpdated,
            isConnected: true,
            detail: itemDetail(localization: localization),
            componentIdentity: nil
        )
    }

    var deviceChargeState: DeviceBatteryChargeState {
        switch reading?.chargeState ?? .unknown {
        case .unknown:
            return .unknown
        case .invalid:
            return .invalid
        case .normal:
            return .normal
        case .charging:
            return .charging
        }
    }

    func itemDetail(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch accessState {
        case .idle:
            return localization.string("vendorHID.detail.idle", defaultValue: "等待检测")
        case .scanning:
            return localization.string("vendorHID.detail.scanning", defaultValue: "检测中")
        case .waitingForReport:
            return localization.string("vendorHID.detail.waitingForReport", defaultValue: "等待电量上报")
        case .connected:
            return deviceChargeState.title(localization: localization)
        case .noDevice:
            return localization.string("vendorHID.detail.noDevice", defaultValue: "未检测到")
        case .permissionDenied:
            return localization.string("vendorHID.detail.permissionDenied", defaultValue: "需要输入监控权限")
        case let .failed(message):
            return message
        }
    }
}

@MainActor
protocol VendorHIDBatteryMonitoring: AnyObject {
    var snapshot: VendorHIDMouseBatterySnapshot { get }
    var deviceSnapshots: [VendorHIDMouseBatterySnapshot] { get }
    var onSnapshotChange: ((VendorHIDMouseBatterySnapshot) -> Void)? { get set }

    func start()
    func stop()
    func refresh()
}

extension VendorHIDBatteryMonitoring {
    var deviceSnapshots: [VendorHIDMouseBatterySnapshot] {
        snapshot.device == nil ? [] : [snapshot]
    }
}

@MainActor
final class VendorHIDBatteryMonitor: VendorHIDBatteryMonitoring {
    private static let permissionDeniedReturnCode: UInt32 = 0xE00002E2

    private var manager: IOHIDManager?
    private var sessions: [String: VendorHIDDeviceSession] = [:]
    private var snapshotsByDeviceKey: [String: VendorHIDMouseBatterySnapshot] = [:]
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    private(set) var snapshot = VendorHIDMouseBatterySnapshot.idle {
        didSet {
            guard oldValue != snapshot else {
                return
            }
            onSnapshotChange?(snapshot)
        }
    }

    var onSnapshotChange: ((VendorHIDMouseBatterySnapshot) -> Void)?

    var deviceSnapshots: [VendorHIDMouseBatterySnapshot] {
        snapshotsByDeviceKey
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    func start() {
        guard manager == nil else {
            refresh()
            return
        }

        snapshotsByDeviceKey.removeAll()
        snapshot = VendorHIDMouseBatterySnapshot(
            accessState: .scanning,
            device: nil,
            reading: nil,
            lastUpdated: nil
        )

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, matchingDictionaries as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, vendorHIDDeviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, vendorHIDDeviceRemovedCallback, context)
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            snapshot = failureSnapshot(for: openResult)
            return
        }

        manager = hidManager
        refresh()
    }

    func stop() {
        guard let manager else {
            sessions.removeAll()
            snapshotsByDeviceKey.removeAll()
            return
        }

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        sessions.removeAll()
        snapshotsByDeviceKey.removeAll()
    }

    func refresh() {
        guard let manager else {
            start()
            return
        }

        syncDevices(from: manager)
        if sessions.isEmpty {
            snapshotsByDeviceKey.removeAll()
            snapshot = VendorHIDMouseBatterySnapshot(
                accessState: .noDevice,
                device: nil,
                reading: nil,
                lastUpdated: nil
            )
            return
        }

        let currentDeviceKey = snapshot.device?.stableKey
        if currentDeviceKey == nil
            || currentDeviceKey.map({ sessions[$0] == nil }) == true
            || snapshot.accessState == .scanning
            || snapshot.accessState == .noDevice {
            let firstDevice = sessions.values.sorted { $0.deviceInfo.stableKey < $1.deviceInfo.stableKey }.first?.deviceInfo
            let waitingSnapshot = VendorHIDMouseBatterySnapshot(
                accessState: .waitingForReport,
                device: firstDevice,
                reading: nil,
                lastUpdated: nil
            )
            if let firstDevice {
                snapshot = snapshotsByDeviceKey[firstDevice.stableKey] ?? waitingSnapshot
            } else {
                snapshot = waitingSnapshot
            }
        }

        // Query-based vendors (MCHOSE) only report on request, so a refresh
        // re-asks every connected device for its current battery state.
        for session in sessions.values where session.catalog.vendor == .mchose {
            session.sendBatteryQuery()
        }
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        guard let deviceInfo = makeDeviceInfo(from: device),
              sessions[deviceInfo.stableKey] == nil
        else {
            return
        }

        let session = VendorHIDDeviceSession(device: device, deviceInfo: deviceInfo, monitor: self)
        sessions[deviceInfo.stableKey] = session

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            session.reportBuffer,
            session.catalog.reportLength,
            vendorHIDInputReportCallback,
            Unmanaged.passUnretained(session).toOpaque()
        )

        let waitingSnapshot = VendorHIDMouseBatterySnapshot(
            accessState: .waitingForReport,
            device: deviceInfo,
            reading: nil,
            lastUpdated: nil
        )
        snapshotsByDeviceKey[deviceInfo.stableKey] = waitingSnapshot
        snapshot = waitingSnapshot

        // MCHOSE mice only answer active queries; Rapoo mice push reports.
        if session.catalog.vendor == .mchose {
            session.sendBatteryQuery()
        }
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let deviceInfo = makeDeviceInfo(from: device) else {
            return
        }

        let previousSnapshot = snapshot
        sessions.removeValue(forKey: deviceInfo.stableKey)
        snapshotsByDeviceKey.removeValue(forKey: deviceInfo.stableKey)
        refresh()
        if snapshot == previousSnapshot {
            onSnapshotChange?(snapshot)
        }
    }

    fileprivate func handleInputReport(
        session: VendorHIDDeviceSession,
        result: IOReturn,
        reportID: Int,
        bytes: [UInt8]
    ) {
        guard result == kIOReturnSuccess else {
            return
        }

        let reading: VendorHIDBatteryReading?
        switch session.catalog.vendor {
        case .rapoo:
            reading = VendorHIDRapooParser.parseInputReport(reportID: reportID, bytes: bytes)
        case .mchose:
            reading = VendorHIDMCHOSEParser.parseInputReport(reportID: reportID, bytes: bytes)
        }
        guard let reading else {
            return
        }

        let updatedSnapshot = VendorHIDMouseBatterySnapshot(
            accessState: .connected,
            device: session.deviceInfo,
            reading: reading,
            lastUpdated: Date()
        )
        snapshotsByDeviceKey[session.deviceInfo.stableKey] = updatedSnapshot
        snapshot = updatedSnapshot
    }

    private var matchingDictionaries: [[String: Int]] {
        VendorHIDDeviceCatalog.all.map { catalog in
            [
                kIOHIDVendorIDKey as String: catalog.vendorID,
                kIOHIDPrimaryUsagePageKey as String: catalog.vendorUsagePage,
                kIOHIDPrimaryUsageKey as String: catalog.vendorUsage
            ]
        }
    }

    private func syncDevices(from manager: IOHIDManager) {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return
        }

        for device in deviceSet {
            handleDeviceMatched(device)
        }
    }

    private func makeDeviceInfo(from device: IOHIDDevice) -> VendorHIDMouseDeviceInfo? {
        guard let productID = intProperty(kIOHIDProductIDKey, from: device),
              let catalog = VendorHIDDeviceCatalog.catalog(for: device),
              catalog.isSupportedMouseProductID(productID)
        else {
            return nil
        }

        let modelName = catalog.modelName(forProductID: productID)
            ?? catalog.vendor.fallbackDeviceName(localization: localization)
        let productName = stringProperty(kIOHIDProductKey, from: device)
        let displayName = productName?.isEmpty == false ? productName! : modelName

        return VendorHIDMouseDeviceInfo(
            vendor: catalog.vendor,
            productID: productID,
            modelName: modelName,
            displayName: displayName,
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: device),
            locationID: intProperty(kIOHIDLocationIDKey, from: device),
            registryEntryID: registryEntryID(for: device)
        )
    }

    private func registryEntryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else {
            return nil
        }
        return identifier
    }

    private func intProperty(_ key: String, from device: IOHIDDevice) -> Int? {
        if let number = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func failureSnapshot(for result: IOReturn) -> VendorHIDMouseBatterySnapshot {
        snapshotsByDeviceKey.removeAll()
        let accessState: VendorHIDBatteryAccessState
        if UInt32(bitPattern: result) == Self.permissionDeniedReturnCode {
            accessState = .permissionDenied
        } else {
            let code = String(UInt32(bitPattern: result), radix: 16, uppercase: false)
            accessState = .failed(
                localization.format("vendorHID.error.openFailed", defaultValue: "HID 打开失败：0x%@", code)
            )
        }

        return VendorHIDMouseBatterySnapshot(
            accessState: accessState,
            device: nil,
            reading: nil,
            lastUpdated: nil
        )
    }
}

private final class VendorHIDDeviceSession {
    let device: IOHIDDevice
    let deviceInfo: VendorHIDMouseDeviceInfo
    let catalog: VendorHIDDeviceCatalog
    let reportBuffer: UnsafeMutablePointer<UInt8>

    weak var monitor: VendorHIDBatteryMonitor?

    init(device: IOHIDDevice, deviceInfo: VendorHIDMouseDeviceInfo, monitor: VendorHIDBatteryMonitor) {
        self.device = device
        self.deviceInfo = deviceInfo
        self.monitor = monitor
        // The monitor only matches devices a catalog claims, so this force-unwrap is safe.
        self.catalog = VendorHIDDeviceCatalog.catalog(for: device)!
        reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: catalog.reportLength)
        reportBuffer.initialize(repeating: 0, count: catalog.reportLength)
    }

    deinit {
        reportBuffer.deinitialize(count: catalog.reportLength)
        reportBuffer.deallocate()
    }

    /// Send the vendor's battery query command. Only used by vendors that need
    /// an explicit request (e.g. MCHOSE); push-based vendors such as Rapoo do not.
    /// The device is already opened through the HID manager, so no per-query
    /// open/close cycle is performed — closing the manager-opened device would
    /// tear down the registered input-report callback.
    /// On macOS, `IOHIDDeviceSetReport` expects the report ID both as its own
    /// argument and as the first byte of the buffer (this mirrors hidapi, which
    /// only strips the leading ID for unnumbered reports with ID 0).
    func sendBatteryQuery() {
        guard let query = catalog.batteryQuery,
              query.first.map(Int.init) == catalog.batteryQueryReportID,
              query.count > 1
        else {
            return
        }

        var report = [UInt8](repeating: 0, count: catalog.reportLength)
        report.replaceSubrange(0..<min(query.count, report.count), with: query.prefix(report.count))

        _ = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            CFIndex(catalog.batteryQueryReportID),
            report,
            report.count
        )
    }
}

extension VendorHIDDeviceSession: @unchecked Sendable {}

// MARK: - Rapoo

enum VendorHIDRapooParser {
    private static let supportedReportIDs: Set<Int> = [0, RapooDeviceCatalogValues.inputReportID]
    private static let candidateOffsets: [(status: Int, level: Int)] = [
        (status: 6, level: 7),
        (status: 7, level: 8)
    ]

    static func parseInputReport(reportID: Int, bytes: [UInt8]) -> VendorHIDBatteryReading? {
        guard supportedReportIDs.contains(reportID) else {
            return nil
        }

        var invalidReading: VendorHIDBatteryReading?
        for candidate in candidateOffsets {
            guard bytes.indices.contains(candidate.status),
                  bytes.indices.contains(candidate.level)
            else {
                continue
            }

            let status = bytes[candidate.status]
            let level = bytes[candidate.level]

            guard let chargeState = chargeState(forStatus: status),
                  level <= 100
            else {
                continue
            }

            if chargeState == .invalid {
                invalidReading = VendorHIDBatteryReading(level: nil, chargeState: .invalid, statusCode: status)
                continue
            }

            return VendorHIDBatteryReading(level: Int(level), chargeState: chargeState, statusCode: status)
        }

        return invalidReading
    }

    private static func chargeState(forStatus status: UInt8) -> VendorHIDBatteryChargeState? {
        switch status {
        case 0:
            return .invalid
        case 1:
            return .normal
        case 2:
            return .charging
        default:
            return nil
        }
    }
}

// MARK: - MCHOSE

enum VendorHIDMCHOSEParser {
    /// MCHOSE "modern" 0x4d protocol, as recovered by the MCHOSE-local-hub project
    /// and verified against a real A7 V3 Ultra+.
    ///
    /// Input report frame (64 bytes):
    /// ```
    /// [0]    0x4d report ID
    /// [1]    0x01 fixed
    /// [2]    0x01 frame counter / fixed
    /// [3]    payload length
    /// [4..5] little-endian command ID (the verified A7 V3 Ultra+ echoes the request 0x0900)
    /// [6..7] 0x00
    /// [8..]  payload
    /// ```
    ///
    /// Battery readBasics response (cmd `0x0900`):
    /// payload = `vid:u16le, pid:u16le, fw:u32le, ?:u8, ?:u8, mode:u8, charge:u8, level:u8`
    /// i.e. `level = payload[12]`, `charge = payload[11]`.
    /// Verified on a real A7 V3 Ultra+ linked over 2.4G through its MagDock: the dock
    /// relays the query to the wireless mouse, and the response reports the mouse's own
    /// PID (0x4026) rather than the dock's USB PID.
    static func parseInputReport(reportID: Int, bytes: [UInt8]) -> VendorHIDBatteryReading? {
        guard reportID == MCHOSEDeviceCatalogValues.inputReportID,
              bytes.count >= 21,
              bytes[0] == MCHOSEDeviceCatalogValues.inputReportID,
              bytes[1] == 0x01
        else {
            return nil
        }

        // Response command is at bytes 4...5 (LE). The verified A7 V3 Ultra+ echoes
        // the 0x0900 request; community captures of other models show 0x0010.
        let responseCommand = Int(bytes[4]) | (Int(bytes[5]) << 8)
        guard MCHOSEDeviceCatalogValues.batteryResponseCommands.contains(responseCommand) else {
            return nil
        }

        // Payload starts at byte 8: vid(2) pid(2) fw(4) b8 b9 mode(10) charge(11) level(12)
        let level = bytes[8 + 12]
        guard level <= 100 else {
            return nil
        }

        let chargeByte = bytes[8 + 11]
        let chargeState: VendorHIDBatteryChargeState = chargeByte != 0 ? .charging : .normal
        return VendorHIDBatteryReading(level: Int(level), chargeState: chargeState, statusCode: chargeByte)
    }
}

// MARK: - Catalogs

struct VendorHIDDeviceCatalog {
    let vendor: VendorHIDVendor
    let vendorID: Int
    let vendorUsagePage: Int
    let vendorUsage: Int
    let inputReportID: Int
    let reportLength: Int
    /// Command to send as an output report to ask for a battery report, if any.
    let batteryQuery: [UInt8]?
    let batteryQueryReportID: Int
    private let productIDToModel: [Int: String]
    private let aliasToModel: [Int: String]

    init(
        vendor: VendorHIDVendor,
        vendorID: Int,
        vendorUsagePage: Int,
        vendorUsage: Int,
        inputReportID: Int,
        reportLength: Int,
        batteryQuery: [UInt8]?,
        batteryQueryReportID: Int,
        productIDToModel: [Int: String],
        aliasToModel: [Int: String] = [:]
    ) {
        self.vendor = vendor
        self.vendorID = vendorID
        self.vendorUsagePage = vendorUsagePage
        self.vendorUsage = vendorUsage
        self.inputReportID = inputReportID
        self.reportLength = reportLength
        self.batteryQuery = batteryQuery
        self.batteryQueryReportID = batteryQueryReportID
        self.productIDToModel = productIDToModel
        self.aliasToModel = aliasToModel
    }

    func modelName(forProductID productID: Int) -> String? {
        productIDToModel[productID] ?? aliasToModel[productID]
    }

    func isSupportedMouseProductID(_ productID: Int) -> Bool {
        modelName(forProductID: productID) != nil
    }

    static let rapoo = VendorHIDDeviceCatalog(
        vendor: .rapoo,
        vendorID: RapooDeviceCatalogValues.vendorID,
        vendorUsagePage: RapooDeviceCatalogValues.vendorUsagePage,
        vendorUsage: RapooDeviceCatalogValues.vendorUsage,
        inputReportID: RapooDeviceCatalogValues.inputReportID,
        reportLength: RapooDeviceCatalogValues.reportLength,
        batteryQuery: nil,
        batteryQueryReportID: 0,
        productIDToModel: RapooDeviceCatalogValues.receiverProductIDToModel,
        aliasToModel: RapooDeviceCatalogValues.webProductIDToModel
    )

    static let mchose = VendorHIDDeviceCatalog(
        vendor: .mchose,
        vendorID: MCHOSEDeviceCatalogValues.vendorID,
        vendorUsagePage: MCHOSEDeviceCatalogValues.vendorUsagePage,
        vendorUsage: MCHOSEDeviceCatalogValues.vendorUsage,
        inputReportID: MCHOSEDeviceCatalogValues.inputReportID,
        reportLength: MCHOSEDeviceCatalogValues.reportLength,
        batteryQuery: MCHOSEDeviceCatalogValues.batteryQuery,
        batteryQueryReportID: MCHOSEDeviceCatalogValues.batteryQueryReportID,
        productIDToModel: MCHOSEDeviceCatalogValues.productIDToModel
    )

    static let all: [VendorHIDDeviceCatalog] = [.rapoo, .mchose]

    static func catalog(for device: IOHIDDevice) -> VendorHIDDeviceCatalog? {
        guard let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue,
              let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue,
              let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue
        else {
            return nil
        }

        return all.first {
            $0.vendorID == vendorID && $0.vendorUsagePage == usagePage && $0.vendorUsage == usage
        }
    }
}

enum RapooDeviceCatalogValues {
    static let vendorID = 0x24AE
    static let vendorUsagePage = 0xFF00
    static let vendorUsage = 0x0001
    static let inputReportID = 7
    static let featureReportID = 8
    static let reportLength = 512

    static let receiverProductIDToModel: [Int: String] = [
        5136: "VT0",
        5137: "VT3S",
        5138: "VT3",
        5139: "VT7",
        5140: "VT9",
        5141: "VT1",
        5142: "VT7MAX",
        5143: "VT3MAX",
        5144: "VT9MAX",
        5145: "VT7Air",
        5146: "VT3Air",
        5147: "VT9Air",
        5148: "VT7Air MAX",
        5149: "VT3Air MAX",
        5150: "VT9Air MAX",
        5152: "VT0 MAX",
        5153: "VT3S MAX",
        5154: "VT2",
        5155: "VT2 MAX",
        5188: "VT1 MAX",
        5191: "ESM612MAX",
        5194: "ESM612PRO",
        5195: "VT1 Air MAX",
        5201: "VT7S",
        5202: "VT2S",
        5203: "VT4",
        5209: "VT7S V2",
        5211: "VT4 V2",
        5213: "VT2S V2",
        5216: "VT7 V2",
        5218: "VT3 V2",
        5220: "VT3S V2",
        5222: "VT9 V2",
        5224: "VT2 V2",
        5229: "VT3 MAX MASTER V2",
        5230: "VT3S MAX MASTER V2",
        5232: "VT7 MAX MASTER V2",
        5233: "VT7S MAX MASTER V2",
        5281: "VT0Air MAX",
        5282: "VT3SAir MAX",
        5284: "VT2K MAX"
    ]

    static let receiverToWebProductID: [Int: Int] = [
        5136: 17936,
        5137: 17937,
        5138: 17938,
        5139: 17939,
        5140: 17940,
        5141: 17941,
        5142: 17942,
        5143: 17943,
        5144: 17944,
        5145: 17945,
        5146: 17946,
        5147: 17947,
        5148: 17948,
        5149: 17949,
        5150: 17950,
        5152: 17952,
        5153: 17953,
        5154: 17954,
        5155: 17955,
        5188: 17988,
        5191: 17991,
        5194: 17994,
        5195: 17995,
        5201: 18001,
        5202: 18002,
        5203: 18003,
        5209: 18009,
        5211: 18011,
        5213: 18013,
        5216: 18016,
        5218: 18018,
        5220: 18020,
        5222: 18022,
        5224: 18024,
        5229: 18029,
        5230: 18030,
        5232: 18032,
        5233: 18033,
        5281: 18081,
        5282: 18082,
        5284: 18084
    ]

    static let webProductIDToModel: [Int: String] = {
        var map: [Int: String] = [:]
        for (receiver, web) in receiverToWebProductID {
            if let model = receiverProductIDToModel[receiver] {
                map[web] = model
            }
        }
        return map
    }()
}

enum MCHOSEDeviceCatalogValues {
    static let vendorID = 0x3837
    static let vendorUsagePage = 0xFF0B
    static let vendorUsage = 0x00C4
    static let inputReportID = 0x4D
    static let reportLength = 64

    /// Battery readBasics query in the "modern" 0x4d protocol.
    /// `4d 01 01 00 00 09 00 00 08` = report id, fixed, counter, len=0, cmd=0x0900 LE, reserved, checksum
    /// (checksum = XOR of bytes 2...7).
    static let batteryQuery: [UInt8] = [0x4D, 0x01, 0x01, 0x00, 0x00, 0x09, 0x00, 0x00, 0x08]
    static let batteryQueryReportID = 0x4D
    /// Response command IDs accepted for a 0x0900 readBasics query. The A7 V3 Ultra+
    /// echoes the request command (0x0900) at bytes 4...5; community captures of other
    /// models describe a 0x0010 reply, so both are accepted.
    static let batteryResponseCommands: Set<Int> = [0x0900, 0x0010]

    /// Only models with a verified VID/PID on a vendor-defined usage page are listed.
    /// Verified: A7 V3 Ultra+ wired = 0x1018 (usage page 0xFF0B).
    /// Community-documented (mchose-battery project): G3 V2 wired = 0x418C,
    /// G3 V2 Pro wired = 0x4042, A7e wired = 0x4012, A7e Pro wired = 0x4013.
    static let productIDToModel: [Int: String] = [
        0x1018: "A7 V3 Ultra+",
        0x418C: "G3 V2",
        0x4042: "G3 V2 Pro",
        0x4012: "A7e",
        0x4013: "A7e Pro"
    ]
}

// MARK: - IOHID callbacks

private func vendorHIDDeviceMatchedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else {
        return
    }

    let monitor = Unmanaged<VendorHIDBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.handleDeviceMatched(device)
    }
}

private func vendorHIDDeviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else {
        return
    }

    let monitor = Unmanaged<VendorHIDBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.handleDeviceRemoved(device)
    }
}

private func vendorHIDInputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, reportLength > 0 else {
        return
    }

    let session = Unmanaged<VendorHIDDeviceSession>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    DispatchQueue.main.async {
        session.monitor?.handleInputReport(
            session: session,
            result: result,
            reportID: Int(reportID),
            bytes: bytes
        )
    }
}
