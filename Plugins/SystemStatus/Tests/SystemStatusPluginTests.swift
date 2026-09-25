import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import SystemStatusPlugin

@MainActor
final class SystemStatusPluginTests: XCTestCase {
    private let suiteName = "SystemStatusPluginTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testForegroundSamplingIsOwnedByEachVisibleSurface() {
        let viewModel = SystemStatusViewModel(sampler: StubSystemStatusSampler(), historyStore: StubSystemStatusHistoryStore())
        defer { viewModel.stop() }
        viewModel.startMenuBar()
        XCTAssertFalse(viewModel.isSamplingForeground)
        viewModel.startForeground(for: .menuBarPopover)
        viewModel.startForeground(for: .menuBarPopover)
        XCTAssertEqual(viewModel.foregroundConsumers, [.menuBarPopover])
        XCTAssertTrue(viewModel.isSamplingForeground)
        viewModel.startForeground(for: .dashboard)
        viewModel.returnToBackground(from: .menuBarPopover)
        XCTAssertTrue(viewModel.isSamplingForeground)
        viewModel.returnToBackground(from: .menuBarPopover)
        XCTAssertEqual(viewModel.foregroundConsumers, [.dashboard])
        viewModel.returnToBackground(from: .dashboard)
        XCTAssertFalse(viewModel.isSamplingForeground)
        viewModel.startForeground(for: .menuBarPopover)
        viewModel.startForeground(for: .dashboard)
        viewModel.returnToBackground(from: .dashboard)
        XCTAssertTrue(viewModel.isSamplingForeground)
        viewModel.stop()
        XCTAssertTrue(viewModel.foregroundConsumers.isEmpty)
        XCTAssertFalse(viewModel.isSamplingForeground)
    }

    func testOpeningPanelRefreshesProcessesBeforeTheBackgroundIntervalExpires() async {
        let sampler = StubSystemStatusSampler()
        let viewModel = SystemStatusViewModel(
            sampler: sampler, historyStore: StubSystemStatusHistoryStore(), schedule: .foregroundRestart
        )
        defer { viewModel.stop() }
        let backgroundSample = expectation(description: "Initial background sample")
        await sampler.observeNextFastCollection { backgroundSample.fulfill() }
        viewModel.startBackground()
        await fulfillment(of: [backgroundSample], timeout: 2)
        let backgroundCounts = await sampler.callCounts
        XCTAssertEqual(backgroundCounts.processes, 0)

        let visibleSample = expectation(description: "Fresh sample when the panel becomes visible")
        await sampler.observeNextProcessCollection { visibleSample.fulfill() }
        viewModel.startForeground()
        await fulfillment(of: [visibleSample], timeout: 2)
    }

    func testSystemStatusActionUsesMenuBarOverviewWhenAvailableAndDashboardOtherwise() {
        XCTAssertEqual(
            SystemStatusShortcutPresentationPolicy.destination(hasMenuBarButton: true),
            .menuBarOverview
        )
        XCTAssertEqual(
            SystemStatusShortcutPresentationPolicy.destination(hasMenuBarButton: false),
            .dashboard
        )
    }

    func testConfigurationPersistsVisibilityAndOrder() {
        let storage = SystemStatusMemoryPluginStorage()
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )

        controller.setPanelMetric(.gpu, visible: false)
        controller.movePanelMetric(.battery, toOffset: 0)
        controller.setMenuBarMetric(.cpu, visible: true)
        controller.setMenuBarMetric(.memory, visible: true)
        controller.moveMenuBarMetric(.memory, toOffset: 0)
        controller.setMenuBarValues(.memory, values: [.swap, .usage])
        controller.setMenuBarStyle(.memory, style: .minimal)
        controller.setMenuBarValueArrangement(.memory, arrangement: .inline)
        controller.setProcessSort(.memory)
        controller.setProcessLimit(.twenty)
        controller.setChartMetric(.memory, metric: .pressure)

        let restoredController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )

        XCTAssertEqual(restoredController.configuration.panelItems.map(\.kind).first, .battery)
        XCTAssertFalse(restoredController.configuration.panelItems.first { $0.kind == .gpu }?.isVisible ?? true)
        XCTAssertEqual(restoredController.configuration.visibleMenuBarMetricKinds, [.memory, .cpu])
        XCTAssertEqual(restoredController.configuration.menuBarItems.first?.values, [.swap, .usage])
        XCTAssertEqual(
            restoredController.configuration.menuBarItems.first?.valueArrangement,
            .inline
        )
        XCTAssertEqual(restoredController.configuration.menuBarItems.first?.style, .minimal)
        XCTAssertEqual(restoredController.configuration.processSort, .memory)
        XCTAssertEqual(restoredController.configuration.processLimit, .twenty)
        XCTAssertEqual(restoredController.configuration.chartMetric(for: .memory), .pressure)
    }

    func testMetricInsertionDropsReorderBothDirectionsAndRejectOtherLists() throws {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let originalOrder = controller.configuration.panelItems.map(\.kind)
        let payload = SystemStatusMetricDrop.payload(for: .cpu, listID: "panel")
        let downward = try XCTUnwrap(SystemStatusMetricDrop.destination(
            for: payload, over: .topProcesses, afterTarget: true, in: originalOrder, listID: "panel"
        ))
        controller.movePanelMetric(downward.kind, toOffset: downward.offset)
        XCTAssertEqual(controller.configuration.panelItems.map(\.kind), Array(originalOrder.dropFirst()) + [.cpu])

        let upward = try XCTUnwrap(SystemStatusMetricDrop.destination(
            for: payload, over: .gpu, afterTarget: false, in: controller.configuration.panelItems.map(\.kind), listID: "panel"
        ))
        controller.movePanelMetric(upward.kind, toOffset: upward.offset)
        XCTAssertEqual(controller.configuration.panelItems.map(\.kind), originalOrder)
        let beforeMemory = try XCTUnwrap(SystemStatusMetricDrop.destination(
            for: payload, over: .memory, afterTarget: false, in: originalOrder, listID: "panel"
        ))
        controller.movePanelMetric(beforeMemory.kind, toOffset: beforeMemory.offset)
        let order = controller.configuration.panelItems.map(\.kind)
        XCTAssertEqual(order.firstIndex(of: .cpu)! + 1, order.firstIndex(of: .memory))
        XCTAssertNil(SystemStatusMetricDrop.destination(
            for: payload, over: .memory, afterTarget: false, in: order, listID: "panel"
        ))
        XCTAssertNil(SystemStatusMetricDrop.destination(
            for: payload, over: .memory, afterTarget: false, in: controller.configuration.menuBarItems.map(\.kind), listID: "menu-bar"
        ))
    }

    func testMenuBarValuePickersAreIndependentAndPreserveRepeatedValues() throws {
        let storage = SystemStatusMemoryPluginStorage()
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )
        controller.setMenuBarMetric(.cpu, visible: true)
        controller.setMenuBarValues(.cpu, values: [.usage, .temperature])
        controller.setMenuBarPrimaryValue(.cpu, value: .temperature)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.temperature, .temperature])

        controller.setMenuBarSecondaryValue(.cpu, value: .power)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.temperature, .power])
        controller.setMenuBarSecondaryValue(.cpu, value: .temperature)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.temperature, .temperature])

        let restored = SystemStatusSettingsController(store: SystemStatusPluginStorageConfigurationStore(storage: storage))
        XCTAssertEqual(restored.configuration, controller.configuration)
        let block = try XCTUnwrap(SystemStatusMenuBarMetricsFormatter.blocks(
            snapshot: .empty, items: restored.configuration.menuBarItems, localization: nil
        ).first)
        XCTAssertEqual(block.valueKinds, [.temperature, .temperature])
        XCTAssertEqual(block.values.count, 2)
        XCTAssertEqual(block.values.first, block.values.last)

        controller.setMenuBarSecondaryValue(.cpu, value: nil)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.temperature])
        controller.setMenuBarPrimaryValue(.cpu, value: .usage)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.usage])

        controller.setMenuBarSecondaryValue(.cpu, value: .usage)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.usage, .usage])
        controller.setMenuBarPrimaryValue(.cpu, value: .power)
        XCTAssertEqual(controller.configuration.menuBarItems.first?.values, [.power, .usage])
    }

    func testProcessLimitDecodesOlderAndUnsupportedPreferencesWithoutLosingOtherSettings() throws {
        var configuration = SystemStatusConfiguration.default
        configuration.processSort = .memory
        let data = try JSONEncoder().encode(configuration)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for storedLimit: Int? in [nil, 7] {
            object["processLimit"] = storedLimit
            let decoded = try JSONDecoder().decode(
                SystemStatusConfiguration.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertEqual(decoded.processLimit, .three)
            XCTAssertEqual(decoded.processSort, .memory)
            XCTAssertEqual(decoded.panelItems, configuration.panelItems)
        }
    }

    func testProcessLimitChangesSamplingAndWidgetHeight() async {
        let sampler = StubSystemStatusSampler()
        let viewModel = SystemStatusViewModel(sampler: sampler, historyStore: StubSystemStatusHistoryStore())
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        controller.setProcessLimit(.five)
        let plugin = SystemStatusPlugin(viewModel: viewModel, settingsController: controller)
        let fiveRowHeight = plugin.descriptor.span.height
        await viewModel.refreshSnapshotNow()
        let initialLimit = await sampler.lastProcessLimit
        XCTAssertEqual(initialLimit, 5)

        controller.setProcessLimit(.twenty)
        await viewModel.refreshSnapshotNow()
        let increasedLimit = await sampler.lastProcessLimit
        XCTAssertEqual(increasedLimit, 20)
        XCTAssertGreaterThan(plugin.descriptor.span.height, fiveRowHeight)

        controller.setPanelMetric(.topProcesses, visible: false)
        let hiddenHeight = plugin.descriptor.span.height
        controller.setProcessLimit(.three)
        XCTAssertEqual(plugin.descriptor.span.height, hiddenHeight)
        await viewModel.refreshSnapshotNow()
        let reducedLimit = await sampler.lastProcessLimit
        XCTAssertEqual(reducedLimit, 20)
        XCTAssertTrue(viewModel.snapshot.topProcesses.isEmpty)
    }

    func testPortablePreferencesRoundTripRestoresEveryConfigurationField() throws {
        let sourceController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let sourcePlugin = SystemStatusPlugin(
            settingsController: sourceController,
            storage: SystemStatusMemoryPluginStorage()
        )
        var sourceChangeCount = 0
        sourcePlugin.onPersistentPreferencesChange = { sourceChangeCount += 1 }

        sourceController.setPanelMetric(.gpu, visible: false)
        sourceController.movePanelMetric(.battery, toOffset: 0)
        sourceController.setMenuBarMetric(.cpu, visible: true)
        sourceController.setMenuBarMetric(.memory, visible: true)
        sourceController.moveMenuBarMetric(.memory, toOffset: 0)
        sourceController.setMenuBarValues(.memory, values: [.swap, .swap])
        sourceController.setMenuBarStyle(.memory, style: .vertical)
        sourceController.setMenuBarValueArrangement(.memory, arrangement: .stacked)
        sourceController.setMenuBarStyle(.cpu, style: .minimal)
        sourceController.setProcessSort(.memory)
        sourceController.setProcessLimit(.fifteen)
        sourceController.setChartMetric(.memory, metric: .pressure)

        XCTAssertGreaterThan(sourceChangeCount, 0)
        let backup = try XCTUnwrap(sourcePlugin.makePortablePreferencesBackup())

        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        let destinationPlugin = SystemStatusPlugin(
            settingsController: destinationController,
            storage: SystemStatusMemoryPluginStorage()
        )
        var destinationChangeCount = 0
        destinationPlugin.onPersistentPreferencesChange = { destinationChangeCount += 1 }

        XCTAssertTrue(destinationPlugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(destinationController.configuration, sourceController.configuration)
        XCTAssertEqual(destinationChangeCount, 1)

        XCTAssertTrue(destinationPlugin.restorePortablePreferencesReportingResult(from: backup))
        XCTAssertEqual(destinationChangeCount, 1)
    }

    func testFailedConfigurationSaveDoesNotPublishOrSignalPersistentChange() {
        let storage = SystemStatusMemoryPluginStorage(
            blockedSetKeys: ["settings.configuration.v1"]
        )
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )
        let plugin = SystemStatusPlugin(settingsController: controller, storage: storage)
        var changeCount = 0
        plugin.onPersistentPreferencesChange = { changeCount += 1 }

        controller.setMenuBarMetric(.cpu, visible: true)

        XCTAssertEqual(controller.configuration, .default)
        XCTAssertEqual(changeCount, 0)
        XCTAssertEqual(
            SystemStatusPluginStorageConfigurationStore(storage: storage).load(),
            .default
        )
    }

    func testPortableRestoreLeavesExistingConfigurationIntactWhenAtomicWriteFails() throws {
        let sourceController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        sourceController.setMenuBarMetric(.cpu, visible: true)
        sourceController.setMenuBarValues(.cpu, values: [.power, .load])
        let backup = try XCTUnwrap(sourceController.makePortablePreferencesBackup())

        let storage = SystemStatusMemoryPluginStorage()
        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )
        let originalConfiguration = destinationController.configuration
        storage.blockedSetKeys.insert("settings.configuration.v1")

        XCTAssertFalse(destinationController.restorePortablePreferences(from: backup))
        XCTAssertEqual(destinationController.configuration, originalConfiguration)
        XCTAssertEqual(
            SystemStatusPluginStorageConfigurationStore(storage: storage).load(),
            originalConfiguration
        )
    }

    func testPortablePreferencesRejectUnsupportedFormatWithoutChangingConfiguration() throws {
        let sourcePlugin = SystemStatusPlugin(storage: SystemStatusMemoryPluginStorage())
        let backup = try XCTUnwrap(sourcePlugin.makePortablePreferencesBackup())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup) as? [String: Any]
        )
        object["formatVersion"] = 999
        let invalidBackup = try JSONSerialization.data(withJSONObject: object)

        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        destinationController.setMenuBarMetric(.cpu, visible: true)
        let originalConfiguration = destinationController.configuration
        let destinationPlugin = SystemStatusPlugin(
            settingsController: destinationController,
            storage: SystemStatusMemoryPluginStorage()
        )

        XCTAssertFalse(destinationPlugin.restorePortablePreferencesReportingResult(from: invalidBackup))
        XCTAssertEqual(destinationController.configuration, originalConfiguration)
    }

    func testViewModelMergesDiskCapacityAndActivitySamples() async throws {
        let viewModel = SystemStatusViewModel(
            sampler: StubSystemStatusSampler(),
            historyStore: StubSystemStatusHistoryStore(),
            schedule: .test
        )

        await viewModel.refreshSnapshotNow(referenceDate: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(viewModel.snapshot.disk.usedBytes, 50)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertEqual(viewModel.snapshot.disk.readBytesPerSecond, 2_048)
        XCTAssertEqual(viewModel.snapshot.disk.writeBytesPerSecond, 1_024)
        XCTAssertEqual(viewModel.snapshot.history.last?.diskReadBytesPerSecond, 2_048)
        XCTAssertEqual(viewModel.snapshot.history.last?.diskWriteBytesPerSecond, 1_024)
    }

}

