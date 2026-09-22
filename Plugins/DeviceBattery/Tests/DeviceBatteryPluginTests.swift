import XCTest
import MacToolsPluginKit
@testable import DeviceBatteryPlugin

@MainActor
final class DeviceBatteryPluginTests: XCTestCase {

    func testStorePersistsLayoutAndSources() {
        let storage = DeviceBatteryMemoryStorage()
        let store = DeviceBatteryStore(storage: storage)

        store.setLayoutMode(.list)
        store.setShowBluetoothDevices(false)
        store.setShowAppleMobileDevices(false)
        store.setShowVendorHIDDevices(false)

        let reloaded = DeviceBatteryStore(storage: storage)
        XCTAssertEqual(reloaded.layoutMode, .list)
        XCTAssertTrue(reloaded.showInternalBattery)
        XCTAssertFalse(reloaded.showBluetoothDevices)
        XCTAssertFalse(reloaded.showAppleMobileDevices)
        XCTAssertFalse(reloaded.showVendorHIDDevices)
    }

    func testBluetoothPowerLogParserReadsConnectedMouseBattery() {
        let line = """
        2026-06-02 14:05:52.648 Df bluetoothd[616:f85de1] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'MX Anywhere 3S', SID 49354549, AcCa Mouse, AcID 0532E370-EA18-11C7-44F9-6D7E86E35891, PID 0xB037 (?), VID 0x046D (?), VIDSrc USB, Type 'Accessory Source', TPT Bluetooth LE, CF 0x1 < Attributes >, IF 0x2 < IOKit >, Present yes, MaxC 100%, Battery -80%
        """

        let reading = DeviceBatteryBluetoothPowerLogParser.reading(from: line)

        XCTAssertEqual(reading?.name, "MX Anywhere 3S")
        XCTAssertEqual(reading?.vendorID, "0x046D")
        XCTAssertEqual(reading?.productID, "0xB037")
        XCTAssertEqual(reading?.deviceType, "Mouse")
        XCTAssertEqual(reading?.level, 80)
        XCTAssertEqual(reading?.chargeState, .normal)
        XCTAssertNotNil(reading?.observedAt)
    }

    func testBluetoothPowerLogParserReadsAirPodsComponents() {
        let line = """
        2026-06-02 16:43:44.978 Df bluetoothd[616:ff000b] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'Custom AirPods 4', SID 70391692, AcCa Headphone, PID 0x201B (Device1,8219), VID 0x004C (Apple), Battery 68% (Unknown), Components (Y): Left +100%, CF 0x1 < Attributes >, Right +100%, CF 0x1 < Attributes >, Case +83%, CF 0x1 < Attributes >
        """

        let readings = DeviceBatteryBluetoothPowerLogParser.readings(fromLine: line)

        XCTAssertEqual(readings.first { $0.component == nil }?.level, 68)
        XCTAssertEqual(readings.first { $0.component == .left }?.chargeState, .charging)
        XCTAssertEqual(readings.first { $0.component == .chargingCase }?.level, 83)
        XCTAssertNotNil(readings.first?.observedAt)
    }

    func testAppleHeadphoneAdvertisementParserReadsObservedBatteryFields() throws {
        var bytes = makeAppleProximityPairingPacket()
        bytes[5] = 0x0E
        bytes[6] = 0x20
        bytes[7] = 0x20
        bytes[8] = 0xA5
        bytes[9] = 0x5A
        bytes[14] = 0x01
        bytes[15] = 0x82
        bytes[16] = 0x63

        let advertisement = try XCTUnwrap(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(from: Data(bytes))
        )

        XCTAssertEqual(advertisement.productID, 0x200E)
        XCTAssertEqual(advertisement.readings.map(\.component), [.chargingCase, .left, .right])
        XCTAssertEqual(
            advertisement.readings.first { $0.component == .chargingCase },
            DeviceBatteryAppleHeadphoneAdvertisementReading(
                component: .chargingCase,
                level: 100,
                chargeState: .charging
            )
        )
        XCTAssertEqual(
            advertisement.readings.first { $0.component == .left },
            DeviceBatteryAppleHeadphoneAdvertisementReading(
                component: .left,
                level: 50,
                chargeState: .charging
            )
        )
        XCTAssertEqual(
            advertisement.readings.first { $0.component == .right },
            DeviceBatteryAppleHeadphoneAdvertisementReading(
                component: .right,
                level: 100,
                chargeState: .normal
            )
        )
    }

