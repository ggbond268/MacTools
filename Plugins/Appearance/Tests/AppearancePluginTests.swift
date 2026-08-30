import XCTest
import MacToolsPluginKit
@testable import AppearancePlugin

@MainActor
final class AppearancePluginTests: XCTestCase {
    func testManifestActionsMatchRuntimePolicy() throws {
        let plugin = AppearancePlugin()

        try PluginManifestActionAssertions.assertConsistency(
            pluginDirectoryName: "Appearance",
            definitions: plugin.actionDefinitions,
            permissionIDs: plugin.permissionRequirementIDs(for:)
        )
    }

    func testPublishesIdempotentLightAndDarkActions() {
        let plugin = AppearancePlugin()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(Array(plugin.actionCatalogEntries.dropFirst().map(\.title)), [
            "启用深色模式",
            "启用浅色模式",
        ])
        XCTAssertEqual(
            plugin.actionCatalogEntries.first?.presentationState,
            plugin.primaryPanelState.isOn ? .active : .inactive
        )
        XCTAssertTrue(
            plugin.actionDefinitions[0].capabilities.contains(.background)
        )
        XCTAssertEqual(
            plugin.actionDefinitions[0].externalInvocationPolicy,
            .allowed
        )
    }

    func testAutomationPermissionIsReportedAsOnDemand() {
        let state = AppearancePlugin().permissionState(for: "automation")

        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusTone, .neutral)
    }
}
