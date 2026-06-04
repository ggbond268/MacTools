import XCTest
@testable import AutoHideMenuBarPlugin

@MainActor
final class AutoHideMenuBarPluginTests: XCTestCase {
    func testMetadataIdentifiesAutoHideMenuBarPlugin() {
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: MockMenuBarCommandRunner(),
            stateReader: { false }
        )

        XCTAssertEqual(plugin.metadata.id, "auto-hide-menu-bar")
        XCTAssertEqual(plugin.metadata.title, "自动隐藏菜单栏")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .switch)
    }

    func testInitialStateReflectsStateReader() {
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: MockMenuBarCommandRunner(),
            stateReader: { true }
        )

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已开启")
    }

    func testSwitchOnUpdatesMenuBarState() {
        let runner = MockMenuBarCommandRunner()
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(runner.setMenuBarAutohideCalls, [true])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchFailureKeepsPreviousStateAndSetsError() {
        let runner = MockMenuBarCommandRunner()
        runner.shouldFailSet = true
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testAutomationDeniedSurfacesActionableGuidance() {
        let runner = MockMenuBarCommandRunner()
        runner.shouldFailSet = true
        // -1743 == errAEEventNotPermitted: user denied the Automation permission.
        runner.failureCode = -1743
        runner.failureMessage = "Not authorized to send Apple events to System Events."
        let plugin = AutoHideMenuBarPlugin(
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

    func testConsentRequiredDenialSurfacesActionableGuidance() {
        let runner = MockMenuBarCommandRunner()
        runner.shouldFailSet = true
        // -1744 == errAEEventWouldRequireUserConsent: also an Automation denial.
        runner.failureCode = -1744
        runner.failureMessage = "User consent required to send Apple events to System Events."
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        let message = plugin.primaryPanelState.errorMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("自动化") == true)
        XCTAssertTrue(message?.contains("系统设置") == true)
        XCTAssertFalse(message?.contains("consent") == true)
    }

    func testNonPermissionFailureKeepsRawMessage() {
        let runner = MockMenuBarCommandRunner()
        runner.shouldFailSet = true
        runner.failureCode = 42
        runner.failureMessage = "some other failure"
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: runner,
            stateReader: { false }
        )

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "some other failure")
    }

    func testRefreshUpdatesStateWhenChangedExternally() {
        var externalState = false
        let plugin = AutoHideMenuBarPlugin(
            commandRunner: MockMenuBarCommandRunner(),
            stateReader: { externalState }
        )

        XCTAssertFalse(plugin.primaryPanelState.isOn)

        var stateChangeCount = 0
        plugin.onStateChange = { stateChangeCount += 1 }

        externalState = true
        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(stateChangeCount, 1)
    }
}

final class MockMenuBarCommandRunner: MenuBarCommandRunning {
    var shouldFailSet = false
    var failureCode = 1
    var failureMessage = "set failed"
    var setMenuBarAutohideCalls: [Bool] = []

    func setMenuBarAutohide(_ isEnabled: Bool) throws {
        if shouldFailSet {
            throw NSError(
                domain: "AutoHideMenuBarPluginTests",
                code: failureCode,
                userInfo: [NSLocalizedDescriptionKey: failureMessage]
            )
        }

        setMenuBarAutohideCalls.append(isEnabled)
    }
}
