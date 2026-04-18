import XCTest
@testable import MacTools

@MainActor
final class HideNotchPluginHostIntegrationTests: XCTestCase {
    func testPluginHostExposesHideNotchPanelItem() {
        let controller = MockHideNotchWallpaperController()
        controller.snapshotValue = HideNotchSnapshot(
            hasSupportedDisplay: true,
            supportedDisplayCount: 1,
            managedDisplayCount: 0,
            unsupportedVisibleDisplayCount: 0,
            pendingRestoreCount: 0,
            isEnabled: false,
            isProcessing: false,
            isAwaitingDisplay: false,
            errorMessage: nil
        )
        let userDefaults = makeIsolatedUserDefaults()
        let plugin = HideNotchPlugin(controller: controller)

        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: userDefaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: userDefaults),
            globalShortcutManager: GlobalShortcutManager()
        )

        XCTAssertEqual(host.panelItems.map(\.id), ["hide-notch"])
        XCTAssertEqual(host.panelItems.first?.title, "隐藏刘海")
        XCTAssertEqual(host.panelItems.first?.description, "自动遮挡刘海屏顶部区域")
    }
}