    func testAppleHeadphoneAdvertisementParserRejectsUnsupportedPackets() {
        var unsupportedMessage = [UInt8](repeating: 0, count: 25)
        unsupportedMessage[0] = 0x4C
        unsupportedMessage[1] = 0x00
        unsupportedMessage[2] = 0x12
        XCTAssertNil(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(
                from: Data(unsupportedMessage)
            )
        )

        var wrongVendor = makeAppleProximityPairingPacket()
        wrongVendor[0] = 0x4D
        XCTAssertNil(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(from: Data(wrongVendor))
        )

        var wrongLength = makeAppleProximityPairingPacket()
        wrongLength[3] = 0x18
        XCTAssertNil(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(from: Data(wrongLength))
        )

        var wrongPrefix = makeAppleProximityPairingPacket()
        wrongPrefix[4] = 0x00
        XCTAssertNil(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(from: Data(wrongPrefix))
        )

        XCTAssertNil(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(
                from: Data([0x4C, 0x00, 0x07])
            )
        )
    }

    func testBluetoothProfileKeepsSplitAirPodsComponents() {
        let output = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Test AirPods": {
                    "device_address": "11-22-33-44-55-66",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones",
                    "device_batteryLevelMain": "68%",
                    "device_batteryLevelLeft": "100%",
                    "device_batteryLevelRight": "100%",
                    "device_batteryLevelCase": "83%"
                  }
                }
              ]
            }
          ]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            items.compactMap { $0.componentIdentity?.role },
            [.chargingCase, .left, .right]
        )
        XCTAssertEqual(items.compactMap(\.level), [83, 100, 100])
    }

    func testDetailedAirPodsComponentsReplaceAggregateAndCombinedEarbuds() {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Test AirPods 4": {
                    "device_address": "11-22-33-44-55-66",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones",
                    "device_batteryLevelMain": "68%",
                    "device_batteryLevelLeft": "72%",
                    "device_batteryLevelRight": "75%",
                    "device_batteryLevelCase": "83%"
                  }
                }
              ]
            }
          ]
        }
        """
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1138:239c] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = EARBUDS-ID; matchIdentifier = SHARED-GROUP-ID; name = Test AirPods 4; groupName =Test AirPods 4; percentCharge = 72; connected = YES; charging = NO; internal = NO; transportType = Bluetooth; accessoryIdentifier = EARBUDS-ACCESSORY-ID; accessoryCategory = Headphone; modelNumber = (null); >)
        2026-08-19 17:15:16.581 Df NotificationCenter[1138:239c] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x2; vendor = Apple; productIdentifier = 8219; parts = case; identifier = CASE-ID; matchIdentifier = SHARED-GROUP-ID; name = Test AirPods 4 Case; groupName =Test AirPods 4 Case; percentCharge = 83; connected = YES; charging = NO; internal = NO; transportType = Bluetooth; accessoryIdentifier = CASE-ACCESSORY-ID; accessoryCategory = Headphone; modelNumber = (null); >)
        """
        let referenceDate = Date(timeIntervalSince1970: 1)
        let profileItems = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            referenceDate: referenceDate
        )
        let batteryCenterItems = DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: referenceDate
        )

        XCTAssertEqual(
            Set(batteryCenterItems.compactMap { $0.componentIdentity?.role }),
            Set([.earbuds, .chargingCase])
        )

        let items = DeviceBatterySampler.deduplicated(profileItems + batteryCenterItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(
            Set(items.compactMap { $0.componentIdentity?.role }),
            Set([.left, .right, .chargingCase])
        )
        XCTAssertEqual(Set(items.compactMap(\.level)), Set([72, 75, 83]))
    }

    func testPhysicalIdentityMergesRenamedSourceRecords() throws {
        let physicalIdentity = DeviceBatteryDeviceIdentity.bluetooth("AA:BB:CC:DD:EE:FF")
        let genericName = makeBatteryItem(
            id: "iobluetooth-max",
            name: "AirPods Max",
            level: 31,
            kind: .airPodsPart,
            deviceIdentity: physicalIdentity,
            source: "IOBluetooth"
        )
        let customName = makeBatteryItem(
            id: "batterycenter-max",
            name: "My AirPods Max",
            level: 31,
            kind: .airPodsPart,
            deviceIdentity: physicalIdentity,
            source: "BatteryCenter"
        )

        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated([genericName, customName]).first)
        XCTAssertEqual(item.name, "My AirPods Max")
        XCTAssertEqual(item.source, "BatteryCenter")
        XCTAssertEqual(DeviceBatterySampler.deduplicated([genericName, customName]).count, 1)
    }

    func testPhysicalIdentityKeepsSameNameDevicesSeparate() {
        let first = makeBatteryItem(
            id: "first",
            name: "Shared Headphones",
            level: 40,
            deviceIdentity: .bluetooth("11:11:11:11:11:11")
        )
        let second = makeBatteryItem(
            id: "second",
            name: "Shared Headphones",
            level: 60,
            deviceIdentity: .bluetooth("22:22:22:22:22:22")
        )

        XCTAssertEqual(DeviceBatterySampler.deduplicated([first, second]).count, 2)
    }

    func testRapooParserReadsProtocolOneBatteryReport() {
        let report = [UInt8](repeating: 0, count: 16).setting(1, at: 6).setting(83, at: 7)

        XCTAssertEqual(
            VendorHIDRapooParser.parseInputReport(reportID: 7, bytes: report),
            VendorHIDBatteryReading(level: 83, chargeState: .normal, statusCode: 1)
        )
    }

    func testMCHOSEParserReadsBatteryReadBasicsResponse() {
        // Frame captured from a real A7 V3 Ultra+ linked over 2.4G through a MagDock,
        // answering a 0x0900 readBasics query while the web driver showed 100%:
        // `4d 01 01 10 00 09 00 00 | 37 38 26 40 04 00 00 00 | 00 10 | 02 | 00 | 64 | 00 08 e4 ef`
        // (header | vid=0x3837 pid=0x4026 fw=4 | ? ? | mode=2 | charge=0 | level=100 | trailer).
        var report = [UInt8](repeating: 0, count: 32)
        let captured: [UInt8] = [
            0x4D, 0x01, 0x01, 0x10, 0x00, 0x09, 0x00, 0x00,
            0x37, 0x38, 0x26, 0x40, 0x04, 0x00, 0x00, 0x00,
            0x00, 0x10, 0x02, 0x00, 0x64, 0x00, 0x08, 0xE4, 0xEF, 0x00, 0x00
        ]
        report.replaceSubrange(0..<captured.count, with: captured)

        XCTAssertEqual(
            VendorHIDMCHOSEParser.parseInputReport(reportID: 0x4D, bytes: report),
            VendorHIDBatteryReading(level: 100, chargeState: .normal, statusCode: 0)
        )
    }

    func testMCHOSEParserRejectsUnexpectedFrames() {
        var report = [UInt8](repeating: 0, count: 32)
        report[0] = 0x4D
        report[1] = 0x01
        report[4] = 0x01 // wrong response command
        report[5] = 0x02
        report[8 + 12] = 88

        XCTAssertNil(VendorHIDMCHOSEParser.parseInputReport(reportID: 0x4D, bytes: report))
        XCTAssertNil(VendorHIDMCHOSEParser.parseInputReport(reportID: 0x07, bytes: report)) // wrong report ID
    }

    func testMobileBatteryParserReadsChargingIPhone() throws {
        let record = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "phone-id",
            name: "测试 iPhone",
            productType: "iPhone18,1",
            deviceClass: "iPhone",
            connectionType: "Wi-Fi",
            battery: [
                "BatteryCurrentCapacity": 67,
                "BatteryIsCharging": true,
                "ExternalConnected": true
            ]
        ))

        XCTAssertEqual(record.category, .phone)
        XCTAssertEqual(record.level, 67)
        XCTAssertEqual(record.chargeState, .charging)
        XCTAssertEqual(record.batteryItem(referenceDate: Date()).kind, .phone)
    }

    func testMobileBatteryParserNormalizesIORegistryCapacity() throws {
        let record = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "vision-id",
            name: "Vision Pro",
            productType: "RealityDevice15,1",
            deviceClass: "RealityDevice",
            connectionType: "Wi-Fi",
            battery: [
                "AppleRawCurrentCapacity": 3_200,
                "AppleRawMaxCapacity": 4_000,
                "IsCharging": false
            ]
        ))

        XCTAssertEqual(record.category, .spatialComputer)
        XCTAssertEqual(record.level, 80)
        XCTAssertEqual(record.chargeState, .normal)
    }

    func testMobileDeviceRecordsPreferUSBAndKeepDistinctDevices() {
        let wifiRecord = DeviceBatteryMobileDeviceRecord(
            identifier: "first-phone",
            name: "Shared iPhone",
            productType: "iPhone18,1",
            category: .phone,
            level: 65,
            chargeState: .charging,
            connectionType: "Wi-Fi",
            parentName: nil
        )
        let usbRecord = DeviceBatteryMobileDeviceRecord(
            identifier: "first-phone",
            name: "Shared iPhone",
            productType: "iPhone18,1",
            category: .phone,
            level: 66,
            chargeState: .unknown,
            connectionType: "USB",
            parentName: nil
        )
        let otherPhone = DeviceBatteryMobileDeviceRecord(
            identifier: "second-phone",
            name: "Shared iPhone",
            productType: "iPhone18,1",
            category: .phone,
            level: 51,
            chargeState: .normal,
            connectionType: "Wi-Fi",
            parentName: nil
        )

        let records = DeviceBatteryMobileDeviceRecord.preferredRecords(
            in: [wifiRecord, otherPhone, usbRecord]
        )

        XCTAssertEqual(records.count, 2)
        let preferredPhone = records.first { $0.identifier == "first-phone" }
        XCTAssertEqual(preferredPhone?.connectionType, "USB")
        XCTAssertEqual(preferredPhone?.level, 66)
        XCTAssertEqual(preferredPhone?.chargeState, .charging)
        XCTAssertTrue(records.contains(otherPhone))
    }

    func testLowBatteryNotificationMergesMultipleDevices() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let snapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 12),
            makeBatteryItem(id: "keyboard", name: "Keyboard", level: 18),
            makeBatteryItem(id: "trackpad", name: "Trackpad", level: 38)
        ])

        controller.evaluate(
            snapshot: snapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertEqual(
            notifier.notifications[0].deviceIDs,
            ["source:test:mouse|aggregate", "source:test:keyboard|aggregate"]
        )
        XCTAssertEqual(notifier.notifications[0].title, "2 台设备电量偏低")
        XCTAssertTrue(notifier.notifications[0].body.contains("Mouse 12%"))
        XCTAssertTrue(notifier.notifications[0].body.contains("Keyboard 18%"))
        XCTAssertFalse(notifier.notifications[0].body.contains("Trackpad"))
    }

    func testLowBatteryNotificationDoesNotRepeatUntilDeviceRecovers() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let lowSnapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 12)
        ])

        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        XCTAssertEqual(notifier.notifications.count, 1)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(id: "mouse", name: "Mouse", level: 35)
            ]),
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 2)
    }

    func testLowBatteryNotificationIgnoresChargingDevicesAndBoundaryValue() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(id: "mouse", name: "Mouse", level: 20),
                makeBatteryItem(id: "keyboard", name: "Keyboard", level: 12, chargeState: .charging),
                makeBatteryItem(id: "trackpad", name: "Trackpad", level: 12, isConnected: false)
            ]),
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    private func makeAppleProximityPairingPacket() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0] = 0x4C
        bytes[1] = 0x00
        bytes[2] = 0x07
        bytes[3] = 0x19
        bytes[4] = 0x01
        bytes[5] = 0x0E
        bytes[6] = 0x20
        bytes[8] = 0xFF
        bytes[9] = 0x0F
        return bytes
    }

    private func makeSnapshot(items: [DeviceBatteryItem]) -> DeviceBatterySnapshot {
        DeviceBatterySnapshot(
            accessState: .ready,
            items: items,
            lastUpdated: Date(),
            vendorHIDState: .idle
        )
    }

    private func makeBatteryItem(
        id: String,
        name: String,
        level: Int,
        model: String? = nil,
        kind: DeviceBatteryKind = .bluetooth,
        chargeState: DeviceBatteryChargeState = .normal,
        isConnected: Bool = true,
        parentName: String? = nil,
        deviceIdentity: DeviceBatteryDeviceIdentity? = nil,
        source: String = "test",
        componentIdentity: DeviceBatteryComponentIdentity? = nil
    ) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: id,
            deviceIdentity: deviceIdentity
                ?? componentIdentity.map { .bluetooth($0.groupID) }
                ?? .source("test:\(id)"),
            name: name,
            model: model,
            kind: kind,
            level: level,
            chargeState: chargeState,
            parentName: parentName,
            source: source,
            lastUpdated: Date(),
            isConnected: isConnected,
            detail: nil,
            componentIdentity: componentIdentity
        )
    }

}

private extension DeviceBatteryMobileDeviceReadResult {
    static func success(
        _ record: DeviceBatteryMobileDeviceRecord
    ) -> DeviceBatteryMobileDeviceReadResult {
        DeviceBatteryMobileDeviceReadResult(
            records: [record],
            didEnumerateDevices: true,
            connectedDeviceCount: 1,
            failedDeviceCount: 0
        )
    }
}

@MainActor
private final class DeviceBatteryMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class RecordingLowBatteryNotifier: DeviceBatteryLowBatteryNotifying {
    private(set) var notifications: [DeviceBatteryLowBatteryNotification] = []

    func notifyLowBatteryDevices(
        _ items: [DeviceBatteryItem],
        threshold: Int,
        localization: PluginLocalization
    ) {
        notifications.append(
            DeviceBatteryLowBatteryNotificationContent.make(
                items: items,
                threshold: threshold,
                localization: localization
            )
        )
    }
}

private extension Array where Element == UInt8 {
    func setting(_ value: UInt8, at index: Int) -> [UInt8] {
        var copy = self
        copy[index] = value
        return copy
    }
}
