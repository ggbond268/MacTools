import MacToolsPluginKit
import XCTest
@testable import DuoStatusPlugin
@testable import MacTools

@MainActor
final class DuoStatusPluginTests: XCTestCase {
    func testSettingsOnlyPluginStartsOnlyOnActivationAndRoutesClickToSettings() throws {
        let fixture = Fixture()
        let plugin = fixture.plugin
        XCTAssertFalse(plugin.panelItems.contains { $0.kind == .row })
        XCTAssertFalse(plugin.panelItems.contains { $0.kind == .widget })
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
        XCTAssertEqual(fixture.monitor.startCount, 0)
        XCTAssertFalse(fixture.menuBar.isVisible)

        var settingsRequests = 0
        plugin.requestSettingsPresentation = { settingsRequests += 1 }
        fixture.menuBar.openSettings?()
        XCTAssertEqual(settingsRequests, 0)
        plugin.activate(context: fixture.context)
        plugin.activate(context: fixture.context)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertTrue(fixture.menuBar.isVisible)
        fixture.menuBar.openSettings?()
        XCTAssertEqual(settingsRequests, 1)

        fixture.monitor.emit(.init(battery: .notPresent, wifi: .off, network: .disconnected))
        XCTAssertEqual(fixture.menuBar.snapshot?.battery, .notPresent)
    }

