import MacToolsPluginKit
import XCTest
@testable import DuoStatusPlugin

@MainActor
final class DuoStatusPluginTests: XCTestCase {
    func testSettingsOnlyPluginStartsOnlyOnActivationAndRoutesClickToSettings() throws {
        let fixture = Fixture()
        let plugin = fixture.plugin
        XCTAssertNil(plugin.primaryPanel)
        XCTAssertNil(plugin.componentPanel)
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
        XCTAssertEqual(plugin.settingsPage?.body.layout, .form)
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
        XCTAssertTrue(try XCTUnwrap(fixture.menuBar.tooltip).hasPrefix(plugin.metadata.title))
    }

    func testHidingStopsMonitoringAndSavedPreferenceSurvivesRecreation() throws {
        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        var notifications = 0
        fixture.plugin.onStateChange = { notifications += 1 }
        fixture.plugin.handleSettingsAction(.setBoolean(controlID: "shows-menu-bar", value: false))
        XCTAssertFalse(fixture.monitor.isRunning)
        XCTAssertFalse(fixture.menuBar.isVisible)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(fixture.storage.object(forKey: "shows-menu-bar") as? Bool, false)

        let newMonitor = MonitorFake()
        let newMenuBar = MenuBarFake()
        let restored = DuoStatusPlugin(context: fixture.context, monitor: newMonitor, menuBar: newMenuBar)
        restored.activate(context: fixture.context)
        restored.refresh()
        XCTAssertFalse(restored.showsMenuBar)
        XCTAssertEqual(newMonitor.startCount, 0)
        XCTAssertFalse(newMenuBar.isVisible)
        guard case let .form(sections) = restored.settingsPage?.body,
              case let .rows(rows) = sections.first?.content,
              case let .toggle(isOn) = rows.first?.control else {
            return XCTFail("Expected a declarative visibility toggle")
        }
        XCTAssertFalse(isOn)

        restored.handleSettingsAction(.setBoolean(controlID: "shows-menu-bar", value: true))
        XCTAssertTrue(newMonitor.isRunning)
        XCTAssertTrue(newMenuBar.isVisible)
    }

    func testInactiveAndHiddenPluginIgnoreLateReadingsAndClicks() {
        for reason in [PluginDeactivationReason.disabled, .uninstalling, .updating, .hostShutdown] {
            let fixture = Fixture()
            fixture.plugin.activate(context: fixture.context)
            var settingsRequests = 0
            fixture.plugin.requestSettingsPresentation = { settingsRequests += 1 }
            fixture.plugin.deactivate(reason: reason)
            fixture.monitor.emit(.init(battery: .level(fraction: 0.4, isCharging: true)))
            fixture.menuBar.openSettings?()
            fixture.plugin.refresh()
            XCTAssertFalse(fixture.monitor.isRunning)
            XCTAssertFalse(fixture.menuBar.isVisible)
            XCTAssertEqual(settingsRequests, 0)
            XCTAssertTrue(fixture.plugin.showsMenuBar)
        }

        let fixture = Fixture()
        fixture.plugin.activate(context: fixture.context)
        fixture.plugin.handleSettingsAction(.setBoolean(controlID: "shows-menu-bar", value: false))
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
        weak var weakPlugin = plugin
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
        XCTAssertTrue(fixture.plugin.showsMenuBar)
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
        XCTAssertEqual(capabilities["primaryPanel"] as? Bool, plugin.primaryPanel != nil)
        XCTAssertEqual(capabilities["componentPanel"] as? Bool, plugin.componentPanel != nil)
        XCTAssertEqual(capabilities["settings"] as? String, "form")
        XCTAssertEqual(manifest["permissions"] as? [String], [])
        XCTAssertFalse(plugin is any PluginActionProviding)
    }

    @MainActor
    private struct Fixture {
        let storage = StorageFake()
        let monitor = MonitorFake()
        let menuBar = MenuBarFake()
        let context: PluginRuntimeContext
        let plugin: DuoStatusPlugin

        init() {
            context = PluginRuntimeContext(pluginID: DuoStatusPlugin.pluginID, storage: storage)
            plugin = DuoStatusPlugin(context: context, monitor: monitor, menuBar: menuBar)
        }
    }
}

@MainActor
private final class MonitorFake: DuoSystemStatusMonitoring {
    var snapshot = DuoSystemStatusSnapshot.unknown
    var onChange: ((DuoSystemStatusSnapshot) -> Void)?
    private(set) var isRunning = false
    private(set) var startCount = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
    }

    func stop() { isRunning = false }
    func refresh() {}

    func emit(_ snapshot: DuoSystemStatusSnapshot) {
        self.snapshot = snapshot
        onChange?(snapshot)
    }
}

@MainActor
private final class MenuBarFake: DuoStatusMenuBarPresenting {
    var openSettings: (() -> Void)?
    private(set) var snapshot: DuoSystemStatusSnapshot?
    private(set) var tooltip: String?
    private(set) var isVisible = false
    private(set) var updateCount = 0
    private(set) var creationCount = 0

    func update(snapshot: DuoSystemStatusSnapshot, tooltip: String) {
        if !isVisible { creationCount += 1 }
        isVisible = true
        self.snapshot = snapshot
        self.tooltip = tooltip
        updateCount += 1
    }

    func remove() {
        isVisible = false
        snapshot = nil
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
