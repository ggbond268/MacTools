import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import HideNotchPlugin

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
        let state = plugin.rowState

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

        XCTAssertEqual(plugin.rowState.subtitle, "已开启")
        XCTAssertTrue(plugin.rowState.isOn)
        XCTAssertFalse(plugin.rowState.isEnabled)
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

        XCTAssertEqual(plugin.rowState.subtitle, "已开启")
        XCTAssertTrue(plugin.rowState.isOn)
    }

    func testToggleOnForwardsToController() async {
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
        plugin.handleAction(.setSwitch(true))
        for _ in 0 ..< 100 where controller.setEnabledCalls.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(controller.setEnabledCalls, [true])
        XCTAssertTrue(plugin.rowState.isOn)
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

        XCTAssertEqual(plugin.rowState.subtitle, "已开启")
        XCTAssertFalse(plugin.rowState.isEnabled)
    }

    func testCanonicalActionUsesTheWallpaperController() async throws {
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
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.setEnabledCalls, [true])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
    }

    func testCanonicalActionDefersMutationAndReportsSyncFailure() async throws {
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
        controller.syncResult = .failed(message: "wallpaper sync failed")
        let plugin = HideNotchPlugin(controller: controller)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let handle = try plugin.beginAction(ActionInvocation(
            reference: reference,
            source: .test,
            mode: .background
        ))

        XCTAssertTrue(controller.setEnabledCalls.isEmpty)
        let result = await handle.result()
        XCTAssertEqual(result, .failed(message: "wallpaper sync failed"))
        XCTAssertEqual(controller.setEnabledCalls, [true])
    }

    func testControllerRollsBackDesiredStateWhenWallpaperSyncFails() async {
        let store = InMemoryHideNotchStateStore()
        let masks = StubHideNotchDesktopMaskManager()
        masks.synchronizeErrors = [StubHideNotchDesktopMaskWindowBuilderError.forcedFailure]
        let controller = HideNotchController(
            displayCatalog: StubHideNotchDisplayCatalog(records: [
                makeHideNotchDisplayRecord(id: 1, displayIdentifier: "built-in"),
            ]),
            maskManager: masks,
            stateStore: store,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter()
        )

        let result = await controller.setEnabledAndWait(true)

        guard case .failed = result else {
            return XCTFail("Expected wallpaper sync failure, got \(result)")
        }
        XCTAssertFalse(store.desiredEnabled)
        XCTAssertFalse(controller.snapshot().isEnabled)
        XCTAssertGreaterThanOrEqual(masks.hideAllCallCount, 1)
    }

    func testCanonicalActionIsUnavailableWithoutANotchDisplay() throws {
        let plugin = HideNotchPlugin(controller: MockHideNotchWallpaperController())
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }
}
