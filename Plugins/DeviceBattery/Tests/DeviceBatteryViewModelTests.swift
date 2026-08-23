import XCTest
import MacToolsPluginKit
@testable import DeviceBatteryPlugin

@MainActor
final class DeviceBatteryViewModelTests: XCTestCase {
    func testNoSamplingRunsWithoutVisibleComponentOrLowBatteryMonitoring() async {
        let sampler = RecordingDeviceBatterySampler()
        let powerObserver = RecordingPowerSourceObserver()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            powerObserver: powerObserver,
            bluetoothObserver: bluetoothObserver
        )

        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: true
        )
        try? await Task.sleep(for: .milliseconds(50))

        let counts = await sampler.counts()
        XCTAssertEqual(counts, .zero)
        XCTAssertFalse(powerObserver.isStarted)
        XCTAssertFalse(bluetoothObserver.isStarted)
        viewModel.stop()
    }

    func testRapooMonitorPublishesEveryConnectedMouse() async {
        let first = RapooMouseBatterySnapshot(
            accessState: .connected,
            device: RapooMouseDeviceInfo(
                productID: 0x0201,
                modelName: "Rapoo MT760",
                displayName: "Desk Mouse",
                serialNumber: "MOUSE-A",
                locationID: 1,
                registryEntryID: nil
            ),
            reading: RapooBatteryReading(
                level: 80,
                chargeState: .normal,
                statusCode: 1
            ),
            lastUpdated: Date(timeIntervalSince1970: 100)
        )
        let second = RapooMouseBatterySnapshot(
            accessState: .connected,
            device: RapooMouseDeviceInfo(
                productID: 0x0202,
                modelName: "Rapoo MT750",
                displayName: "Travel Mouse",
                serialNumber: "MOUSE-B",
                locationID: 2,
                registryEntryID: nil
            ),
            reading: RapooBatteryReading(
                level: 60,
                chargeState: .charging,
                statusCode: 3
            ),
            lastUpdated: Date(timeIntervalSince1970: 200)
        )
        let rapooMonitor = MultipleRapooBatteryMonitor(snapshots: [first, second])
        let viewModel = DeviceBatteryViewModel(
            sampler: RecordingDeviceBatterySampler(),
            rapooMonitor: rapooMonitor,
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.01
            )
        )

        viewModel.start(
            includeInternalBattery: false,
            includeBluetoothDevices: false,
            includeAppleMobileDevices: false,
            includeRapooDevices: true
        )
        viewModel.setComponentPanelVisible(true)

        XCTAssertEqual(viewModel.snapshot.items.count, 2)
        XCTAssertEqual(Set(viewModel.snapshot.items.map(\.level)), Set([60, 80]))
        XCTAssertEqual(viewModel.snapshot.lastUpdated, Date(timeIntervalSince1970: 200))
        viewModel.stop()
    }

    func testVisibleComponentStartsEachSourceAndHidingStopsPeriodicWork() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )

        viewModel.setComponentPanelVisible(true)
        await waitForCounts(.oneEach, sampler: sampler)
        viewModel.setComponentPanelVisible(false)
        try? await Task.sleep(for: .milliseconds(50))

        let counts = await sampler.counts()
        XCTAssertEqual(counts, .oneEach)
        viewModel.stop()
    }

    func testLowBatteryMonitoringActsAsBackgroundConsumer() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )

        await waitForCounts(.oneEach, sampler: sampler)
        XCTAssertEqual(viewModel.bluetoothRefreshInterval, 30)
        viewModel.stop()
    }

    func testHidingVisibleComponentWhileMonitoringDoesNotImmediatelyResample() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.setComponentPanelVisible(true)
        let visibleCounts = DeviceBatterySamplingCounts(
            internalBattery: 2,
            bluetooth: 2,
            appleMobile: 2
        )
        await waitForCounts(visibleCounts, sampler: sampler)

        viewModel.setComponentPanelVisible(false)
        try? await Task.sleep(for: .milliseconds(50))

        let countsAfterHiding = await sampler.counts()
        let optionsAfterHiding = await sampler.bluetoothOptions()
        let mobileRefreshIntervals = await sampler.appleMobileRefreshIntervals()
        XCTAssertEqual(countsAfterHiding, visibleCounts)
        XCTAssertEqual(optionsAfterHiding.count, 2)
        XCTAssertFalse(optionsAfterHiding[0].revalidateSupplementalState)
        XCTAssertTrue(optionsAfterHiding[1].revalidateSupplementalState)
        XCTAssertEqual(mobileRefreshIntervals, [30, 15])
        viewModel.stop()
    }

    func testOpeningDuringBluetoothCollectionQueuesStateRevalidationWithoutAnotherScan() async {
        let sampler = SuspendedBluetoothSampler()
        let viewModel = DeviceBatteryViewModel(
            sampler: sampler,
            rapooMonitor: RecordingRapooBatteryMonitor(),
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.01
            )
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )

        for _ in 0..<100 {
            if await sampler.hasStartedFirstCollection() { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didStartFirstCollection = await sampler.hasStartedFirstCollection()
        XCTAssertTrue(didStartFirstCollection)

        viewModel.setComponentPanelVisible(true)
        await sampler.resumeFirstCollection()

        for _ in 0..<100 {
            if (await sampler.options()).count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let options = await sampler.options()
        XCTAssertEqual(options.count, 2)
        XCTAssertFalse(options[0].revalidateSupplementalState)
        XCTAssertTrue(options[0].performActiveScan)
        XCTAssertTrue(options[1].revalidateSupplementalState)
        XCTAssertFalse(options[1].performActiveScan)
        viewModel.stop()
    }

    func testTogglingLowBatteryMonitoringWhileVisibleDoesNotResample() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.setLowBatteryMonitoringEnabled(false)
        try? await Task.sleep(for: .milliseconds(50))

        let countsAfterToggling = await sampler.counts()
        XCTAssertEqual(countsAfterToggling, .oneEach)
        viewModel.stop()
    }

    func testUpdatingSourcesRestartsOnlyNewlyEnabledSource() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.updateSources(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        try? await Task.sleep(for: .milliseconds(30))
        let countsAfterDisabling = await sampler.counts()
        XCTAssertEqual(countsAfterDisabling, .oneEach)

        viewModel.updateSources(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(
            DeviceBatterySamplingCounts(
                internalBattery: 2,
                bluetooth: 1,
                appleMobile: 1
            ),
            sampler: sampler
        )
        viewModel.stop()
    }

    func testUpdatingSourcesDuringWakeDelayIsAppliedBySingleResumeBatch() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(
            sampler: sampler,
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.05
            )
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: false,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 1, bluetooth: 0, appleMobile: 0),
            sampler: sampler
        )

        viewModel.setApplicationActivityState(.displayAsleep)
        viewModel.setApplicationActivityState(.interactive)
        viewModel.updateSources(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )
        try? await Task.sleep(for: .milliseconds(20))
        let countsDuringWakeDelay = await sampler.counts()
        XCTAssertEqual(
            countsDuringWakeDelay,
            DeviceBatterySamplingCounts(internalBattery: 1, bluetooth: 0, appleMobile: 0)
        )

        let resumedCounts = DeviceBatterySamplingCounts(
            internalBattery: 1,
            bluetooth: 1,
            appleMobile: 0
        )
        await waitForCounts(resumedCounts, sampler: sampler)
        try? await Task.sleep(for: .milliseconds(80))
        let finalCounts = await sampler.counts()
        XCTAssertEqual(finalCounts, resumedCounts)
        viewModel.stop()
    }

    func testDisablingSourceClearsScanningStateWhileCollectionIsSuspended() async {
        let sampler = SuspendedAppleMobileSampler()
        let viewModel = DeviceBatteryViewModel(
            sampler: sampler,
            rapooMonitor: RecordingRapooBatteryMonitor(),
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.01
            )
        )
        viewModel.start(
            includeInternalBattery: false,
            includeBluetoothDevices: false,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        viewModel.setComponentPanelVisible(true)
        for _ in 0..<100 {
            if await sampler.hasStartedAppleMobileCollection() {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let didStartCollection = await sampler.hasStartedAppleMobileCollection()
        XCTAssertTrue(didStartCollection)
        XCTAssertEqual(viewModel.snapshot.accessState, .scanning)

        viewModel.updateSources(
            includeInternalBattery: false,
            includeBluetoothDevices: false,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )

        XCTAssertEqual(viewModel.snapshot.accessState, .noDevices)
        await sampler.resumeAppleMobileCollection()
        viewModel.stop()
    }

    func testSystemEventsRefreshOnlyTheirSourceAndDebounceBluetooth() async {
        let sampler = RecordingDeviceBatterySampler()
        let powerObserver = RecordingPowerSourceObserver()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            powerObserver: powerObserver,
            bluetoothObserver: bluetoothObserver
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        powerObserver.sendChange()
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 1, appleMobile: 1),
            sampler: sampler
        )

        bluetoothObserver.sendConnectionChange()
        bluetoothObserver.sendConnectionChange()
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 2, appleMobile: 1),
            sampler: sampler
        )
        viewModel.stop()
    }

    func testActivityPauseDefersEventsAndCoalescesResume() async {
        let sampler = RecordingDeviceBatterySampler()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            bluetoothObserver: bluetoothObserver
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.setApplicationActivityState(.systemSleeping)
        bluetoothObserver.sendConnectionChange()
        try? await Task.sleep(for: .milliseconds(50))
        let counts = await sampler.counts()
        XCTAssertEqual(counts, .oneEach)

        viewModel.setApplicationActivityState(.interactive)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 2, appleMobile: 2),
            sampler: sampler
        )
        let options = await sampler.bluetoothOptions()
        XCTAssertEqual(options.last?.forceProfileRefresh, true)
        viewModel.stop()
    }

    func testReopeningComponentForcesBluetoothProfileRefresh() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )

        viewModel.setComponentPanelVisible(true)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 0, bluetooth: 1, appleMobile: 0),
            sampler: sampler
        )
        viewModel.setComponentPanelVisible(false)
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 0, bluetooth: 2, appleMobile: 0),
            sampler: sampler
        )

        let options = await sampler.bluetoothOptions()
        XCTAssertEqual(options.map(\.forceProfileRefresh), [true, true])
        viewModel.stop()
    }

    func testWakeWindowConnectionEventIsMergedIntoResumeSampling() async {
        let sampler = RecordingDeviceBatterySampler()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            bluetoothObserver: bluetoothObserver,
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.05
            )
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.setApplicationActivityState(.displayAsleep)
        viewModel.setApplicationActivityState(.interactive)
        bluetoothObserver.sendConnectionChange()
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 2, appleMobile: 2),
            sampler: sampler
        )
        try? await Task.sleep(for: .milliseconds(100))

        let finalCounts = await sampler.counts()
        let finalBluetoothOptions = await sampler.bluetoothOptions()
        XCTAssertEqual(finalCounts, DeviceBatterySamplingCounts(
            internalBattery: 2,
            bluetooth: 2,
            appleMobile: 2
        ))
        XCTAssertEqual(finalBluetoothOptions.last?.forceProfileRefresh, true)
        viewModel.stop()
    }

    func testRemovingLastConsumerClearsCollectedSnapshot() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: false,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 1, bluetooth: 0, appleMobile: 0),
            sampler: sampler
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(viewModel.snapshot.lastUpdated)

        viewModel.setComponentPanelVisible(false)

        XCTAssertNil(viewModel.snapshot.lastUpdated)
        XCTAssertTrue(viewModel.snapshot.items.isEmpty)
        viewModel.stop()
    }

    func testSnapshotMergesBatteryCenterPhoneWithSharedMobileDeviceIdentity() async throws {
        let batteryCenterIdentity = DeviceBatteryDeviceIdentity.batteryCenter("PHONE-GROUP")
        let sampler = FixedDeviceBatterySampler(
            bluetoothItems: [
                DeviceBatteryItem(
                    id: "battery-center-phone",
                    deviceIdentity: batteryCenterIdentity,
                    name: "Test iPhone",
                    model: "iPhone18,1",
                    kind: .phone,
                    level: 65,
                    chargeState: .charging,
                    parentName: nil,
                    source: "BatteryCenter",
                    lastUpdated: Date(),
                    isConnected: true,
                    detail: nil,
                    alternateDeviceIdentities: [.mobileDevice("PHONE-UDID")]
                )
            ],
            mobileItems: [
                DeviceBatteryItem(
                    id: "mobile-phone",
                    deviceIdentity: .mobileDevice("PHONE-UDID"),
                    name: "Test iPhone",
                    model: "iPhone18,1",
                    kind: .phone,
                    level: 66,
                    chargeState: .unknown,
                    parentName: nil,
                    source: "MobileDevice",
                    lastUpdated: Date(),
                    isConnected: true,
                    detail: nil
                )
            ]
        )
        let viewModel = DeviceBatteryViewModel(
            sampler: sampler,
            rapooMonitor: RecordingRapooBatteryMonitor(),
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.01
            )
        )
        viewModel.start(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        viewModel.setComponentPanelVisible(true)

        for _ in 0..<100 {
            if viewModel.snapshot.items.first?.alternateDeviceIdentities
                .contains(batteryCenterIdentity) == true {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let item = try XCTUnwrap(viewModel.snapshot.items.first)
        XCTAssertEqual(viewModel.snapshot.items.count, 1)
        XCTAssertEqual(item.source, "MobileDevice")
        XCTAssertEqual(item.deviceIdentity, .mobileDevice("PHONE-UDID"))
        XCTAssertEqual(item.level, 66)
        XCTAssertEqual(item.chargeState, .charging)
        XCTAssertTrue(item.alternateDeviceIdentities.contains(batteryCenterIdentity))
        viewModel.stop()
    }

    private func makeViewModel(
        sampler: RecordingDeviceBatterySampler,
        powerObserver: RecordingPowerSourceObserver? = nil,
        bluetoothObserver: RecordingBluetoothConnectionObserver? = nil,
        schedule: DeviceBatterySamplingSchedule? = nil
    ) -> DeviceBatteryViewModel {
        DeviceBatteryViewModel(
            sampler: sampler,
            rapooMonitor: RecordingRapooBatteryMonitor(),
            powerSourceObserver: powerObserver ?? RecordingPowerSourceObserver(),
            bluetoothConnectionObserver: bluetoothObserver ?? RecordingBluetoothConnectionObserver(),
            schedule: schedule ?? DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.01
            )
        )
    }

    private func waitForCounts(
        _ expected: DeviceBatterySamplingCounts,
        sampler: RecordingDeviceBatterySampler
    ) async {
        for _ in 0..<100 {
            if await sampler.counts() == expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let actual = await sampler.counts()
        XCTFail("Timed out waiting for sampling counts \(expected); got \(actual)")
    }
}

private struct DeviceBatterySamplingCounts: Equatable, Sendable {
    let internalBattery: Int
    let bluetooth: Int
    let appleMobile: Int

    static let zero = DeviceBatterySamplingCounts(
        internalBattery: 0,
        bluetooth: 0,
        appleMobile: 0
    )
    static let oneEach = DeviceBatterySamplingCounts(
        internalBattery: 1,
        bluetooth: 1,
        appleMobile: 1
    )
}

private actor RecordingDeviceBatterySampler: DeviceBatterySampling {
    private var samplingCounts = DeviceBatterySamplingCounts.zero
    private var recordedBluetoothOptions: [DeviceBatteryBluetoothSamplingOptions] = []
    private var recordedAppleMobileRefreshIntervals: [TimeInterval] = []

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        samplingCounts = DeviceBatterySamplingCounts(
            internalBattery: samplingCounts.internalBattery + 1,
            bluetooth: samplingCounts.bluetooth,
            appleMobile: samplingCounts.appleMobile
        )
        return []
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        samplingCounts = DeviceBatterySamplingCounts(
            internalBattery: samplingCounts.internalBattery,
            bluetooth: samplingCounts.bluetooth + 1,
            appleMobile: samplingCounts.appleMobile
        )
        recordedBluetoothOptions.append(options)
        return []
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        samplingCounts = DeviceBatterySamplingCounts(
            internalBattery: samplingCounts.internalBattery,
            bluetooth: samplingCounts.bluetooth,
            appleMobile: samplingCounts.appleMobile + 1
        )
        recordedAppleMobileRefreshIntervals.append(minimumRefreshInterval)
        return []
    }

    func counts() -> DeviceBatterySamplingCounts {
        samplingCounts
    }

    func bluetoothOptions() -> [DeviceBatteryBluetoothSamplingOptions] {
        recordedBluetoothOptions
    }

    func appleMobileRefreshIntervals() -> [TimeInterval] {
        recordedAppleMobileRefreshIntervals
    }
}

