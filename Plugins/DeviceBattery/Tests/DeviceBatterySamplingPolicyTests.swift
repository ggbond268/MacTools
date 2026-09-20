import XCTest
@testable import DeviceBatteryPlugin

final class DeviceBatterySamplingPolicyTests: XCTestCase {
    func testIncrementalLogWindowIsCappedAfterLongSleep() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let arguments = DeviceBatterySampler.logWindowArguments(
            startDate: referenceDate.addingTimeInterval(-4 * 60 * 60),
            fallbackLookback: "5m",
            referenceDate: referenceDate
        )

        XCTAssertEqual(arguments.first, "--start")
        XCTAssertEqual(
            parseLogDate(arguments[1]),
            referenceDate.addingTimeInterval(-10 * 60)
        )
    }

    func testIncrementalLogWindowKeepsRecentCursor() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let startDate = referenceDate.addingTimeInterval(-90)
        let arguments = DeviceBatterySampler.logWindowArguments(
            startDate: startDate,
            fallbackLookback: "5m",
            referenceDate: referenceDate
        )

        XCTAssertEqual(parseLogDate(arguments[1]), startDate)
    }

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

    func testDisconnectedAppleHeadphonesDoNotCreateActiveScanTargets() {
        let disconnectedAirPods = makeBluetoothTarget(
            id: "disconnected-airpods",
            kind: .airPodsPart,
            isConnected: false
        )

        let plan = DeviceBatteryBluetoothScanPlan(targets: [disconnectedAirPods])

        XCTAssertTrue(plan.eligibleTargets.isEmpty)
        XCTAssertTrue(plan.advertisementTargetIDs.isEmpty)
        XCTAssertFalse(DeviceBatterySampler.needsBluetoothPowerLogFallback(
            target: disconnectedAirPods,
            existingItems: []
        ))
    }

    func testConnectedAppleHeadphonesRemainAdvertisementScanTargets() {
        let connectedAirPods = makeBluetoothTarget(
            id: "connected-airpods",
            kind: .airPodsPart,
            isConnected: true
        )

        let plan = DeviceBatteryBluetoothScanPlan(targets: [connectedAirPods])

        XCTAssertEqual(plan.eligibleTargets.map(\.id), ["connected-airpods"])
        XCTAssertEqual(plan.advertisementTargetIDs, ["connected-airpods"])
        XCTAssertTrue(DeviceBatterySampler.needsBluetoothPowerLogFallback(
            target: connectedAirPods,
            existingItems: []
        ))
    }

    func testDisconnectedRecordWithSameIDDoesNotReenterScanPlan() {
        let connectedAirPods = makeBluetoothTarget(
            id: "shared-airpods",
            kind: .airPodsPart,
            isConnected: true
        )
        let disconnectedAirPods = makeBluetoothTarget(
            id: "shared-airpods",
            kind: .airPodsPart,
            isConnected: false
        )

        let plan = DeviceBatteryBluetoothScanPlan(
            targets: [disconnectedAirPods, connectedAirPods]
        )

        XCTAssertEqual(plan.eligibleTargets.count, 1)
        XCTAssertTrue(plan.eligibleTargets[0].isConnected)
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

    func testConnectionRefreshScansOnlyNewlyConnectedDevices() {
        let existing = makeBluetoothTarget(id: "existing", kind: .bluetooth, isConnected: true)
        let disconnected = makeBluetoothTarget(id: "disconnected", kind: .bluetooth, isConnected: false)
        let added = makeBluetoothTarget(id: "added", kind: .bluetooth, isConnected: true)
        let targets = [existing, disconnected, added]

        XCTAssertEqual(DeviceBatteryBluetoothScanScope.newlyConnected.targets(
            from: targets, previouslyConnected: [existing.deviceIdentity, disconnected.deviceIdentity]
        ).map(\.id), [added.id])
        XCTAssertTrue(DeviceBatteryBluetoothScanScope.newlyConnected.targets(
            from: targets, previouslyConnected: [existing.deviceIdentity, added.deviceIdentity]
        ).isEmpty)
        XCTAssertEqual(DeviceBatteryBluetoothScanScope.allConnected.targets(
            from: targets, previouslyConnected: [existing.deviceIdentity, added.deviceIdentity]
        ).map(\.id), [existing.id, added.id])
        XCTAssertTrue(DeviceBatteryBluetoothScanScope.none.targets(
            from: targets, previouslyConnected: []
        ).isEmpty)
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

    func testGattReaderDoesNotCollapseMultipleBatteryServices() {
        XCTAssertTrue(
            DeviceBatteryGATTBatteryPolicy.canRepresentBatteryServiceInstanceCount(1)
        )
        XCTAssertFalse(
            DeviceBatteryGATTBatteryPolicy.canRepresentBatteryServiceInstanceCount(2)
        )
    }

    func testBluetoothPowerLogQueryAvoidsRedundantProcessFilter() {
        let arguments = DeviceBatterySampler.bluetoothPowerLogCommandArguments(
            targets: [],
            startDate: nil,
            lookback: "5m"
        )

        XCTAssertFalse(arguments.contains("--process"))
        XCTAssertFalse(arguments.contains("bluetoothd"))
        XCTAssertTrue(arguments.contains("--predicate"))
    }

    func testAdvertisementNamesResolveOneUnambiguousTarget() {
        let genericTarget = BluetoothBatteryTarget(
            id: "generic",
            name: "AirPods",
            address: "11:11:11:11:11:11",
            vendorID: "0x004C",
            productID: "0x201B",
            model: "AirPods 4",
            kind: .airPodsPart,
            detail: "Headphones",
            isConnected: true
        )
        let customTarget = BluetoothBatteryTarget(
            id: "custom",
            name: "My AirPods",
            address: "22:22:22:22:22:22",
            vendorID: "0x004C",
            productID: "0x201B",
            model: "AirPods 4",
            kind: .airPodsPart,
            detail: "Headphones",
            isConnected: true
        )
        let targets = [genericTarget, customTarget]
        let eligibleTargetIDs: Set<String> = [genericTarget.id, customTarget.id]

        XCTAssertNil(DeviceBatteryBluetoothScanPolicy.advertisementTarget(
            localName: genericTarget.name,
            peripheralName: customTarget.name,
            productID: 0x201B,
            targets: targets,
            eligibleTargetIDs: eligibleTargetIDs
        ))
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.advertisementTarget(
            localName: "Unknown Local Name",
            peripheralName: customTarget.name,
            productID: 0x201B,
            targets: targets,
            eligibleTargetIDs: eligibleTargetIDs
        )?.id, customTarget.id)
        XCTAssertEqual(DeviceBatteryBluetoothScanPolicy.advertisementTarget(
            localName: customTarget.name,
            peripheralName: nil,
            productID: 0x201B,
            targets: targets,
            eligibleTargetIDs: eligibleTargetIDs
        )?.id, customTarget.id)
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

    func testSupplementalCacheUsesSourceSpecificFreshnessWindows() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        var batteryCenterCache = DeviceBatterySupplementalItemCache()
        var powerLogCache = DeviceBatterySupplementalItemCache()
        batteryCenterCache.update(
            with: [makeSupplementalItem(
                id: "battery-center",
                identity: identity,
                role: .aggregate,
                level: 50,
                referenceDate: referenceDate,
                source: "BatteryCenter"
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: referenceDate
        )
        powerLogCache.update(
            with: [makeSupplementalItem(
                id: "power-log",
                identity: identity,
                role: .aggregate,
                level: 50,
                referenceDate: referenceDate,
                source: "BluetoothPowerLog"
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: referenceDate
        )

        let laterDate = referenceDate.addingTimeInterval(121)
        batteryCenterCache.update(
            with: [],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: laterDate
        )
        powerLogCache.update(
            with: [],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: laterDate
        )

        XCTAssertTrue(batteryCenterCache.items.isEmpty)
        XCTAssertEqual(try XCTUnwrap(powerLogCache.items.first).id, "power-log")
    }

    func testSupplementalCacheLetsFreshNormalReadingReplaceExpiredChargingReading() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        var cache = DeviceBatterySupplementalItemCache(itemLifetime: 60)
        cache.update(
            with: [makeSupplementalItem(
                id: "old-charging",
                identity: identity,
                role: .aggregate,
                level: 50,
                referenceDate: referenceDate,
                chargeState: .charging
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: referenceDate
        )
        let freshDate = referenceDate.addingTimeInterval(61)
        cache.update(
            with: [makeSupplementalItem(
                id: "fresh-normal",
                identity: identity,
                role: .aggregate,
                level: 49,
                referenceDate: freshDate
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: freshDate
        )

        let item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(cache.items.count, 1)
        XCTAssertEqual(item.id, "fresh-normal")
        XCTAssertEqual(item.chargeState, .normal)
        XCTAssertEqual(item.lastUpdated, freshDate)
    }

    func testSupplementalCacheUsesNewerReadingFromSameSourceWithinLifetime() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "old-charging",
                identity: identity,
                role: .aggregate,
                level: 50,
                referenceDate: referenceDate,
                chargeState: .charging
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: referenceDate
        )
        let freshDate = referenceDate.addingTimeInterval(1)
        cache.update(
            with: [makeSupplementalItem(
                id: "fresh-normal",
                identity: identity,
                role: .aggregate,
                level: 49,
                referenceDate: freshDate
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: freshDate
        )

        let item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(item.id, "fresh-normal")
        XCTAssertEqual(item.level, 49)
        XCTAssertEqual(item.chargeState, .normal)
        XCTAssertEqual(item.lastUpdated, freshDate)
    }

    func testSupplementalCachePrefersCombinedEarbudsOverAggregateAtSameTime() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        let aggregate = makeSupplementalItem(
            id: "a-aggregate",
            identity: identity,
            role: .aggregate,
            level: 50,
            referenceDate: referenceDate
        )
        let earbuds = makeSupplementalItem(
            id: "z-earbuds",
            identity: identity,
            role: .earbuds,
            level: 49,
            referenceDate: referenceDate
        )

        for readings in [[aggregate, earbuds], [earbuds, aggregate]] {
            var cache = DeviceBatterySupplementalItemCache()
            cache.update(
                with: readings,
                knownTargetIdentities: [identity],
                connectedTargetIdentities: [identity],
                referenceDate: referenceDate
            )

            let item = try XCTUnwrap(cache.items.first)
            XCTAssertEqual(cache.items.count, 1)
            XCTAssertEqual(item.id, "z-earbuds")
            XCTAssertEqual(item.batterySlot, .earbuds)
            XCTAssertEqual(item.level, 49)
        }
    }

    func testSupplementalCacheRefreshesAdvertisementLevelAndChargingState() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "old-advertisement",
                identity: identity,
                role: .left,
                level: 50,
                referenceDate: referenceDate,
                source: "AppleHeadphoneAdvertisement"
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: referenceDate
        )
        let freshDate = referenceDate.addingTimeInterval(1)
        cache.update(
            with: [makeSupplementalItem(
                id: "fresh-advertisement",
                identity: identity,
                role: .left,
                level: 40,
                referenceDate: freshDate,
                source: "AppleHeadphoneAdvertisement",
                chargeState: .charging
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: freshDate
        )

        let item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(item.id, "fresh-advertisement")
        XCTAssertEqual(item.level, 40)
        XCTAssertEqual(item.chargeState, .charging)
        XCTAssertEqual(item.lastUpdated, freshDate)
    }

    func testAdvertisementDoesNotRenewOlderPreciseReading() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        var cache = DeviceBatterySupplementalItemCache(itemLifetime: 60)
        cache.update(
            with: [makeSupplementalItem(
                id: "precise-reading",
                identity: identity,
                role: .left,
                level: 80,
                referenceDate: referenceDate,
                chargeState: .charging
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: referenceDate
        )

        let firstAdvertisementDate = referenceDate.addingTimeInterval(30)
        cache.update(
            with: [makeSupplementalItem(
                id: "first-advertisement",
                identity: identity,
                role: .left,
                level: 50,
                referenceDate: firstAdvertisementDate,
                source: "AppleHeadphoneAdvertisement"
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: firstAdvertisementDate
        )

        var item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(item.level, 80)
        XCTAssertEqual(item.chargeState, .normal)
        XCTAssertEqual(item.lastUpdated, referenceDate)

        let preciseReadingExpiryDate = referenceDate.addingTimeInterval(61)
        cache.update(
            with: [],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: preciseReadingExpiryDate
        )

        item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(item.id, "first-advertisement")
        XCTAssertEqual(item.level, 50)
        XCTAssertEqual(item.lastUpdated, firstAdvertisementDate)

        let secondAdvertisementDate = referenceDate.addingTimeInterval(62)
        cache.update(
            with: [makeSupplementalItem(
                id: "second-advertisement",
                identity: identity,
                role: .left,
                level: 40,
                referenceDate: secondAdvertisementDate,
                source: "AppleHeadphoneAdvertisement"
            )],
            knownTargetIdentities: [identity],
            connectedTargetIdentities: [identity],
            referenceDate: secondAdvertisementDate
        )

        item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(item.id, "second-advertisement")
        XCTAssertEqual(item.level, 40)
        XCTAssertEqual(item.lastUpdated, secondAdvertisementDate)
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

    func testEqualPriorityReductionUsesStableTieBreakers() throws {
        let identity = DeviceBatteryDeviceIdentity.bluetooth("headphones")
        let referenceDate = Date(timeIntervalSince1970: 20)
        let ioRegistry = makeSupplementalItem(
            id: "shared-id",
            identity: identity,
            role: .aggregate,
            level: 60,
            referenceDate: referenceDate,
            source: "IORegistry"
        )
        let powerSources = makeSupplementalItem(
            id: "shared-id",
            identity: identity,
            role: .aggregate,
            level: 70,
            referenceDate: referenceDate,
            source: "IOPowerSources"
        )
        for readings in [[ioRegistry, powerSources], [powerSources, ioRegistry]] {
            let item = try XCTUnwrap(DeviceBatterySampler.deduplicated(readings).first)
            XCTAssertEqual(item.source, "IOPowerSources")
            XCTAssertEqual(item.level, 70)
        }

        let firstPayload = makeSupplementalItem(
            id: "same-source-id",
            identity: identity,
            role: .aggregate,
            level: 40,
            referenceDate: referenceDate
        )
        let secondPayload = makeSupplementalItem(
            id: "same-source-id",
            identity: identity,
            role: .aggregate,
            level: 50,
            referenceDate: referenceDate
        )
        let resolvedLevels = try [
            [firstPayload, secondPayload],
            [secondPayload, firstPayload]
        ].map { readings in
            try XCTUnwrap(
                XCTUnwrap(DeviceBatterySampler.deduplicated(readings).first).level
            )
        }
        XCTAssertEqual(Set(resolvedLevels), [40])
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

    func testSupplementalCacheDropsTargetRemovedFromProfile() {
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
            knownTargetIdentities: [],
            connectedTargetIdentities: [],
            referenceDate: referenceDate
        )

        XCTAssertTrue(cache.items.isEmpty)
    }

    func testSupplementalCacheMigratesBatteryCenterIdentityToMatchedTarget() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter("AIRPODS-GROUP")
        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")
        var cache = DeviceBatterySupplementalItemCache()
        let unmatched = DeviceBatteryItem(
            id: "unmatched-main",
            deviceIdentity: batteryCenterIdentity,
            name: "AirPods",
            model: "AirPods 4",
            kind: .airPodsPart,
            level: 50,
            chargeState: .normal,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: batteryCenterIdentity.key,
                role: .aggregate
            )
        )
        let matched = DeviceBatteryItem(
            id: "matched-earbuds",
            deviceIdentity: bluetoothIdentity,
            name: "AirPods",
            model: "AirPods 4",
            kind: .airPodsPart,
            level: 49,
            chargeState: .normal,
            parentName: nil,
            source: "BatteryCenter",
            lastUpdated: referenceDate.addingTimeInterval(1),
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: bluetoothIdentity.key,
                role: .earbuds
            ),
            alternateDeviceIdentities: [batteryCenterIdentity]
        )

        cache.update(
            with: [unmatched],
            knownTargetIdentities: [],
            connectedTargetIdentities: [],
            referenceDate: referenceDate
        )
        cache.update(
            with: [matched],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )

        let item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(cache.items.count, 1)
        XCTAssertEqual(item.deviceIdentity, bluetoothIdentity)
        XCTAssertEqual(item.batterySlot, .earbuds)
    }

    func testSupplementalCacheAliasMigrationIsIndependentOfBatchOrder() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter("AIRPODS-GROUP")
        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")
        let unmatched = makeSupplementalItem(
            id: "unmatched-main",
            identity: batteryCenterIdentity,
            role: .aggregate,
            level: 50,
            referenceDate: referenceDate
        )
        let matched = makeSupplementalItem(
            id: "matched-earbuds",
            identity: bluetoothIdentity,
            role: .earbuds,
            level: 49,
            referenceDate: referenceDate,
            alternateIdentities: [batteryCenterIdentity]
        )

        for batch in [[unmatched, matched], [matched, unmatched]] {
            var cache = DeviceBatterySupplementalItemCache()
            cache.update(
                with: batch,
                knownTargetIdentities: [bluetoothIdentity],
                connectedTargetIdentities: [bluetoothIdentity],
                referenceDate: referenceDate
            )

            let item = try XCTUnwrap(cache.items.first)
            XCTAssertEqual(cache.items.count, 1)
            XCTAssertEqual(item.deviceIdentity, bluetoothIdentity)
            XCTAssertEqual(item.batterySlot, .earbuds)
            XCTAssertEqual(item.id, "matched-earbuds")
        }
    }

    func testSupplementalCacheKeepsCanonicalAliasWhenReadingBecomesUnmatched() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter("AIRPODS-GROUP")
        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "matched",
                identity: bluetoothIdentity,
                role: .earbuds,
                level: 50,
                referenceDate: referenceDate,
                alternateIdentities: [batteryCenterIdentity]
            )],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate
        )
        cache.update(
            with: [makeSupplementalItem(
                id: "temporarily-unmatched",
                identity: batteryCenterIdentity,
                role: .aggregate,
                level: 48,
                referenceDate: referenceDate.addingTimeInterval(1)
            )],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )

        let item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(cache.items.count, 1)
        XCTAssertEqual(item.deviceIdentity, bluetoothIdentity)
        XCTAssertTrue(item.alternateDeviceIdentities.contains(batteryCenterIdentity))
    }

    func testSupplementalCachePreservesAliasWhenCanonicalReadingOverwritesSlot() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter("AIRPODS-GROUP")
        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "matched",
                identity: bluetoothIdentity,
                role: .earbuds,
                level: 50,
                referenceDate: referenceDate,
                alternateIdentities: [batteryCenterIdentity]
            )],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate
        )
        cache.update(
            with: [makeSupplementalItem(
                id: "canonical-refresh",
                identity: bluetoothIdentity,
                role: .aggregate,
                level: 49,
                referenceDate: referenceDate.addingTimeInterval(1),
                source: "CoreBluetooth"
            )],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )
        cache.update(
            with: [makeSupplementalItem(
                id: "unmatched-refresh",
                identity: batteryCenterIdentity,
                role: .earbuds,
                level: 48,
                referenceDate: referenceDate.addingTimeInterval(2)
            )],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate.addingTimeInterval(2)
        )

        let item = try XCTUnwrap(cache.items.first)
        XCTAssertEqual(cache.items.count, 1)
        XCTAssertEqual(item.deviceIdentity, bluetoothIdentity)
        XCTAssertTrue(item.alternateDeviceIdentities.contains(batteryCenterIdentity))
    }

    func testSupplementalCacheMovesAllSlotsWhenCanonicalIdentityChanges() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceIdentity = DeviceBatteryDeviceIdentity.batteryCenter("AIRPODS-GROUP")
        let oldIdentity = DeviceBatteryDeviceIdentity.bluetooth("OLD-ADDRESS")
        let newIdentity = DeviceBatteryDeviceIdentity.bluetooth("NEW-ADDRESS")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [
                makeSupplementalItem(
                    id: "old-earbuds",
                    identity: oldIdentity,
                    role: .earbuds,
                    level: 50,
                    referenceDate: referenceDate,
                    alternateIdentities: [sourceIdentity]
                ),
                makeSupplementalItem(
                    id: "old-case",
                    identity: oldIdentity,
                    role: .chargingCase,
                    level: 80,
                    referenceDate: referenceDate,
                    alternateIdentities: [sourceIdentity]
                )
            ],
            knownTargetIdentities: [oldIdentity],
            connectedTargetIdentities: [oldIdentity],
            referenceDate: referenceDate
        )
        cache.update(
            with: [makeSupplementalItem(
                id: "new-earbuds",
                identity: newIdentity,
                role: .earbuds,
                level: 49,
                referenceDate: referenceDate.addingTimeInterval(1),
                alternateIdentities: [sourceIdentity]
            )],
            knownTargetIdentities: [newIdentity],
            connectedTargetIdentities: [newIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )

        XCTAssertEqual(cache.items.count, 2)
        XCTAssertEqual(Set(cache.items.map(\.deviceIdentity)), [newIdentity])
        XCTAssertEqual(Set(cache.items.map(\.batterySlot)), [.earbuds, .chargingCase])
    }

    func testSupplementalCacheMigratesOldPartsBeforeSingleBatteryFiltering() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceIdentity = DeviceBatteryDeviceIdentity.batteryCenter("HEADSET-GROUP")
        let bluetoothIdentity = DeviceBatteryDeviceIdentity.bluetooth("11:22:33:44:55:66")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "unmatched-case",
                identity: sourceIdentity,
                role: .chargingCase,
                level: 5,
                referenceDate: referenceDate
            )],
            knownTargetIdentities: [],
            connectedTargetIdentities: [],
            referenceDate: referenceDate
        )
        cache.update(
            with: [makeSupplementalItem(
                id: "matched-headset",
                identity: bluetoothIdentity,
                role: .aggregate,
                level: 55,
                referenceDate: referenceDate.addingTimeInterval(1),
                alternateIdentities: [sourceIdentity]
            )],
            knownTargetIdentities: [bluetoothIdentity],
            connectedTargetIdentities: [bluetoothIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )

        XCTAssertEqual(Set(cache.items.map(\.deviceIdentity)), [bluetoothIdentity])
        let filtered = DeviceBatteryItemNormalizer.removingComponentItems(
            cache.items,
            forSingleBatteryDevices: [bluetoothIdentity]
        )
        let item = try XCTUnwrap(filtered.first)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(item.batterySlot, .aggregate)
    }

    func testSupplementalCacheDoesNotPersistWeakBatteryCenterFallback() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let weakIdentity = DeviceBatteryDeviceIdentity.source(
            "batterycenter:test-airpods|201B"
        )
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "weak-reading",
                identity: weakIdentity,
                role: .aggregate,
                level: 50,
                referenceDate: referenceDate
            )],
            knownTargetIdentities: [],
            connectedTargetIdentities: [],
            referenceDate: referenceDate
        )
        XCTAssertEqual(cache.items.count, 1)

        cache.update(
            with: [],
            knownTargetIdentities: [],
            connectedTargetIdentities: [],
            referenceDate: referenceDate.addingTimeInterval(1)
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

    func testSupplementalCacheDropsUnmatchedPrimaryWhenAliasBecomesAmbiguous() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sharedAlias = DeviceBatteryDeviceIdentity.batteryCenter("SHARED-GROUP")
        let firstIdentity = DeviceBatteryDeviceIdentity.bluetooth("FIRST-ADDRESS")
        let secondIdentity = DeviceBatteryDeviceIdentity.bluetooth("SECOND-ADDRESS")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "unmatched",
                identity: sharedAlias,
                role: .aggregate,
                level: 55,
                referenceDate: referenceDate
            )],
            knownTargetIdentities: [],
            connectedTargetIdentities: [],
            referenceDate: referenceDate
        )
        cache.update(
            with: [
                makeSupplementalItem(
                    id: "first-target",
                    identity: firstIdentity,
                    role: .aggregate,
                    level: 50,
                    referenceDate: referenceDate.addingTimeInterval(1),
                    alternateIdentities: [sharedAlias]
                ),
                makeSupplementalItem(
                    id: "second-target",
                    identity: secondIdentity,
                    role: .aggregate,
                    level: 60,
                    referenceDate: referenceDate.addingTimeInterval(1),
                    alternateIdentities: [sharedAlias]
                )
            ],
            knownTargetIdentities: [firstIdentity, secondIdentity],
            connectedTargetIdentities: [firstIdentity, secondIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )

        XCTAssertEqual(cache.items.count, 2)
        XCTAssertEqual(
            Set(cache.items.map(\.deviceIdentity)),
            [firstIdentity, secondIdentity]
        )
    }

    func testSupplementalCacheResolvesUniqueOwnerAfterRemovingSharedAlias() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sharedAlias = DeviceBatteryDeviceIdentity.batteryCenter("SHARED-GROUP")
        let oldIdentity = DeviceBatteryDeviceIdentity.bluetooth("OLD-ADDRESS")
        let firstIdentity = DeviceBatteryDeviceIdentity.bluetooth("FIRST-ADDRESS")
        let secondIdentity = DeviceBatteryDeviceIdentity.bluetooth("SECOND-ADDRESS")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeSupplementalItem(
                id: "old-target",
                identity: oldIdentity,
                role: .chargingCase,
                level: 80,
                referenceDate: referenceDate,
                alternateIdentities: [firstIdentity, sharedAlias]
            )],
            knownTargetIdentities: [oldIdentity],
            connectedTargetIdentities: [oldIdentity],
            referenceDate: referenceDate
        )
        cache.update(
            with: [
                makeSupplementalItem(
                    id: "first-target",
                    identity: firstIdentity,
                    role: .earbuds,
                    level: 50,
                    referenceDate: referenceDate.addingTimeInterval(1),
                    alternateIdentities: [sharedAlias]
                ),
                makeSupplementalItem(
                    id: "second-target",
                    identity: secondIdentity,
                    role: .earbuds,
                    level: 60,
                    referenceDate: referenceDate.addingTimeInterval(1),
                    alternateIdentities: [sharedAlias]
                )
            ],
            knownTargetIdentities: [firstIdentity, secondIdentity],
            connectedTargetIdentities: [firstIdentity, secondIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )

        XCTAssertEqual(cache.items.count, 3)
        XCTAssertEqual(
            Set(cache.items.map(\.deviceIdentity)),
            [firstIdentity, secondIdentity]
        )
        XCTAssertEqual(
            cache.items.filter { $0.deviceIdentity == firstIdentity }.map(\.batterySlot).sorted {
                $0.rawValue < $1.rawValue
            },
            [.chargingCase, .earbuds]
        )
        XCTAssertTrue(cache.items.allSatisfy {
            !$0.alternateDeviceIdentities.contains(sharedAlias)
        })
    }

    func testSupplementalCacheDropsUnanchoredBridgeBetweenKnownTargets() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let firstAlias = DeviceBatteryDeviceIdentity.batteryCenter("FIRST-GROUP")
        let secondAlias = DeviceBatteryDeviceIdentity.batteryCenter("SECOND-GROUP")
        let bridgeIdentity = DeviceBatteryDeviceIdentity.batteryCenter("BRIDGE")
        let firstIdentity = DeviceBatteryDeviceIdentity.bluetooth("FIRST-ADDRESS")
        let secondIdentity = DeviceBatteryDeviceIdentity.bluetooth("SECOND-ADDRESS")
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [
                makeSupplementalItem(
                    id: "first-target",
                    identity: firstIdentity,
                    role: .aggregate,
                    level: 50,
                    referenceDate: referenceDate,
                    alternateIdentities: [firstAlias]
                ),
                makeSupplementalItem(
                    id: "bridge",
                    identity: bridgeIdentity,
                    role: .aggregate,
                    level: 55,
                    referenceDate: referenceDate,
                    alternateIdentities: [firstAlias, secondAlias]
                ),
                makeSupplementalItem(
                    id: "second-target",
                    identity: secondIdentity,
                    role: .aggregate,
                    level: 60,
                    referenceDate: referenceDate,
                    alternateIdentities: [secondAlias]
                )
            ],
            knownTargetIdentities: [firstIdentity, secondIdentity],
            connectedTargetIdentities: [firstIdentity, secondIdentity],
            referenceDate: referenceDate
        )

        XCTAssertEqual(cache.items.count, 2)
        XCTAssertEqual(
            Set(cache.items.map(\.deviceIdentity)),
            [firstIdentity, secondIdentity]
        )

        cache.update(
            with: [],
            knownTargetIdentities: [secondIdentity],
            connectedTargetIdentities: [secondIdentity],
            referenceDate: referenceDate.addingTimeInterval(1)
        )
        XCTAssertEqual(cache.items.count, 1)
        XCTAssertEqual(cache.items.first?.deviceIdentity, secondIdentity)
    }

    private func parseLogDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
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

    private func makeBluetoothTarget(
        id: String,
        kind: DeviceBatteryKind,
        isConnected: Bool
    ) -> BluetoothBatteryTarget {
        BluetoothBatteryTarget(
            id: id,
            name: "Test AirPods 4",
            address: "00:11:22:33:44:55",
            vendorID: "0x004C",
            productID: "0x201B",
            model: "AirPods 4",
            kind: kind,
            detail: "Headphones",
            isConnected: isConnected,
            deviceIdentity: .source("test:\(id)")
        )
    }

    // MARK: - JBL ExcelPoint Regression Tests

    func testJBLSenseLiteIsDetectedByParser() {
        XCTAssertTrue(JBLSenseLiteBLEBatteryParser.isJBLEarbuds("JBL Sense Lite"))
        XCTAssertTrue(JBLSenseLiteBLEBatteryParser.isJBLEarbuds("JBL Sense Lite-LE"))
        XCTAssertTrue(JBLSenseLiteBLEBatteryParser.isJBLEarbuds("jbl tour pro 2"))
        XCTAssertFalse(JBLSenseLiteBLEBatteryParser.isJBLEarbuds("AirPods Pro"))
        XCTAssertFalse(JBLSenseLiteBLEBatteryParser.isJBLEarbuds("Sony WH-1000XM5"))
    }

    func testJBLSenseLiteScanPlanIncludesConnectedTarget() {
        let kind = DeviceBatterySampler.inferredBluetoothKind(
            name: "JBL Sense Lite", minorType: "Headset", vendorID: nil, field: "single"
        )
        let jblTarget = BluetoothBatteryTarget(
            id: "bluetooth:jbl",
            name: "JBL Sense Lite",
            address: "38:D5:18:8C:59:19",
            vendorID: nil,
            productID: nil,
            model: nil,
            kind: kind,
            detail: "Headset",
            isConnected: true
        )

        let plan = DeviceBatteryBluetoothScanPlan(targets: [jblTarget])

        XCTAssertEqual(plan.eligibleTargets.map(\.id), ["bluetooth:jbl"])
        XCTAssertEqual(plan.gattTargetIDs, ["bluetooth:jbl"])
        XCTAssertEqual(plan.jblTargetIDs, ["bluetooth:jbl"])
    }

    func testJBLDisconnectedTargetIsNotEligible() {
        let jblTarget = BluetoothBatteryTarget(
            id: "bluetooth:jbl",
            name: "JBL Sense Lite",
            address: "38:D5:18:8C:59:19",
            vendorID: nil,
            productID: nil,
            model: nil,
            kind: .bluetooth,
            detail: "Headset",
            isConnected: false
        )

        let plan = DeviceBatteryBluetoothScanPlan(targets: [jblTarget])

        XCTAssertTrue(plan.eligibleTargets.isEmpty)
        XCTAssertTrue(plan.gattTargetIDs.isEmpty)
    }

    func testEmptyScanPlanHasNoEligibleTargets() {
        let plan = DeviceBatteryBluetoothScanPlan(targets: [])

        XCTAssertTrue(plan.eligibleTargets.isEmpty)
        XCTAssertTrue(plan.advertisementTargetIDs.isEmpty)
        XCTAssertTrue(plan.gattTargetIDs.isEmpty)
    }

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

    func testJBLSensorParserClampsOutOfRangeValues() {
        // Packet with left=228 (out of range), right=100, case=52
        let bytes: [UInt8] = [
            0x00, 0xDD, 0x03, 0x00, 0x01, 0x00,
            0x2F, 0x00, 0x00, 0x00,
            0x0C, 0x00, 0x03, 0x00, 0x1A, 0x04, 0x0A, 0x00,
            0x10, 0x01, 0x00, 0x80, 0x12, 0x00, 0x02, 0x00,
            0x08, 0x87,
            0x0D, 0x00, 0x01, 0x00, 0xE4, // left: 228 (invalid)
            0x0E, 0x00, 0x01, 0x00, 0x64, // right: 100
            0x03, 0x1F, 0x01, 0x00, 0x34, // case: 52
            0x34, 0x00, 0x01, 0x00, 0xFF,
            0x01, 0x1F, 0x03, 0x00, 0x19, 0x0A, 0x0A
        ]
        let data = Data(bytes)

        let reading = JBLSenseLiteBLEBatteryParser.parseBatteryNotification(data)

        XCTAssertNotNil(reading)
        XCTAssertNil(reading?.leftBattery) // clamped: 228 not in 0...100
        XCTAssertEqual(reading?.rightBattery, 100)
        XCTAssertEqual(reading?.caseBattery, 52)
    }

    func testDeduplicationPrefersComponentReadingsOverAggregate() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("38:D5:18:8C:59:19")

        // Aggregate from system_profiler
        let aggregate = DeviceBatteryItem(
            id: "system_profiler-jbl",
            deviceIdentity: identity,
            name: "JBL Sense Lite",
            model: nil,
            kind: .bluetooth,
            level: 100,
            chargeState: .unknown,
            parentName: nil,
            source: "system_profiler",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: "Headset",
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .aggregate
            )
        )

        // Left ear from ExcelPoint
        let left = DeviceBatteryItem(
            id: "jbl-uuid-left",
            deviceIdentity: identity,
            name: "JBL Sense Lite-LE 左耳",
            model: nil,
            kind: .bluetooth,
            level: 100,
            chargeState: .unknown,
            parentName: "JBL Sense Lite-LE",
            source: "JBLExcelPoint",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .left
            )
        )

        // Right ear from ExcelPoint
        let right = DeviceBatteryItem(
            id: "jbl-uuid-right",
            deviceIdentity: identity,
            name: "JBL Sense Lite-LE 右耳",
            model: nil,
            kind: .bluetooth,
            level: 100,
            chargeState: .unknown,
            parentName: "JBL Sense Lite-LE",
            source: "JBLExcelPoint",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .right
            )
        )

        // Case from ExcelPoint
        let caseItem = DeviceBatteryItem(
            id: "jbl-uuid-case",
            deviceIdentity: identity,
            name: "JBL Sense Lite-LE 充电盒",
            model: nil,
            kind: .bluetooth,
            level: 52,
            chargeState: .unknown,
            parentName: "JBL Sense Lite-LE",
            source: "JBLExcelPoint",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .chargingCase
            )
        )

        let deduplicated = DeviceBatterySampler.deduplicated([aggregate, left, right, caseItem])

        // Aggregate should be dropped when component readings exist
        let roles = deduplicated.compactMap { $0.componentIdentity?.role }
        XCTAssertFalse(roles.contains(.aggregate), "Aggregate should be dropped when components exist")
        XCTAssertTrue(roles.contains(.left))
        XCTAssertTrue(roles.contains(.right))
        XCTAssertTrue(roles.contains(.chargingCase))
    }

    func testFallbackReadingPreservedWhenNoExcelPointData() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("38:D5:18:8C:59:19")

        // Only aggregate from system_profiler, no ExcelPoint readings
        let aggregate = DeviceBatteryItem(
            id: "system_profiler-jbl",
            deviceIdentity: identity,
            name: "JBL Sense Lite",
            model: nil,
            kind: .bluetooth,
            level: 100,
            chargeState: .unknown,
            parentName: nil,
            source: "system_profiler",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: "Headset",
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .aggregate
            )
        )

        let deduplicated = DeviceBatterySampler.deduplicated([aggregate])

        // Aggregate should be preserved as fallback
        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.level, 100)
        XCTAssertEqual(deduplicated.first?.source, "system_profiler")
    }

    func testUnmatchedJBLDevicePreservesSystemReading() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = DeviceBatteryDeviceIdentity.bluetooth("38:D5:18:8C:59:19")

        // system_profiler reading
        let systemReading = DeviceBatteryItem(
            id: "system_profiler-jbl",
            deviceIdentity: identity,
            name: "JBL Sense Lite",
            model: nil,
            kind: .bluetooth,
            level: 100,
            chargeState: .unknown,
            parentName: nil,
            source: "system_profiler",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: "Headset",
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .aggregate
            )
        )

        // IOBluetooth reading
        let ioBluetoothReading = DeviceBatteryItem(
            id: "iobluetooth-jbl",
            deviceIdentity: identity,
            name: "JBL Sense Lite",
            model: nil,
            kind: .bluetooth,
            level: 100,
            chargeState: .unknown,
            parentName: nil,
            source: "IOBluetooth",
            lastUpdated: referenceDate,
            isConnected: true,
            detail: "Headset",
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: identity.key,
                role: .aggregate
            )
        )

        let deduplicated = DeviceBatterySampler.deduplicated([systemReading, ioBluetoothReading])

        // Should keep exactly one reading (IOBluetooth preferred over system_profiler)
        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.level, 100)
    }
}
