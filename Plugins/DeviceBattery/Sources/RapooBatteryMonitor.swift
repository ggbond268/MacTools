import Foundation
@preconcurrency import IOKit.hid

enum RapooBatteryAccessState: Equatable, Sendable {
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

enum RapooBatteryChargeState: Equatable, Sendable {
    case unknown
    case invalid
    case normal
    case charging
}

struct RapooBatteryReading: Equatable, Sendable {
    let level: Int?
    let chargeState: RapooBatteryChargeState
    let statusCode: UInt8
}

struct RapooMouseDeviceInfo: Equatable, Sendable {
    let productID: Int
    let modelName: String
    let displayName: String
    let serialNumber: String?
    let locationID: Int?

    var stableKey: String {
        let serial = serialNumber?.isEmpty == false ? serialNumber! : "no-serial"
        let location = locationID.map(String.init) ?? "no-location"
        return "\(productID)-\(serial)-\(location)"
    }
}

struct RapooMouseBatterySnapshot: Equatable, Sendable {
    var accessState: RapooBatteryAccessState
    var device: RapooMouseDeviceInfo?
    var reading: RapooBatteryReading?
    var lastUpdated: Date?

    static let idle = RapooMouseBatterySnapshot(
        accessState: .idle,
        device: nil,
        reading: nil,
        lastUpdated: nil
    )

    var batteryItem: DeviceBatteryItem? {
        guard let device else {
            return nil
        }

        return DeviceBatteryItem(
            id: "rapoo-\(device.stableKey)",
            name: device.modelName,
            model: device.displayName == device.modelName ? nil : device.displayName,
            kind: .rapooMouse,
            level: reading?.level,
            chargeState: deviceChargeState,
            parentName: nil,
            source: "Rapoo HID",
            lastUpdated: lastUpdated,
            isConnected: true,
            detail: itemDetail
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

    var itemDetail: String {
        switch accessState {
        case .idle:
            return "等待检测"
        case .scanning:
            return "检测中"
        case .waitingForReport:
            return "等待电量上报"
        case .connected:
            return deviceChargeState.title
        case .noDevice:
            return "未检测到"
        case .permissionDenied:
            return "需要输入监控权限"
        case let .failed(message):
            return message
        }
    }
}

@MainActor
protocol RapooBatteryMonitoring: AnyObject {
    var snapshot: RapooMouseBatterySnapshot { get }
    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)? { get set }

    func start()
    func stop()
    func refresh()
}

@MainActor
final class RapooHIDBatteryMonitor: RapooBatteryMonitoring {
    private static let permissionDeniedReturnCode: UInt32 = 0xE00002E2

    private var manager: IOHIDManager?
    private var sessions: [String: RapooHIDDeviceSession] = [:]

    private(set) var snapshot = RapooMouseBatterySnapshot.idle {
        didSet {
            guard oldValue != snapshot else {
                return
            }
            onSnapshotChange?(snapshot)
        }
    }

    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)?

