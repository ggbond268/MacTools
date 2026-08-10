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

    func testSystemStatusLayoutHeightFollowsVisibleMetricRows() {
        XCTAssertEqual(SystemStatusComponentLayout.contentHeight(for: []), 96)
        XCTAssertEqual(SystemStatusComponentLayout.contentHeight(for: [.cpu]), 99)
        XCTAssertEqual(SystemStatusComponentLayout.contentHeight(for: [.cpu, .gpu, .topProcesses]), 201)
    }

    func testConfigurationDefaultsShowPanelMetricsAndUsefulMenuBarMetrics() {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )

        XCTAssertEqual(
            controller.configuration.visiblePanelMetricKinds,
            SystemStatusComponentLayout.defaultPanelMetricKinds
        )
        XCTAssertEqual(
            controller.configuration.visibleMenuBarMetricKinds,
            [.cpu, .network, .memory]
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

        let restoredController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: storage)
        )

        XCTAssertEqual(restoredController.configuration.panelItems.map(\.kind).first, .battery)
        XCTAssertFalse(restoredController.configuration.panelItems.first { $0.kind == .gpu }?.isVisible ?? true)
        XCTAssertEqual(restoredController.configuration.visibleMenuBarMetricKinds, [.memory, .cpu])
    }

    func testPluginDescriptorShrinksWhenPanelMetricsAreHidden() {
        let controller = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: SystemStatusMemoryPluginStorage())
        )
        controller.setPanelMetric(.gpu, visible: false)
        controller.setPanelMetric(.network, visible: false)
        controller.setPanelMetric(.disk, visible: false)
        controller.setPanelMetric(.memory, visible: false)
        controller.setPanelMetric(.battery, visible: false)
        controller.setPanelMetric(.topProcesses, visible: false)

        let plugin = SystemStatusPlugin(
            settingsController: controller,
            storage: SystemStatusMemoryPluginStorage()
        )

        let expectedHeight = PluginComponentPanelLayoutMetrics.default.heightSpan(
            fittingContentHeight: SystemStatusComponentLayout.contentHeight(for: [.cpu])
        )
        XCTAssertEqual(plugin.descriptor.span, PluginComponentSpan(width: 4, height: expectedHeight)!)
    }

    func testMenuBarFormatterUsesSelectedOrder() {
        var snapshot = SystemStatusSnapshot.empty
        snapshot.cpu = SystemStatusCPUSnapshot(
            usage: 0.125,
            loadAverage1Minute: nil,
            temperatureCelsius: 42.4,
            systemPowerWatts: nil,
            isCollecting: false
        )
        snapshot.memory = SystemStatusMemorySnapshot(
            usedBytes: 6_000,
            totalBytes: 10_000,
            swapUsedBytes: nil,
            swapTotalBytes: nil
        )
        snapshot.network = SystemStatusNetworkSnapshot(
            interfaceName: "en0",
            ipAddress: nil,
            publicIPAddress: nil,
            downloadBytesPerSecond: 1_024,
            uploadBytesPerSecond: 2_048,
            isConnected: true,
            isCollecting: false
        )

        XCTAssertEqual(
            SystemStatusMenuBarMetricsFormatter.text(snapshot: snapshot, kinds: [.memory, .cpu, .network]),
            "RAM 60% | CPU 13% 42° | NET ↓1K ↑2K"
        )
    }

    func testProductionSamplingScheduleBalancesForegroundDetailAndBackgroundCost() {
        let schedule = SystemStatusSamplingSchedule.production

        XCTAssertEqual(schedule.backgroundFastInterval, .seconds(30))
        XCTAssertEqual(schedule.menuBarFastInterval, .seconds(3))
        XCTAssertEqual(schedule.foregroundFastInterval, .seconds(3))
        XCTAssertEqual(schedule.backgroundSlowInterval, 300)
        XCTAssertEqual(schedule.menuBarSlowInterval, 3)
        XCTAssertEqual(schedule.foregroundSlowInterval, 15)
        XCTAssertEqual(schedule.backgroundProcessInterval, 300)
        XCTAssertEqual(schedule.foregroundProcessInterval, 15)
        XCTAssertEqual(schedule.backgroundHistoryInterval, 300)
        XCTAssertEqual(schedule.foregroundHistoryInterval, 60)
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

    func testDisplayHistoryFastPruneKeepsRecentSortedSamples() {
        let points = (0..<1_905).map { index in
            SystemStatusHistoryPoint(
                timestamp: TimeInterval(index),
                cpuUsage: Double(index) / 2_000
            )
        }

        let pruned = SystemStatusViewModel.prunedSortedDisplayHistory(
            points,
            referenceDate: Date(timeIntervalSince1970: 1_904)
        )

        XCTAssertEqual(pruned.count, 1_800)
        XCTAssertEqual(pruned.first?.timestamp, 105)
        XCTAssertEqual(pruned.last?.timestamp, 1_904)
    }

    func testPluginReusesViewModelAcrossComponentViews() {
        let viewModel = SystemStatusViewModel(sampler: StubSystemStatusSampler())
        let plugin = SystemStatusPlugin(viewModel: viewModel, storage: SystemStatusMemoryPluginStorage())

        let first = plugin.makeView(
            context: PluginComponentContext(
                pluginID: "system-status",
                dismiss: {},
                isPanelVisible: true
            )
        )
        let second = plugin.makeView(
            context: PluginComponentContext(
                pluginID: "system-status",
                dismiss: {},
                isPanelVisible: true
            )
        )

        XCTAssertFalse(String(describing: first).isEmpty)
        XCTAssertFalse(String(describing: second).isEmpty)
    }

}

private actor StubSystemStatusSampler: SystemStatusSampling {
    private(set) var fastCallCount = 0
    private(set) var slowCallCount = 0
    private(set) var processCallCount = 0
    private(set) var publicIPCallCount = 0

    var callCounts: (fast: Int, slow: Int, processes: Int, publicIP: Int) {
        (fastCallCount, slowCallCount, processCallCount, publicIPCallCount)
    }

    func collectFast(referenceDate: Date) async -> SystemStatusFastSample {
        fastCallCount += 1
        return SystemStatusFastSample(
            cpu: SystemStatusCPUSnapshot(
                usage: min(0.95, 0.20 + Double(fastCallCount) * 0.01),
                loadAverage1Minute: 1.42,
                temperatureCelsius: 42,
                systemPowerWatts: 8.5,
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

    func collectSlow() async -> SystemStatusSlowSample {
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
        return [
            SystemStatusTopProcess(
                pid: 1,
                displayName: "launchd",
                command: "/sbin/launchd",
                cpuPercent: 1,
                memoryPercent: 0.1,
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
        backgroundProcessInterval: 0,
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
        backgroundProcessInterval: 30,
        foregroundProcessInterval: 30,
        backgroundHistoryInterval: 30,
        foregroundHistoryInterval: 30
    )
}
