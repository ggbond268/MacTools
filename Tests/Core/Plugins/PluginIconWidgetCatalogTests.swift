import AppKit
import XCTest
import MacToolsPluginKit
import AppHotkeyPlugin
import AppearancePlugin
import AutoHideDockPlugin
import AutoHideMenuBarPlugin
import AutoInputPlugin
import ClipboardClearPlugin
import ClipboardHistoryPlugin
import CloudflareR2Plugin
import DisplaySleepPlugin
import DisplayTrueColorPlugin
import DockClickMinimizePlugin
import DockLockPlugin
import EjectDiskPlugin
import EmptyTrashPlugin
import FixDamagedAppPlugin
import HideNotchPlugin
import HomebrewPlugin
import IPOverviewPlugin
import InputRemappingPlugin
import KeepAwakePlugin
import LaunchpadPlugin
import LockScreenPlugin
import MicrophoneMutePlugin
import MouseEnhancerPlugin
import NightShiftPlugin
import PhysicalCleanModePlugin
import QuitAppsPlugin
import StageManagerPlugin
import SystemMutePlugin
import SystemSoftRestartPlugin
import TrackpadGesturesPlugin
import TranslatorPlugin
import ZshConfigPlugin
import ScreenshotPlugin
import SiriPlugin

@MainActor
final class PluginIconWidgetCatalogTests: XCTestCase {
    func testSupportedControlsShareRowStateAndHaveNoDefaultWidgetPlacement() throws {
        for entry in Self.registrations {
            let context = PluginRuntimeContext(pluginID: entry.id, storage: IconWidgetCatalogStorage())
            let plugins = try entry.factory(context).makePlugins()
            let plugin = try XCTUnwrap(plugins.first, entry.id)
            let items = plugin.panelItems
            XCTAssertEqual(items.map(\.id), ["control", "quick-control"], entry.id)
            guard case let .row(row) = items[0].content,
                  case let .widget(widget) = items[1].content else {
                XCTFail("Expected one row and one icon widget: \(entry.id)")
                continue
            }
            XCTAssertEqual(items[0].initialPlacement, .featurePanel, entry.id)
            XCTAssertNil(items[1].initialPlacement, entry.id)
            XCTAssertEqual(widget.descriptor.span, PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact), entry.id)
            XCTAssertNil(row.state.detail, "A compact control must not omit row actions: \(entry.id)")
            XCTAssertEqual(widget.state.isEnabled, row.state.isEnabled, entry.id)
            XCTAssertEqual(widget.state.isAvailable, row.state.isAvailable, entry.id)
            XCTAssertEqual(widget.state.subtitle, row.state.subtitle, entry.id)
            XCTAssertEqual(widget.state.errorMessage, row.state.errorMessage, entry.id)
            XCTAssertEqual(widget.state.isActive, row.descriptor.controlStyle == .switch && row.state.isOn, entry.id)
            let symbol = try XCTUnwrap(items[1].systemImage, entry.id)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(entry.id): \(symbol)")
            XCTAssertFalse(try XCTUnwrap(items[1].title, entry.id).isEmpty, entry.id)
            XCTAssertEqual(items[0].visibilityHandler != nil, items[1].visibilityHandler != nil, entry.id)
            let manifestURL = repositoryRoot.appendingPathComponent("Plugins/\(entry.directory)/plugin.json")
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
            XCTAssertEqual(capabilities["panelItems"] as? [String], ["row", "widget"], entry.id)
        }
        XCTAssertEqual(Self.registrations.count, 31)
    }

    func testMultiStateAndAdditionalActionControlsRemainRowOnly() throws {
        for (id, factory) in [
            ("siri", SiriPluginFactory.makeProvider),
            ("screenshot", ScreenshotPluginFactory.makeProvider),
            ("keep-awake", KeepAwakePluginFactory.makeProvider),
            ("ip-overview", IPOverviewPluginFactory.makeProvider)
        ] {
            let context = PluginRuntimeContext(pluginID: id, storage: IconWidgetCatalogStorage())
            let plugin = try XCTUnwrap(factory(context).makePlugins().first)
            XCTAssertEqual(plugin.panelItems.map(\.kind), [.row], id)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Registration {
        let id: String
        let directory: String
        let factory: (PluginRuntimeContext) throws -> any PluginProvider
    }

    private static let registrations: [Registration] = [
        .init(id: "app-hotkey", directory: "AppHotkey", factory: AppHotkeyPluginFactory.makeProvider),
        .init(id: "appearance", directory: "Appearance", factory: AppearancePluginFactory.makeProvider),
        .init(id: "auto-hide-dock", directory: "AutoHideDock", factory: AutoHideDockPluginFactory.makeProvider),
        .init(id: "auto-hide-menu-bar", directory: "AutoHideMenuBar", factory: AutoHideMenuBarPluginFactory.makeProvider),
        .init(id: "auto-input", directory: "AutoInput", factory: AutoInputPluginFactory.makeProvider),
        .init(id: "clipboard-clear", directory: "ClipboardClear", factory: ClipboardClearPluginFactory.makeProvider),
        .init(id: "clipboard", directory: "ClipboardHistory", factory: ClipboardHistoryPluginFactory.makeProvider),
        .init(id: "cloudflare-r2", directory: "CloudflareR2", factory: CloudflareR2PluginFactory.makeProvider),
        .init(id: "display-sleep", directory: "DisplaySleep", factory: DisplaySleepPluginFactory.makeProvider),
        .init(id: "display-true-color", directory: "DisplayTrueColor", factory: DisplayTrueColorPluginFactory.makeProvider),
        .init(id: "dock-click-minimize", directory: "DockClickMinimize", factory: DockClickMinimizePluginFactory.makeProvider),
        .init(id: "dock-lock", directory: "DockLock", factory: DockLockPluginFactory.makeProvider),
        .init(id: "eject-disk", directory: "EjectDisk", factory: EjectDiskPluginFactory.makeProvider),
        .init(id: "empty-trash", directory: "EmptyTrash", factory: EmptyTrashPluginFactory.makeProvider),
        .init(id: "fix-damaged-app", directory: "FixDamagedApp", factory: FixDamagedAppPluginFactory.makeProvider),
        .init(id: "hide-notch", directory: "HideNotch", factory: HideNotchPluginFactory.makeProvider),
        .init(id: "homebrew", directory: "Homebrew", factory: HomebrewPluginFactory.makeProvider),
        .init(id: "input-remapping", directory: "InputRemapping", factory: InputRemappingPluginFactory.makeProvider),
        .init(id: "launchpad", directory: "Launchpad", factory: LaunchpadPluginFactory.makeProvider),
        .init(id: "lock-screen", directory: "LockScreen", factory: LockScreenPluginFactory.makeProvider),
        .init(id: "microphone-mute", directory: "MicrophoneMute", factory: MicrophoneMutePluginFactory.makeProvider),
        .init(id: "mouse-enhancer", directory: "MouseEnhancer", factory: MouseEnhancerPluginFactory.makeProvider),
        .init(id: "night-shift", directory: "NightShift", factory: NightShiftPluginFactory.makeProvider),
        .init(id: "physical-clean-mode", directory: "PhysicalCleanMode", factory: PhysicalCleanModePluginFactory.makeProvider),
        .init(id: "quit-apps", directory: "QuitApps", factory: QuitAppsPluginFactory.makeProvider),
        .init(id: "stage-manager", directory: "StageManager", factory: StageManagerPluginFactory.makeProvider),
        .init(id: "system-mute", directory: "SystemMute", factory: SystemMutePluginFactory.makeProvider),
        .init(id: "system-soft-restart", directory: "SystemSoftRestart", factory: SystemSoftRestartPluginFactory.makeProvider),
        .init(id: "trackpad-gestures", directory: "TrackpadGestures", factory: TrackpadGesturesPluginFactory.makeProvider),
        .init(id: "translator", directory: "Translator", factory: TranslatorPluginFactory.makeProvider),
        .init(id: "zsh-config", directory: "ZshConfig", factory: ZshConfigPluginFactory.makeProvider),
    ]
}

@MainActor
private final class IconWidgetCatalogStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else { return }
        values[key] = value
    }
}
