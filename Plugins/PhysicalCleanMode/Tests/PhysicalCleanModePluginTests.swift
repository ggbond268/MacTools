import XCTest
import MacToolsPluginKit
@testable import PhysicalCleanModePlugin

@MainActor
final class PhysicalCleanModePluginTests: XCTestCase {
    func testEntryButtonsPreservePermissionGuardAndStayInactiveOnDenial() throws {
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { false },
            accessibilityRequester: { _ in false }
        )
        var guidance: [String] = []
        plugin.requestPermissionGuidance = { guidance.append($0) }
        let rowItem = try XCTUnwrap(plugin.panelItems.first)
        guard case let .row(row) = rowItem.content else { return XCTFail("Expected row") }
        XCTAssertEqual(rowItem.id, "control")
        XCTAssertEqual(rowItem.initialPlacement, .featurePanel)
        XCTAssertEqual(row.descriptor.controlStyle, .button)
        XCTAssertEqual(row.descriptor.menuActionBehavior, .dismissBeforeHandling)
        XCTAssertEqual(row.descriptor.buttonTitle, "开启")
        row.action(.invokeAction(controlID: "execute"))

        let item = try XCTUnwrap(plugin.panelItems.last)
        guard case let .widget(widget) = item.content else { return XCTFail("Expected widget") }
        XCTAssertEqual(item.id, "quick-control")
        XCTAssertNil(item.initialPlacement)
        XCTAssertFalse(widget.state.isActive)
        XCTAssertEqual(guidance, ["accessibility"])
        XCTAssertEqual(widget.state.errorMessage, plugin.rowState.errorMessage)
    }

    func testEntryButtonRequiresAnEmergencyExitShortcut() throws {
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { true },
            accessibilityRequester: { _ in XCTFail("Should not request granted permission"); return true }
        )
        plugin.handleAction(.invokeAction(controlID: "execute"))

        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertTrue(plugin.rowState.isEnabled)
        XCTAssertNotNil(plugin.rowState.errorMessage)
        let item = try XCTUnwrap(plugin.panelItems.last)
        guard case let .widget(widget) = item.content else { return XCTFail("Expected widget") }
        XCTAssertFalse(widget.state.isActive)
        XCTAssertEqual(widget.state.errorMessage, plugin.rowState.errorMessage)
    }

    func testLegacySwitchAndUnknownActionsCannotEnterMode() {
        var permissionReads = 0
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { permissionReads += 1; return false },
            accessibilityRequester: { _ in XCTFail("Unexpected permission request"); return false }
        )
        permissionReads = 0
        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSwitch(false))
        plugin.handleAction(.invokeAction(controlID: "unknown"))

        XCTAssertEqual(permissionReads, 0)
        XCTAssertFalse(plugin.rowState.isOn)
        XCTAssertNil(plugin.rowState.errorMessage)
    }

    func testCanonicalEnterActionIsGuardedAndForegroundOnly() throws {
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { false },
            accessibilityRequester: { _ in false }
        )
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.key.actionID, "enter")
        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .unavailable)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive])
        XCTAssertEqual(
            plugin.permissionRequirementIDs(for: definition.key),
            ["accessibility"]
        )
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }

    func testCanonicalEnterActionRequiresAValidEmergencyExitShortcut() throws {
        let plugin = PhysicalCleanModePlugin(
            accessibilityReader: { true },
            accessibilityRequester: { _ in true }
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        plugin.shortcutBindingResolver = { id in
            guard id == "exit-physical-clean-mode" else { return nil }
            return ShortcutBinding(keyCode: 53, modifiers: [.control, .command])
        }

        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)
    }
}
