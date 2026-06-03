import XCTest
import MacToolsPluginKit
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarPluginTests: XCTestCase {
    func testMetadataAndPanelsAreExposed() {
        let harness = makeHarness()

        XCTAssertEqual(harness.plugin.metadata.id, "activity-bar")
        XCTAssertEqual(harness.plugin.metadata.title, "活动统计")
        XCTAssertEqual(harness.plugin.primaryPanelDescriptor.controlStyle, .switch)
        XCTAssertEqual(harness.plugin.descriptor.span, PluginComponentSpan(width: 4, height: 127)!)
    }

    func testSwitchStartsAndStopsRuntime() {
        let harness = makeHarness()

        harness.plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.plugin.primaryPanelState.isOn)

        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.stopCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 1)
    }

    func testMonitorEventsUpdateComponentSubtitle() {
        let harness = makeHarness()

        harness.plugin.handleAction(.setSwitch(true))
        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.inputMonitor.emit(.pointerClick(app: "Terminal"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 2)
        XCTAssertEqual(harness.plugin.componentPanelState.subtitle, "2 次输入")
    }

    func testResetActionClearsToday() {
        let harness = makeHarness()

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 1)

        harness.plugin.handleAction(.invokeAction(controlID: "reset-today"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 0)
    }

    func testRefreshRetriesEventTapAfterPermissionGranted() {
        let harness = makeHarness()
        harness.plugin.handleAction(.setSwitch(true)) // tracking on

        // Simulate the tap having been denied Input Monitoring on first start,
        // then the user granting the permission in System Settings.
        harness.inputMonitor.status = .inputMonitoringDenied
        harness.inputMonitor.statusAfterRetry = .running

        // A panel appear / refresh must re-attempt the tap and recover.
        harness.plugin.refresh()

        XCTAssertGreaterThanOrEqual(harness.inputMonitor.retryCallCount, 1)
        XCTAssertEqual(harness.controller.monitorStatus, .running)
    }

    func testRefreshDoesNotRetryWhenTrackingDisabled() {
        let harness = makeHarness()
        // Tracking is off by default; a denied tap should not be retried.
        harness.inputMonitor.status = .inputMonitoringDenied

        harness.plugin.refresh()

        XCTAssertEqual(harness.inputMonitor.retryCallCount, 0)
    }

    private func makeHarness() -> Harness {
        let storage = ActivityBarMemoryStorage()
        let inputMonitor = ActivityBarFakeInputMonitor()
        let socketServer = ActivityBarFakeSocketServer()
        let context = PluginRuntimeContext(
            pluginID: ActivityBarConstants.pluginID,
            storage: storage,
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        )
        let controller = ActivityBarController(
            context: context,
            inputMonitor: inputMonitor,
            socketServer: socketServer
        )
        let plugin = ActivityBarPlugin(context: context, controller: controller)

        return Harness(
            plugin: plugin,
            controller: controller,
            inputMonitor: inputMonitor,
            socketServer: socketServer
        )
    }

    private struct Harness {
        let plugin: ActivityBarPlugin
        let controller: ActivityBarController
        let inputMonitor: ActivityBarFakeInputMonitor
        let socketServer: ActivityBarFakeSocketServer
    }
}
