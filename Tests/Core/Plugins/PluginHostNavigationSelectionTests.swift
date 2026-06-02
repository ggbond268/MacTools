import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
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
            for: plugin.metadata.id
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

    func testInvokePanelActionForwardsInvokeActionToPlugin() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.invokePanelAction(controlID: "open-system-settings", for: plugin.metadata.id)

        XCTAssertEqual(
            plugin.receivedActions,
            [.invokeAction(controlID: "open-system-settings")]
        )
    }

    func testPresentPluginMarketplaceSelectsMarketplaceSettings() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.presentPluginMarketplace()

        XCTAssertEqual(host.selectedSettingsDestination, .pluginConfiguration)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .marketplace)
        XCTAssertEqual(host.settingsPresentationRequestCount, 1)
    }

    func testPresentInstalledPluginsSelectsInstalledSettings() {
        let plugin = MockNavigationPlugin()
        let host = makeHost(plugin: plugin)

        host.presentPluginMarketplace()
        host.presentInstalledPlugins()

        XCTAssertEqual(host.selectedSettingsDestination, .pluginConfiguration)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .installed)
        XCTAssertEqual(host.settingsPresentationRequestCount, 2)
    }

    func testPluginConfigurationPresentationCallbackOpensPluginSettings() {
        let plugin = MockNavigationPlugin(hasConfiguration: true)
        let host = makeHost(plugin: plugin)

        plugin.requestPluginConfigurationPresentation?(plugin.metadata.id)

        XCTAssertEqual(host.selectedSettingsDestination, .pluginConfiguration)
        XCTAssertEqual(host.selectedFeatureSettingsPane, .configuration(plugin.metadata.id))
        XCTAssertEqual(host.settingsPresentationRequestCount, 1)
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
private final class MockNavigationPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginConfigurationPresenting {
    let metadata = PluginMetadata(
        id: "mock-navigation",
        title: "Mock Navigation",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "Mock navigation plugin"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var requestPluginConfigurationPresentation: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var receivedActions: [PluginPanelAction] = []
    private let hasConfigurationSurface: Bool

    init(hasConfiguration: Bool = false) {
        hasConfigurationSurface = hasConfiguration
    }

    var primaryPanelState: PluginPanelState {
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
    var configuration: PluginConfiguration? {
        guard hasConfigurationSurface else { return nil }
        return PluginConfiguration(description: "Mock settings") { _ in
            EmptyView()
        }
    }

    func refresh() {}

    func handleAction(_ action: PluginPanelAction) {
        receivedActions.append(action)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}