private actor StubSystemStatusSampler: SystemStatusSampling {
    func setDemand(_ demand: SystemStatusSamplingDemand) {}
    private var onNextProcessCollection: (@Sendable () -> Void)?
    private var onNextFastCollection: (@Sendable () -> Void)?
    func observeNextFastCollection(_ callback: @escaping @Sendable () -> Void) {
        onNextFastCollection = callback
    }

    func observeNextProcessCollection(_ callback: @escaping @Sendable () -> Void) {
        onNextProcessCollection = callback
    }
    private(set) var fastCallCount = 0
    private(set) var slowCallCount = 0
    private(set) var processCallCount = 0
    private(set) var lastProcessLimit: Int?
    private(set) var publicIPCallCount = 0

    var callCounts: (fast: Int, slow: Int, processes: Int, publicIP: Int) {
        (fastCallCount, slowCallCount, processCallCount, publicIPCallCount)
    }

    func collectFast(referenceDate: Date, demand: SystemStatusSamplingDemand) async -> SystemStatusFastSample {
        fastCallCount += 1
        onNextFastCollection?()
        onNextFastCollection = nil
        return SystemStatusFastSample(
            cpu: SystemStatusCPUSnapshot(
                usage: min(0.95, 0.20 + Double(fastCallCount) * 0.01),
                loadAverage1Minute: 1.42,
                temperatureCelsius: 42,
                cpuPowerWatts: 8.5,
                isCollecting: false
            ),
            memory: SystemStatusMemorySnapshot(
                usedBytes: 4_000,
                totalBytes: 8_000,
                swapUsedBytes: 512,
                swapTotalBytes: 2_048
            ),
            network: SystemStatusNetworkSnapshot(
                interfaceName: "en0",
                ipAddress: "192.168.1.2",
                publicIPAddress: nil,
                downloadBytesPerSecond: 1_024,
                uploadBytesPerSecond: 512,
                isConnected: true,
                isCollecting: false
            ),
            disk: SystemStatusDiskSnapshot(
                usedBytes: nil,
                totalBytes: nil,
                readBytesPerSecond: 2_048,
                writeBytesPerSecond: 1_024
            )
        )
    }

    func collectSlow(demand: SystemStatusSamplingDemand) async -> SystemStatusSlowSample {
        slowCallCount += 1
        return SystemStatusSlowSample(
            disk: SystemStatusDiskSnapshot(
                usedBytes: 50,
                totalBytes: 100,
                readBytesPerSecond: nil,
                writeBytesPerSecond: nil
            ),
            battery: SystemStatusBatterySnapshot(
                isAvailable: true,
                level: 0.8,
                state: .acPower,
                timeRemainingMinutes: nil,
                adapterWatts: 70,
                batteryPowerWatts: -18.5,
                temperatureCelsius: 31,
                healthPercent: 96,
                cycleCount: 120
            ),
            gpu: SystemStatusGPUSnapshot(
                usage: 0.4,
                name: "M1 Pro",
                temperatureCelsius: 43,
                isAvailable: true,
                isCollecting: false
            ),
            hardware: SystemStatusHardwareSnapshot(
                modelName: "MacBookPro18,3",
                chipName: "Apple M1 Pro",
                macOSVersion: "macOS 15.0",
                uptimeSeconds: 3_600,
                totalMemoryBytes: 16_000
            )
        )
    }

    func collectTopProcesses(limit: Int) async -> [SystemStatusTopProcess] {
        processCallCount += 1
        lastProcessLimit = limit
        onNextProcessCollection?()
        onNextProcessCollection = nil
        return [
            SystemStatusTopProcess(
                pid: 1,
                displayName: "launchd",
                command: "/sbin/launchd",
                cpuPercent: 1,
                memoryBytes: 12_582_912
            )
        ]
    }

    func collectPublicIPAddress() async -> String? {
        publicIPCallCount += 1
        return "203.0.113.1"
    }
}

