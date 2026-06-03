import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import BatteryChargeLimitPlugin

// MARK: - Mocks

@MainActor
private final class MockBatteryReader: BatteryChargeLimitReading {
    var snapshot: BatterySnapshot

    init(snapshot: BatterySnapshot = .empty) {
        self.snapshot = snapshot
    }

    func readSnapshot() -> BatterySnapshot { snapshot }
}

@MainActor
private final class MockBatteryWriter: BatteryChargeLimitWriting {
    var isHelperAvailable: Bool
    var capabilities: BatterySMCCapabilities
    var inhibitCalls: [Int] = []
    var resumeCalls: Int = 0
    var dischargeCalls: [Bool] = []
    var nextError: BatteryChargeWriteError?

    init(
        isHelperAvailable: Bool = true,
        capabilities: BatterySMCCapabilities = BatterySMCCapabilities(
            hasCHIE: false, hasCH0BC: true, hasBCLM: false, hasCH0I: true
        )
    ) {
        self.isHelperAvailable = isHelperAvailable
        self.capabilities = capabilities
    }

    func probeCapabilities() -> BatterySMCCapabilities { capabilities }

    @discardableResult
    func inhibitCharging(limitPercent: Int) -> BatteryChargeWriteError? {
        inhibitCalls.append(limitPercent)
        return nextError
    }

    @discardableResult
    func resumeCharging() -> BatteryChargeWriteError? {
        resumeCalls += 1
        return nextError
    }

    @discardableResult
    func setForceDischarge(_ on: Bool) -> BatteryChargeWriteError? {
        dischargeCalls.append(on)
        return nextError
    }
}

// MARK: - Tests

@MainActor
final class BatteryChargeLimitPluginTests: XCTestCase {

    // MARK: Metadata

