import AppKit
import ApplicationServices
import XCTest
import MacToolsPluginKit
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherListingTests: XCTestCase {
    func testDefaultPolicyKeepsMinimizedOtherDesktopAndFullscreenWindows() {
        let entries = [window("min", minimized: true), window("space", otherDesktop: true), window("full", fullscreen: true)]
        XCTAssertEqual(WindowSwitcherListing.apply(entries, policy: .default).map(\.id), ["min", "space", "full"])
    }

    func testPolicyCanHideMinimizedOtherDesktopAndFullscreenWindows() {
        var policy = WindowSwitcherListingPolicy(
            includesMinimizedWindows: false,
            includesOtherDesktopWindows: false,
            includesFullscreenSpaceWindows: false
        )
        let entries = [
            window("live"),
            window("min", minimized: true),
            window("space", otherDesktop: true),
            window("full", fullscreen: true)
        ]
        XCTAssertEqual(WindowSwitcherListing.apply(entries, policy: policy).map(\.id), ["live"])
        policy.includesMinimizedWindows = true
        XCTAssertEqual(WindowSwitcherListing.apply(entries, policy: policy).map(\.id), ["live", "min"])
    }

    func testUnknownSpaceMembershipIsNotTreatedAsAnotherDesktop() {
        var policy = WindowSwitcherListingPolicy.default
        policy.includesOtherDesktopWindows = false
        let unknown = window("unknown")
        XCTAssertFalse(unknown.isOnOtherDesktop)
        XCTAssertEqual(WindowSwitcherListing.apply([unknown], policy: policy).map(\.id), ["unknown"])
    }

    func testDuplicateWindowNumbersKeepTheFirstIdentity() {
        let first = window("ax", number: 9)
        let second = window("helper", number: 9)
        XCTAssertEqual(WindowSwitcherListing.preferringUniqueWindowNumbers([first, second]).map(\.id), ["ax"])
    }

    func testStorePersistsListingTogglesAndNewInstallsEnablePreview() throws {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        XCTAssertTrue(store.configuration.showsPreview)
        XCTAssertTrue(store.configuration.includesMinimizedWindows)
        XCTAssertTrue(store.configuration.includesOtherDesktopWindows)
        XCTAssertTrue(store.configuration.includesFullscreenSpaceWindows)
        store.setShowsPreview(false)
        store.setIncludesMinimizedWindows(false)
        store.setIncludesOtherDesktopWindows(false)
        store.setIncludesFullscreenSpaceWindows(false)
        let reopened = WindowSwitcherStore(storage: storage)
        XCTAssertFalse(reopened.configuration.showsPreview)
        XCTAssertFalse(reopened.configuration.includesMinimizedWindows)
        XCTAssertFalse(reopened.configuration.includesOtherDesktopWindows)
        XCTAssertFalse(reopened.configuration.includesFullscreenSpaceWindows)
    }

    func testPluginSettingsTogglesUpdateListingPolicy() {
        let plugin = WindowSwitcherPlugin(
            context: PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID, storage: WindowSwitcherMemoryStorage()),
            appCatalog: WindowSwitcherAppCatalog()
        )
        plugin.handleSettingsAction(.setBoolean(controlID: "minimized-windows", value: false))
        plugin.handleSettingsAction(.setBoolean(controlID: "other-desktop-windows", value: false))
        plugin.handleSettingsAction(.setBoolean(controlID: "fullscreen-space-windows", value: false))
        plugin.handleSettingsAction(.setBoolean(controlID: "selected-preview", value: false))
        XCTAssertFalse(plugin.store.configuration.includesMinimizedWindows)
        XCTAssertFalse(plugin.store.configuration.includesOtherDesktopWindows)
        XCTAssertFalse(plugin.store.configuration.includesFullscreenSpaceWindows)
        XCTAssertFalse(plugin.store.configuration.showsPreview)
        XCTAssertFalse(plugin.store.configuration.listingPolicy.includesMinimizedWindows)
    }

    func testLegacyConfigurationKeepsPreviewOffAndIncludesAllWindowKinds() throws {
        let storage = WindowSwitcherMemoryStorage()
        storage.set(Data(#"{"mode":"searchSelect","sortMode":"recentUse"}"#.utf8), forKey: "configuration")
        let store = WindowSwitcherStore(storage: storage)
        XCTAssertFalse(store.configuration.showsPreview)
        XCTAssertTrue(store.configuration.includesMinimizedWindows)
        XCTAssertTrue(store.configuration.includesOtherDesktopWindows)
        XCTAssertTrue(store.configuration.includesFullscreenSpaceWindows)
    }

    private func window(
        _ id: String,
        minimized: Bool = false,
        otherDesktop: Bool = false,
        fullscreen: Bool = false,
        number: CGWindowID? = nil
    ) -> WindowSwitcherAppEntry {
        var entry = WindowSwitcherAppEntry(
            id: id, processIdentifier: 42, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: id, icon: nil, windowElement: AXUIElementCreateApplication(42),
            isMinimized: minimized, windowNumber: number, shortcutToken: nil
        )
        entry.isOnOtherDesktop = otherDesktop
        entry.isOnFullscreenSpace = fullscreen
        return entry
    }
}