private actor SuspendedAppleMobileSampler: DeviceBatterySampling {
    private var appleMobileContinuation: CheckedContinuation<[DeviceBatteryItem], Never>?
    private var didStartAppleMobileCollection = false

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        []
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        []
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        didStartAppleMobileCollection = true
        return await withCheckedContinuation { continuation in
            appleMobileContinuation = continuation
        }
    }

    func hasStartedAppleMobileCollection() -> Bool {
        didStartAppleMobileCollection
    }

    func resumeAppleMobileCollection() {
        appleMobileContinuation?.resume(returning: [])
        appleMobileContinuation = nil
    }
}

private actor SuspendedBluetoothSampler: DeviceBatterySampling {
    private var firstContinuation: CheckedContinuation<[DeviceBatteryItem], Never>?
    private var recordedOptions: [DeviceBatteryBluetoothSamplingOptions] = []

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        []
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        recordedOptions.append(options)
        guard recordedOptions.count == 1 else { return [] }
        return await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        []
    }

    func hasStartedFirstCollection() -> Bool {
        firstContinuation != nil
    }

    func resumeFirstCollection() {
        firstContinuation?.resume(returning: [])
        firstContinuation = nil
    }

    func options() -> [DeviceBatteryBluetoothSamplingOptions] {
        recordedOptions
    }
}