private actor StubSystemStatusHistoryStore: SystemStatusHistoryStoring {
    private(set) var appendedCount = 0
    private var points: [SystemStatusHistoryPoint] = []

    func load(referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        points
    }

    func append(_ point: SystemStatusHistoryPoint, referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        appendedCount += 1
        points.append(point)
        return points
    }
}

@MainActor
private final class SystemStatusMemoryPluginStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var blockedSetKeys: Set<String>

    init(blockedSetKeys: Set<String> = []) {
        self.blockedSetKeys = blockedSetKeys
    }

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        guard !blockedSetKeys.contains(key) else {
            return
        }
        guard let value else {
            removeObject(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

private extension SystemStatusSamplingSchedule {
    static let test = SystemStatusSamplingSchedule(
        backgroundFastInterval: .milliseconds(20),
        menuBarFastInterval: .milliseconds(20),
        foregroundFastInterval: .milliseconds(20),
        backgroundSlowInterval: 0,
        menuBarSlowInterval: 0,
        foregroundSlowInterval: 0,
        foregroundProcessInterval: 0,
        backgroundHistoryInterval: 0,
        foregroundHistoryInterval: 0
    )

    static let foregroundRestart = SystemStatusSamplingSchedule(
        backgroundFastInterval: .seconds(30),
        menuBarFastInterval: .milliseconds(20),
        foregroundFastInterval: .milliseconds(20),
        backgroundSlowInterval: 30,
        menuBarSlowInterval: 30,
        foregroundSlowInterval: 30,
        foregroundProcessInterval: 30,
        backgroundHistoryInterval: 30,
        foregroundHistoryInterval: 30
    )
}
