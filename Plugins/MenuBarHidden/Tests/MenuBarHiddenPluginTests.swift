import AppKit
import XCTest
import MacToolsPluginKit
@testable import MenuBarHiddenPlugin

@MainActor
final class MenuBarHiddenPluginTests: XCTestCase {
    func testMetadataAndSurfacesAreExposed() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let plugin = MenuBarHiddenPlugin(context: context)

        XCTAssertEqual(plugin.metadata.id, "menu-bar-hidden")
        XCTAssertEqual(plugin.metadata.title, "隐藏菜单栏图标")
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .switch)
        XCTAssertEqual(plugin.descriptor.span, PluginComponentSpan(width: 4, height: 5)!)
        XCTAssertNotNil(plugin.configuration)
    }

    func testComponentSpanGrowsFromHiddenIconContentWidth() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let controller = MenuBarHiddenController(
            context: context,
            permissionProvider: {
                MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: true)
            },
            hostSupportProbe: { .supported }
        )
        controller.replaceSnapshotForTesting(
            hiddenItems: (0..<20).map { index in
                makeItem(index: index, width: 70)
            }
        )
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)

        XCTAssertGreaterThan(plugin.descriptor.span.height, 5)
    }

    func testPermissionRequirementsContainAccessibilityAndScreenRecording() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let plugin = MenuBarHiddenPlugin(context: context)

        let ids = plugin.permissionRequirements.map(\.id)
        XCTAssertTrue(ids.contains("accessibility"), "Should require accessibility")
        XCTAssertTrue(ids.contains("screen-recording"), "Should require screen-recording")
        XCTAssertEqual(plugin.permissionRequirements.count, 2)
    }

    func testPermissionKindsAreCorrect() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let plugin = MenuBarHiddenPlugin(context: context)

        let ax = plugin.permissionRequirements.first { $0.id == "accessibility" }
        let sr = plugin.permissionRequirements.first { $0.id == "screen-recording" }
        XCTAssertEqual(ax?.kind, .accessibility)
        XCTAssertEqual(sr?.kind, .screenRecording)
    }

    func testComponentPanelIsHiddenUntilFullyAuthorized() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let controller = MenuBarHiddenController(
            context: context,
            permissionProvider: {
                MenuBarHiddenPermissionsStatus(hasAccessibility: false, hasScreenRecording: false)
            },
            hostSupportProbe: { .supported }
        )
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)
        let state = plugin.componentPanelState

        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.subtitle, "")
    }

    func testReadingPermissionDrivenStatesDoesNotPublishStateChange() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let plugin = MenuBarHiddenPlugin(context: context)
        var stateChangeCount = 0
        plugin.onStateChange = {
            stateChangeCount += 1
        }

        _ = plugin.componentPanelState
        _ = plugin.permissionState(for: "accessibility")
        _ = plugin.permissionState(for: "screen-recording")

        XCTAssertEqual(stateChangeCount, 0)
    }

    func testHandleSetSwitchActionTogglesEnabledInStore() {
        let storage = MenuBarHiddenMemoryStorage()
        let store = MenuBarHiddenStore(storage: storage)

        XCTAssertFalse(store.isEnabled)
        store.isEnabled = true
        XCTAssertTrue(store.isEnabled)
        store.isEnabled = false
        XCTAssertFalse(store.isEnabled)
        XCTAssertFalse(store.isAlwaysHiddenEnabled)
        store.isAlwaysHiddenEnabled = true
        XCTAssertTrue(store.isAlwaysHiddenEnabled)
        store.isAlwaysHiddenEnabled = false
        XCTAssertFalse(store.isAlwaysHiddenEnabled)
        XCTAssertFalse(store.showsHiddenIconsInPanel)
        store.showsHiddenIconsInPanel = true
        XCTAssertTrue(store.showsHiddenIconsInPanel)
        store.showsHiddenIconsInPanel = false
        XCTAssertFalse(store.showsHiddenIconsInPanel)
        store.recordAlwaysHiddenItem(
            MenuBarItemTag(namespace: "com.example.app", title: "Item", windowID: nil, instanceIndex: 0)
        )
        XCTAssertEqual(store.alwaysHiddenItemStableKeys, ["com.example.app:Item"])
    }

    func testComponentPanelRequiresPanelSettingAndPermissions() {
        let storage = MenuBarHiddenMemoryStorage()
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: storage
        )
        let controller = MenuBarHiddenController(
            context: context,
            permissionProvider: {
                MenuBarHiddenPermissionsStatus(hasAccessibility: true, hasScreenRecording: true)
            },
            hostSupportProbe: { .supported }
        )
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)

        XCTAssertFalse(plugin.componentPanelState.isVisible)

        controller.showsHiddenIconsInPanel = true
        XCTAssertTrue(plugin.componentPanelState.isVisible)
    }

    func testProtectedSettingsCannotEnableWithoutPermissions() {
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: MenuBarHiddenMemoryStorage()
        )
        let controller = MenuBarHiddenController(
            context: context,
            permissionProvider: {
                MenuBarHiddenPermissionsStatus(hasAccessibility: false, hasScreenRecording: false)
            },
            hostSupportProbe: { .supported }
        )

        controller.isAlwaysHiddenEnabled = true
        controller.showsHiddenIconsInPanel = true

        XCTAssertFalse(controller.isAlwaysHiddenEnabled)
        XCTAssertFalse(controller.showsHiddenIconsInPanel)
    }

    private func makeItem(index: Int, width: CGFloat) -> MenuBarItem {
        MenuBarItem(
            tag: MenuBarItemTag(namespace: "test", title: "Item-\(index)", windowID: nil, instanceIndex: 0),
            windowID: CGWindowID(index + 1),
            ownerPID: 1000 + pid_t(index),
            bounds: CGRect(x: CGFloat(index) * width, y: 0, width: width, height: 24),
            title: "Item \(index)",
            isOnScreen: true
        )
    }
}