private actor FixedDeviceBatterySampler: DeviceBatterySampling {
    let bluetoothItems: [DeviceBatteryItem]
    let mobileItems: [DeviceBatteryItem]

    init(
        bluetoothItems: [DeviceBatteryItem],
        mobileItems: [DeviceBatteryItem]
    ) {
        self.bluetoothItems = bluetoothItems
        self.mobileItems = mobileItems
    }

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        []
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        bluetoothItems
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        mobileItems
    }
}

@MainActor
private final class RecordingPowerSourceObserver: DeviceBatteryPowerSourceObserving {
    var onChange: (() -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func sendChange() { onChange?() }
}

@MainActor
private final class RecordingBluetoothConnectionObserver:
    DeviceBatteryBluetoothConnectionObserving {
    var onConnectionChange: (() -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func sendConnectionChange() { onConnectionChange?() }
}

@MainActor
private final class RecordingRapooBatteryMonitor: RapooBatteryMonitoring {
    var snapshot = RapooMouseBatterySnapshot.idle
    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)?
    func start() {}
    func stop() {}
    func refresh() {}
}

@MainActor
private final class MultipleRapooBatteryMonitor: RapooBatteryMonitoring {
    var snapshot: RapooMouseBatterySnapshot
    var deviceSnapshots: [RapooMouseBatterySnapshot]
    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)?

    init(snapshots: [RapooMouseBatterySnapshot]) {
        deviceSnapshots = snapshots
        snapshot = snapshots.first ?? .idle
    }

    func start() {}
    func stop() {}
    func refresh() {}
}
