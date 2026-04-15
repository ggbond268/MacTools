import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostNavigationSelectionTests: XCTestCase {
    private let suiteName = "PluginHostNavigationSelectionTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetPanelNavigationSelectionValueForwardsNavigationAction() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.setPanelNavigationSelectionValue(
            "display-2",
            controlID: "display-navigation",
            for: plugin.manifest.id
        )

        XCTAssertEqual(
            plugin.receivedActions,
            [.setNavigationSelection(controlID: "display-navigation", optionID: "display-2")]
        )
        XCTAssertNotEqual(
            plugin.receivedActions,
            [.setSelection(controlID: "display-navigation", optionID: "display-2")]
        )
    }

    func testNavigationListControlKindIsDistinctFromSelectList() {
        let kind = PluginPanelControlKind.navigationList

        if case .selectList = kind {
            XCTFail("Expected navigationList to be distinct from selectList")
        }
    }

    private func makeHost(plugin: MockNavigationPlugin) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }
}

@MainActor
private final class MockNavigationPlugin: FeaturePlugin {
    let manifest = PluginManifest(
        id: "mock-navigation",
        title: "Mock Navigation",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented,
        order: 1,
        defaultDescription: "Mock navigation plugin"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var receivedActions: [PluginPanelAction] = []

    var panelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Mock",
            isOn: false,
            isExpanded: true,
            isEnabled: true,
            isVisible: true,
            detail: PluginPanelDetail(primaryControls: [], secondaryPanel: nil),
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}

    func handlePanelAction(_ action: PluginPanelAction) {
        receivedActions.append(action)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}
