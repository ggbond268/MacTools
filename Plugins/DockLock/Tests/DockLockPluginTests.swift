import CoreGraphics
import MacToolsPluginKit
import XCTest
@testable import DockLockPlugin

@MainActor
final class DockLockPluginTests: XCTestCase {
    func testCursorAtBottomIsClampedWithoutChangingHorizontalPosition() {
        let location = CGPoint(x: 1_800, y: 1_000)

        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: location,
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertEqual(result, CGPoint(x: 1_800, y: 996))
    }

    func testCursorOutsideBottomInsetIsNotClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 1_800, y: 990),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testSingleDisplayIsNeverClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 400, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
            ]
        )

        XCTAssertNil(result)
    }

    func testCurrentDockDisplayIsNeverClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 400, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testSharedEdgeWithDisplayBelowIsNotClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 1_800, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
                screen(frame: CGRect(x: 1_440, y: -800, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testExposedPartOfPartiallySharedBottomEdgeIsStillClamped() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 2_200, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(
                    frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000),
                    bottomDockInset: 80
                ),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
                screen(frame: CGRect(x: 1_440, y: -800, width: 500, height: 800)),
            ]
        )

        XCTAssertEqual(result, CGPoint(x: 2_200, y: 996))
    }

    func testUnknownDockDisplayFailsOpen() {
        let result = DockLockCursorBoundary.clampedQuartzLocation(
            for: CGPoint(x: 1_800, y: 1_000),
            primaryDisplayHeight: 1_000,
            screens: [
                screen(frame: CGRect(x: 0, y: 0, width: 1_440, height: 1_000)),
                screen(frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 800)),
            ]
        )

        XCTAssertNil(result)
    }

    func testSideDockDoesNotEnableCursorClamping() {
        XCTAssertFalse(DockLockDockOrientation.isBottom(preferenceValue: "left"))
        XCTAssertFalse(DockLockDockOrientation.isBottom(preferenceValue: "right"))
        XCTAssertFalse(DockLockDockOrientation.isBottom(preferenceValue: nil))
        XCTAssertFalse(DockLockDockOrientation.isBottom(preferenceValue: 1))
        XCTAssertTrue(DockLockDockOrientation.isBottom(preferenceValue: "bottom"))
    }

    func testAutoHiddenDockDisablesCursorClamping() {
        XCTAssertTrue(
            DockLockDockPreferences.shouldClamp(
                orientationValue: "bottom",
                autoHideValue: false
            )
        )
        XCTAssertFalse(
            DockLockDockPreferences.shouldClamp(
                orientationValue: "bottom",
                autoHideValue: true
            )
        )
    }

    func testActivationStartsMonitorWhenPermissionIsGranted() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testDisablingStopsMonitorAndPersistsState() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })
        plugin.activate(context: context)

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testSettingsPageExposesPersistedEnableToggle() {
        let plugin = DockLockPlugin(
            context: makeContext(isEnabled: true),
            accessibilityTrusted: { true }
        )

        guard case let .form(sections) = plugin.settingsPage?.body,
              case let .rows(rows) = sections.first?.content,
              let row = rows.first,
              case let .toggle(isOn) = row.control
        else {
            return XCTFail("Expected a Dock Lock settings toggle")
        }

        XCTAssertEqual(row.title, "启用")
        XCTAssertNotEqual(row.title, plugin.metadata.title)
        XCTAssertEqual(row.description, "开启后防止程序坞在多显示器之间意外移动。")
        XCTAssertNotEqual(row.description, plugin.metadata.defaultDescription)
        XCTAssertTrue(isOn)
    }

    func testSettingsPageUsesValidPluginKitForm() throws {
        let plugin = DockLockPlugin(
            context: makeContext(),
            accessibilityTrusted: { true }
        )
        let page = try XCTUnwrap(plugin.settingsPage)

        XCTAssertEqual(page.body.layout, .form)
        XCTAssertNoThrow(try PluginSettingsValidator.validate(page))
    }

    func testSettingsEnableToggleUsesPrimaryPanelActivationLifecycle() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: false)
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })

        plugin.handleSettingsAction(
            .setBoolean(controlID: "dock-lock.settings.enabled", value: true)
        )

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertTrue(plugin.primaryPanelState.isOn)

        let enabledReloadedPlugin = DockLockPlugin(
            context: context,
            monitor: MockDockLockMonitor(),
            accessibilityTrusted: { true }
        )
        XCTAssertTrue(enabledReloadedPlugin.primaryPanelState.isOn)

        plugin.handleSettingsAction(
            .setBoolean(controlID: "dock-lock.settings.enabled", value: false)
        )

        XCTAssertEqual(monitor.stopCallCount, 1)
        XCTAssertFalse(plugin.primaryPanelState.isOn)

        let reloadedPlugin = DockLockPlugin(
            context: context,
            monitor: MockDockLockMonitor(),
            accessibilityTrusted: { true }
        )
        XCTAssertFalse(reloadedPlugin.primaryPanelState.isOn)
    }

    func testSettingsEnableToggleReportsMissingAccessibilityPermission() {
        let monitor = MockDockLockMonitor()
        let plugin = DockLockPlugin(
            context: makeContext(isEnabled: false),
            monitor: monitor,
            accessibilityTrusted: { false },
            requestAccessibilityTrust: { _ in false }
        )

        plugin.handleSettingsAction(
            .setBoolean(controlID: "dock-lock.settings.enabled", value: true)
        )

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testMissingPermissionDoesNotStartMonitor() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(
            context: context,
            monitor: monitor,
            accessibilityTrusted: { false },
            requestAccessibilityTrust: { _ in false }
        )

        plugin.activate(context: context)

        XCTAssertEqual(monitor.startCallCount, 0)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testFirstLaunchIsDisabled() {
        let monitor = MockDockLockMonitor()
        let context = makeContext()
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })

        plugin.activate(context: context)

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(monitor.startCallCount, 0)
    }

    func testUpdateDeactivationStopsMonitorBeforeReplacementActivates() {
        let monitor = MockDockLockMonitor()
        let context = makeContext(isEnabled: true)
        let plugin = DockLockPlugin(context: context, monitor: monitor, accessibilityTrusted: { true })
        plugin.activate(context: context)

        plugin.deactivate(reason: .updating)

        XCTAssertEqual(monitor.stopCallCount, 1)
    }

    func testCanonicalActionsExposeStatefulToggleAndDeterministicChoices() throws {
        let plugin = DockLockPlugin(
            context: makeContext(),
            monitor: MockDockLockMonitor(),
            accessibilityTrusted: { true }
        )

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.count, 3)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)
        XCTAssertEqual(plugin.actionDefinitions.map(\.externalInvocationPolicy), [.allowed, .allowed])
    }

    func testCanonicalEnableAndDisableActionsUseTheSharedMutationPath() async throws {
        let monitor = MockDockLockMonitor()
        let plugin = DockLockPlugin(
            context: makeContext(),
            monitor: monitor,
            accessibilityTrusted: { true }
        )
        let enable = try XCTUnwrap(plugin.actionCatalogEntries.dropFirst().first?.reference)
        let disable = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let enableResult = try await plugin.beginAction(
            ActionInvocation(reference: enable, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(enableResult, .succeeded())
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)

        let disableResult = try await plugin.beginAction(
            ActionInvocation(reference: disable, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(disableResult, .succeeded())
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertGreaterThanOrEqual(monitor.stopCallCount, 1)
    }

    func testEnableActionIsUnavailableWithoutAccessibilityPermission() throws {
        let plugin = DockLockPlugin(
            context: makeContext(),
            monitor: MockDockLockMonitor(),
            accessibilityTrusted: { false }
        )
        let enable = try XCTUnwrap(plugin.actionCatalogEntries.dropFirst().first?.reference)
        let disable = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: enable).isAvailable)
        XCTAssertTrue(plugin.actionAvailability(for: disable).isAvailable)
    }

    private func makeContext(isEnabled: Bool? = nil) -> PluginRuntimeContext {
        let storage = DockLockMemoryStorage()
        if let isEnabled {
            storage.set(isEnabled, forKey: "dock-lock.enabled")
        }
        return PluginRuntimeContext(pluginID: "dock-lock", storage: storage)
    }

    private func screen(
        frame: CGRect,
        bottomDockInset: CGFloat = 0
    ) -> DockLockCursorBoundary.ScreenGeometry {
        DockLockCursorBoundary.ScreenGeometry(
            frame: frame,
            visibleFrame: CGRect(
                x: frame.minX,
                y: frame.minY + bottomDockInset,
                width: frame.width,
                height: frame.height - bottomDockInset
            )
        )
    }
}

@MainActor
private final class MockDockLockMonitor: @preconcurrency DockLockMonitoring {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() -> Bool {
        startCallCount += 1
        return true
    }

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
private final class DockLockMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
