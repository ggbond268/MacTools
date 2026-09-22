import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostSliderActionTests: XCTestCase {
    private let suiteName = "PluginHostSliderActionTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSetPanelSliderValueForwardsSliderAction() {
        let plugin = MockSliderPlugin()
        let host = makeHost(plugin: plugin)

        host.setPanelSliderValue(
            0.78,
            controlID: "display.2.brightness",
            for: host.testEntry(pluginID: plugin.metadata.id, kind: .row).id,
            phase: .ended
        )

        XCTAssertEqual(
            plugin.receivedActions,
            [.setSlider(controlID: "display.2.brightness", value: 0.78, phase: .ended)]
        )
    }

    func testChangedSliderValueDoesNotRebuildAllDerivedState() {
        let plugin = MockSliderPlugin()
        let host = makeHost(plugin: plugin)
        _ = host.panelItems
        let readCountAfterInitialBuild = plugin.primaryPanelStateReadCount

        host.setPanelSliderValue(
            0.42,
            controlID: "display.2.brightness",
            for: host.testEntry(pluginID: plugin.metadata.id, kind: .row).id,
            phase: .changed
        )

        XCTAssertEqual(
            plugin.receivedActions,
            [.setSlider(controlID: "display.2.brightness", value: 0.42, phase: .changed)]
        )
        XCTAssertEqual(plugin.primaryPanelStateReadCount, readCountAfterInitialBuild)
    }

    func testEndedSliderValueRebuildsDerivedState() {
        let plugin = MockSliderPlugin()
        let host = makeHost(plugin: plugin)
        _ = host.panelItems
        let readCountAfterInitialBuild = plugin.primaryPanelStateReadCount

        host.setPanelSliderValue(
            0.42,
            controlID: "display.2.brightness",
            for: host.testEntry(pluginID: plugin.metadata.id, kind: .row).id,
            phase: .ended
        )

        XCTAssertEqual(
            plugin.receivedActions,
            [.setSlider(controlID: "display.2.brightness", value: 0.42, phase: .ended)]
        )
        XCTAssertGreaterThan(plugin.primaryPanelStateReadCount, readCountAfterInitialBuild)
    }

    func testChangedSettingsValueForwardsTypedActionWithoutRebuilding() {
        let plugin = MockSliderPlugin()
        let host = makeHost(plugin: plugin)
        _ = host.panelItems
        let readCountAfterInitialBuild = plugin.primaryPanelStateReadCount

        host.performSettingsAction(
            pluginID: plugin.metadata.id,
            action: .setNumber(controlID: "level", value: 42, phase: .changed)
        )

        XCTAssertEqual(
            plugin.receivedSettingsActions,
            [.setNumber(controlID: "level", value: 42, phase: .changed)]
        )
        XCTAssertEqual(plugin.primaryPanelStateReadCount, readCountAfterInitialBuild)
    }

    func testCommittedSettingsValueRebuildsDerivedState() {
        let plugin = MockSliderPlugin()
        let host = makeHost(plugin: plugin)
        _ = host.panelItems
        let readCountAfterInitialBuild = plugin.primaryPanelStateReadCount

        host.performSettingsAction(
            pluginID: plugin.metadata.id,
            action: .setText(controlID: "name", value: "Display", phase: .committed)
        )

        XCTAssertEqual(
            plugin.receivedSettingsActions,
            [.setText(controlID: "name", value: "Display", phase: .committed)]
        )
        XCTAssertGreaterThan(plugin.primaryPanelStateReadCount, readCountAfterInitialBuild)
    }

    private func makeHost(plugin: MockSliderPlugin) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }
}

@MainActor
private final class MockSliderPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    let metadata = PluginMetadata(
        id: "mock-slider",
        title: "Mock Slider",
        iconName: "sun.max",
        iconTint: Color(nsColor: .systemYellow),
        order: 1,
        defaultDescription: "Mock slider plugin"
    )

    let rowDescriptor = PluginPanelRowDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var receivedActions: [PluginPanelAction] = []
    var receivedSettingsActions: [PluginSettingsAction] = []
    var primaryPanelStateReadCount = 0

    var rowState: PluginPanelRowState {
        primaryPanelStateReadCount += 1
        return PluginPanelRowState(
            subtitle: "Mock",
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: PluginPanelDetail(primaryControls: [], secondaryPanel: nil),
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {}

    func handleAction(_ action: PluginPanelAction) {
        receivedActions.append(action)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {
        receivedSettingsActions.append(action)
    }
    func handleShortcutAction(id: String) {}
}
