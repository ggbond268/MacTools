import XCTest
@testable import MacTools
@testable import EmptyTrashPlugin

@MainActor
final class EmptyTrashPluginTests: XCTestCase {
    func testMetadataIdentifiesEmptyTrashPlugin() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.metadata.id, "empty-trash")
        XCTAssertEqual(plugin.metadata.title, "清空废纸篓")
    }

    func testControlStyleIsButton() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "清空")
    }

    func testInitialStateIsOffAndDisabled() {
        let plugin = EmptyTrashPlugin()

        let state = plugin.primaryPanelState
        XCTAssertFalse(state.isOn)
        XCTAssertFalse(state.isEnabled)
    }

    func testInitialSubtitleShowsEmpty() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "废纸篓为空")
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = EmptyTrashPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testPluginHostIncludesEmptyTrashWhenProvided() {
        let host = makePluginHostForTests(plugins: [EmptyTrashPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "empty-trash" })
    }

    func testPluginDescriptionMatches() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "清空废纸篓中的所有项目")
    }

    func testMenuActionBehaviorIsKeepPresented() {
        let plugin = EmptyTrashPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .keepPresented)
    }

    // MARK: - Failure classification

    func testAutomationDeniedStderrYieldsActionableGuidance() {
        let stderr = "execution error: Finder got an error: Not authorized to send Apple events to Finder. (-1743)"
        let message = EmptyTrashPlugin.emptyTrashFailureMessage(stderr: stderr)

        XCTAssertTrue(message.contains("自动化"))
        XCTAssertTrue(message.contains("访达"))
        XCTAssertFalse(message.contains("-1743"))
    }

    func testAutomationWouldRequireConsentStderrYieldsActionableGuidance() {
        // -1744 == errAEEventWouldRequireUserConsent: also an Automation denial.
        let stderr = "execution error: Finder got an error: Not authorized to send Apple events to Finder. (-1744)"
        let message = EmptyTrashPlugin.emptyTrashFailureMessage(stderr: stderr)

        XCTAssertTrue(message.contains("自动化"))
        XCTAssertTrue(message.contains("访达"))
        XCTAssertFalse(message.contains("-1744"))
    }

    func testNonPermissionStderrYieldsGenericMessage() {
        let stderr = "execution error: The operation couldn't be completed. (-30720)"
        let message = EmptyTrashPlugin.emptyTrashFailureMessage(stderr: stderr)

        XCTAssertEqual(message, "清空废纸篓失败")
    }
}
