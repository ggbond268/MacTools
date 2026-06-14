import AppKit
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import MenuBarHiddenPlugin

/// Fail-closed behavior when the menu bar host is incompatible (macOS 27 beta
/// single-window menu bar: the CGS per-item window enumeration returns
/// nothing). The probe is injected as a fake so these run on every OS.
@MainActor
final class MenuBarHiddenUnsupportedHostTests: XCTestCase {
    private func makeController(
        storage: MenuBarHiddenMemoryStorage,
        permissions: MenuBarHiddenPermissionsStatus = MenuBarHiddenPermissionsStatus(
            hasAccessibility: true,
            hasScreenRecording: true
        ),
        hostSupportProbe: @escaping () -> MenuBarHiddenHostProbe.Outcome
    ) -> MenuBarHiddenController {
        MenuBarHiddenController(
            context: PluginRuntimeContext(
                pluginID: MenuBarHiddenConstants.pluginID,
                storage: storage
            ),
            permissionProvider: { permissions },
            hostSupportProbe: hostSupportProbe
        )
    }

    func testUnsupportedHostPrimaryPanelShowsIncompatibilityAndDisablesSwitch() {
        let storage = MenuBarHiddenMemoryStorage()
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: storage
        )
        let controller = makeController(storage: storage, hostSupportProbe: { .unsupported })
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)

        controller.activate()

        XCTAssertFalse(controller.isHostSupported)
        let state = plugin.primaryPanelState
        XCTAssertTrue(state.isVisible, "Row stays visible so users see why it is off")
        XCTAssertFalse(state.isEnabled, "Switch must be disabled on unsupported hosts")
        XCTAssertFalse(state.isOn)
        XCTAssertNotNil(state.errorMessage, "Incompatibility must be surfaced explicitly")
        XCTAssertEqual(state.errorMessage, "当前 macOS 版本暂不兼容菜单栏隐藏")
        XCTAssertEqual(state.subtitle, "暂不兼容")
    }

    func testUnsupportedHostIgnoresEnableAttemptsFailClosed() {
        let controller = makeController(
            storage: MenuBarHiddenMemoryStorage(),
            hostSupportProbe: { .unsupported }
        )
        controller.activate()

        controller.isEnabled = true
        XCTAssertFalse(controller.isEnabled, "Enable must be inert on unsupported hosts")

        controller.isAlwaysHiddenEnabled = true
        XCTAssertFalse(controller.isAlwaysHiddenEnabled)
    }

    func testUnsupportedHostWithPreviouslyEnabledStoreDoesNotExpand() {
        // User had hiding enabled on an older OS, then booted into the
        // incompatible host: activation must not install/expand the 10000pt
        // divider, and the panel must report off + unsupported.
        let storage = MenuBarHiddenMemoryStorage()
        let store = MenuBarHiddenStore(storage: storage)
        store.isEnabled = true

        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: storage
        )
        let controller = makeController(storage: storage, hostSupportProbe: { .unsupported })
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)

        controller.activate()

        XCTAssertFalse(controller.isHostSupported)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertFalse(plugin.primaryPanelState.isEnabled)
        XCTAssertTrue(controller.snapshot.hiddenItems.isEmpty)
        XCTAssertTrue(controller.snapshot.visibleItems.isEmpty)
        XCTAssertTrue(controller.snapshot.alwaysHiddenItems.isEmpty)
    }

    func testUnsupportedHostHidesComponentCardEvenWithPermissionsAndSetting() {
        let storage = MenuBarHiddenMemoryStorage()
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: storage
        )
        let controller = makeController(storage: storage, hostSupportProbe: { .unsupported })
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)

        controller.activate()
        controller.showsHiddenIconsInPanel = true

        let state = plugin.componentPanelState
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.subtitle, "")
    }

    func testHostSupportIsProbedOnceAndCached() {
        var probeCount = 0
        let controller = makeController(
            storage: MenuBarHiddenMemoryStorage(),
            hostSupportProbe: {
                probeCount += 1
                return .unsupported
            }
        )

        controller.activate()
        // Unsupported activation leaves the manager inactive, so a second
        // activate re-enters the guard — the cached probe must not re-run.
        controller.activate()

        XCTAssertEqual(probeCount, 1)
        XCTAssertFalse(controller.isHostSupported)
    }

    func testIndeterminateProbeStaysFailClosedButIsNotCached() {
        var probeCount = 0
        let controller = makeController(
            storage: MenuBarHiddenMemoryStorage(),
            hostSupportProbe: {
                probeCount += 1
                return .indeterminate
            }
        )

        controller.activate()
        XCTAssertFalse(controller.isHostSupported, "Indeterminate probes must stay fail-closed")

        controller.activate()
        XCTAssertEqual(probeCount, 2, "Indeterminate verdicts must not be cached")
    }

    func testIndeterminateProbeRecoversOnLaterActivation() {
        // Displays asleep at first activation (indeterminate), awake by the
        // next one: the gate must reopen instead of staying stuck.
        var outcomes: [MenuBarHiddenHostProbe.Outcome] = [.indeterminate, .supported]
        let controller = makeController(
            storage: MenuBarHiddenMemoryStorage(),
            hostSupportProbe: { outcomes.isEmpty ? .supported : outcomes.removeFirst() }
        )

        controller.activate()
        XCTAssertFalse(controller.isHostSupported)

        controller.activate()
        XCTAssertTrue(controller.isHostSupported)
        controller.deactivate()
    }

    func testSupportedProbeKeepsNormalPanelBehavior() {
        let storage = MenuBarHiddenMemoryStorage()
        let context = PluginRuntimeContext(
            pluginID: MenuBarHiddenConstants.pluginID,
            storage: storage
        )
        let controller = makeController(storage: storage, hostSupportProbe: { .supported })
        let plugin = MenuBarHiddenPlugin(context: context, controller: controller)

        XCTAssertTrue(controller.isHostSupported)
        let state = plugin.primaryPanelState
        XCTAssertTrue(state.isEnabled)
        XCTAssertNil(state.errorMessage)
    }
}
