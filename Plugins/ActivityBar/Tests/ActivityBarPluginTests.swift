import XCTest
import MacToolsPluginKit
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarPluginTests: XCTestCase {
    func testDashboardUsesReducedFallbackHeight() {
        let harness = makeHarness()
        let metrics = PluginComponentPanelLayoutMetrics.default

        XCTAssertEqual(
            metrics.itemHeight(forSpanHeight: harness.plugin.descriptor.span.height),
            912
        )
    }

    func testDashboardAdaptsToMeasuredContentHeight() {
        let harness = makeHarness()
        let metrics = PluginComponentPanelLayoutMetrics.default
        var notificationCount = 0
        harness.plugin.onStateChange = {
            notificationCount += 1
        }

        harness.plugin.dashboardContentHeightDidChange(501)

        XCTAssertEqual(
            metrics.itemHeight(forSpanHeight: harness.plugin.descriptor.span.height),
            504
        )
        XCTAssertEqual(notificationCount, 1)

        harness.plugin.dashboardContentHeightDidChange(503)
        harness.plugin.dashboardContentHeightDidChange(.nan)

        XCTAssertEqual(notificationCount, 1)
    }

    func testPrimaryPanelExpandsWithTrackingSwitchAndActions() throws {
        let harness = makeHarness()

        harness.plugin.handleAction(.setDisclosureExpanded(true))

        let state = harness.plugin.primaryPanelState
        let controls = try XCTUnwrap(state.detail?.primaryControls)

        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(controls.map(\.id), [
            "tracking-enabled",
            "open-input-monitoring",
            "install-hooks",
            "reset-today"
        ])
        XCTAssertEqual(controls.first?.kind, .switchRow)
        XCTAssertFalse(state.isOn)
    }

    func testPrimaryPanelShowsUninstallActionAfterHooksInstalled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()
        harness.plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(harness.plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.map(\.id), [
            "tracking-enabled",
            "open-input-monitoring",
            "uninstall-hooks",
            "reset-today"
        ])
    }

    func testSwitchStartsAndStopsRuntime() {
        let harness = makeHarness()

        harness.plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 0)
        XCTAssertTrue(harness.plugin.primaryPanelState.isOn)

        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.stopCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 0)
    }

    func testCanonicalTrackingActionUsesThePanelMutationPath() async throws {
        let harness = makeHarness()
        let reference = try XCTUnwrap(harness.plugin.actionCatalogEntries.first?.reference)

        let handle = try harness.plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        )

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 0)

        let result = await handle.result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 1)
    }

    func testCanonicalTrackingActionFailsClosedWhenPersistenceIsRejected() async throws {
        let harness = makeHarness()
        let reference = try XCTUnwrap(harness.plugin.actionCatalogEntries.first?.reference)
        harness.storage.enqueueWriteBehaviors(
            [.ignore],
            forKey: "activity-bar.tracking.enabled"
        )

        let result = try await harness.plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected rejected persistence to fail the action")
        }
        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 0)
        XCTAssertNil(harness.storage.object(forKey: "activity-bar.tracking.enabled"))
    }

    func testCanonicalResetActionRequiresConfirmationAndClearsToday() async throws {
        let harness = makeHarness()
        harness.controller.setTrackingEnabled(true)
        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        let entry = try XCTUnwrap(
            harness.plugin.actionCatalogEntries.first { $0.reference.key.actionID == "reset-today" }
        )
        let definition = try XCTUnwrap(
            harness.plugin.actionDefinitions.first { $0.key.actionID == "reset-today" }
        )

        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        let result = try await harness.plugin.beginAction(
            ActionInvocation(reference: entry.reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 0)
    }

    func testCanonicalResetRollsBackInputStatsWhenCodingPersistenceFails() async throws {
        let harness = makeHarness()
        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.controller.inputStats.flushPendingChanges()
        harness.controller.codingStats.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .userPromptSubmit,
                status: .processing,
                userPrompt: "keep this",
                tool: nil,
                interactive: true
            )
        )
        harness.storage.enqueueWriteBehaviors(
            [.ignore],
            forKey: "activity-bar.coding.days.v1"
        )
        let entry = try XCTUnwrap(
            harness.plugin.actionCatalogEntries.first { $0.reference.key.actionID == "reset-today" }
        )

        let result = try await harness.plugin.beginAction(
            ActionInvocation(reference: entry.reference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected the cross-store reset to fail")
        }
        XCTAssertEqual(harness.controller.todayInputStats.keystrokes, 1)
        XCTAssertEqual(harness.controller.todayCodingStats.wordCount, 2)

        let inputReloaded = ActivityBarStatsStore(storage: harness.storage)
        let codingReloaded = ActivityBarCodingSessionStore(storage: harness.storage)
        XCTAssertEqual(inputReloaded.today.keystrokes, 1)
        XCTAssertEqual(codingReloaded.today.wordCount, 2)
    }

    func testCanonicalResetFailsClosedOnUnreadableInputStats() async throws {
        let storage = ActivityBarMemoryStorage()
        storage.set("invalid", forKey: "activity-bar.input.days.v1")
        let harness = makeHarness(storage: storage)
        let entry = try XCTUnwrap(
            harness.plugin.actionCatalogEntries.first { $0.reference.key.actionID == "reset-today" }
        )

        let result = try await harness.plugin.beginAction(
            ActionInvocation(reference: entry.reference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected unreadable persisted input stats to fail the reset")
        }
        XCTAssertEqual(storage.object(forKey: "activity-bar.input.days.v1") as? String, "invalid")
    }

    func testCanonicalResetReconcilesInputStateWhenCrossStoreRollbackFails() async throws {
        let harness = makeHarness()
        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.controller.inputStats.flushPendingChanges()
        harness.storage.enqueueWriteBehaviors(
            [.accept, .corrupt],
            forKey: "activity-bar.input.days.v1"
        )
        harness.storage.enqueueWriteBehaviors(
            [.ignore],
            forKey: "activity-bar.coding.days.v1"
        )
        let entry = try XCTUnwrap(
            harness.plugin.actionCatalogEntries.first { $0.reference.key.actionID == "reset-today" }
        )

        let result = try await harness.plugin.beginAction(
            ActionInvocation(reference: entry.reference, source: .test, mode: .background)
        ).result()

        guard case .failed = result else {
            return XCTFail("Expected failed rollback to fail the reset")
        }
        XCTAssertEqual(harness.storage.object(forKey: "activity-bar.input.days.v1") as? String, "corrupt")
        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 0)
        XCTAssertNotNil(harness.controller.inputStats.loadError)
    }

    func testActivateStartsInstalledHookSocketWithoutInputTracking() {
        let storage = ActivityBarMemoryStorage()
        storage.set("2026-05-18 09:00", forKey: "activity-bar.hooks.installed-at")
        let harness = makeHarness(storage: storage)

        harness.plugin.activate(context: harness.context)

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 0)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.socketServer.isRunning)
        XCTAssertTrue(harness.plugin.componentPanelState.isActive)
        XCTAssertEqual(harness.plugin.componentPanelState.subtitle, "AI 监听中")
    }

    func testInstallHooksStartsSocketWithoutTrackingSwitch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 0)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.socketServer.isRunning)
    }

    func testDisablingTrackingKeepsInstalledHookSocketRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()
        harness.plugin.handleAction(.setSwitch(true))
        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.stopCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 0)
        XCTAssertTrue(harness.socketServer.isRunning)
    }

    func testUninstallHooksStopsSocketAndClearsInstalledState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()
        harness.controller.uninstallHooks()

        XCTAssertNil(harness.storage.string(forKey: "activity-bar.hooks.installed-at"))
        XCTAssertEqual(harness.controller.hookInstallState, .notInstalled)
        XCTAssertEqual(harness.socketServer.stopCallCount, 1)
        XCTAssertFalse(harness.socketServer.isRunning)
        XCTAssertFalse(harness.plugin.componentPanelState.isActive)
    }

    func testDeactivateForUpdatingStopsHookSocket() {
        let storage = ActivityBarMemoryStorage()
        storage.set("2026-05-18 09:00", forKey: "activity-bar.hooks.installed-at")
        let harness = makeHarness(storage: storage)

        harness.plugin.activate(context: harness.context)
        harness.plugin.deactivate(reason: .updating)

        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 1)
        XCTAssertFalse(harness.socketServer.isRunning)
    }

    func testInputTrackingDoesNotHideHookSocketStartError() {
        let storage = ActivityBarMemoryStorage()
        storage.set("2026-05-18 09:00", forKey: "activity-bar.hooks.installed-at")
        storage.set(true, forKey: "activity-bar.tracking.enabled")
        let harness = makeHarness(storage: storage)
        harness.socketServer.startError = ActivityBarSocketError.socketFailed(1)

        harness.plugin.activate(context: harness.context)

        XCTAssertEqual(harness.inputMonitor.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.controller.lastErrorMessage?.contains("AI 活动监听启动失败") == true)
    }

    func testExpandedTrackingSwitchReflectsEnabledState() throws {
        let harness = makeHarness()

        harness.plugin.handleAction(.setDisclosureExpanded(true))
        harness.plugin.handleAction(.setSwitch(true))

        let controls = try XCTUnwrap(harness.plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.first?.kind, .switchRow)
        XCTAssertTrue(harness.plugin.primaryPanelState.isOn)
    }

    func testMonitorEventsUpdateComponentSubtitle() {
        let harness = makeHarness()

        harness.plugin.handleAction(.setSwitch(true))
        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.inputMonitor.emit(.pointerClick(app: "Terminal"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 2)
        XCTAssertEqual(harness.plugin.componentPanelState.subtitle, "2 次输入")
    }

    func testMonitorEventsBatchPluginStateNotifications() {
        let harness = makeHarness(inputEventNotificationDelay: .seconds(60))
        var notificationCount = 0
        harness.plugin.onStateChange = {
            notificationCount += 1
        }

        harness.plugin.handleAction(.setSwitch(true))
        notificationCount = 0

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.inputMonitor.emit(.pointerClick(app: "Terminal"))
        harness.inputMonitor.emit(.scroll(app: "Terminal"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 3)
        XCTAssertEqual(notificationCount, 0)

        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(harness.storage.setCallCount(forKey: "activity-bar.input.days.v1"), 1)
    }

    func testHostShutdownFlushesPendingInputStats() {
        let harness = makeHarness()

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.plugin.deactivate(reason: .hostShutdown)

        let reloaded = ActivityBarStatsStore(storage: harness.storage)

        XCTAssertEqual(reloaded.today.totalInputs, 1)
    }

    func testHostShutdownFlushesActiveCodingDuration() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(hour: 10)
        let codingStats = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )
        let harness = makeHarness(storage: storage, codingStats: codingStats)

        harness.controller.codingStats.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .sessionStart,
                status: .processing,
                userPrompt: nil,
                tool: nil,
                interactive: true
            )
        )

        now = now.addingTimeInterval(10)
        harness.plugin.deactivate(reason: .hostShutdown)

        let reloaded = ActivityBarCodingSessionStore(
            storage: harness.storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        XCTAssertEqual(reloaded.today.durationSeconds, 10, accuracy: 0.1)
    }

    func testResetActionClearsToday() {
        let harness = makeHarness()

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 1)

        harness.plugin.handleAction(.invokeAction(controlID: "reset-today"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 0)
    }

    private func makeHarness(
        storage providedStorage: ActivityBarMemoryStorage? = nil,
        codingStats: ActivityBarCodingSessionStore? = nil,
        hookInstallerPaths: ActivityBarHookInstallerPaths? = nil,
        inputEventNotificationDelay: Duration = .milliseconds(750)
    ) -> Harness {
        let storage = providedStorage ?? ActivityBarMemoryStorage()
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
            socketServer: socketServer,
            codingStats: codingStats,
            hookInstallerPaths: hookInstallerPaths,
            inputEventNotificationDelay: inputEventNotificationDelay
        )
        let plugin = ActivityBarPlugin(context: context, controller: controller)

        return Harness(
            plugin: plugin,
            controller: controller,
            context: context,
            storage: storage,
            inputMonitor: inputMonitor,
            socketServer: socketServer
        )
    }

    private struct Harness {
        let plugin: ActivityBarPlugin
        let controller: ActivityBarController
        let context: PluginRuntimeContext
        let storage: ActivityBarMemoryStorage
        let inputMonitor: ActivityBarFakeInputMonitor
        let socketServer: ActivityBarFakeSocketServer
    }
}
