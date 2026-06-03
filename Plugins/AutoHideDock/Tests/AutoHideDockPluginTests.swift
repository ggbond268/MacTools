import XCTest
@testable import AutoHideDockPlugin

@MainActor
final class AutoHideDockPluginTests: XCTestCase {
    func testMetadataIdentifiesAutoHideDockPlugin() {
        let plugin = AutoHideDockPlugin(
            commandRunner: MockDockCommandRunner(),
            stateReader: { false }
        )

        XCTAssertEqual(plugin.metadata.id, "auto-hide-dock")
        XCTAssertEqual(plugin.metadata.title, "自动隐藏程序坞")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .switch)
    }

    func testInitialStateReflectsStateReader() {
        let plugin = AutoHideDockPlugin(
            commandRunner: MockDockCommandRunner(),
            stateReader: { true }
        )

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已开启")
    }

    func testSwitchOnUpdatesDockState() {
        let runner = MockDockCommandRunner()
        let plugin = AutoHideDockPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(runner.setDockAutohideCalls, [true])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsPreviousStateAndSetsError() {
        let runner = MockDockCommandRunner()
        runner.shouldFailSet = true
        let plugin = AutoHideDockPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testAutomationDeniedSurfacesActionableGuidance() {
        let runner = MockDockCommandRunner()
        runner.shouldFailSet = true
        // -1743 == errAEEventNotPermitted: user denied the Automation permission.
        runner.failureCode = -1743
        runner.failureMessage = "Not authorized to send Apple events to System Events."
        let plugin = AutoHideDockPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        let message = plugin.primaryPanelState.errorMessage
        XCTAssertNotNil(message)
        // The cryptic system message is replaced with actionable, localized guidance.
        XCTAssertTrue(message?.contains("自动化") == true)
        XCTAssertTrue(message?.contains("系统设置") == true)
        XCTAssertFalse(message?.contains("Not authorized") == true)
    }

    func testNonPermissionFailureKeepsRawMessage() {
        let runner = MockDockCommandRunner()
        runner.shouldFailSet = true
        runner.failureCode = 42
        runner.failureMessage = "some other failure"
        let plugin = AutoHideDockPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "some other failure")
    }
}

private final class MockDockCommandRunner: DockCommandRunning {
    var shouldFailSet = false
    var failureCode = 1
    var failureMessage = "set failed"
    var setDockAutohideCalls: [Bool] = []

    func setDockAutohide(_ isEnabled: Bool) throws {
        if shouldFailSet {
            throw NSError(
                domain: "AutoHideDockPluginTests",
                code: failureCode,
                userInfo: [NSLocalizedDescriptionKey: failureMessage]
            )
        }

        setDockAutohideCalls.append(isEnabled)
    }
}
