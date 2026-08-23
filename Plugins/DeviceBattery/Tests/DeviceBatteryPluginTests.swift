import XCTest
import MacToolsPluginKit
@testable import DeviceBatteryPlugin

@MainActor
final class DeviceBatteryPluginTests: XCTestCase {
    func testPluginDescriptorUsesExpandedFullWidthSpan() {
        let plugin = DeviceBatteryPlugin(
            context: makeContext(),
            viewModel: DeviceBatteryViewModel(
                sampler: StubDeviceBatterySampler(items: []),
                rapooMonitor: StubRapooBatteryMonitor()
            ),
            inputMonitoringAuthorizationStatus: { .unknown }
        )

        XCTAssertEqual(plugin.metadata.id, "device-battery")
        XCTAssertEqual(plugin.metadata.title, "设备电量")
        XCTAssertEqual(plugin.descriptor.span, PluginComponentSpan(width: 4, height: 15)!)
    }

    func testLayoutSpanGrowsToFitEveryVisibleDevice() {
        XCTAssertEqual(DeviceBatteryComponentLayout.spanHeight(mode: .list, visibleItemCount: 1), 14)
        XCTAssertEqual(DeviceBatteryComponentLayout.spanHeight(mode: .list, visibleItemCount: 9), 31)
        XCTAssertEqual(DeviceBatteryComponentLayout.spanHeight(mode: .list, visibleItemCount: 13), 41)
        XCTAssertEqual(DeviceBatteryComponentLayout.spanHeight(mode: .grid, visibleItemCount: 13), 59)
    }

    func testStorePersistsLayoutAndSources() {
        let storage = DeviceBatteryMemoryStorage()
        let store = DeviceBatteryStore(storage: storage)

        store.setLayoutMode(.list)
        store.setShowBluetoothDevices(false)
        store.setShowAppleMobileDevices(false)
        store.setShowRapooDevices(false)

        let reloaded = DeviceBatteryStore(storage: storage)
        XCTAssertEqual(reloaded.layoutMode, .list)
        XCTAssertTrue(reloaded.showInternalBattery)
        XCTAssertFalse(reloaded.showBluetoothDevices)
        XCTAssertFalse(reloaded.showAppleMobileDevices)
        XCTAssertFalse(reloaded.showRapooDevices)
    }

    func testStorePersistsLowBatteryNotificationSettings() {
        let storage = DeviceBatteryMemoryStorage()
        let store = DeviceBatteryStore(storage: storage)

        XCTAssertFalse(store.lowBatteryNotificationEnabled)
        XCTAssertEqual(store.lowBatteryNotificationThreshold, 20)

        store.setLowBatteryNotificationEnabled(true)
        store.setLowBatteryNotificationThreshold(15)

        let reloaded = DeviceBatteryStore(storage: storage)
        XCTAssertTrue(reloaded.lowBatteryNotificationEnabled)
        XCTAssertEqual(reloaded.lowBatteryNotificationThreshold, 15)
    }

    func testAppleMobileRefreshIntervalTracksComponentVisibility() {
        let viewModel = DeviceBatteryViewModel(
            sampler: StubDeviceBatterySampler(items: []),
            rapooMonitor: StubRapooBatteryMonitor()
        )
        let plugin = DeviceBatteryPlugin(
            context: makeContext(),
            viewModel: viewModel,
            inputMonitoringAuthorizationStatus: { .unknown }
        )

        XCTAssertEqual(viewModel.appleMobileRefreshInterval, 5 * 60)
        XCTAssertEqual(viewModel.bluetoothRefreshInterval, 5 * 60)

        plugin.panelSurfaceDidBecomeVisible(.primary)
        XCTAssertEqual(viewModel.appleMobileRefreshInterval, 5 * 60)

        plugin.panelSurfaceDidBecomeVisible(.component)
        XCTAssertEqual(viewModel.appleMobileRefreshInterval, 90)
        XCTAssertEqual(viewModel.bluetoothRefreshInterval, 60)

        viewModel.stop()
        XCTAssertEqual(viewModel.appleMobileRefreshInterval, 5 * 60)

        plugin.panelSurfaceDidBecomeVisible(.component)
        XCTAssertEqual(viewModel.appleMobileRefreshInterval, 90)

        plugin.panelSurfaceDidBecomeHidden(.component)
        XCTAssertEqual(viewModel.appleMobileRefreshInterval, 5 * 60)
    }

    func testStoreClampsLowBatteryNotificationThreshold() {
        let store = DeviceBatteryStore(storage: DeviceBatteryMemoryStorage())

        store.setLowBatteryNotificationThreshold(0)
        XCTAssertEqual(store.lowBatteryNotificationThreshold, 1)

        store.setLowBatteryNotificationThreshold(120)
        XCTAssertEqual(store.lowBatteryNotificationThreshold, 99)
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

    func testBluetoothPowerLogParserKeepsUnsignedStateUnknown() {
        let line = """
        2026-06-02 16:43:44.978 Df bluetoothd[616:ff000b] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'Test Headphones', AcCa Headphone, PID 0x1234 (?), VID 0x5678 (?), Battery 68% (Unknown)
        """

        let reading = DeviceBatteryBluetoothPowerLogParser.reading(from: line)

        XCTAssertEqual(reading?.level, 68)
        XCTAssertEqual(reading?.chargeState, .unknown)
    }

    func testBatteryCenterLogParserReadsChargingState() {
        let line = """
        2026-06-12 21:43:32.313 Df NotificationCenter[1199:36289f6] [com.apple.BatteryCenter:PowerSourceController] Found device: <BCBatteryDevice: 0x804941b80; vendor = Apple; productIdentifier = 8212; parts = (null); identifier = 49443244; matchIdentifier = (null); name = Custom AirPods; groupName =Custom AirPods; percentCharge = 24; lowBattery = NO; lowPowerModeActive = NO; connected = YES; charging = YES; paused = NO; internal = NO; powerSource = NO; poweredSoureState = AC Power; transportType = Bluetooth; accessoryIdentifier = 2C7600E3-8F61-4CAA-A1F0-BADBEEF12345; accessoryCategory = Headphones; modelNumber = AirPods Pro 2; >
        """

        let reading = DeviceBatteryBatteryCenterLogParser.reading(fromLine: line)

        XCTAssertEqual(reading?.name, "Custom AirPods")
        XCTAssertEqual(reading?.model, "AirPods Pro 2")
        XCTAssertNil(reading?.parts)
        XCTAssertEqual(reading?.identifier, "49443244")
        XCTAssertNil(reading?.matchIdentifier)
        XCTAssertEqual(reading?.level, 24)
        XCTAssertEqual(reading?.chargeState, .charging)
        XCTAssertEqual(reading?.isConnected, true)
        XCTAssertNotNil(reading?.observedAt)
    }

    func testBatteryCenterLogParserReadsAirPodsComponentGrouping() {
        let line = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1138:239c] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x7b2410f980; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = EARBUDS-ID; matchIdentifier = SHARED-GROUP-ID; name = Test AirPods 4; groupName =Test AirPods 4; percentCharge = 72; connected = YES; charging = NO; internal = NO; transportType = Bluetooth; accessoryIdentifier = EARBUDS-ACCESSORY-ID; accessoryCategory = Headphone; modelNumber = (null); >)
        """

        let reading = DeviceBatteryBatteryCenterLogParser.reading(fromLine: line)

        XCTAssertEqual(reading?.parts, "left-right")
        XCTAssertEqual(reading?.identifier, "EARBUDS-ID")
        XCTAssertEqual(reading?.matchIdentifier, "SHARED-GROUP-ID")
        XCTAssertEqual(reading?.level, 72)
    }

    func testBatteryCenterLogParserKeepsMissingChargingStateUnknown() {
        let line = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = EARBUDS-ID; matchIdentifier = SHARED-GROUP-ID; name = Test AirPods 4; groupName =Test AirPods 4; percentCharge = 72; connected = YES; internal = NO; accessoryCategory = Headphone; >)
        """

        let reading = DeviceBatteryBatteryCenterLogParser.reading(fromLine: line)

        XCTAssertEqual(reading?.level, 72)
        XCTAssertEqual(reading?.chargeState, .unknown)
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

