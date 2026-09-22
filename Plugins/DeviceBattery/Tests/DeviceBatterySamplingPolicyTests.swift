import XCTest
@testable import DeviceBatteryPlugin

final class DeviceBatterySamplingPolicyTests: XCTestCase {

    func testTimedOutLogAttemptIsThrottledWithoutAdvancingCursor() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DeviceBatteryIncrementalLogState()
        state.recordAttempt(at: referenceDate, completion: .completed)
        let completedCursor = state.cursorDate

        let timeoutDate = referenceDate.addingTimeInterval(5 * 60)
        state.recordAttempt(at: timeoutDate, completion: .timedOut)

        XCTAssertEqual(state.cursorDate, completedCursor)
        XCTAssertEqual(state.lastAttemptDate, timeoutDate)
        XCTAssertFalse(state.shouldRefresh(
            at: timeoutDate.addingTimeInterval(4 * 60),
            interval: 5 * 60
        ))
        XCTAssertTrue(state.shouldRefresh(
            at: timeoutDate.addingTimeInterval(5 * 60),
            interval: 5 * 60
        ))
    }

    func testDiscoveryScanUsesTheNarrowestRequiredMode() {
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: [],
            gattTargetIDs: ["mouse", "keyboard"],
            registeredGATTTargetIDs: ["mouse", "keyboard"]
        ), .none)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: [],
            gattTargetIDs: ["mouse", "keyboard"],
            registeredGATTTargetIDs: ["mouse"]
        ), .batteryService)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: ["airpods"],
            gattTargetIDs: ["mouse"],
            registeredGATTTargetIDs: ["mouse"]
        ), .allAdvertisements)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: [],
            gattTargetIDs: ["jbl", "mouse"],
            registeredGATTTargetIDs: ["mouse"],
            jblTargetIDs: ["jbl"]
        ), .allAdvertisements)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: [],
            gattTargetIDs: ["jbl", "mouse"],
            registeredGATTTargetIDs: ["jbl"],
            jblTargetIDs: ["jbl"]
        ), .batteryService)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.discoveryMode(
            advertisementTargetIDs: [],
            gattTargetIDs: ["jbl"],
            registeredGATTTargetIDs: ["jbl"],
            jblTargetIDs: ["jbl"]
        ), .none)
    }

    func testGattMatchingRequiresAnUnambiguousNameOrJBLLESuffix() {
        func target(_ id: String, name: String) -> BluetoothBatteryTarget {
            BluetoothBatteryTarget(
                id: id, name: name, address: nil, vendorID: nil, productID: nil,
                model: nil, kind: .bluetooth, detail: nil, isConnected: true
            )
        }
        let mouse = target("mouse", name: "Mouse")
        let jbl = target("jbl", name: "JBL Sense Lite")
        let targets = [mouse, jbl]
        let eligibleIDs = Set(targets.map(\.id))

        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.gattTarget(
            named: " mouse ", targets: targets, eligibleTargetIDs: eligibleIDs
        )?.id, mouse.id)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.gattTarget(
            named: "jbl sense lite-LE", targets: targets, eligibleTargetIDs: eligibleIDs
        )?.id, jbl.id)
        for name in ["JBL Sense Lite 2", "JBL Sense", "Mouse-LE", "Unknown"] {
            XCTAssertNil(DeviceBatteryBluetoothScanPolicy.gattTarget(
                named: name, targets: targets, eligibleTargetIDs: eligibleIDs
            ))
        }
        let duplicate = target("second-jbl", name: jbl.name)
        for name in [jbl.name, "JBL Sense Lite-LE"] {
            XCTAssertNil(DeviceBatteryBluetoothScanPolicy.gattTarget(
                named: name, targets: targets + [duplicate],
                eligibleTargetIDs: eligibleIDs.union([duplicate.id])
            ))
        }
    }

    func testSupplementalCacheRetainsMissingReadingUntilExpiry() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = DeviceBatterySupplementalItemCache(itemLifetime: 60)
        let item = makeItem(lastUpdated: referenceDate, groupID: "headphones")

        cache.update(
            with: [item],
            knownTargetIdentities: [.bluetooth("headphones")],
            connectedTargetIdentities: [.bluetooth("headphones")],
            referenceDate: referenceDate
        )
        cache.update(
            with: [],
            knownTargetIdentities: [.bluetooth("headphones")],
            connectedTargetIdentities: [.bluetooth("headphones")],
            referenceDate: referenceDate.addingTimeInterval(30)
        )

        XCTAssertEqual(try XCTUnwrap(cache.items.first).lastUpdated, referenceDate)

        cache.update(
            with: [],
            knownTargetIdentities: [.bluetooth("headphones")],
            connectedTargetIdentities: [.bluetooth("headphones")],
            referenceDate: referenceDate.addingTimeInterval(61)
        )
        XCTAssertTrue(cache.items.isEmpty)
    }

    func testThreeSourceReductionIsIndependentOfInputOrder() throws {
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        let powerLog = makeSupplementalItem(
            id: "power-log",
            identity: identity,
            role: .left,
            level: 70,
            referenceDate: Date(timeIntervalSince1970: 5),
            source: "BluetoothPowerLog",
            chargeState: .charging
        )
        let batteryCenter = makeSupplementalItem(
            id: "battery-center",
            identity: identity,
            role: .left,
            level: 80,
            referenceDate: Date(timeIntervalSince1970: 10)
        )
        let advertisement = makeSupplementalItem(
            id: "advertisement",
            identity: identity,
            role: .left,
            level: 50,
            referenceDate: Date(timeIntervalSince1970: 20),
            source: "AppleHeadphoneAdvertisement"
        )
        let permutations = [
            [powerLog, batteryCenter, advertisement],
            [powerLog, advertisement, batteryCenter],
            [batteryCenter, powerLog, advertisement],
            [batteryCenter, advertisement, powerLog],
            [advertisement, powerLog, batteryCenter],
            [advertisement, batteryCenter, powerLog]
        ]

        for readings in permutations {
            let directItem = try XCTUnwrap(DeviceBatterySampler.deduplicated(readings).first)
            XCTAssertEqual(directItem.id, "battery-center")
            XCTAssertEqual(directItem.level, 80)
            XCTAssertEqual(directItem.chargeState, .normal)
            XCTAssertEqual(directItem.lastUpdated, Date(timeIntervalSince1970: 10))

            var cache = DeviceBatterySupplementalItemCache(itemLifetime: 60)
            cache.update(
                with: readings,
                knownTargetIdentities: [identity],
                connectedTargetIdentities: [identity],
                referenceDate: Date(timeIntervalSince1970: 20)
            )
            let cachedItem = try XCTUnwrap(cache.items.first)
            XCTAssertEqual(cachedItem.id, "battery-center")
            XCTAssertEqual(cachedItem.level, 80)
            XCTAssertEqual(cachedItem.chargeState, .normal)
            XCTAssertEqual(cachedItem.lastUpdated, Date(timeIntervalSince1970: 10))
        }
    }

    func testSupplementalCacheDropsDisconnectedTarget() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeItem(lastUpdated: referenceDate, groupID: "headphones")],
            knownTargetIdentities: [.bluetooth("headphones")],
            connectedTargetIdentities: [.bluetooth("headphones")],
            referenceDate: referenceDate
        )

        cache.update(
            with: [],
            knownTargetIdentities: [.bluetooth("headphones")],
            connectedTargetIdentities: [],
            referenceDate: referenceDate
        )

        XCTAssertTrue(cache.items.isEmpty)
    }

    func testSupplementalCacheKeepsTargetsSeparateWhenAliasIsAmbiguous() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sharedAlias = DeviceBatteryDeviceIdentity.batteryCenter("SHARED-GROUP")
        let firstIdentity = DeviceBatteryDeviceIdentity.bluetooth("FIRST-ADDRESS")
        let secondIdentity = DeviceBatteryDeviceIdentity.bluetooth("SECOND-ADDRESS")
        let first = makeSupplementalItem(
            id: "first-target",
            identity: firstIdentity,
            role: .aggregate,
            level: 50,
            referenceDate: referenceDate,
            alternateIdentities: [sharedAlias]
        )
        let second = makeSupplementalItem(
            id: "second-target",
            identity: secondIdentity,
            role: .aggregate,
            level: 60,
            referenceDate: referenceDate,
            alternateIdentities: [sharedAlias]
        )

        for batch in [[first, second], [second, first]] {
            for connectedIdentities: Set<DeviceBatteryDeviceIdentity> in [
                [firstIdentity, secondIdentity],
                [firstIdentity]
            ] {
                var cache = DeviceBatterySupplementalItemCache()
                cache.update(
                    with: batch,
                    knownTargetIdentities: [firstIdentity, secondIdentity],
                    connectedTargetIdentities: connectedIdentities,
                    referenceDate: referenceDate
                )

                XCTAssertEqual(cache.items.count, connectedIdentities.count)
                XCTAssertEqual(
                    Set(cache.items.map(\.deviceIdentity)),
                    connectedIdentities
                )
                XCTAssertTrue(cache.items.allSatisfy {
                    !$0.alternateDeviceIdentities.contains(sharedAlias)
                })
            }
        }
    }

    private func makeItem(lastUpdated: Date, groupID: String) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: "cached-headphones",
            deviceIdentity: .bluetooth(groupID),
            name: "Headphones",
            model: nil,
            kind: .airPodsPart,
            level: 50,
            chargeState: .normal,
            parentName: nil,
            source: "test",
            lastUpdated: lastUpdated,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: groupID,
                role: .aggregate
            )
        )
    }

    private func makeSupplementalItem(
        id: String,
        identity: DeviceBatteryDeviceIdentity,
        role: DeviceBatteryComponentRole,
        level: Int,
        referenceDate: Date,
        alternateIdentities: Set<DeviceBatteryDeviceIdentity> = [],
        source: String = "BatteryCenter",
        chargeState: DeviceBatteryChargeState = .normal
    ) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: id,
            deviceIdentity: identity,
            name: "Test AirPods",
            model: "AirPods 4",
            kind: .airPodsPart,
            level: level,
            chargeState: chargeState,
            parentName: nil,
            source: source,
            lastUpdated: referenceDate,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: role
            ),
            alternateDeviceIdentities: alternateIdentities
        )
    }

    // MARK: - JBL ExcelPoint Regression Tests

    func testJBLSensorParserParsesValidPacket() {
        // Real notification packet from JBL Sense Lite
        let bytes: [UInt8] = [
            0x00, 0xDD, 0x03, 0x00, 0x01, 0x00, // header
            0x2F, 0x00, 0x00, 0x00,               // length
            0x0C, 0x00, 0x03, 0x00, 0x1A, 0x04, 0x0A, 0x00,
            0x10, 0x01, 0x00, 0x80, 0x12, 0x00, 0x02, 0x00,
            0x08, 0x87,
            0x0D, 0x00, 0x01, 0x00, 0x64, // left: 100%
            0x0E, 0x00, 0x01, 0x00, 0x64, // right: 100%
            0x03, 0x1F, 0x01, 0x00, 0x34, // case: 52%
            0x34, 0x00, 0x01, 0x00, 0xFF,
            0x01, 0x1F, 0x03, 0x00, 0x19, 0x0A, 0x0A
        ]
        let data = Data(bytes)

        let reading = JBLSenseLiteBLEBatteryParser.parseBatteryNotification(data)

        XCTAssertNotNil(reading)
        XCTAssertEqual(reading?.leftBattery, 100)
        XCTAssertEqual(reading?.rightBattery, 100)
        XCTAssertEqual(reading?.caseBattery, 52)
    }

    func testJBLSensorParserRejectsInvalidHeader() {
        var bytes: [UInt8] = Array(repeating: 0, count: 20)
        bytes[0] = 0xFF // wrong header
        let data = Data(bytes)

        let reading = JBLSenseLiteBLEBatteryParser.parseBatteryNotification(data)

        XCTAssertNil(reading)
    }

}