    func start() {
        guard manager == nil else {
            refresh()
            return
        }

        snapshot = RapooMouseBatterySnapshot(
            accessState: .scanning,
            device: nil,
            reading: nil,
            lastUpdated: nil
        )

        let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(hidManager, matchingDictionary as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, rapooHIDDeviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hidManager, rapooHIDDeviceRemovedCallback, context)
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
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        for session in activeSessions {
            teardownSession(session)
        }

        guard let manager else {
            return
        }

        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    func refresh() {
        guard let manager else {
            start()
            return
        }

        syncDevices(from: manager)
        if sessions.isEmpty {
            snapshot = RapooMouseBatterySnapshot(
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
            snapshot = RapooMouseBatterySnapshot(
                accessState: .waitingForReport,
                device: firstDevice,
                reading: nil,
                lastUpdated: nil
            )
        }
    }

    fileprivate func handleDeviceMatched(_ device: IOHIDDevice) {
        guard let deviceInfo = makeDeviceInfo(from: device),
              sessions[deviceInfo.stableKey] == nil
        else {
            return
        }

        let session = RapooHIDDeviceSession(device: device, deviceInfo: deviceInfo, monitor: self)
        sessions[deviceInfo.stableKey] = session

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            session.reportBuffer,
            RapooDeviceCatalog.reportLength,
            rapooHIDInputReportCallback,
            Unmanaged.passUnretained(session).toOpaque()
        )

        snapshot = RapooMouseBatterySnapshot(
            accessState: .waitingForReport,
            device: deviceInfo,
            reading: nil,
            lastUpdated: nil
        )
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard let deviceInfo = makeDeviceInfo(from: device) else {
            return
        }

        if let session = sessions.removeValue(forKey: deviceInfo.stableKey) {
            teardownSession(session)
        }
        refresh()
    }

    // Clear the input-report callback and unschedule the device BEFORE its session
    // (and reportBuffer) can be freed; otherwise a late HID report writes into freed
    // memory and the callback dereferences a freed context (use-after-free).
    private func teardownSession(_ session: RapooHIDDeviceSession) {
        IOHIDDeviceRegisterInputReportCallback(
            session.device,
            session.reportBuffer,
            RapooDeviceCatalog.reportLength,
            nil,
            nil
        )
        IOHIDDeviceUnscheduleFromRunLoop(
            session.device,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    fileprivate func handleInputReport(
        session: RapooHIDDeviceSession,
        result: IOReturn,
        reportID: Int,
        bytes: [UInt8]
    ) {
        guard result == kIOReturnSuccess,
              let reading = RapooBatteryParser.parseInputReport(reportID: reportID, bytes: bytes)
        else {
            return
        }

        snapshot = RapooMouseBatterySnapshot(
            accessState: .connected,
            device: session.deviceInfo,
            reading: reading,
            lastUpdated: Date()
        )
    }

    private var matchingDictionary: [String: Int] {
        [
            kIOHIDVendorIDKey as String: RapooDeviceCatalog.vendorID,
            kIOHIDPrimaryUsagePageKey as String: RapooDeviceCatalog.vendorUsagePage,
            kIOHIDPrimaryUsageKey as String: RapooDeviceCatalog.vendorUsage
        ]
    }

    private func syncDevices(from manager: IOHIDManager) {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return
        }

        for device in deviceSet {
            handleDeviceMatched(device)
        }
    }

    private func makeDeviceInfo(from device: IOHIDDevice) -> RapooMouseDeviceInfo? {
        guard let productID = intProperty(kIOHIDProductIDKey, from: device),
              RapooDeviceCatalog.isSupportedMouseProductID(productID)
        else {
            return nil
        }

        let modelName = RapooDeviceCatalog.modelName(forProductID: productID) ?? "Rapoo 鼠标"
        let productName = stringProperty(kIOHIDProductKey, from: device)
        let displayName = productName?.isEmpty == false ? productName! : modelName

        return RapooMouseDeviceInfo(
            productID: productID,
            modelName: modelName,
            displayName: displayName,
            serialNumber: stringProperty(kIOHIDSerialNumberKey, from: device),
            locationID: intProperty(kIOHIDLocationIDKey, from: device)
        )
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

    private func failureSnapshot(for result: IOReturn) -> RapooMouseBatterySnapshot {
        let accessState: RapooBatteryAccessState
        if UInt32(bitPattern: result) == Self.permissionDeniedReturnCode {
            accessState = .permissionDenied
        } else {
            let code = String(UInt32(bitPattern: result), radix: 16, uppercase: false)
            accessState = .failed("HID 打开失败：0x\(code)")
        }

        return RapooMouseBatterySnapshot(
            accessState: accessState,
            device: nil,
            reading: nil,
            lastUpdated: nil
        )
    }
}

private final class RapooHIDDeviceSession {
    let device: IOHIDDevice
    let deviceInfo: RapooMouseDeviceInfo
    let reportBuffer: UnsafeMutablePointer<UInt8>

    weak var monitor: RapooHIDBatteryMonitor?

    init(device: IOHIDDevice, deviceInfo: RapooMouseDeviceInfo, monitor: RapooHIDBatteryMonitor) {
        self.device = device
        self.deviceInfo = deviceInfo
        self.monitor = monitor
        reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: RapooDeviceCatalog.reportLength)
        reportBuffer.initialize(repeating: 0, count: RapooDeviceCatalog.reportLength)
    }

    deinit {
        // Safety net for teardown paths that bypass the monitor's explicit
        // teardownSession (e.g. the monitor deallocating without stop()): clear the
        // input-report callback and unschedule before the buffer/context is freed,
        // so a late HID report can never dereference this freed session.
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, RapooDeviceCatalog.reportLength, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        reportBuffer.deinitialize(count: RapooDeviceCatalog.reportLength)
        reportBuffer.deallocate()
    }
}

extension RapooHIDDeviceSession: @unchecked Sendable {}

enum RapooBatteryParser {
    private static let supportedReportIDs: Set<Int> = [0, RapooDeviceCatalog.inputReportID]
    private static let candidateOffsets: [(status: Int, level: Int)] = [
        (status: 6, level: 7),
        (status: 7, level: 8)
    ]

    static func parseInputReport(reportID: Int, bytes: [UInt8]) -> RapooBatteryReading? {
        guard supportedReportIDs.contains(reportID) else {
            return nil
        }

        var invalidReading: RapooBatteryReading?
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
                invalidReading = RapooBatteryReading(level: nil, chargeState: .invalid, statusCode: status)
                continue
            }

            return RapooBatteryReading(level: Int(level), chargeState: chargeState, statusCode: status)
        }

        return invalidReading
    }

    private static func chargeState(forStatus status: UInt8) -> RapooBatteryChargeState? {
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

enum RapooDeviceCatalog {
    static let vendorID = 0x24AE
    static let vendorUsagePage = 0xFF00
    static let vendorUsage = 0x0001
    static let inputReportID = 7
    static let featureReportID = 8
    static let reportLength = 512

    private static let receiverProductIDToModel: [Int: String] = [
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

    private static let receiverToWebProductID: [Int: Int] = [
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

    static func modelName(forProductID productID: Int) -> String? {
        if let model = receiverProductIDToModel[productID] {
            return model
        }

        if let receiverProductID = receiverToWebProductID.first(where: { $0.value == productID })?.key {
            return receiverProductIDToModel[receiverProductID]
        }

        return nil
    }

    static func isSupportedMouseProductID(_ productID: Int) -> Bool {
        modelName(forProductID: productID) != nil
    }
}

private func rapooHIDDeviceMatchedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else {
        return
    }

    let monitor = Unmanaged<RapooHIDBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handleDeviceMatched(device)
    }
}

private func rapooHIDDeviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else {
        return
    }

    let monitor = Unmanaged<RapooHIDBatteryMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handleDeviceRemoved(device)
    }
}

private func rapooHIDInputReportCallback(
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

    let session = Unmanaged<RapooHIDDeviceSession>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    MainActor.assumeIsolated {
        session.monitor?.handleInputReport(
            session: session,
            result: result,
            reportID: Int(reportID),
            bytes: bytes
        )
    }
}