    func testAppleHeadphoneAdvertisementParserUsesStatusBitFiveForEarOrder() throws {
        var bytes = makeAppleProximityPairingPacket()
        bytes[5] = 0x14
        bytes[6] = 0x20
        bytes[7] = 0x31
        bytes[8] = 0xA9
        bytes[9] = 0xA7

        let advertisement = try XCTUnwrap(
            DeviceBatteryAppleHeadphoneAdvertisementParser.advertisement(from: Data(bytes))
        )

        XCTAssertEqual(advertisement.productID, 0x2014)
        XCTAssertEqual(advertisement.readings.first { $0.component == .left }?.level, 90)
        XCTAssertEqual(advertisement.readings.first { $0.component == .left }?.chargeState, .normal)
        XCTAssertEqual(advertisement.readings.first { $0.component == .right }?.level, 100)
        XCTAssertEqual(advertisement.readings.first { $0.component == .right }?.chargeState, .charging)
        XCTAssertEqual(advertisement.readings.first { $0.component == .chargingCase }?.level, 70)
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

    func testAppleHeadphoneAdvertisementParserAcceptsOnlyObservedBatteryRange() {
        for value in 0...15 {
            var bytes = makeAppleProximityPairingPacket()
            bytes[7] = 0x20
            bytes[8] = UInt8(value << 4 | 0x0F)
            bytes[9] = 0x0F

            let rightReading = DeviceBatteryAppleHeadphoneAdvertisementParser
                .readings(from: Data(bytes))
                .first { $0.component == .right }

            if value > 10 {
                XCTAssertNil(rightReading)
            } else {
                XCTAssertEqual(rightReading?.level, value * 10)
                XCTAssertEqual(rightReading?.chargeState, .normal)
            }
        }
    }

    func testAppleBluetoothProductCatalogReadsSystemTypeDeclarations() {
        let info: [String: Any] = [
            "UTExportedTypeDeclarations": [
                [
                    "UTTypeDescription": "Test Headphones",
                    "UTTypeIdentifier": "com.example.test-headphones"
                ],
                [
                    "UTTypeIdentifier": "com.example.test-headphones.variant",
                    "UTTypeConformsTo": "com.example.test-headphones",
                    "UTTypeTagSpecification": [
                        "public.bluetooth-vendor-product-id": ["76:8219"]
                    ]
                ],
                [
                    "UTTypeIdentifier": "com.example.test-headphones.second-variant",
                    "UTTypeConformsTo": ["com.example.test-headphones"],
                    "UTTypeTagSpecification": [
                        "public.bluetooth-vendor-product-id": ["76:8231"]
                    ]
                ]
            ]
        ]
        let names = AppleBluetoothProductCatalog.namesByProductID(in: [info])
        let ambiguousNames = names.merging([2002: "Wrong Device", 8194: "Original AirPods"]) { current, _ in
            current
        }

        XCTAssertEqual(
            AppleBluetoothProductCatalog.modelName(
                forProductID: "0x201B",
                namesByProductID: names
            ),
            "Test Headphones"
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.modelName(
                forProductID: "8219",
                namesByProductID: names
            ),
            "Test Headphones"
        )
        XCTAssertEqual(names[8231], "Test Headphones")
        XCTAssertEqual(
            AppleBluetoothProductCatalog.modelName(
                forProductID: "2002",
                namesByProductID: ambiguousNames
            ),
            "Original AirPods"
        )
        XCTAssertTrue(
            AppleBluetoothProductCatalog.modelName(forProductID: "0x2002")?
                .localizedCaseInsensitiveContains("AirPods") == true
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.modelName(forProductID: "0x201D"),
            "Powerbeats Pro 2"
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.modelName(forProductID: "0x2027"),
            "AirPods Pro 3"
        )
        XCTAssertTrue(
            AppleBluetoothProductCatalog.matches(
                productID: 0x201B,
                encodedProductID: "0x201B"
            )
        )
        XCTAssertTrue(
            AppleBluetoothProductCatalog.matches(
                productID: 0x201B,
                encodedProductID: "8219"
            )
        )
        XCTAssertFalse(
            AppleBluetoothProductCatalog.matches(
                productID: 0x2014,
                encodedProductID: "0x201B"
            )
        )
        XCTAssertFalse(
            AppleBluetoothProductCatalog.matches(
                productID: 0x8212,
                encodedProductID: "8212"
            )
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.supportsSplitBattery(forProductID: "0x201B"),
            true
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.supportsSplitBattery(forProductID: "0x200A"),
            false
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.supportsSplitBattery(forProductID: 0x200A),
            false
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.batteryTopology(forProductID: "0x201F"),
            .single
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.batteryTopology(forProductID: "0x202D"),
            .single
        )
        XCTAssertEqual(
            AppleBluetoothProductCatalog.batteryTopology(forProductID: "0x201B"),
            .split
        )
        XCTAssertNil(
            AppleBluetoothProductCatalog.supportsSplitBattery(forProductID: "0x7FFF")
        )

        let legacyProductIDs = [
            "2002", "2003", "2005", "2006", "200A", "200B", "200C", "200D",
            "200E", "200F", "2010", "2011", "2012", "2013", "2014", "2016",
            "2017", "2019", "201B", "201D", "201F", "2024", "2026", "2027"
        ]
        for productID in legacyProductIDs {
            XCTAssertNotNil(
                AppleBluetoothProductCatalog.modelName(forProductID: productID),
                "Missing maintained model for product ID \(productID)"
            )
        }
    }

    func testBluetoothProfileTreatsAirPodsMaxAsOneBattery() throws {
        let output = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Test AirPods Max": {
                    "device_address": "AA-BB-CC-DD-EE-FF",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201F",
                    "device_minorType": "Headset",
                    "device_batteryLevelMain": "48%",
                    "device_batteryLevelLeft": "1%",
                    "device_batteryLevelRight": "2%",
                    "device_batteryLevelCase": "3%"
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
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.name, "Test AirPods Max")
        XCTAssertEqual(item.model, "AirPods Max (USB-C)")
        XCTAssertEqual(item.level, 48)
        XCTAssertEqual(item.chargeState, .unknown)
        XCTAssertNil(item.parentName)
        XCTAssertNil(item.componentIdentity)
    }

