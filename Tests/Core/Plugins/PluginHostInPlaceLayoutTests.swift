import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginHostInPlaceLayoutTests: XCTestCase {
    private let suiteName = "PluginHostInPlaceLayoutTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCanMovePluginBoundsChecking() {
        let p1 = MockDualPanelPlugin(id: "p1", order: 1)
        let p2 = MockDualPanelPlugin(id: "p2", order: 2)
        let p3 = MockDualPanelPlugin(id: "p3", order: 3)
        let host = makeHost(plugins: [p1, p2, p3])

        // Dashboard
        XCTAssertFalse(host.canMovePlugin(id: "p1", by: -1, on: .dashboard))
        XCTAssertTrue(host.canMovePlugin(id: "p1", by: 1, on: .dashboard))

        XCTAssertTrue(host.canMovePlugin(id: "p2", by: -1, on: .dashboard))
        XCTAssertTrue(host.canMovePlugin(id: "p2", by: 1, on: .dashboard))

        XCTAssertTrue(host.canMovePlugin(id: "p3", by: -1, on: .dashboard))
        XCTAssertFalse(host.canMovePlugin(id: "p3", by: 1, on: .dashboard))

        // Invalid moves
        XCTAssertFalse(host.canMovePlugin(id: "p2", by: 0, on: .dashboard))
        XCTAssertFalse(host.canMovePlugin(id: "unknown", by: 1, on: .dashboard))
        XCTAssertFalse(host.canMovePlugin(id: "p1", by: -2, on: .dashboard))
    }

    func testMovePluginByDeltaOnDashboard() {
        let p1 = MockDualPanelPlugin(id: "p1", order: 1)
        let p2 = MockDualPanelPlugin(id: "p2", order: 2)
        let p3 = MockDualPanelPlugin(id: "p3", order: 3)
        let host = makeHost(plugins: [p1, p2, p3])

        XCTAssertEqual(host.componentItems.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(host.panelItems.map(\.id), ["p1", "p2", "p3"])

        host.movePlugin(id: "p1", by: 1, on: .dashboard)
        XCTAssertEqual(host.componentItems.map(\.id), ["p2", "p1", "p3"])
        // Feature panel is independent
        XCTAssertEqual(host.panelItems.map(\.id), ["p1", "p2", "p3"])

        host.movePlugin(id: "p3", by: -1, on: .dashboard)
        XCTAssertEqual(host.componentItems.map(\.id), ["p2", "p3", "p1"])
        XCTAssertEqual(host.panelItems.map(\.id), ["p1", "p2", "p3"])
    }

    func testMovePluginByDeltaOnFeaturePanel() {
        let p1 = MockDualPanelPlugin(id: "p1", order: 1)
        let p2 = MockDualPanelPlugin(id: "p2", order: 2)
        let p3 = MockDualPanelPlugin(id: "p3", order: 3)
        let host = makeHost(plugins: [p1, p2, p3])

        host.movePlugin(id: "p3", by: -1, on: .featurePanel)
        XCTAssertEqual(host.panelItems.map(\.id), ["p1", "p3", "p2"])
        // Dashboard is independent
        XCTAssertEqual(host.componentItems.map(\.id), ["p1", "p2", "p3"])
    }

    func testSetDashboardAndFeaturePanelPluginOrder() {
        let p1 = MockDualPanelPlugin(id: "p1", order: 1)
        let p2 = MockDualPanelPlugin(id: "p2", order: 2)
        let p3 = MockDualPanelPlugin(id: "p3", order: 3)
        let host = makeHost(plugins: [p1, p2, p3])

        host.setDashboardPluginOrder(["p3", "p1", "p2"])
        XCTAssertEqual(host.componentItems.map(\.id), ["p3", "p1", "p2"])
        XCTAssertEqual(host.panelItems.map(\.id), ["p1", "p2", "p3"])

        host.setFeaturePanelPluginOrder(["p2", "p3", "p1"])
        XCTAssertEqual(host.panelItems.map(\.id), ["p2", "p3", "p1"])
        XCTAssertEqual(host.componentItems.map(\.id), ["p3", "p1", "p2"])
    }

    func testSetDashboardAndFeaturePanelPluginVisible() {
        let p1 = MockDualPanelPlugin(id: "p1", order: 1)
        let p2 = MockDualPanelPlugin(id: "p2", order: 2)
        let host = makeHost(plugins: [p1, p2])

        host.setDashboardPluginVisible(false, id: "p1")
        XCTAssertEqual(host.componentItems.map(\.id), ["p2"])
        XCTAssertEqual(host.panelItems.map(\.id), ["p1", "p2"])

        host.setFeaturePanelPluginVisible(false, id: "p2")
        XCTAssertEqual(host.panelItems.map(\.id), ["p1"])
        XCTAssertEqual(host.componentItems.map(\.id), ["p2"])

        host.setDashboardPluginVisible(true, id: "p1")
        XCTAssertEqual(host.componentItems.map(\.id), ["p1", "p2"])
    }

    private func makeHost(
        plugins: [any MacToolsPlugin]
    ) -> PluginHost {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        return PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            pluginStateChangeRebuildDelay: .milliseconds(20)
        )
    }
}

@MainActor
private final class MockDualPanelPlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginComponentPanel
{
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )
    let descriptor = PluginComponentDescriptor(span: .oneByOne)

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int = 1) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "circle",
            iconTint: Color(nsColor: .systemBlue),
            order: order,
            defaultDescription: "Mock plugin \(id)"
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: "Mock \(metadata.id)",
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: "Summary \(metadata.id)",
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(metadata.id))
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    func refresh() {}
    func handleAction(_ action: PluginPanelAction) {}
    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }
    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}
}