    func testPlacementSwitchReusesMonitoringAndRestoresStandaloneItem() throws {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        var notifications = 0
        fixture.plugin.onStateChange = { notifications += 1 }
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "placement", optionID: "primary"))
        XCTAssertTrue(fixture.monitor.isRunning)
        XCTAssertFalse(fixture.menuBar.isVisible)
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(fixture.plugin.placement, .primary)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "placement", optionID: "standalone"))
        XCTAssertTrue(fixture.monitor.isRunning)
        XCTAssertTrue(fixture.menuBar.isVisible)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertNil(fixture.coordinator.primaryIconOwner)
    }

    func testInactivePluginIgnoresLateReadingsAndClicks() {
        for reason in [PluginDeactivationReason.disabled, .uninstalling, .updating, .hostShutdown] {
            let fixture = Fixture()
            fixture.plugin.activate(context: fixture.context)
            var settingsRequests = 0
            fixture.plugin.requestSettingsPresentation = { settingsRequests += 1 }
            fixture.coordinator.unregister(pluginID: DuoStatusPlugin.pluginID, reason: reason)
            fixture.plugin.deactivate(reason: reason)
            fixture.monitor.emit(.init(battery: .level(fraction: 0.4, isCharging: true)))
            fixture.menuBar.openSettings?()
            fixture.plugin.refresh()
            XCTAssertFalse(fixture.monitor.isRunning)
            XCTAssertFalse(fixture.menuBar.isVisible)
            XCTAssertEqual(settingsRequests, 0)
            XCTAssertEqual(fixture.plugin.placement, .standalone)
        }

        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "placement", optionID: "primary"))
        fixture.monitor.emit(.init(battery: .notPresent))
        XCTAssertFalse(fixture.menuBar.isVisible)
    }

    func testActivityPausesMonitoringWithoutCreatingDuplicateItems() {
        let fixture = Fixture()
        fixture.plugin.applicationActivityStateDidChange(.systemSleeping)
        fixture.plugin.activate(context: fixture.context)
        XCTAssertFalse(fixture.monitor.isRunning)
        XCTAssertTrue(fixture.menuBar.isVisible)

        fixture.plugin.applicationActivityStateDidChange(.interactive)
        XCTAssertTrue(fixture.monitor.isRunning)
        for state in [PluginApplicationActivityState.sessionInactive, .displayAsleep, .systemSleeping, .waking] {
            fixture.plugin.applicationActivityStateDidChange(state)
            XCTAssertFalse(fixture.monitor.isRunning)
            let updates = fixture.menuBar.updateCount
            fixture.monitor.emit(.init(wifi: .off))
            XCTAssertEqual(fixture.menuBar.updateCount, updates)
        }
        fixture.plugin.applicationActivityStateDidChange(.interactive)
        XCTAssertTrue(fixture.monitor.isRunning)
        XCTAssertEqual(fixture.menuBar.creationCount, 1)
    }

    func testDeinitStopsResourcesAndClearsCallbacks() {
        let storage = StorageFake()
        let monitor = MonitorFake()
        let menuBar = MenuBarFake()
        let context = PluginRuntimeContext(pluginID: DuoStatusPlugin.pluginID, storage: storage)
        var plugin: DuoStatusPlugin? = DuoStatusPlugin(context: context, monitor: monitor, menuBar: menuBar)
        weak let weakPlugin = plugin
        plugin?.activate(context: context)
        plugin = nil
        XCTAssertNil(weakPlugin)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(menuBar.isVisible)
        XCTAssertNil(monitor.onChange)
        XCTAssertNil(menuBar.openSettings)
    }

    func testUnrelatedSettingDoesNotPersistOrChangeVisibility() {
        let fixture = Fixture()
        fixture.plugin.handleSettingsAction(.setBoolean(controlID: "unknown", value: false))
        XCTAssertEqual(fixture.plugin.placement, .standalone)
        XCTAssertNil(fixture.storage.object(forKey: "shows-menu-bar"))
        XCTAssertEqual(fixture.monitor.startCount, 0)
    }

    func testFactoryAndManifestAgreeOnSettingsOnlyCapabilities() throws {
        let fixture = Fixture()
        let provider = try DuoStatusPluginFactory.makeProvider(context: fixture.context)
        let plugins = provider.makePlugins()
        XCTAssertEqual(plugins.count, 1)
        let plugin = try XCTUnwrap(plugins.first)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugin.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
        XCTAssertEqual(manifest["id"] as? String, plugin.metadata.id)
        XCTAssertEqual(capabilities["panelItems"] as? [String], plugin.panelItems.map { $0.kind.rawValue })
        XCTAssertEqual(capabilities["settings"] as? String, "form")
        XCTAssertEqual(manifest["permissions"] as? [String], [])
        XCTAssertFalse(plugin is any PluginActionProviding)
    }

    func testAudioIsMonitoredOnlyWhileAnOptionRendersIt() {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        XCTAssertEqual(fixture.monitor.refreshScope, [.battery, .wifi])

        fixture.plugin.handleSettingsAction(.setSelection(controlID: "bottom-indicator", optionID: "volume"))
        XCTAssertEqual(fixture.monitor.refreshScope, [.battery, .wifi, .volume])
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "bottom-indicator", optionID: "wifi"))
        XCTAssertEqual(fixture.monitor.refreshScope, [.battery, .wifi])

        fixture.plugin.handleSettingsAction(.setBoolean(controlID: "shows-bluetooth-audio-glyph", value: true))
        XCTAssertEqual(fixture.monitor.refreshScope, [.battery, .wifi, .volume])
        fixture.plugin.handleSettingsAction(.setBoolean(controlID: "shows-bluetooth-audio-glyph", value: false))
        XCTAssertEqual(fixture.monitor.refreshScope, [.battery, .wifi])
    }

    func testUntouchedOptionsKeepShippingIconAndPersistNothing() {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        XCTAssertEqual(fixture.menuBar.options, .default)
        XCTAssertNil(fixture.storage.object(forKey: "icon-size"))
        XCTAssertNil(fixture.storage.object(forKey: "bottom-indicator"))
    }

    func testOptionChangeRedrawsAndSurvivesRelaunch() {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        var iconChanges = 0
        fixture.plugin.onMenuBarIconChange = { _ in iconChanges += 1 }
        let updates = fixture.menuBar.updateCount

        fixture.plugin.handleSettingsAction(.setSelection(controlID: "icon-size", optionID: "large"))
        fixture.plugin.handleSettingsAction(.setBoolean(controlID: "distinguishes-hotspot", value: true))
        XCTAssertEqual(fixture.menuBar.options?.iconSize, .large)
        XCTAssertEqual(fixture.menuBar.options?.distinguishesHotspot, true)
        XCTAssertEqual(fixture.menuBar.updateCount, updates + 2)
        XCTAssertEqual(iconChanges, 2)

        // Re-sending the current value is not a change.
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "icon-size", optionID: "large"))
        XCTAssertEqual(iconChanges, 2)

        let menuBar = MenuBarFake()
        let relaunched = DuoStatusPlugin(context: fixture.context, monitor: MonitorFake(), menuBar: menuBar)
        let coordinator = PluginMenuBarIconCoordinator(userDefaults: fixture.defaults)
        coordinator.synchronize(with: [relaunched], pendingPluginIDs: [])
        relaunched.activate(context: fixture.context)
        XCTAssertEqual(menuBar.options?.iconSize, .large)
        XCTAssertEqual(menuBar.options?.distinguishesHotspot, true)
    }

    func testCriticalThresholdPersistsOnlyCommittedClampedValues() {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        fixture.plugin.handleSettingsAction(.setNumber(
            controlID: "battery-critical-threshold", value: 35, phase: .changed
        ))
        XCTAssertNil(fixture.storage.object(forKey: "battery-critical-threshold"))
        fixture.plugin.handleSettingsAction(.setNumber(
            controlID: "battery-critical-threshold", value: 90, phase: .committed
        ))
        XCTAssertEqual(fixture.storage.object(forKey: "battery-critical-threshold") as? Int, 50)
        XCTAssertEqual(fixture.menuBar.options?.batteryCriticalThreshold, 50)
    }

    func testTooltipNamesPreciseWiFiStateAndDotSource() throws {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        // The hotspot glyph is off by default, but the tooltip still says what it is.
        fixture.monitor.emit(.init(wifi: .hotspot, wifiSignalLevel: 3, network: .connected,
                                   volume: .init(scalar: 0.5)))
        let tooltip = try XCTUnwrap(fixture.menuBar.tooltip)
        XCTAssertTrue(tooltip.contains("3/4"))
        XCTAssertNotEqual(tooltip, try tooltipText(for: .connected(level: 3)))
        XCTAssertFalse(tooltip.contains("50%"))

        fixture.plugin.handleSettingsAction(.setSelection(controlID: "bottom-indicator", optionID: "volume"))
        XCTAssertTrue(try XCTUnwrap(fixture.menuBar.tooltip).contains("50%"))
    }

    func testVolumeStyleIsOfferedOnlyForVolumeAndSurvivesRelaunch() throws {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        XCTAssertFalse(try settingsRowIDs(fixture.plugin).contains("volume-style"))

        fixture.plugin.handleSettingsAction(.setSelection(controlID: "bottom-indicator", optionID: "volume"))
        XCTAssertTrue(try settingsRowIDs(fixture.plugin).contains("volume-style"))
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "volume-style", optionID: "bar"))
        XCTAssertEqual(fixture.menuBar.options?.volumeStyle, .bar)

        let menuBar = MenuBarFake()
        let relaunched = DuoStatusPlugin(context: fixture.context, monitor: MonitorFake(), menuBar: menuBar)
        let coordinator = PluginMenuBarIconCoordinator(userDefaults: fixture.defaults)
        coordinator.synchronize(with: [relaunched], pendingPluginIDs: [])
        relaunched.activate(context: fixture.context)
        XCTAssertEqual(menuBar.options?.volumeStyle, .bar)
    }

    private func settingsRowIDs(_ plugin: DuoStatusPlugin) throws -> [String] {
        guard case let .form(sections) = plugin.settingsPage?.body else {
            XCTFail("Missing form")
            return []
        }
        return sections.flatMap { section -> [String] in
            guard case let .rows(rows) = section.content else { return [] }
            return rows.map(\.id)
        }
    }

    private func tooltipText(for wifi: DuoSystemStatusSnapshot.WiFi) throws -> String {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        fixture.monitor.emit(.init(wifi: wifi, network: .connected))
        return try XCTUnwrap(fixture.menuBar.tooltip)
    }

    @MainActor
    private final class Fixture {
        let storage = StorageFake()
        let monitor = MonitorFake()
        let menuBar = MenuBarFake()
        let context: PluginRuntimeContext
        let plugin: DuoStatusPlugin
        let suiteName = "DuoStatusPluginTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let coordinator: PluginMenuBarIconCoordinator

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            coordinator = PluginMenuBarIconCoordinator(userDefaults: defaults)
            context = PluginRuntimeContext(pluginID: DuoStatusPlugin.pluginID, storage: storage)
            plugin = DuoStatusPlugin(context: context, monitor: monitor, menuBar: menuBar)
            coordinator.synchronize(with: [plugin], pendingPluginIDs: [])
        }

        isolated deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testConflictKeepsStandaloneAndShowsInlineError() throws {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        let owner = PluginMenuBarIconOwner(pluginID: "other", iconID: "status", pluginTitle: "Other Status")
        fixture.plugin.menuBarIconHostContext = PluginMenuBarIconHostContext(
            placement: { _ in .standalone }, primaryIconOwner: { owner },
            requestPlacement: { _, _ in .failure(.occupied(owner: owner)) }
        )
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "placement", optionID: "primary"))
        XCTAssertEqual(fixture.plugin.placement, .standalone)
        XCTAssertTrue(fixture.menuBar.isVisible)
        guard case let .form(sections) = fixture.plugin.settingsPage?.body,
              case let .rows(rows) = sections.first?.content else { return XCTFail("Missing form") }
        XCTAssertTrue(try XCTUnwrap(rows.first?.error).contains("Other Status"))
        fixture.plugin.menuBarIconPlacementDidChange()
        guard case let .form(updated) = fixture.plugin.settingsPage?.body,
              case let .rows(updatedRows) = updated.first?.content else { return XCTFail("Missing form") }
        XCTAssertNil(updatedRows.first?.error)
    }

    func testRestoredPrimaryPlacementWaitsForHostWithoutCreatingStandaloneItem() throws {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        fixture.plugin.handleSettingsAction(.setSelection(controlID: "placement", optionID: "primary"))
        fixture.coordinator.deactivateAll(reason: .hostShutdown)
        fixture.plugin.deactivate(reason: .hostShutdown)
        let menuBar = MenuBarFake()
        let monitor = MonitorFake()
        let restored = DuoStatusPlugin(context: fixture.context, monitor: monitor, menuBar: menuBar)
        restored.activate(context: fixture.context)
        XCTAssertEqual(menuBar.creationCount, 0)
        XCTAssertEqual(monitor.startCount, 0)
        let coordinator = PluginMenuBarIconCoordinator(userDefaults: fixture.defaults)
        coordinator.synchronize(with: [restored], pendingPluginIDs: [])
        XCTAssertEqual(restored.placement, .primary)
        XCTAssertEqual(menuBar.creationCount, 0)
        XCTAssertEqual(monitor.startCount, 1)
    }
}

