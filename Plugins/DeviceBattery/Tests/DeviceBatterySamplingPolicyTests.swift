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
            isConnected: isConnected
        )
    }
}
