import XCTest
@testable import MacTools

@MainActor
final class HideNotchPluginTests: XCTestCase {
    func testPanelStateDisablesSwitchWhenNoSupportedDisplayExists() {
        let controller = MockHideNotchWallpaperController()
        controller.snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: false,
            supportedDisplayCount: 0,
            managedDisplayCount: 0,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: false,
            isProcessing: false,
            isAwaitingDisplay: false,
            errorMessage: nil
        )

        let plugin = HideNotchPlugin(controller: controller)
        let state = plugin.panelState

        XCTAssertEqual(state.subtitle, "未检测到刘海屏")
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isOn)
    }

    func testPanelStateShowsWaitingSubtitleWhenEnabledWithoutSupportedDisplay() {
        let controller = MockHideNotchWallpaperController()
        controller.snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: false,
            supportedDisplayCount: 0,
            managedDisplayCount: 0,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: true,
            isProcessing: false,
            isAwaitingDisplay: true,
            errorMessage: nil
        )

        let plugin = HideNotchPlugin(controller: controller)

        XCTAssertEqual(plugin.panelState.subtitle, "已开启")
        XCTAssertTrue(plugin.panelState.isOn)
        XCTAssertFalse(plugin.panelState.isEnabled)
    }

    func testPanelStateShowsManagedDisplayCountWhenEnabled() {
        let controller = MockHideNotchWallpaperController()
        controller.snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: true,
            supportedDisplayCount: 2,
            managedDisplayCount: 2,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: true,
            isProcessing: false,
            isAwaitingDisplay: false,
            errorMessage: nil
        )

        let plugin = HideNotchPlugin(controller: controller)

        XCTAssertEqual(plugin.panelState.subtitle, "已开启")
        XCTAssertTrue(plugin.panelState.isOn)
    }

    func testToggleOnForwardsToController() {
        let controller = MockHideNotchWallpaperController()
        controller.snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: true,
            supportedDisplayCount: 1,
            managedDisplayCount: 0,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: false,
            isProcessing: false,
            isAwaitingDisplay: false,
            errorMessage: nil
        )

        let plugin = HideNotchPlugin(controller: controller)
        plugin.handlePanelAction(.setSwitch(true))

        XCTAssertEqual(controller.setEnabledCalls, [true])
        XCTAssertTrue(plugin.panelState.isOn)
    }

    func testPanelStateShowsEnabledSubtitleWhileProcessing() {
        let controller = MockHideNotchWallpaperController()
        controller.snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: true,
            supportedDisplayCount: 1,
            managedDisplayCount: 0,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: true,
            isProcessing: true,
            isAwaitingDisplay: false,
            errorMessage: nil
        )

        let plugin = HideNotchPlugin(controller: controller)

        XCTAssertEqual(plugin.panelState.subtitle, "已开启")
        XCTAssertFalse(plugin.panelState.isEnabled)
    }
}
