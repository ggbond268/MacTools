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
        viewModel.startMenuBar(requiresSlowSampling: false)
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
        sourceController.setMenuBarValues(.memory, values: [.swap, .usage])
        sourceController.setMenuBarStyle(.memory, style: .vertical)
        sourceController.setMenuBarValueArrangement(.memory, arrangement: .stacked)
        sourceController.setMenuBarStyle(.cpu, style: .minimal)
        sourceController.setProcessSort(.memory)

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
