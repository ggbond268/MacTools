import AppKit
import SwiftUI
import XCTest
@testable import MacTools

@MainActor
final class PluginHostDisclosureStateTests: XCTestCase {
    private let suiteName = "PluginHostDisclosureStateTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDisclosureExpansionDoesNotMarkPluginActive() {
        let plugin = MockDisclosurePlugin()
        let host = makeHost(plugin: plugin)

        XCTAssertFalse(host.hasActivePlugin)
        XCTAssertFalse(host.featureManagementItems[0].isActive)
        XCTAssertFalse(host.panelItems[0].isExpanded)

        host.setDisclosureExpanded(true, for: plugin.manifest.id)

        XCTAssertTrue(host.panelItems[0].isExpanded)
        XCTAssertFalse(host.featureManagementItems[0].isActive)
        XCTAssertFalse(host.hasActivePlugin)
    }

    func testErrorMessageMapsToErrorDescriptionTone() {
        let plugin = MockDisclosurePlugin()
        plugin.errorMessage = "切换失败：显示器已断开连接"
        let host = makeHost(plugin: plugin)

        switch host.panelItems[0].descriptionTone {
        case .error:
            break
        case .secondary:
            XCTFail("Expected .error when panelState.errorMessage is non-nil")
        }
    }

    private func makeHost(plugin: MockDisclosurePlugin) -> PluginHost {
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
private final class MockDisclosurePlugin: FeaturePlugin {
    let manifest = PluginManifest(
        id: "mock-disclosure",
        title: "Mock Disclosure",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented,
        order: 1,
        defaultDescription: "Mock plugin"
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var isExpanded = false
    var errorMessage: String?

    var panelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Mock plugin",
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}

    func handlePanelAction(_ action: PluginPanelAction) {
        if case let .setDisclosureExpanded(value) = action {
            isExpanded = value
            onStateChange?()
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}
}
