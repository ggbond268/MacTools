import AppKit
import Carbon.HIToolbox
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherMigrationTests: XCTestCase {
    func testStableProfileKeepsDirectKeysAndAssignmentsAcrossRelaunch() throws {
        let storage = WindowSwitcherMemoryStorage()
        storage.set(Data(#"{"mode":"keyWindow","sortMode":"recentUse"}"#.utf8), forKey: "configuration")
        let saved = WindowSwitcherShortcutBindingState(manual: ["fixture": "cmd+w"], automatic: ["other": "j"])
        storage.set(try JSONEncoder().encode(saved), forKey: "shortcut-bindings")
        let store = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(store.configuration.mode, .keyWindow)
        XCTAssertTrue(store.configuration.protectsLegacyCommands)
        XCTAssertEqual(store.shortcutBindings, saved)
        let reopened = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(reopened.configuration.mode, .keyWindow)
        XCTAssertEqual(reopened.shortcutBindings, saved)
        store.setMode(.searchSelect)
        XCTAssertEqual(WindowSwitcherStore(storage: storage).configuration.mode, .searchSelect)
        XCTAssertEqual(store.shortcutBindings, saved)
        XCTAssertTrue(store.configuration.protectsLegacyCommands)
        store.setMode(.keyWindow)
        XCTAssertEqual(WindowSwitcherStore(storage: storage).configuration.mode, .keyWindow)
    }

    func testNewInstallStartsInSearchAndExperimentalSearchDoesNotRevert() {
        let fresh = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())
        XCTAssertEqual(fresh.configuration.mode, .searchSelect)
        XCTAssertTrue(fresh.configuration.usesCompanionDefaults)
        XCTAssertTrue(fresh.configuration.showsPreview)
        let storage = WindowSwitcherMemoryStorage()
        storage.set(Data(#"{"mode":"keyWindow","usesCompanionDefaults":false,"showsPreview":true}"#.utf8), forKey: "configuration")
        let upgraded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(upgraded.configuration.mode, .searchSelect)
        XCTAssertTrue(upgraded.configuration.showsPreview)
        XCTAssertFalse(upgraded.configuration.usesCompanionDefaults)
        upgraded.setMode(.keyWindow)
        XCTAssertEqual(WindowSwitcherStore(storage: storage).configuration.mode, .keyWindow)
    }

    func testBindingsWithoutConfigurationIdentifyAnExistingInstallation() throws {
        let storage = WindowSwitcherMemoryStorage()
        storage.set(try JSONEncoder().encode(WindowSwitcherShortcutBindingState(manual: ["fixture": "f"])), forKey: "shortcut-bindings")
        XCTAssertEqual(WindowSwitcherStore(storage: storage).configuration.mode, .keyWindow)
    }

}
