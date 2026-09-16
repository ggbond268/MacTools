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

    func testDirectKeysWinOverDestructiveAndSearchCommands() throws {
        for (token, text, code, flags) in [("cmd+w", "w", kVK_ANSI_W, NSEvent.ModifierFlags.command),
                                          ("cmd+q", "q", kVK_ANSI_Q, .command),
                                          ("cmd+f", "f", kVK_ANSI_F, .command),
                                          ("cmd+1", "1", kVK_ANSI_1, .command),
                                          ("f", "f", kVK_ANSI_F, [])] {
            let controller = WindowSwitcherOverlayController()
            let entry = WindowSwitcherAppEntry(id: "fixture", processIdentifier: 100, bundleIdentifier: "fixture", appName: "Fixture",
                windowTitle: "Document", icon: nil, windowElement: nil, isMinimized: false, shortcutToken: token)
            var session = WindowSwitcherSession(entries: [entry], selectedID: entry.id, isPersistent: true, originalWindowID: nil)
            session.usesDirectKeys = true
            session.protectedCommandKeys = ["w", "q"]
            controller.show(session, currentPID: 100, showsPreview: false)
            defer { controller.hide() }
            var selected: String?
            var destructive = false
            controller.onSelect = { selected = $0.id }
            controller.onClose = { _ in destructive = true }
            controller.onQuit = { _ in destructive = true }
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)))
            XCTAssertTrue(controller.handleChooserShortcut(event))
            XCTAssertEqual(selected, "fixture")
            XCTAssertFalse(destructive)
            XCTAssertTrue(controller.session?.usesDirectKeys == true)
        }
    }

    func testLegacyBadgeEditsPersistAndConflictsDoNotReplaceAssignments() throws {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        store.setMode(.keyWindow)
        func entry(_ id: String) -> WindowSwitcherAppEntry {
            WindowSwitcherAppEntry(id: id, processIdentifier: 100, bundleIdentifier: id, appName: id,
                windowTitle: "Document", icon: nil, windowElement: nil, isMinimized: false, shortcutToken: nil)
        }
        let raw = [entry("first"), entry("second")]
        _ = store.setManualShortcut("f", for: "first", in: raw)
        _ = store.setManualShortcut("g", for: "second", in: raw)
        let controller = WindowSwitcherOverlayController()
        var session = WindowSwitcherSession(entries: store.assignShortcuts(to: raw), selectedID: "first", isPersistent: true, originalWindowID: nil)
        session.usesDirectKeys = true
        controller.onShortcutChange = { target, token in store.setManualShortcut(token, for: target.id, in: controller.session!.entries) }
        controller.show(session, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let badge = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "F" })
        badge.performClick(nil)
        func record(_ text: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            XCTAssertTrue(controller.handleChooserShortcut(event))
        }
        try record("g", code: UInt16(kVK_ANSI_G))
        XCTAssertEqual(store.shortcutBindings.manual["bundle:first"], "f")
        try record("x", code: UInt16(kVK_ANSI_X))
        XCTAssertEqual(WindowSwitcherStore(storage: storage).shortcutBindings.manual["bundle:first"], "x")
        XCTAssertEqual(controller.session?.entries.first { $0.id == "first" }?.shortcutToken, "x")
        let edit = try XCTUnwrap(controller.contextMenu(forRow: 0)?.items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(edit.action), to: edit.target, from: edit))
        try record("z", code: UInt16(kVK_ANSI_Z))
        XCTAssertEqual(WindowSwitcherStore(storage: storage).shortcutBindings.manual["bundle:first"], "z")
    }


    func testDirectKeysListShowsEditableKeysAndReceivesRecordingEvents() throws {
        let controller = WindowSwitcherOverlayController()
        let entry = WindowSwitcherAppEntry(id: "fixture", processIdentifier: 100, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: "Document", icon: nil, windowElement: nil, isMinimized: false, shortcutToken: "f")
        var session = WindowSwitcherSession(entries: [entry], selectedID: entry.id, isPersistent: true, originalWindowID: nil)
        session.usesDirectKeys = true
        var recorded: String?
        controller.onShortcutChange = { _, token in recorded = token; return .updated([entry]) }
        controller.show(session, currentPID: 100, showsPreview: false, preferredLayout: .list)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let badge = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "window-shortcut-badge" })
        XCTAssertEqual(badge.title, "F")
        badge.performClick(nil)
        XCTAssertTrue(panel.firstResponder is NSTableView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X)))
        panel.sendEvent(event)
        XCTAssertEqual(recorded, "x")
    }


    func testUnselectedCardBadgeSurvivesSelectionAndShowsVisibleRecorder() throws {
        let controller = WindowSwitcherOverlayController()
        let entries = ["one", "two"].enumerated().map { index, id in
            WindowSwitcherAppEntry(id: id, processIdentifier: 100, bundleIdentifier: id, appName: id,
                windowTitle: id, icon: nil, windowElement: nil, isMinimized: false, shortcutToken: index == 0 ? "a" : "b")
        }
        var session = WindowSwitcherSession(entries: entries, selectedID: "one", isPersistent: true, originalWindowID: nil)
        session.usesDirectKeys = true
        controller.show(session, currentPID: 100, showsPreview: false, preferredLayout: .grid)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(panel.contentView)
        let collection = try XCTUnwrap(descendants(content).compactMap { $0 as? NSCollectionView }.first)
        let item = try XCTUnwrap(collection.item(at: 1))
        let badge = try XCTUnwrap(descendants(item.view).compactMap { $0 as? NSButton }.first { $0.title == "B" })
        controller.collectionView(collection, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        XCTAssertTrue(collection.item(at: 1) === item, "Selection must not recycle a tracking button")
        badge.performClick(nil)
        content.layoutSubtreeIfNeeded()
        let banner = try XCTUnwrap(descendants(content).first { $0.identifier?.rawValue == "window-shortcut-recording" })
        XCTAssertFalse(banner.isHidden)
        XCTAssertGreaterThan(banner.frame.height, 20)
        var recordedID: String?
        controller.onShortcutChange = { target, _ in recordedID = target.id; return .updated(entries) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: UInt16(kVK_ANSI_Z)))
        panel.sendEvent(event)
        XCTAssertEqual(recordedID, "two")
        XCTAssertTrue(banner.isHidden)
        let menu = try XCTUnwrap(controller.contextMenu(forRow: 0))
        var cancelled = false
        controller.onCancel = { cancelled = true }
        controller.menuWillOpen(menu)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        XCTAssertFalse(cancelled, "Menu tracking must not dismiss the chooser before its action")
        let edit = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(edit.action), to: edit.target, from: edit))
        XCTAssertFalse(banner.isHidden)
        panel.sendEvent(event)
        XCTAssertEqual(recordedID, "one")
    }

    func testExplicitSearchKeepsDestructiveKeysProtected() throws {
        let controller = WindowSwitcherOverlayController()
        let entry = WindowSwitcherAppEntry(id: "fixture", processIdentifier: 100, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: "Document", icon: nil, windowElement: nil, isMinimized: false, shortcutToken: "cmd+w")
        var session = WindowSwitcherSession(entries: [entry], selectedID: entry.id, isPersistent: true, originalWindowID: nil)
        session.usesDirectKeys = true
        session.protectedCommandKeys = ["w", "q"]
        controller.show(session, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
        panel.makeFirstResponder(search)
        XCTAssertFalse(controller.session!.usesDirectKeys)
        XCTAssertTrue(controller.session!.isPersistent)
        var destructive = false
        controller.onClose = { _ in destructive = true }
        controller.onQuit = { _ in destructive = true }
        for (text, code) in [("w", kVK_ANSI_W), ("q", kVK_ANSI_Q)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)))
            _ = panel.performKeyEquivalent(with: event)
        }
        XCTAssertFalse(destructive)
        XCTAssertTrue(panel.isVisible)
    }
}