@MainActor
private final class MonitorFake: DuoSystemStatusMonitoring {
    var snapshot = DuoSystemStatusSnapshot.unknown
    var onChange: ((DuoSystemStatusSnapshot) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var refreshScope: DuoSystemStatusRefreshScope?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    func stop() { isRunning = false }
    func refresh() {}
    func setRefreshScope(_ scope: DuoSystemStatusRefreshScope) { refreshScope = scope }

    func emit(_ snapshot: DuoSystemStatusSnapshot) {
        self.snapshot = snapshot
        onChange?(snapshot)
    }
}

@MainActor
private final class MenuBarFake: DuoStatusMenuBarPresenting {
    var openSettings: (() -> Void)?
    private(set) var snapshot: DuoSystemStatusSnapshot?
    private(set) var options: DuoStatusIconOptions?
    private(set) var tooltip: String?
    private(set) var isVisible = false
    private(set) var updateCount = 0
    private(set) var creationCount = 0

    func update(snapshot: DuoSystemStatusSnapshot, options: DuoStatusIconOptions, tooltip: String) {
        if !isVisible { creationCount += 1 }
        isVisible = true
        self.snapshot = snapshot
        self.options = options
        self.tooltip = tooltip
        updateCount += 1
    }

    func remove() {
        isVisible = false
        snapshot = nil
        options = nil
        tooltip = nil
    }
}

@MainActor
private final class StorageFake: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