    func testPIDlessSystemNamedAirPodsMaxRejectsComponentsWithoutGuessingIdentity() {
        let output = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [{
              "AirPods Max": {
                "device_address": "AA-BB-CC-DD-EE-01",
                "device_vendorID": "0x004c",
                "device_minorType": "Headset",
                "device_batteryLevelMain": "48%",
                "device_batteryLevelLeft": "1%",
                "device_batteryLevelRight": "2%",
                "device_batteryLevelCase": "3%"
              }
            }],
            "device_not_connected": [{
              "My AirPods Max": {
                "device_address": "11-22-33-44-55-66",
                "device_vendorID": "0x004c",
                "device_productID": "0x201F",
                "device_minorType": "Headset",
                "device_batteryLevelMain": "48%"
              }
            }]
          }]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )
        let connectedItems = items.filter(\.isConnected)

        XCTAssertEqual(connectedItems.count, 1)
        XCTAssertEqual(connectedItems.first?.name, "AirPods Max")
        XCTAssertEqual(connectedItems.first?.level, 48)
        XCTAssertNil(connectedItems.first?.componentIdentity)
        XCTAssertEqual(Set(items.map(\.deviceIdentity)).count, 2)
        XCTAssertFalse(
            AppleBluetoothProductCatalog.isVerifiedSingleBatteryModelName("My AirPods Max")
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

    func testCachedBluetoothProfileKeepsItsOriginalObservationDate() throws {
        let profileDate = Date(timeIntervalSince1970: 100)
        let batteryCenterDate = Date(timeIntervalSince1970: 160)
        let nextCollectionDate = Date(timeIntervalSince1970: 220)
        let profileOutput = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [{
              "Test Headphones": {
                "device_address": "11-22-33-44-55-66",
                "device_batteryLevelMain": "80%"
              }
            }]
          }]
        }
        """
        var cache = DeviceBatteryBluetoothProfileCache()
        _ = cache.store(output: profileOutput, observedAt: profileDate)
        let reusedSnapshot = try XCTUnwrap(cache.reusableSnapshot(
            at: nextCollectionDate,
            maximumAge: 5 * 60
        ))
        let profileItem = try XCTUnwrap(DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: reusedSnapshot.output,
            referenceDate: reusedSnapshot.observedAt
        ).first)
        let batteryCenterItem = DeviceBatteryItem(
            id: "battery-center-headphones",
            deviceIdentity: .bluetooth("11:22:33:44:55:66"),
            name: "Test Headphones",
            model: nil,
            kind: .bluetooth,
            level: 70,
            chargeState: .normal,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: batteryCenterDate,
            isConnected: true,
            detail: nil
        )

        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            profileItem,
            batteryCenterItem
        ]).first)

        XCTAssertEqual(reusedSnapshot.observedAt, profileDate)
        XCTAssertEqual(profileItem.lastUpdated, profileDate)
        XCTAssertEqual(item.source, "BatteryCenter")
        XCTAssertEqual(item.level, 70)
    }

    func testBluetoothPowerLogRejectsComponentsForAirPodsMax() throws {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Test AirPods Max": {
                    "device_address": "AA-BB-CC-DD-EE-FF",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201F",
                    "device_minorType": "Headset"
                  }
                }
              ]
            }
          ]
        }
        """
        let powerLogOutput = """
        2026-08-19 10:00:00.000 Df bluetoothd[1:1] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'Test AirPods Max', AcCa Headset, PID 0x201F (?), VID 0x004C (Apple), Battery -48%, Components (Y): Left -1%, Right -2%, Case -3%
        """

        let items = DeviceBatterySampler.bluetoothPowerLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            powerLogOutput: powerLogOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        )
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.name, "Test AirPods Max")
        XCTAssertEqual(item.level, 48)
        XCTAssertNil(item.parentName)
        XCTAssertNil(item.componentIdentity)
    }

    func testBluetoothPowerLogUsesReadingProductIDForSingleBatteryTopology() throws {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Custom Headset": {
                    "device_address": "AA-BB-CC-DD-EE-FF",
                    "device_vendorID": "0x004c",
                    "device_minorType": "Headset"
                  }
                }
              ]
            }
          ]
        }
        """
        let powerLogOutput = """
        2026-08-19 10:00:00.000 Df bluetoothd[1:1] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'Custom Headset', AcCa Headset, PID 0x201F (?), VID 0x004C (Apple), Battery -48%, Components (Y): Left -1%, Right -2%, Case -3%
        """

        let items = DeviceBatterySampler.bluetoothPowerLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            powerLogOutput: powerLogOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        )
        let item = try XCTUnwrap(items.first)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.name, "Custom Headset")
        XCTAssertEqual(item.level, 48)
        XCTAssertEqual(item.batterySlot, .aggregate)
    }

    func testLevelOnlyProfileKeepsExplicitPowerLogChargeState() throws {
        let profileOutput = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [{
              "Test AirPods 4": {
                "device_address": "11-22-33-44-55-66",
                "device_vendorID": "0x004c",
                "device_productID": "0x201B",
                "device_minorType": "Headphones",
                "device_serialNumber": "GROUP-SERIAL",
                "device_batteryLevelLeft": "97%",
                "device_batteryLevelRight": "100%",
                "device_batteryLevelCase": "100%"
              }
            }]
          }]
        }
        """
        let powerLogOutput = """
        2026-08-20 12:12:44.156 Df bluetoothd[1:1] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'Test AirPods 4', AcCa Headphone, PID 0x201B (Device1,8219), VID 0x004C (Apple), Components (Y): Left -97%, Right +100%, Case -100%
        """
        let profileDate = Date(timeIntervalSince1970: 2_600_000_000)
        let profileItems = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            referenceDate: profileDate
        )
        let powerLogItems = DeviceBatterySampler.bluetoothPowerLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            powerLogOutput: powerLogOutput,
            referenceDate: profileDate
        )

        let rightItem = try XCTUnwrap(
            DeviceBatterySampler.deduplicated(profileItems + powerLogItems)
                .first { $0.batterySlot == .right }
        )

        XCTAssertEqual(rightItem.source, "system_profiler")
        XCTAssertEqual(rightItem.level, 100)
        XCTAssertEqual(rightItem.chargeState, .charging)
        XCTAssertEqual(rightItem.lastUpdated, profileDate)
    }

    func testBatteryCenterUsesReadingProductIDForSingleBatteryTopology() {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Custom Headset": {
                    "device_address": "AA-BB-CC-DD-EE-FF",
                    "device_vendorID": "0x004c",
                    "device_minorType": "Headset"
                  }
                }
              ]
            }
          ]
        }
        """
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8223; parts = case; identifier = MAX-CASE; matchIdentifier = MAX-GROUP; name = Custom Headset; groupName =Custom Headset; percentCharge = 2; connected = YES; charging = NO; internal = NO; accessoryIdentifier = MAX-CASE-ACCESSORY; accessoryCategory = Headphone; >)
        """

        let items = DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testUnmatchedBatteryCenterReadingRejectsAirPodsMaxComponents() {
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8223; parts = case; identifier = MAX-CASE; matchIdentifier = MAX-GROUP; name = Custom Headset Case; groupName =Custom Headset; percentCharge = 2; connected = YES; charging = NO; internal = NO; accessoryIdentifier = MAX-CASE-ACCESSORY; accessoryCategory = Headphone; >)
        """

        let items = DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: "{\"SPBluetoothDataType\": []}",
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testUnmatchedBatteryCenterReadingWithoutStableIdentifierIsIgnored() {
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Example; productIdentifier = 1234; parts = (null); identifier = (null); matchIdentifier = (null); name = Shared Device; groupName =Shared Device; percentCharge = 52; connected = YES; charging = NO; internal = NO; accessoryIdentifier = (null); accessoryCategory = Headphone; >)
        """

        let items = DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: "{\"SPBluetoothDataType\": []}",
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(items.isEmpty)
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

    func testCorroboratedLiveAndPairedAirPodsRecordsShareOneIdentity() {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "My AirPods 4": {
                    "device_address": "AA-BB-CC-DD-EE-01",
                    "device_firmwareVersion": "8A293",
                    "device_batteryLevelMain": "68%",
                    "device_batteryLevelLeft": "72%",
                    "device_batteryLevelRight": "75%",
                    "device_batteryLevelCase": "83%"
                  }
                }
              ],
              "device_not_connected": [
                {
                  "My AirPods 4": {
                    "device_address": "11-22-33-44-55-66",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones",
                    "device_firmwareVersion": "8A293",
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
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = EARBUDS-ID; matchIdentifier = SHARED-GROUP-ID; name = My AirPods 4; groupName =My AirPods 4; percentCharge = 70; connected = YES; charging = NO; internal = NO; accessoryIdentifier = EARBUDS-ACCESSORY; accessoryCategory = Headphone; >)
        2026-08-19 17:15:16.581 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x2; vendor = Apple; productIdentifier = 8219; parts = case; identifier = CASE-ID; matchIdentifier = SHARED-GROUP-ID; name = My AirPods 4 Case; groupName =My AirPods 4 Case; percentCharge = 83; connected = YES; charging = NO; internal = NO; accessoryIdentifier = CASE-ACCESSORY; accessoryCategory = Headphone; >)
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
        let expectedIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")

        XCTAssertEqual(Set(profileItems.map(\.deviceIdentity)), [expectedIdentity])
        XCTAssertEqual(Set(batteryCenterItems.map(\.deviceIdentity)), [expectedIdentity])

        let items = DeviceBatterySampler.deduplicated(profileItems + batteryCenterItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(
            Set(items.map(\.batterySlot)),
            Set([.left, .right, .chargingCase])
        )
        XCTAssertEqual(Set(items.map(\.deviceIdentity)), [expectedIdentity])
    }

    func testLiveAndPairedAirPodsCorrelationRejectsAmbiguousCandidatesInAnyOrder() {
        let firstConnectedRecord = """
        {
          "Shared AirPods": {
            "device_address": "AA-BB-CC-DD-EE-01",
            "device_services": "0x400000 < BLE >",
            "device_firmwareVersion": "8A293",
            "device_batteryLevelLeft": "72%",
            "device_batteryLevelRight": "75%",
            "device_batteryLevelCase": "83%"
          }
        }
        """
        let secondConnectedRecord = """
        {
          "Shared AirPods": {
            "device_address": "AA-BB-CC-DD-EE-02",
            "device_services": "0x400000 < BLE >",
            "device_firmwareVersion": "8A293",
            "device_batteryLevelLeft": "72%",
            "device_batteryLevelRight": "75%",
            "device_batteryLevelCase": "83%"
          }
        }
        """
        let pairedRecord = """
        {
          "Shared AirPods": {
            "device_address": "11-22-33-44-55-66",
            "device_vendorID": "0x004c",
            "device_productID": "0x201B",
            "device_minorType": "Headphones",
            "device_serialNumber": "GROUP-SERIAL",
            "device_firmwareVersion": "8A293",
            "device_batteryLevelLeft": "72%",
            "device_batteryLevelRight": "75%",
            "device_batteryLevelCase": "83%"
          }
        }
        """

        for connectedRecords in [
            [firstConnectedRecord, secondConnectedRecord],
            [secondConnectedRecord, firstConnectedRecord]
        ] {
            let output = """
            {
              "SPBluetoothDataType": [
                {
                  "device_connected": [
                    \(connectedRecords.joined(separator: ","))
                  ],
                  "device_not_connected": [
                    \(pairedRecord)
                  ]
                }
              ]
            }
            """
            let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
                fromSystemProfilerOutput: output,
                referenceDate: Date(timeIntervalSince1970: 1)
            )

            XCTAssertEqual(Set(items.map(\.deviceIdentity)).count, 3)
            XCTAssertEqual(items.count, 9)
        }
    }

    func testLiveAndPairedAirPodsCorrelationRejectsUniformBatteryFingerprint() {
        let output = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [{
              "Shared AirPods": {
                "device_address": "AA-BB-CC-DD-EE-01",
                "device_firmwareVersion": "8A293",
                "device_batteryLevelLeft": "100%",
                "device_batteryLevelRight": "100%",
                "device_batteryLevelCase": "100%"
              }
            }],
            "device_not_connected": [{
              "Shared AirPods": {
                "device_address": "11-22-33-44-55-66",
                "device_vendorID": "0x004c",
                "device_productID": "0x201B",
                "device_minorType": "Headphones",
                "device_firmwareVersion": "8A293",
                "device_batteryLevelLeft": "100%",
                "device_batteryLevelRight": "100%",
                "device_batteryLevelCase": "100%"
              }
            }]
          }]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(Set(items.map(\.deviceIdentity)).count, 2)
        XCTAssertEqual(items.count, 6)
    }

    func testMetadataPoorBLEShadowUsesStablePairedIdentityAtUniformCharge() {
        let output = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [{
              "My AirPods": {
                "device_address": "AA-BB-CC-DD-EE-01",
                "device_services": "0x400000 < BLE >",
                "device_firmwareVersion": "LIVE-FIRMWARE",
                "device_batteryLevelLeft": "100%",
                "device_batteryLevelRight": "100%",
                "device_batteryLevelCase": "100%"
              }
            }],
            "device_not_connected": [{
              "My AirPods": {
                "device_address": "11-22-33-44-55-66",
                "device_vendorID": "0x004c",
                "device_productID": "0x201B",
                "device_minorType": "Headphones",
                "device_serialNumber": "GROUP-SERIAL",
                "device_firmwareVersion": "PAIRED-FIRMWARE",
                "device_batteryLevelLeft": "100%",
                "device_batteryLevelRight": "100%",
                "device_batteryLevelCase": "100%"
              }
            }]
          }]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.deviceIdentity)), [.bluetooth("serial:GROUP:SERIAL")])
        XCTAssertEqual(Set(items.map(\.batterySlot)), [.left, .right, .chargingCase])
    }

    func testConnectedBLEShadowUsesStableConnectedIdentityWithPartialStaleComponents() {
        let output = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [
              {
                "My AirPods": {
                  "device_address": "AA-BB-CC-DD-EE-01",
                  "device_services": "0x400000 < BLE >",
                  "device_firmwareVersion": "LIVE-FIRMWARE",
                  "device_batteryLevelLeft": "98%",
                  "device_batteryLevelCase": "100%"
                }
              },
              {
                "My AirPods": {
                  "device_address": "11-22-33-44-55-66",
                  "device_vendorID": "0x004c",
                  "device_productID": "0x201B",
                  "device_minorType": "Headphones",
                  "device_serialNumber": "GROUP-SERIAL",
                  "device_firmwareVersion": "PAIRED-FIRMWARE",
                  "device_services": "0x980019 < HFP AVRCP A2DP AACP GATT ACL >",
                  "device_batteryLevelLeft": "97%",
                  "device_batteryLevelRight": "100%",
                  "device_batteryLevelCase": "100%"
                }
              }
            ]
          }]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.deviceIdentity)), [.bluetooth("serial:GROUP:SERIAL")])
        XCTAssertEqual(Set(items.map(\.batterySlot)), [.left, .right, .chargingCase])
        XCTAssertEqual(items.first { $0.batterySlot == .left }?.level, 97)
    }

    func testConnectedBLEShadowDoesNotGuessBetweenStableSameNameDevices() {
        let output = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [
              {
                "Shared AirPods": {
                  "device_address": "AA-BB-CC-DD-EE-01",
                  "device_services": "0x400000 < BLE >",
                  "device_batteryLevelLeft": "72%",
                  "device_batteryLevelCase": "83%"
                }
              },
              {
                "Shared AirPods": {
                  "device_address": "11-22-33-44-55-66",
                  "device_vendorID": "0x004c",
                  "device_productID": "0x201B",
                  "device_serialNumber": "GROUP-ONE",
                  "device_batteryLevelLeft": "72%",
                  "device_batteryLevelRight": "75%",
                  "device_batteryLevelCase": "83%"
                }
              },
              {
                "Shared AirPods": {
                  "device_address": "22-33-44-55-66-77",
                  "device_vendorID": "0x004c",
                  "device_productID": "0x201B",
                  "device_serialNumber": "GROUP-TWO",
                  "device_batteryLevelLeft": "62%",
                  "device_batteryLevelRight": "65%",
                  "device_batteryLevelCase": "73%"
                }
              }
            ]
          }]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(Set(items.map(\.deviceIdentity)).count, 3)
        XCTAssertEqual(items.count, 8)
    }

    func testBluetoothProfileUsesStableGroupSerialBeforeSourcePositionAndName() throws {
        let firstOutput = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [{
              "Original Name": {
                "device_serialNumberMain": "SERIAL-123",
                "device_batteryLevelMain": "41%"
              }
            }]
          }]
        }
        """
        let renamedOutput = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [
              { "Unrelated": { "device_address": "00-00-00-00-00-01" } },
              {
                "Renamed Device": {
                  "device_serialNumberMain": "SERIAL-123",
                  "device_batteryLevelMain": "42%"
                }
              }
            ]
          }]
        }
        """

        let first = try XCTUnwrap(DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: firstOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        ).first)
        let renamed = try XCTUnwrap(DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: renamedOutput,
            referenceDate: Date(timeIntervalSince1970: 2)
        ).first)

        XCTAssertEqual(first.deviceIdentity, .bluetooth("serial:SERIAL:123"))
        XCTAssertEqual(renamed.deviceIdentity, first.deviceIdentity)
    }

    func testBluetoothProfileDoesNotMergeSameNameWithoutStrongIdentity() {
        let output = """
        {
          "SPBluetoothDataType": [{
            "device_connected": [
              { "Shared Device": { "device_batteryLevelMain": "41%" } },
              { "Shared Device": { "device_batteryLevelMain": "42%" } }
            ]
          }]
        }
        """

        let items = DeviceBatterySampler.bluetoothProfileBatteryItems(
            fromSystemProfilerOutput: output,
            referenceDate: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.deviceIdentity)).count, 2)
    }

    func testKnownAppleProductIDClassifiesRenamedHeadphonesWithoutMinorType() {
        XCTAssertEqual(
            DeviceBatterySampler.inferredBluetoothKind(
                name: "Custom Device",
                minorType: nil,
                vendorID: "0x004C",
                productID: "0x201F",
                field: "main"
            ),
            .airPodsPart
        )
        XCTAssertEqual(
            DeviceBatterySampler.inferredBluetoothKind(
                name: "Custom Device",
                minorType: nil,
                vendorID: "0x004C",
                productID: "0x201B",
                field: "main"
            ),
            .airPodsPart
        )
        XCTAssertEqual(
            DeviceBatterySampler.inferredBluetoothKind(
                name: "Custom Speaker",
                minorType: nil,
                vendorID: "0x004C",
                productID: "0x201A",
                field: "main"
            ),
            .bluetooth
        )
        XCTAssertEqual(
            DeviceBatterySampler.inferredBluetoothKind(
                name: "Custom Input Device",
                minorType: "Mouse",
                vendorID: "0x004C",
                field: "main"
            ),
            .magicAccessory
        )
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

    func testPowerLogDoesNotGuessBetweenSameNameAndModelDevices() {
        let reading = DeviceBatteryBluetoothPowerLogReading(
            name: "Shared AirPods",
            vendorID: "0x004C",
            productID: "0x201B",
            deviceType: "Headphones",
            component: .left,
            level: 50,
            chargeState: .normal
        )
        let targets = [
            BluetoothBatteryTarget(
                id: "first",
                name: "Shared AirPods",
                address: "11:11:11:11:11:11",
                vendorID: "0x004C",
                productID: "0x201B",
                model: "AirPods 4",
                kind: .airPodsPart,
                detail: "Headphones",
                isConnected: true
            ),
            BluetoothBatteryTarget(
                id: "second",
                name: "Shared AirPods",
                address: "22:22:22:22:22:22",
                vendorID: "0x004C",
                productID: "0x201B",
                model: "AirPods 4",
                kind: .airPodsPart,
                detail: "Headphones",
                isConnected: true
            )
        ]

        XCTAssertNil(DeviceBatterySampler.matchingBluetoothPowerLogTarget(reading, in: targets))
    }

    func testPowerLogDoesNotUseProductIDWhenExplicitNameConflicts() {
        let reading = DeviceBatteryBluetoothPowerLogReading(
            name: "Previous AirPods",
            vendorID: "0x004C",
            productID: "0x201B",
            deviceType: "Headphones",
            component: .left,
            level: 50,
            chargeState: .normal
        )
        let target = BluetoothBatteryTarget(
            id: "current",
            name: "Current AirPods",
            address: "11:11:11:11:11:11",
            vendorID: "0x004C",
            productID: "0x201B",
            model: "AirPods 4",
            kind: .airPodsPart,
            detail: "Headphones",
            isConnected: true
        )

        XCTAssertNil(DeviceBatterySampler.matchingBluetoothPowerLogTarget(
            reading,
            in: [target]
        ))
    }

    func testBatteryCenterDoesNotUseProductIDWhenExplicitNameConflicts() {
        let reading = DeviceBatteryBatteryCenterLogReading(
            name: "Previous AirPods",
            groupName: "Previous AirPods",
            productID: "8219",
            parts: "left-right",
            identifier: "READING-ID",
            matchIdentifier: "READING-GROUP",
            model: "AirPods 4",
            category: "Headphone",
            accessoryID: "ACCESSORY-ID",
            transportType: "Bluetooth",
            level: 50,
            chargeState: .normal,
            isConnected: true,
            isInternal: false
        )
        let target = BluetoothBatteryTarget(
            id: "current",
            name: "Current AirPods",
            address: "11:11:11:11:11:11",
            vendorID: "0x004C",
            productID: "0x201B",
            model: "AirPods 4",
            kind: .airPodsPart,
            detail: "Headphones",
            isConnected: true
        )

        XCTAssertNil(DeviceBatterySampler.matchingBatteryCenterLogTarget(
            reading,
            in: [target]
        ))

        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Current AirPods": {
                    "device_address": "11-11-11-11-11-11",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones"
                  }
                }
              ]
            }
          ]
        }
        """
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = READING-ID; matchIdentifier = READING-GROUP; name = Previous AirPods; groupName =Previous AirPods; percentCharge = 50; connected = YES; charging = NO; internal = NO; accessoryIdentifier = ACCESSORY-ID; accessoryCategory = Headphone; >)
        """

        XCTAssertTrue(DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        ).isEmpty)

        let misleadingComponentOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = case; identifier = OTHER-CASE-ID; matchIdentifier = OTHER-GROUP; name = Current AirPods Backup充电盒; groupName =Current AirPods Backup充电盒; percentCharge = 50; connected = YES; charging = NO; internal = NO; accessoryIdentifier = OTHER-ACCESSORY-ID; accessoryCategory = Headphone; >)
        """
        XCTAssertTrue(DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            batteryCenterLogOutput: misleadingComponentOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        ).isEmpty)
    }

    func testBatteryCenterMatchesIsolatedComponentNameToUniqueTarget() throws {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Current AirPods": {
                    "device_address": "11-11-11-11-11-11",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones"
                  }
                }
              ]
            }
          ]
        }
        """
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = case; identifier = CASE-ID; matchIdentifier = CASE-GROUP; name = Current AirPods充电盒; groupName =Current AirPods充电盒; percentCharge = 83; connected = YES; charging = NO; internal = NO; accessoryIdentifier = CASE-ACCESSORY; accessoryCategory = Headphone; >)
        """

        let item = try XCTUnwrap(DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        ).first)

        XCTAssertEqual(item.deviceIdentity, .bluetooth("11:11:11:11:11:11"))
        XCTAssertEqual(item.componentIdentity?.role, .chargingCase)
        XCTAssertEqual(item.level, 83)
    }

    func testBatteryCenterDoesNotGuessIsolatedComponentBetweenSameNameTargets() {
        let reading = DeviceBatteryBatteryCenterLogReading(
            name: "Shared AirPods充电盒",
            groupName: "Shared AirPods充电盒",
            productID: "8219",
            parts: "case",
            identifier: "CASE-ID",
            matchIdentifier: "CASE-GROUP",
            model: "AirPods 4",
            category: "Headphone",
            accessoryID: "CASE-ACCESSORY",
            transportType: "Bluetooth",
            level: 83,
            chargeState: .normal,
            isConnected: true,
            isInternal: false
        )
        let targets = [
            BluetoothBatteryTarget(
                id: "first",
                name: "Shared AirPods",
                address: "11:11:11:11:11:11",
                vendorID: "0x004C",
                productID: "0x201B",
                model: "AirPods 4",
                kind: .airPodsPart,
                detail: "Headphones",
                isConnected: true
            ),
            BluetoothBatteryTarget(
                id: "second",
                name: "Shared AirPods",
                address: "22:22:22:22:22:22",
                vendorID: "0x004C",
                productID: "0x201B",
                model: "AirPods 4",
                kind: .airPodsPart,
                detail: "Headphones",
                isConnected: true
            )
        ]

        XCTAssertNil(DeviceBatterySampler.matchingBatteryCenterLogTarget(
            reading,
            in: targets
        ))
    }

    func testBatteryCenterMatchIdentifierKeepsSameModelAirPodsSeparate() {
        let profileOutput = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Alpha AirPods": {
                    "device_address": "11-11-11-11-11-11",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones"
                  }
                },
                {
                  "Beta AirPods": {
                    "device_address": "22-22-22-22-22-22",
                    "device_vendorID": "0x004c",
                    "device_productID": "0x201B",
                    "device_minorType": "Headphones"
                  }
                }
              ]
            }
          ]
        }
        """
        let batteryCenterOutput = """
        2026-08-19 17:15:16.580 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = ALPHA-EARBUDS; matchIdentifier = ALPHA-GROUP; name = Alpha AirPods; groupName =Alpha AirPods; percentCharge = 72; connected = YES; charging = NO; internal = NO; accessoryIdentifier = ALPHA-EARBUDS-ACCESSORY; accessoryCategory = Headphone; >)
        2026-08-19 17:15:16.581 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x2; vendor = Apple; productIdentifier = 8219; parts = case; identifier = ALPHA-CASE; matchIdentifier = ALPHA-GROUP; name = Alpha AirPods Case; groupName =Alpha AirPods Case; percentCharge = 83; connected = YES; charging = NO; internal = NO; accessoryIdentifier = ALPHA-CASE-ACCESSORY; accessoryCategory = Headphone; >)
        2026-08-19 17:15:16.582 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x3; vendor = Apple; productIdentifier = 8219; parts = left-right; identifier = BETA-EARBUDS; matchIdentifier = BETA-GROUP; name = Beta AirPods; groupName =Beta AirPods; percentCharge = 64; connected = YES; charging = NO; internal = NO; accessoryIdentifier = BETA-EARBUDS-ACCESSORY; accessoryCategory = Headphone; >)
        2026-08-19 17:15:16.583 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x4; vendor = Apple; productIdentifier = 8219; parts = case; identifier = BETA-CASE; matchIdentifier = BETA-GROUP; name = Beta AirPods Case; groupName =Beta AirPods Case; percentCharge = 91; connected = YES; charging = NO; internal = NO; accessoryIdentifier = BETA-CASE-ACCESSORY; accessoryCategory = Headphone; >)
        """

        let items = DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: profileOutput,
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1)
        )
        let itemsByGroupID = Dictionary(grouping: items) {
            $0.componentIdentity?.groupID ?? ""
        }

        XCTAssertEqual(
            Set(itemsByGroupID.keys),
            Set([
                "bluetooth:11:11:11:11:11:11",
                "bluetooth:22:22:22:22:22:22"
            ])
        )
        XCTAssertEqual(itemsByGroupID.values.map(\.count).sorted(), [2, 2])
        for groupItems in itemsByGroupID.values {
            XCTAssertEqual(
                Set(groupItems.compactMap { $0.componentIdentity?.role }),
                Set([.earbuds, .chargingCase])
            )
        }
    }

    func testRapooParserReadsProtocolOneBatteryReport() {
        let report = [UInt8](repeating: 0, count: 16).setting(1, at: 6).setting(83, at: 7)

        XCTAssertEqual(
            RapooBatteryParser.parseInputReport(reportID: 7, bytes: report),
            RapooBatteryReading(level: 83, chargeState: .normal, statusCode: 1)
        )
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

    func testMobileBatteryParserDistinguishesPluggedAndFullyCharged() throws {
        let plugged = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "tablet-id",
            name: "iPad",
            productType: "iPad17,2",
            deviceClass: "iPad",
            connectionType: "USB",
            battery: [
                "BatteryCurrentCapacity": 80,
                "BatteryIsCharging": false,
                "ExternalConnected": true
            ]
        ))
        let charged = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "watch-id",
            name: "Apple Watch",
            productType: "Watch7,5",
            deviceClass: "Watch",
            connectionType: "Wi-Fi",
            battery: [
                "BatteryCurrentCapacity": 100,
                "FullyCharged": true,
                "ExternalConnected": true
            ]
        ))

        XCTAssertEqual(plugged.category, .tablet)
        XCTAssertEqual(plugged.chargeState, .plugged)
        XCTAssertEqual(charged.category, .watch)
        XCTAssertEqual(charged.chargeState, .charged)
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

    func testMobileBatteryParserKeepsMissingChargeFieldsUnknown() throws {
        let record = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "phone-id",
            name: "Test iPhone",
            productType: "iPhone18,1",
            deviceClass: "iPhone",
            connectionType: "Wi-Fi",
            battery: ["BatteryCurrentCapacity": 67]
        ))

        XCTAssertEqual(record.level, 67)
        XCTAssertEqual(record.chargeState, .unknown)
    }

    func testMobileBatteryParserCombinesDirectLevelWithRegistryChargeState() throws {
        let mergedBattery = try XCTUnwrap(
            DeviceBatteryMobileBatteryParser.mergingBatteryDictionaries(
                primary: ["BatteryCurrentCapacity": 67],
                fallback: [
                    "AppleRawCurrentCapacity": 3_200,
                    "AppleRawMaxCapacity": 4_000,
                    "IsCharging": true,
                    "AppleRawExternalConnected": true
                ]
            )
        )
        let record = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "phone-id",
            name: "Test iPhone",
            productType: "iPhone18,1",
            deviceClass: "iPhone",
            connectionType: "Wi-Fi",
            battery: mergedBattery
        ))

        XCTAssertEqual(record.level, 67)
        XCTAssertEqual(record.chargeState, .charging)
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

    func testMobileDeviceReaderCarriesOnlyRecentExplicitChargeState() async throws {
        let chargingRecord = makeMobileRecord(level: 65, chargeState: .charging)
        let unknownRecord = makeMobileRecord(level: 66, chargeState: .unknown)
        let normalRecord = makeMobileRecord(level: 67, chargeState: .normal)
        let sequence = MobileReadResultSequence([
            .success(chargingRecord),
            .success(unknownRecord),
            .success(normalRecord)
        ])
        let reader = DeviceBatteryMobileDeviceReader {
            sequence.next()
        }
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

        let first = await reader.collectDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: 0
        )
        let second = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(60),
            minimumRefreshInterval: 0
        )
        let third = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(120),
            minimumRefreshInterval: 0
        )

        XCTAssertEqual(try XCTUnwrap(first.first).chargeState, .charging)
        XCTAssertEqual(try XCTUnwrap(first.first).chargeStateLastUpdated, referenceDate)
        XCTAssertEqual(try XCTUnwrap(second.first).level, 66)
        XCTAssertEqual(try XCTUnwrap(second.first).chargeState, .charging)
        XCTAssertEqual(try XCTUnwrap(second.first).chargeStateLastUpdated, referenceDate)
        XCTAssertEqual(try XCTUnwrap(third.first).level, 67)
        XCTAssertEqual(try XCTUnwrap(third.first).chargeState, .normal)
        XCTAssertEqual(
            try XCTUnwrap(third.first).chargeStateLastUpdated,
            referenceDate.addingTimeInterval(120)
        )
    }

    func testCarriedMobileChargeStateDoesNotOutrankNewerExplicitState() async throws {
        let chargingRecord = makeMobileRecord(level: 65, chargeState: .charging)
        let unknownRecord = makeMobileRecord(level: 66, chargeState: .unknown)
        let sequence = MobileReadResultSequence([
            .success(chargingRecord),
            .success(unknownRecord)
        ])
        let reader = DeviceBatteryMobileDeviceReader {
            sequence.next()
        }
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await reader.collectDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: 0
        )
        let mobileItems = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(60),
            minimumRefreshInterval: 0
        )
        let mobileItem = try XCTUnwrap(mobileItems.first)
        let newerExplicitState = DeviceBatteryItem(
            id: "battery-center-phone",
            deviceIdentity: mobileItem.deviceIdentity,
            name: mobileItem.name,
            model: mobileItem.model,
            kind: mobileItem.kind,
            level: 65,
            chargeState: .normal,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: referenceDate.addingTimeInterval(30),
            isConnected: true,
            detail: nil
        )

        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            mobileItem,
            newerExplicitState
        ]).first)

        XCTAssertEqual(item.source, "MobileDevice")
        XCTAssertEqual(item.level, 66)
        XCTAssertEqual(item.lastUpdated, referenceDate.addingTimeInterval(60))
        XCTAssertEqual(item.chargeState, .normal)
        XCTAssertEqual(
            item.chargeStateLastUpdated,
            referenceDate.addingTimeInterval(30)
        )
    }

    func testMobileDeviceReaderExpiresUnknownStateAndClearsDisconnectedDevice() async throws {
        let chargingRecord = makeMobileRecord(level: 65, chargeState: .charging)
        let unknownRecord = makeMobileRecord(level: 66, chargeState: .unknown)
        let sequence = MobileReadResultSequence([
            .success(chargingRecord),
            .success(unknownRecord),
            DeviceBatteryMobileDeviceReadResult(
                records: [],
                didEnumerateDevices: true,
                connectedDeviceCount: 1,
                failedDeviceCount: 1
            ),
            DeviceBatteryMobileDeviceReadResult(
                records: [],
                didEnumerateDevices: true,
                connectedDeviceCount: 0,
                failedDeviceCount: 0
            )
        ])
        let reader = DeviceBatteryMobileDeviceReader {
            sequence.next()
        }
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await reader.collectDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: 0
        )
        let expiredState = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(181),
            minimumRefreshInterval: 0
        )
        let retainedAfterFailure = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(182),
            minimumRefreshInterval: 0
        )
        let disconnected = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(183),
            minimumRefreshInterval: 0
        )

        XCTAssertEqual(try XCTUnwrap(expiredState.first).chargeState, .unknown)
        XCTAssertEqual(retainedAfterFailure, expiredState)
        XCTAssertTrue(disconnected.isEmpty)
    }

    func testMobileDeviceReaderDoesNotRenewCarriedStateAfterTransientFailure() async throws {
        let chargingRecord = makeMobileRecord(level: 65, chargeState: .charging)
        let unknownRecord = makeMobileRecord(level: 66, chargeState: .unknown)
        let transientFailure = DeviceBatteryMobileDeviceReadResult(
            records: [],
            didEnumerateDevices: true,
            connectedDeviceCount: 1,
            failedDeviceCount: 1
        )
        let sequence = MobileReadResultSequence([
            .success(chargingRecord),
            .success(unknownRecord),
            transientFailure,
            transientFailure
        ])
        let reader = DeviceBatteryMobileDeviceReader {
            sequence.next()
        }
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await reader.collectDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: 0
        )
        let bridged = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(60),
            minimumRefreshInterval: 0
        )
        let expiredState = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(181),
            minimumRefreshInterval: 0
        )
        let expiredItem = await reader.collectDevices(
            referenceDate: referenceDate.addingTimeInterval(241),
            minimumRefreshInterval: 0
        )

        XCTAssertEqual(try XCTUnwrap(bridged.first).chargeState, .charging)
        XCTAssertEqual(try XCTUnwrap(expiredState.first).level, 66)
        XCTAssertEqual(try XCTUnwrap(expiredState.first).chargeState, .unknown)
        XCTAssertTrue(expiredItem.isEmpty)
    }

    func testBatteryCenterDoesNotSurfaceUnmatchedAppleMobileRecord() {
        let batteryCenterOutput = """
        2026-08-20 14:00:00.000 Df NotificationCenter[1:1] [com.apple.BatteryCenter:Widget] (<BCBatteryDevice: 0x1; vendor = Apple; productIdentifier = 0; parts = (null); identifier = PHONE-POWER-SOURCE; matchIdentifier = (null); name = Test iPhone; groupName =Test iPhone; percentCharge = 65; connected = YES; charging = YES; internal = NO; transportType = WiFi; accessoryIdentifier = PHONE-ACCESSORY; accessoryCategory = MobilePhone; modelNumber = iPhone18,1; >)
        """

        XCTAssertTrue(DeviceBatterySampler.batteryCenterLogBatteryItems(
            fromSystemProfilerOutput: #"{"SPBluetoothDataType":[{"device_connected":[],"device_not_connected":[]}]}"#,
            batteryCenterLogOutput: batteryCenterOutput,
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000)
        ).isEmpty)
    }

    func testLevelOnlyReadingKeepsLatestExplicitChargeState() throws {
        let identity = DeviceBatteryDeviceIdentity.bluetooth("airpods-max")
        let chargingReading = DeviceBatteryItem(
            id: "battery-center-max",
            deviceIdentity: identity,
            name: "AirPods Max",
            model: "AirPods Max",
            kind: .airPodsPart,
            level: 19,
            chargeState: .charging,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: Date(timeIntervalSince1970: 100),
            isConnected: true,
            detail: "Headphones"
        )
        let levelOnlyReading = DeviceBatteryItem(
            id: "iobluetooth-max",
            deviceIdentity: identity,
            name: "AirPods Max",
            model: "AirPods Max",
            kind: .airPodsPart,
            level: 21,
            chargeState: .unknown,
            parentName: nil,
            source: "IOBluetooth",
            lastUpdated: Date(timeIntervalSince1970: 200),
            isConnected: true,
            detail: "Headphones"
        )

        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            chargingReading,
            levelOnlyReading
        ]).first)

        XCTAssertEqual(item.source, "IOBluetooth")
        XCTAssertEqual(item.level, 21)
        XCTAssertEqual(item.chargeState, .charging)
        XCTAssertEqual(item.lastUpdated, Date(timeIntervalSince1970: 200))
    }

    func testNewerExplicitNormalStateReplacesOlderChargingState() throws {
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        let oldCharging = DeviceBatteryItem(
            id: "old-charging",
            deviceIdentity: identity,
            name: "Headphones",
            model: nil,
            kind: .bluetooth,
            level: 60,
            chargeState: .charging,
            parentName: nil,
            source: "BluetoothPowerLog",
            lastUpdated: Date(timeIntervalSince1970: 100),
            isConnected: true,
            detail: nil
        )
        let newerNormal = DeviceBatteryItem(
            id: "newer-normal",
            deviceIdentity: identity,
            name: "Headphones",
            model: nil,
            kind: .bluetooth,
            level: 61,
            chargeState: .normal,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: Date(timeIntervalSince1970: 150),
            isConnected: true,
            detail: nil
        )
        let newestLevelOnly = DeviceBatteryItem(
            id: "newest-level",
            deviceIdentity: identity,
            name: "Headphones",
            model: nil,
            kind: .bluetooth,
            level: 62,
            chargeState: .unknown,
            parentName: nil,
            source: "CoreBluetooth",
            lastUpdated: Date(timeIntervalSince1970: 200),
            isConnected: true,
            detail: nil
        )

        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            oldCharging,
            newerNormal,
            newestLevelOnly
        ]).first)

        XCTAssertEqual(item.source, "CoreBluetooth")
        XCTAssertEqual(item.level, 62)
        XCTAssertEqual(item.chargeState, .normal)
    }

    func testSameSourceCarriesExplicitStateOnlyWithinFreshnessWindow() throws {
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        let charging = DeviceBatteryItem(
            id: "battery-center-charging",
            deviceIdentity: identity,
            name: "Headphones",
            model: nil,
            kind: .bluetooth,
            level: 60,
            chargeState: .charging,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: Date(timeIntervalSince1970: 100),
            isConnected: true,
            detail: nil
        )
        let recentLevelOnly = DeviceBatteryItem(
            id: "battery-center-recent",
            deviceIdentity: identity,
            name: "Headphones",
            model: nil,
            kind: .bluetooth,
            level: 61,
            chargeState: .unknown,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: Date(timeIntervalSince1970: 200),
            isConnected: true,
            detail: nil
        )
        let expiredLevelOnly = DeviceBatteryItem(
            id: "battery-center-expired",
            deviceIdentity: identity,
            name: "Headphones",
            model: nil,
            kind: .bluetooth,
            level: 62,
            chargeState: .unknown,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: Date(timeIntervalSince1970: 301),
            isConnected: true,
            detail: nil
        )

        let recent = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            charging,
            recentLevelOnly
        ]).first)
        let expired = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            charging,
            expiredLevelOnly
        ]).first)

        XCTAssertEqual(recent.level, 61)
        XCTAssertEqual(recent.chargeState, .charging)
        XCTAssertEqual(recent.chargeStateLastUpdated, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(expired.level, 62)
        XCTAssertEqual(expired.chargeState, .unknown)
        XCTAssertNil(expired.chargeStateLastUpdated)
    }

    func testMobileDeviceReadingWinsWhenBatteryCenterSharesItsIdentity() throws {
        let now = Date()
        let mobile = try XCTUnwrap(DeviceBatteryMobileBatteryParser.record(
            identifier: "phone-id",
            name: "测试 iPhone",
            productType: "iPhone18,1",
            deviceClass: "iPhone",
            connectionType: "Wi-Fi",
            battery: [
                "BatteryCurrentCapacity": 66,
                "BatteryIsCharging": false,
                "ExternalConnected": false
            ]
        )).batteryItem(referenceDate: now)
        let staleLog = DeviceBatteryItem(
            id: "batterycenter-phone-id",
            deviceIdentity: .batteryCenter("battery-center-phone-id"),
            name: "测试 iPhone",
            model: "iPhone18,1",
            kind: .phone,
            level: 65,
            chargeState: .charging,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: now,
            isConnected: true,
            detail: nil,
            alternateDeviceIdentities: [.mobileDevice("phone-id")]
        )

        let resolvedItems = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(
            [staleLog, mobile]
        )
        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated(resolvedItems).first)
        XCTAssertEqual(DeviceBatterySampler.deduplicated(resolvedItems).count, 1)
        XCTAssertEqual(item.source, "MobileDevice")
        XCTAssertEqual(item.level, 66)
        XCTAssertEqual(item.chargeState, .normal)
        XCTAssertEqual(
            item.alternateDeviceIdentities,
            [.batteryCenter("battery-center-phone-id")]
        )
    }

    func testNewerBatteryCenterStateReplacesOlderMobileDeviceState() throws {
        let mobileIdentity = DeviceBatteryDeviceIdentity.mobileDevice("phone-id")
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter(
            "battery-center-phone-id"
        )
        let mobile = DeviceBatteryItem(
            id: "mobile-phone-id",
            deviceIdentity: mobileIdentity,
            name: "Test iPhone",
            model: "iPhone18,1",
            kind: .phone,
            level: 66,
            chargeState: .normal,
            parentName: nil,
            source: "MobileDevice",
            lastUpdated: Date(timeIntervalSince1970: 100),
            isConnected: true,
            detail: "Wi-Fi",
            alternateDeviceIdentities: [batteryCenterIdentity]
        )
        let batteryCenter = DeviceBatteryItem(
            id: "batterycenter-phone-id",
            deviceIdentity: batteryCenterIdentity,
            name: "Test iPhone",
            model: "iPhone18,1",
            kind: .phone,
            level: 67,
            chargeState: .charging,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: Date(timeIntervalSince1970: 200),
            isConnected: true,
            detail: nil,
            alternateDeviceIdentities: [mobileIdentity]
        )

        let resolvedItems = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases([
            mobile,
            batteryCenter
        ])
        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated(resolvedItems).first)

        XCTAssertEqual(item.source, "BatteryCenter")
        XCTAssertEqual(item.level, 67)
        XCTAssertEqual(item.chargeState, .charging)
        XCTAssertEqual(item.lastUpdated, Date(timeIntervalSince1970: 200))
    }

    func testMobileDeviceAliasResolutionUsesSharedBluetoothAddress() throws {
        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth(
            "5C:13:CC:2C:E4:04"
        )
        let mobileIdentity = DeviceBatteryDeviceIdentity.mobileDevice("phone-id")
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let mobileItem = DeviceBatteryItem(
            id: "mobile-phone",
            deviceIdentity: mobileIdentity,
            name: "Renamed iPhone",
            model: "iPhone18,1",
            kind: .phone,
            level: 67,
            chargeState: .charging,
            parentName: nil,
            source: "MobileDevice",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: "Wi-Fi",
            componentIdentity: nil,
            alternateDeviceIdentities: [bluetoothIdentity]
        )
        let bluetoothItem = DeviceBatteryItem(
            id: "bluetooth-phone",
            deviceIdentity: bluetoothIdentity,
            name: "Different Bluetooth Name",
            model: nil,
            kind: .bluetooth,
            level: 66,
            chargeState: .unknown,
            parentName: nil,
            source: "CoreBluetooth",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: nil,
            componentIdentity: nil
        )

        let resolved = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases([
            bluetoothItem,
            mobileItem
        ])
        let deduplicated = DeviceBatterySampler.deduplicated(resolved)

        XCTAssertEqual(deduplicated.count, 1)
        let item = try XCTUnwrap(deduplicated.first)
        XCTAssertEqual(item.deviceIdentity, mobileIdentity)
        XCTAssertEqual(item.name, "Renamed iPhone")
        XCTAssertEqual(item.level, 67)
        XCTAssertEqual(item.chargeState, .charging)
    }

    func testMobileDeviceRecordExposesBluetoothAddressAsStrongAlias() {
        let record = DeviceBatteryMobileDeviceRecord(
            identifier: "phone-id",
            bluetoothAddress: "5C:13:CC:2C:E4:04",
            name: "Test iPhone",
            productType: "iPhone18,1",
            category: .phone,
            level: 67,
            chargeState: .charging,
            connectionType: "Wi-Fi",
            parentName: nil
        )

        let item = record.batteryItem(
            referenceDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(item.deviceIdentity, .mobileDevice("phone-id"))
        XCTAssertEqual(
            item.alternateDeviceIdentities,
            [.bluetooth("5C:13:CC:2C:E4:04")]
        )
    }

    func testMobileDeviceAliasResolutionDoesNotGuessFromNameAndModel() {
        let batteryCenter = makeBatteryItem(
            id: "battery-center-phone",
            name: "Shared iPhone",
            level: 65,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .batteryCenter("battery-center-phone"),
            source: "BatteryCenter"
        )
        let mobile = makeBatteryItem(
            id: "mobile-phone",
            name: "Shared iPhone",
            level: 66,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .mobileDevice("mobile-phone"),
            source: "MobileDevice"
        )

        let resolved = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(
            [batteryCenter, mobile]
        )

        XCTAssertEqual(Set(resolved.map(\.deviceIdentity)).count, 2)
        XCTAssertEqual(DeviceBatterySampler.deduplicated(resolved).count, 2)
    }

    func testMobileDeviceAliasResolutionDoesNotGuessBetweenSameNameDevices() {
        let batteryCenter = makeBatteryItem(
            id: "battery-center-phone",
            name: "Shared iPhone",
            level: 65,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .batteryCenter("battery-center-phone"),
            source: "BatteryCenter"
        )
        let firstMobile = makeBatteryItem(
            id: "first-mobile",
            name: "Shared iPhone",
            level: 66,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .mobileDevice("first-mobile"),
            source: "MobileDevice"
        )
        let secondMobile = makeBatteryItem(
            id: "second-mobile",
            name: "Shared iPhone",
            level: 67,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .mobileDevice("second-mobile"),
            source: "MobileDevice"
        )

        let resolved = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(
            [batteryCenter, firstMobile, secondMobile]
        )

        XCTAssertEqual(Set(resolved.map(\.deviceIdentity)).count, 3)
        XCTAssertEqual(DeviceBatterySampler.deduplicated(resolved).count, 3)
    }

    func testMobileDeviceAliasResolutionDoesNotGuessBetweenBatteryCenterDevices() {
        let firstBatteryCenter = makeBatteryItem(
            id: "first-battery-center-phone",
            name: "Shared iPhone",
            level: 65,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .batteryCenter("first-battery-center-phone"),
            source: "BatteryCenter"
        )
        let secondBatteryCenter = makeBatteryItem(
            id: "second-battery-center-phone",
            name: "Shared iPhone",
            level: 64,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .batteryCenter("second-battery-center-phone"),
            source: "BatteryCenter"
        )
        let mobile = makeBatteryItem(
            id: "mobile-phone",
            name: "Shared iPhone",
            level: 66,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .mobileDevice("mobile-phone"),
            source: "MobileDevice"
        )

        let resolved = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(
            [firstBatteryCenter, secondBatteryCenter, mobile]
        )

        XCTAssertEqual(Set(resolved.map(\.deviceIdentity)).count, 3)
        XCTAssertEqual(DeviceBatterySampler.deduplicated(resolved).count, 3)
    }

    func testMobileDeviceAliasResolutionRejectsConflictingModels() {
        let batteryCenter = makeBatteryItem(
            id: "battery-center-phone",
            name: "Shared iPhone",
            level: 65,
            model: "iPhone17,1",
            kind: .phone,
            deviceIdentity: .batteryCenter("battery-center-phone"),
            source: "BatteryCenter"
        )
        let mobile = makeBatteryItem(
            id: "mobile-phone",
            name: "Shared iPhone",
            level: 66,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .mobileDevice("mobile-phone"),
            source: "MobileDevice"
        )

        let resolved = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(
            [batteryCenter, mobile]
        )

        XCTAssertEqual(Set(resolved.map(\.deviceIdentity)).count, 2)
        XCTAssertEqual(DeviceBatterySampler.deduplicated(resolved).count, 2)
    }

    func testMobileDeviceAliasResolutionRequiresModelsFromBothSources() {
        let batteryCenter = makeBatteryItem(
            id: "battery-center-phone",
            name: "Shared iPhone",
            level: 65,
            kind: .phone,
            deviceIdentity: .batteryCenter("battery-center-phone"),
            source: "BatteryCenter"
        )
        let mobile = makeBatteryItem(
            id: "mobile-phone",
            name: "Shared iPhone",
            level: 66,
            model: "iPhone18,1",
            kind: .phone,
            deviceIdentity: .mobileDevice("mobile-phone"),
            source: "MobileDevice"
        )

        let resolved = DeviceBatteryItemNormalizer.resolvingAppleMobileDeviceAliases(
            [batteryCenter, mobile]
        )

        XCTAssertEqual(Set(resolved.map(\.deviceIdentity)).count, 2)
        XCTAssertEqual(DeviceBatterySampler.deduplicated(resolved).count, 2)
    }

    func testAdvertisementOnlyAddsChargingStateToPreciseSystemReading() throws {
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let identity = DeviceBatteryComponentIdentity(groupID: "airpods", role: .left)
        let systemReading = DeviceBatteryItem(
            id: "system-left",
            deviceIdentity: .bluetooth("airpods"),
            name: "AirPods Left",
            model: "AirPods Pro 2",
            kind: .airPodsPart,
            level: 83,
            chargeState: .normal,
            parentName: "AirPods Case",
            source: "system_profiler",
            lastUpdated: olderDate,
            isConnected: true,
            detail: "Headphones",
            componentIdentity: identity
        )
        let advertisementReading = DeviceBatteryItem(
            id: "advertisement-left",
            deviceIdentity: .bluetooth("airpods"),
            name: "AirPods Left",
            model: "AirPods Pro 2",
            kind: .airPodsPart,
            level: 80,
            chargeState: .charging,
            parentName: "AirPods Case",
            source: "AppleHeadphoneAdvertisement",
            lastUpdated: newerDate,
            isConnected: true,
            detail: "Headphones",
            componentIdentity: identity
        )

        for readings in [
            [systemReading, advertisementReading],
            [advertisementReading, systemReading]
        ] {
            let item = try XCTUnwrap(DeviceBatterySampler.deduplicated(readings).first)
            XCTAssertEqual(item.id, "system-left")
            XCTAssertEqual(item.source, "system_profiler")
            XCTAssertEqual(item.level, 83)
            XCTAssertEqual(item.chargeState, .charging)
            XCTAssertEqual(item.lastUpdated, olderDate)
        }
    }

    func testOlderAdvertisementDoesNotOverrideNewerPreciseChargeState() throws {
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let deviceIdentity = DeviceBatteryDeviceIdentity.bluetooth("airpods")
        let componentIdentity = DeviceBatteryComponentIdentity(
            groupID: deviceIdentity.key,
            role: .left
        )
        let advertisementReading = DeviceBatteryItem(
            id: "advertisement-left",
            deviceIdentity: deviceIdentity,
            name: "AirPods Left",
            model: "AirPods Pro 2",
            kind: .airPodsPart,
            level: 80,
            chargeState: .charging,
            parentName: "AirPods Case",
            source: "AppleHeadphoneAdvertisement",
            lastUpdated: olderDate,
            isConnected: true,
            detail: "Headphones",
            componentIdentity: componentIdentity
        )
        let systemReading = DeviceBatteryItem(
            id: "system-left",
            deviceIdentity: deviceIdentity,
            name: "AirPods Left",
            model: "AirPods Pro 2",
            kind: .airPodsPart,
            level: 83,
            chargeState: .normal,
            parentName: "AirPods Case",
            source: "system_profiler",
            lastUpdated: newerDate,
            isConnected: true,
            detail: "Headphones",
            componentIdentity: componentIdentity
        )

        let item = try XCTUnwrap(DeviceBatterySampler.deduplicated([
            advertisementReading,
            systemReading
        ]).first)
        XCTAssertEqual(item.id, "system-left")
        XCTAssertEqual(item.level, 83)
        XCTAssertEqual(item.chargeState, .normal)
        XCTAssertEqual(item.lastUpdated, newerDate)
    }

    func testItemNormalizerKeepsAirPodsAggregateAlongsideChargingCase() {
        let aggregate = makeAirPodsItem(id: "main", role: .aggregate)
        let caseItem = makeAirPodsItem(id: "case", role: .chargingCase)

        XCTAssertEqual(
            DeviceBatteryItemNormalizer.preferringDetailedComponents([aggregate, caseItem]).map(\.id),
            ["main", "case"]
        )
    }

    func testItemNormalizerPrefersIndividualEarbudsOverCombinedReading() {
        let aggregate = makeAirPodsItem(id: "main", role: .aggregate)
        let earbuds = makeAirPodsItem(id: "earbuds", role: .earbuds)
        let left = makeAirPodsItem(id: "left", role: .left)
        let right = makeAirPodsItem(id: "right", role: .right)
        let caseItem = makeAirPodsItem(id: "case", role: .chargingCase)

        XCTAssertEqual(
            DeviceBatteryItemNormalizer.preferringDetailedComponents(
                [aggregate, earbuds, left, right, caseItem]
            ).map(\.id),
            ["left", "right", "case"]
        )
        XCTAssertEqual(
            DeviceBatteryItemNormalizer.preferringDetailedComponents(
                [aggregate, earbuds, caseItem]
            ).map(\.id),
            ["earbuds", "case"]
        )
        XCTAssertEqual(
            DeviceBatteryItemNormalizer.preferringDetailedComponents(
                [aggregate, left, caseItem]
            ).map(\.id),
            ["main", "left", "case"]
        )
        XCTAssertEqual(
            DeviceBatteryItemNormalizer.preferringDetailedComponents([aggregate]).map(\.id),
            ["main"]
        )
    }

    func testItemNormalizerDropsOnlyComponentsForSingleBatteryHeadset() {
        let maxMain = makeBatteryItem(
            id: "max-main",
            name: "AirPods Max",
            level: 48,
            kind: .airPodsPart,
            componentIdentity: DeviceBatteryComponentIdentity(groupID: "max", role: .aggregate)
        )
        let maxCase = makeBatteryItem(
            id: "max-case",
            name: "AirPods Max Case",
            level: 1,
            kind: .airPodsPart,
            parentName: "AirPods Max",
            componentIdentity: DeviceBatteryComponentIdentity(groupID: "max", role: .chargingCase)
        )
        let airPodsCase = makeBatteryItem(
            id: "airpods-case",
            name: "AirPods Case",
            level: 80,
            kind: .airPodsPart,
            parentName: "AirPods",
            componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods", role: .chargingCase)
        )

        XCTAssertEqual(
            DeviceBatteryItemNormalizer.removingComponentItems(
                [maxMain, maxCase, airPodsCase],
                forSingleBatteryDevices: [.bluetooth("max")]
            ).map(\.id),
            ["max-main", "airpods-case"]
        )
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

    func testLowBatteryNotificationDoesNotRepeatWhenSourceIDChanges() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "bluetooth-powerlog-airpods-left",
                    name: "AirPods 左耳",
                    level: 7,
                    kind: .airPodsPart,
                    parentName: "AirPods 充电盒",
                    deviceIdentity: .bluetooth("airpods-address"),
                    componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods-address", role: .left)
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "apple-headphone-advertisement-airpods-left",
                    name: "AirPods 左耳",
                    level: 6,
                    kind: .airPodsPart,
                    parentName: "AirPods 充电盒",
                    deviceIdentity: .bluetooth("airpods-address"),
                    componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods-advertisement", role: .left)
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
    }

    func testLowBatteryNotificationDoesNotRepeatWhenIdentityAndCombinedSlotResolve() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter("AIRPODS-GROUP")

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                DeviceBatteryItem(
                    id: "battery-center-main",
                    deviceIdentity: batteryCenterIdentity,
                    name: "AirPods",
                    model: "AirPods 4",
                    kind: .airPodsPart,
                    level: 8,
                    chargeState: .normal,
                    parentName: nil,
                    source: "BatteryCenter",
                    lastUpdated: Date(),
                    isConnected: true,
                    detail: nil,
                    componentIdentity: DeviceBatteryComponentIdentity(
                        groupID: batteryCenterIdentity.key,
                        role: .aggregate
                    )
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                DeviceBatteryItem(
                    id: "matched-earbuds",
                    deviceIdentity: .bluetooth("11:22:33:44:55:66"),
                    name: "AirPods",
                    model: "AirPods 4",
                    kind: .airPodsPart,
                    level: 7,
                    chargeState: .normal,
                    parentName: nil,
                    source: "BatteryCenter",
                    lastUpdated: Date(),
                    isConnected: true,
                    detail: nil,
                    componentIdentity: DeviceBatteryComponentIdentity(
                        groupID: "bluetooth:11:22:33:44:55:66",
                        role: .earbuds
                    ),
                    alternateDeviceIdentities: [batteryCenterIdentity]
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)

        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")
        let earbudsIdentity = DeviceBatteryComponentIdentity(
            groupID: bluetoothIdentity.key,
            role: .earbuds
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "bluetooth-only-low",
                    name: "AirPods",
                    level: 6,
                    kind: .airPodsPart,
                    deviceIdentity: bluetoothIdentity,
                    componentIdentity: earbudsIdentity
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        XCTAssertEqual(notifier.notifications.count, 1)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "bluetooth-only-recovered",
                    name: "AirPods",
                    level: 30,
                    kind: .airPodsPart,
                    deviceIdentity: bluetoothIdentity,
                    componentIdentity: earbudsIdentity
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "battery-center-low-again",
                    name: "AirPods",
                    level: 5,
                    kind: .airPodsPart,
                    deviceIdentity: batteryCenterIdentity,
                    componentIdentity: DeviceBatteryComponentIdentity(
                        groupID: batteryCenterIdentity.key,
                        role: .aggregate
                    )
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        XCTAssertEqual(notifier.notifications.count, 2)
    }

    func testLowBatteryNotificationDoesNotResetWhenDeviceTemporarilyMissing() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let lowSnapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 8)
        ])

        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: []),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
    }

    func testLowBatteryNotificationResetsAfterDeviceIsCharged() {
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
            snapshot: makeSnapshot(items: [
                makeBatteryItem(id: "mouse", name: "Mouse", level: 100, chargeState: .charged)
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

    private func makeContext() -> PluginRuntimeContext {
        PluginRuntimeContext(pluginID: "device-battery", storage: DeviceBatteryMemoryStorage())
    }

    private func makeSnapshot(items: [DeviceBatteryItem]) -> DeviceBatterySnapshot {
        DeviceBatterySnapshot(
            accessState: .ready,
            items: items,
            lastUpdated: Date(),
            rapooState: .idle
        )
    }

    private func makeAirPodsItem(id: String, role: DeviceBatteryComponentRole) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: id,
            deviceIdentity: .bluetooth("airpods"),
            name: id,
            model: "AirPods 4",
            kind: .airPodsPart,
            level: 80,
            chargeState: .normal,
            parentName: nil,
            source: "test",
            lastUpdated: Date(),
            isConnected: true,
            detail: "Headphones",
            componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods", role: role)
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

    private func makeMobileRecord(
        level: Int,
        chargeState: DeviceBatteryChargeState
    ) -> DeviceBatteryMobileDeviceRecord {
        DeviceBatteryMobileDeviceRecord(
            identifier: "phone-id",
            name: "Test iPhone",
            productType: "iPhone18,1",
            category: .phone,
            level: level,
            chargeState: chargeState,
            connectionType: "Wi-Fi",
            parentName: nil
        )
    }

}

private final class MobileReadResultSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [DeviceBatteryMobileDeviceReadResult]

    init(_ results: [DeviceBatteryMobileDeviceReadResult]) {
        self.results = results
    }

    func next() -> DeviceBatteryMobileDeviceReadResult {
        lock.withLock {
            guard !results.isEmpty else {
                return DeviceBatteryMobileDeviceReadResult(
                    records: [],
                    didEnumerateDevices: true,
                    connectedDeviceCount: 0,
                    failedDeviceCount: 0
                )
            }
            return results.removeFirst()
        }
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

private struct StubDeviceBatterySampler: DeviceBatterySampling {
    let items: [DeviceBatteryItem]

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        items.filter { $0.kind == .internalBattery }
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        items.filter {
            switch $0.kind {
            case .bluetooth, .magicAccessory, .airPodsPart, .other:
                true
            default:
                false
            }
        }
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        items
            .filter {
                switch $0.kind {
                case .phone, .tablet, .mediaPlayer, .watch, .spatialComputer:
                    true
                default:
                    false
                }
            }
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

@MainActor
private final class StubRapooBatteryMonitor: RapooBatteryMonitoring {
    var snapshot = RapooMouseBatterySnapshot.idle
    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)?

    func start() {}
    func stop() {}
    func refresh() {}
}

private extension Array where Element == UInt8 {
    func setting(_ value: UInt8, at index: Int) -> [UInt8] {
        var copy = self
        copy[index] = value
        return copy
    }
}
