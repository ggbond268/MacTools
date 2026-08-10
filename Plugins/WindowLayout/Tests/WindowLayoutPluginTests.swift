import XCTest
import MacToolsPluginKit
@testable import WindowLayoutPlugin

@MainActor
final class FakeWindowLayoutApplicator: WindowLayoutApplying {
    var window: WindowLayoutTargetWindow?
    private(set) var lastSetFrame: CGRect?
    private(set) var lastSetKey: WindowLayoutWindowKey?

    init(window: WindowLayoutTargetWindow?) {
        self.window = window
    }

    func resolveFrontmostResizableWindow() throws -> WindowLayoutTargetWindow {
        guard let window else {
            throw WindowLayoutApplyError.noResizableWindow
        }
        return window
    }

    func setFrame(_ frame: CGRect, for key: WindowLayoutWindowKey) throws {
        lastSetFrame = frame
        lastSetKey = key
        if let existing = window {
            window = WindowLayoutTargetWindow(
                key: existing.key,
                frame: frame,
                visibleFrame: existing.visibleFrame
            )
        }
    }
}

@MainActor
final class WindowLayoutPluginTests: XCTestCase {
    func testInsetDefaultsToEightAndClamps() {
        let suiteName = "window-layout-store-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = UserDefaultsPluginStorage(pluginID: "window-layout", userDefaults: defaults)
        let store = WindowLayoutStore(storage: storage)
        XCTAssertEqual(store.almostMaximizeInset, 8)
        store.setAlmostMaximizeInset(99)
        XCTAssertEqual(store.almostMaximizeInset, 40)
        store.setAlmostMaximizeInset(-1)
        XCTAssertEqual(store.almostMaximizeInset, 0)
    }

    func testApplyLeftHalfSnapshotsAndSetsFrame() throws {
        let fake = FakeWindowLayoutApplicator(
            window: WindowLayoutTargetWindow(
                key: WindowLayoutWindowKey(pid: 42, windowID: "w"),
                frame: CGRect(x: 10, y: 10, width: 400, height: 300),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
            )
        )
        let history = WindowLayoutHistory()
        let plugin = WindowLayoutPlugin(
            localization: PluginLocalization(bundle: .main),
            applicator: fake,
            history: history,
            accessibilityTrusted: { true }
        )
        plugin.handleAction(.invokeAction(controlID: WindowLayoutAction.leftHalf.rawValue))
        XCTAssertEqual(fake.lastSetFrame?.width, 500)
        plugin.handleAction(.invokeAction(controlID: WindowLayoutAction.restore.rawValue))
        XCTAssertEqual(fake.lastSetFrame, CGRect(x: 10, y: 10, width: 400, height: 300))
    }

    func testDeniedAccessibilitySetsError() {
        let plugin = WindowLayoutPlugin(
            localization: PluginLocalization(bundle: .main),
            applicator: FakeWindowLayoutApplicator(window: nil),
            accessibilityTrusted: { false }
        )
        plugin.handleAction(.invokeAction(controlID: WindowLayoutAction.maximize.rawValue))
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testSettingsCommitUpdatesInset() {
        let suiteName = "window-layout-settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = UserDefaultsPluginStorage(pluginID: "window-layout", userDefaults: defaults)
        let context = PluginRuntimeContext(pluginID: "window-layout", storage: storage)
        let plugin = WindowLayoutPlugin(
            context: context,
            localization: PluginLocalization(bundle: .main),
            applicator: FakeWindowLayoutApplicator(window: nil),
            accessibilityTrusted: { true }
        )
        plugin.handleSettingsAction(
            .setNumber(controlID: "almost-maximize-inset", value: 16, phase: .committed)
        )
        XCTAssertEqual(plugin.store.almostMaximizeInset, 16)
    }

    func testExpandedPanelExposesAllActionControls() {
        let plugin = WindowLayoutPlugin(
            localization: PluginLocalization(bundle: .main),
            applicator: FakeWindowLayoutApplicator(window: nil),
            accessibilityTrusted: { true }
        )
        plugin.handleAction(.setDisclosureExpanded(true))
        let ids = Set(plugin.primaryPanelState.detail?.primaryControls.map(\.id) ?? [])
        for action in WindowLayoutAction.allCases {
            XCTAssertTrue(ids.contains(action.rawValue), "missing control \(action.rawValue)")
        }
    }

    func testShortcutDefinitionsCoverEveryAction() {
        let plugin = WindowLayoutPlugin(
            localization: PluginLocalization(bundle: .main),
            applicator: FakeWindowLayoutApplicator(window: nil),
            accessibilityTrusted: { true }
        )
        let ids = Set(plugin.shortcutDefinitions.map(\.id))
        XCTAssertEqual(ids, Set(WindowLayoutAction.allCases.map(\.rawValue)))
    }

    func testRestoreDisabledWhenHistoryEmpty() {
        let plugin = WindowLayoutPlugin(
            localization: PluginLocalization(bundle: .main),
            applicator: FakeWindowLayoutApplicator(window: nil),
            accessibilityTrusted: { true }
        )
        plugin.handleAction(.setDisclosureExpanded(true))
        let restore = plugin.primaryPanelState.detail?.primaryControls.first {
            $0.id == WindowLayoutAction.restore.rawValue
        }
        XCTAssertEqual(restore?.isEnabled, false)
    }
}