    func testMetadataIdentifiesBatteryChargeLimitPlugin() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "battery-charge-limit")
        XCTAssertEqual(plugin.metadata.title, "电池充电上限")
    }

    func testControlStyleIsDisclosure() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .disclosure)
    }

    // MARK: Visibility

    func testPanelHiddenWhenNoBattery() {
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: .empty))

        XCTAssertFalse(plugin.primaryPanelState.isVisible)
    }

    func testPanelVisibleWhenBatteryPresent() {
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 65)))
        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.isVisible)
    }

    // MARK: Enable / Disable

    func testEnableTogglePersistsAndInhibitsAtOrAboveLimit() {
        let writer = MockBatteryWriter()
        // At/above the limit, enabling must inhibit charging immediately
        // (below the limit it auto-resumes instead — covered separately).
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 85)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(writer.inhibitCalls, [BatteryChargeLimits.defaultPercent])
    }

    func testDisableTogglePersistsAndResumesCharging() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertGreaterThanOrEqual(writer.resumeCalls, 1)
    }

    func testEnableWithUnsupportedHardwareSurfacesError() {
        let writer = MockBatteryWriter(capabilities: .none)
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    // MARK: Limit Changes

    func testLimitSliderUpdatesPersistedLimitOnEnd() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 70)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        // Lowering the limit below the current level must re-evaluate and inhibit.
        plugin.handleAction(.setSlider(controlID: "battery-limit-slider", value: 65, phase: .ended))

        XCTAssertEqual(plugin.store.limitPercent, 65)
        XCTAssertTrue(writer.inhibitCalls.contains(65))
    }

    func testLimitSliderChangedPhaseDoesNotPersist() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.setSlider(controlID: "battery-limit-slider", value: 70, phase: .changed))

        XCTAssertEqual(plugin.store.limitPercent, BatteryChargeLimits.defaultPercent)
    }

    // MARK: Mode Transitions

    func testHoldAtLimitAutoResumesBelowLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 80))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        writer.resumeCalls = 0

        // Auto-maintain: dropping below limit-hysteresis must resume charging on its own.
        reader.snapshot = makeSnapshot(level: 60)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .holdAtLimit)
        XCTAssertGreaterThanOrEqual(writer.resumeCalls, 1, "holdAtLimit must auto-resume below the limit")
    }

    func testAutoMaintainInhibitsAtLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        // Reaching the limit must stop charging.
        reader.snapshot = makeSnapshot(level: BatteryChargeLimits.defaultPercent)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .holdAtLimit)
        XCTAssertTrue(writer.inhibitCalls.contains(BatteryChargeLimits.defaultPercent))
    }

    func testChargeActionPausesAutoMaintain() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        writer.inhibitCalls.removeAll()

        plugin.handleAction(.invokeAction(controlID: "battery-charge-action"))

        XCTAssertEqual(plugin.store.mode, .manualPaused)
        XCTAssertFalse(writer.inhibitCalls.isEmpty, "Pausing must inhibit charging")
    }

    func testManualPausedDoesNotAutoResumeBelowLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-charge-action")) // -> manualPaused
        writer.resumeCalls = 0

        reader.snapshot = makeSnapshot(level: 40)
        plugin.refresh()
        reader.snapshot = makeSnapshot(level: 30)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .manualPaused)
        XCTAssertEqual(writer.resumeCalls, 0, "manualPaused must never auto-resume")
    }

    func testAutoInhibitFailureRetriesOnNextCycle() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        // Make the SMC write fail, then cross the limit twice. A transient failure
        // must NOT latch the direction — the next monitoring cycle has to retry.
        writer.nextError = .writeFailed("transient")
        writer.inhibitCalls.removeAll()

        reader.snapshot = makeSnapshot(level: 85)
        plugin.refresh()
        reader.snapshot = makeSnapshot(level: 85)
        plugin.refresh()

        XCTAssertGreaterThanOrEqual(
            writer.inhibitCalls.count, 2,
            "A failed auto-inhibit must be retried on the next cycle, not latched"
        )
    }

    func testForceDischargeStartsWhenSupportedAndAboveLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 90))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        plugin.handleAction(.invokeAction(controlID: "battery-discharge-action"))

        XCTAssertEqual(plugin.store.mode, .discharging)
        XCTAssertTrue(writer.dischargeCalls.contains(true))
    }

    func testForceDischargeStopsWhenReachingLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 90))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-discharge-action"))

        reader.snapshot = makeSnapshot(level: BatteryChargeLimits.defaultPercent)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .holdAtLimit)
    }

    // MARK: Permissions

    func testPermissionRequirementsIsEmpty() {
        let plugin = makePlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testSettingsSectionsIsEmpty() {
        let plugin = makePlugin()

        XCTAssertTrue(plugin.settingsSections.isEmpty)
    }

    func testShortcutDefinitionsIsEmpty() {
        let plugin = makePlugin()

        XCTAssertTrue(plugin.shortcutDefinitions.isEmpty)
    }

    // MARK: Host Integration

    func testPluginHostIncludesBatteryChargeLimitPlugin() {
        let host = makePluginHostForTests(plugins: [makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)))])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "battery-charge-limit" })
    }

    // MARK: - Helpers

    private func makePlugin(
        reader: MockBatteryReader? = nil,
        writer: MockBatteryWriter? = nil
    ) -> BatteryChargeLimitPlugin {
        let suiteName = "BatteryChargeLimitPluginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = UserDefaultsPluginStorage(pluginID: "battery-charge-limit", userDefaults: defaults)
        let context = PluginRuntimeContext(pluginID: "battery-charge-limit", storage: storage)
        return BatteryChargeLimitPlugin(
            context: context,
            reader: reader ?? MockBatteryReader(),
            writer: writer ?? MockBatteryWriter()
        )
    }

    private func makeSnapshot(level: Int, state: BatteryPowerState = .acPower, isOnAdapter: Bool = true) -> BatterySnapshot {
        BatterySnapshot(
            isAvailable: true,
            levelPercent: level,
            state: state,
            isOnAdapter: isOnAdapter
        )
    }
}
