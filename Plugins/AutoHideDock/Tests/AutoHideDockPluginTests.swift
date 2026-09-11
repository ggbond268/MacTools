import XCTest
import MacToolsPluginKit
@testable import AutoHideDockPlugin

@MainActor
final class AutoHideDockPluginTests: XCTestCase {
    func testInitialStateReflectsStateReader() {
        let plugin = AutoHideDockPlugin(
            commandRunner: MockDockCommandRunner(),
            stateReader: { true }
        )

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已开启")
    }

    func testAutomationPermissionIsReportedAsOnDemand() {
        let state = AutoHideDockPlugin(
            commandRunner: MockDockCommandRunner(),
            stateReader: { false }
        ).permissionState(for: "automation")

        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
    }

    func testSwitchUpdatesDockState() {
        let runner = MockDockCommandRunner()
        let plugin = AutoHideDockPlugin(commandRunner: runner, stateReader: { false })

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(runner.calls, [true])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsStateAndReportsError() {
        let runner = MockDockCommandRunner(shouldFail: true)
        let plugin = AutoHideDockPlugin(commandRunner: runner, stateReader: { false })

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testActionExecutesThroughSameDockMutation() async throws {
        let runner = MockDockCommandRunner()
        let plugin = AutoHideDockPlugin(commandRunner: runner, stateReader: { false })
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(runner.calls, [true])
        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
    }
}

private final class MockDockCommandRunner: DockCommandRunning {
    let shouldFail: Bool
    private(set) var calls: [Bool] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func setDockAutohide(_ isEnabled: Bool) throws {
        if shouldFail {
            throw NSError(domain: "AutoHideDockPluginTests", code: 1)
        }
        calls.append(isEnabled)
    }
}
