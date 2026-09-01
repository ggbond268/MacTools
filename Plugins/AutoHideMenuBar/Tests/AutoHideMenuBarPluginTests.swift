import XCTest
import MacToolsPluginKit
@testable import AutoHideMenuBarPlugin

@MainActor
final class AutoHideMenuBarPluginTests: XCTestCase {
    func testInitialStateReflectsExactMode() {
        let plugin = makePlugin(mode: .desktopOnly)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "On Desktop Only")
    }

    func testAutomationPermissionIsReportedAsOnDemand() {
        let state = makePlugin().permissionState(for: "automation")
        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
    }

    func testSwitchMapsToAlwaysAndNeverWithoutChangingSetEnabledCompatibility() {
        let controller = MockMenuBarAutoHideController(mode: .never)
        let plugin = makePlugin(controller: controller)
        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSwitch(false))
        XCTAssertEqual(controller.calls, [.always, .never])
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let controller = MockMenuBarAutoHideController(mode: .never, shouldFail: true)
        let plugin = makePlugin(controller: controller)
        plugin.handleAction(.setSwitch(true))
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testRefreshPublishesExternalModeChange() {
        let controller = MockMenuBarAutoHideController(mode: .never)
        let plugin = makePlugin(controller: controller)
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }
        controller.mode = .fullScreenOnly
        plugin.refresh()
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "In Full Screen Only")
        XCTAssertEqual(notificationCount, 1)
    }

    func testEveryPreferencePairResolvesToDistinctMode() {
        XCTAssertEqual(MenuBarAutoHideController.resolvedMode(desktopAutoHide: true, visibleInFullScreen: false), .always)
        XCTAssertEqual(MenuBarAutoHideController.resolvedMode(desktopAutoHide: true, visibleInFullScreen: true), .desktopOnly)
        XCTAssertEqual(MenuBarAutoHideController.resolvedMode(desktopAutoHide: false, visibleInFullScreen: false), .fullScreenOnly)
        XCTAssertEqual(MenuBarAutoHideController.resolvedMode(desktopAutoHide: false, visibleInFullScreen: true), .never)
    }

    func testSetModeActionUsesExactModeAndPublishesActiveEntry() async throws {
        let controller = MockMenuBarAutoHideController(mode: .never)
        let plugin = makePlugin(controller: controller)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first {
            $0.reference.key.actionID == "set-mode"
                && $0.reference.parameters["mode"] == .string("desktop-only")
        }?.reference)
        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.calls, [.desktopOnly])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled", "set-mode"])
        XCTAssertEqual(plugin.actionCatalogEntries.first {
            $0.reference.parameters["mode"] == .string("desktop-only")
        }?.presentationState, .active)
    }

    private func makePlugin(
        mode: MenuBarAutoHideMode = .never,
        controller: MockMenuBarAutoHideController? = nil
    ) -> AutoHideMenuBarPlugin {
        AutoHideMenuBarPlugin(controller: controller ?? MockMenuBarAutoHideController(mode: mode))
    }
}

@MainActor
private final class MockMenuBarAutoHideController: MenuBarAutoHideControlling {
    var mode: MenuBarAutoHideMode
    let shouldFail: Bool
    private(set) var calls: [MenuBarAutoHideMode] = []

    init(mode: MenuBarAutoHideMode, shouldFail: Bool = false) {
        self.mode = mode
        self.shouldFail = shouldFail
    }

    func read() throws -> MenuBarAutoHideMode { mode }

    func setMode(_ mode: MenuBarAutoHideMode) throws {
        if shouldFail { throw NSError(domain: "AutoHideMenuBarPluginTests", code: 1) }
        calls.append(mode)
        self.mode = mode
    }
}
