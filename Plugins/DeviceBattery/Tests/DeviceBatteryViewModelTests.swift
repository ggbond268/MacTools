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
            includeVendorHIDDevices: true
        )
        try? await Task.sleep(for: .milliseconds(50))

        let counts = await sampler.counts()
        XCTAssertEqual(counts, .zero)
        XCTAssertFalse(powerObserver.isStarted)
        XCTAssertFalse(bluetoothObserver.isStarted)
        viewModel.stop()
    }

    func testVisibleComponentStartsEachSourceAndHidingStopsPeriodicWork() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeVendorHIDDevices: false
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
            includeVendorHIDDevices: false
        )

        await waitForCounts(.oneEach, sampler: sampler)
        XCTAssertEqual(viewModel.bluetoothRefreshInterval, 30)
        viewModel.stop()
    }

    func testUpdatingSourcesRestartsOnlyNewlyEnabledSource() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeVendorHIDDevices: false
        )
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.updateSources(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeVendorHIDDevices: false
        )
        try? await Task.sleep(for: .milliseconds(30))
        let countsAfterDisabling = await sampler.counts()
        XCTAssertEqual(countsAfterDisabling, .oneEach)

        viewModel.updateSources(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeVendorHIDDevices: false
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
            includeVendorHIDDevices: false
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
        let options = await sampler.bluetoothOptions()
        XCTAssertEqual(options.last?.scanScope, .newlyConnected)
        XCTAssertEqual(options.last?.forceProfileRefresh, true)
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
            includeVendorHIDDevices: false
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
            vendorHIDMonitor: RecordingVendorHIDBatteryMonitor(),
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
            includeVendorHIDDevices: false
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
            vendorHIDMonitor: RecordingVendorHIDBatteryMonitor(),
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
    private var bluetoothItems: [DeviceBatteryItem]
    private var shouldSuspendBluetoothRead = false
    private var bluetoothContinuation: CheckedContinuation<[DeviceBatteryItem], Never>?

    init(bluetoothItems: [DeviceBatteryItem] = []) {
        self.bluetoothItems = bluetoothItems
    }

    func suspendNextBluetoothRead() {
        shouldSuspendBluetoothRead = true
    }

    func resumeBluetoothRead(returning items: [DeviceBatteryItem]) {
        bluetoothItems = items
        bluetoothContinuation?.resume(returning: items)
        bluetoothContinuation = nil
    }

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
        if shouldSuspendBluetoothRead {
            shouldSuspendBluetoothRead = false
            return await withCheckedContinuation { bluetoothContinuation = $0 }
        }
        return bluetoothItems
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
private final class RecordingVendorHIDBatteryMonitor: VendorHIDBatteryMonitoring {
    var snapshot = VendorHIDMouseBatterySnapshot.idle
    var onSnapshotChange: ((VendorHIDMouseBatterySnapshot) -> Void)?
    func start() {}
    func stop() {}
    func refresh() {}
}
