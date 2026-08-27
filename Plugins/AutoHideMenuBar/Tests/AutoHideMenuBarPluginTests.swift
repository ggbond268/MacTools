import XCTest
import MacToolsPluginKit
@testable import AutoHideMenuBarPlugin

@MainActor
final class AutoHideMenuBarPluginTests: XCTestCase {
    func testInitialStateReflectsStateReader() {
        let plugin = makePlugin(stateReader: { true })

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已开启")
    }

    func testAutomationPermissionIsReportedAsOnDemand() {
        let state = makePlugin().permissionState(for: "automation")

        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
    }

    func testSwitchUpdatesMenuBarState() {
        let runner = MockMenuBarCommandRunner()
        let plugin = makePlugin(runner: runner)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(runner.calls, [true])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let runner = MockMenuBarCommandRunner(shouldFail: true)
        let plugin = makePlugin(runner: runner)

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testRefreshPublishesExternalStateChange() {
        var externalState = false
        let plugin = makePlugin(stateReader: { externalState })
        var notificationCount = 0
        plugin.onStateChange = { notificationCount += 1 }

        externalState = true
        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(notificationCount, 1)
    }

    func testStateResolutionPrefersGlobalKeyAndFallsBackToLegacyDockKey() {
        XCTAssertTrue(AutoHideMenuBarPlugin.resolvedMenuBarAutohideState(
            globalValue: true,
            dockValue: false
        ))
        XCTAssertTrue(AutoHideMenuBarPlugin.resolvedMenuBarAutohideState(
            globalValue: nil,
            dockValue: true
        ))
    }

    func testActionExecutesThroughSameMenuBarMutation() async throws {
        let runner = MockMenuBarCommandRunner()
        let plugin = makePlugin(runner: runner)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(runner.calls, [true])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
    }

    private func makePlugin(
        runner: MockMenuBarCommandRunner = MockMenuBarCommandRunner(),
        stateReader: @escaping () -> Bool = { false }
    ) -> AutoHideMenuBarPlugin {
        AutoHideMenuBarPlugin(commandRunner: runner, stateReader: stateReader)
    }
}

private final class MockMenuBarCommandRunner: MenuBarCommandRunning {
    let shouldFail: Bool
    private(set) var calls: [Bool] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func setMenuBarAutohide(_ isEnabled: Bool) throws {
        if shouldFail {
            throw NSError(domain: "AutoHideMenuBarPluginTests", code: 1)
        }
        calls.append(isEnabled)
    }
}
