import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherSessionTests: XCTestCase {
    func testNativePanelScrollsToSixtiethWindowAndProtectsMarkedText() throws {
        let controller = WindowSwitcherOverlayController()
        let entries = (0..<60).map { entry("window-\($0)", title: "Chrome document \($0 + 1)") }
        let value = WindowSwitcherSession(entries: entries, selectedID: "window-0", isPersistent: true, originalWindowID: nil)
        controller.show(value, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 60)
        XCTAssertGreaterThan(table.enclosingScrollView?.frame.height ?? 0, 100)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
        for _ in 0..<59 {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: UInt16(kVK_DownArrow)))
            table.keyDown(with: event)
        }
        XCTAssertEqual(controller.session?.selectedID, "window-59")
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: 59)))

        let search = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSearchField }.first)
        let editor = NSTextView()
        editor.setMarkedText("旅行", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var committed = false
        controller.onSelect = { _ in committed = true }
        XCTAssertFalse(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(committed)
        editor.unmarkText()
        XCTAssertTrue(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(committed)
        var quitID: String?
        controller.onQuit = { quitID = $0.id }
        let quitEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)))
        XCTAssertTrue(panel.performKeyEquivalent(with: quitEvent))
        XCTAssertEqual(quitID, "window-59")

        // This captures only this synthetic fixture's view, never the user's desktop.
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/window-switcher-native-preview.png"))
        }
    }

    func testNativeSearchEditorPastesChineseAndKeepsCompositionCommandsLocal() async throws {
        let controller = WindowSwitcherOverlayController()
        let value = WindowSwitcherSession(entries: [entry("travel", title: "旅行计划"), entry("work", title: "Work")],
            selectedID: "work", isPersistent: true, originalWindowID: "work")
        controller.show(value, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSSearchField }.first)
        XCTAssertTrue(panel.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        XCTAssertTrue(pasteboard.setString("旅行", forType: .string))
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.session?.query, "旅行")
        XCTAssertEqual(controller.session?.results.map(\.id), ["travel"])
        XCTAssertTrue(controller.session?.isPersistent == true)
        var selected: String?, cancelled = false
        controller.onSelect = { selected = $0.id }
        controller.onCancel = { cancelled = true }
        editor.setMarkedText("旅行", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertFalse(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(selected)
        XCTAssertFalse(cancelled)
        editor.unmarkText()
        XCTAssertTrue(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(selected, "travel")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.session?.query, "")
        XCTAssertEqual(controller.session?.results.count, 2)
        XCTAssertTrue(controller.session?.isPersistent == true)
    }

    func testMetadataRefreshPreservesManualScrollButNavigationRevealsSelection() throws {
        let controller = WindowSwitcherOverlayController()
        var value = WindowSwitcherSession(entries: (0..<60).map { entry("window-\($0)") }, selectedID: "window-0",
                                          isPersistent: true, originalWindowID: nil)
        controller.show(value, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        table.scrollRowToVisible(45)
        let position = table.visibleRect.origin.y
        XCTAssertGreaterThan(position, 100)
        value.entries[1] = entry("window-1", title: "Updated title")
        controller.update(value)
        XCTAssertEqual(table.visibleRect.origin.y, position, accuracy: 1)
        XCTAssertEqual(controller.session?.selectedID, "window-0")
        value.selectedID = "window-59"
        controller.update(value)
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: 59)))
        value.query = "Updated title"
        value.normalizeSelection()
        controller.update(value)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: 0)))
    }

    func testHeldInvocationModifierTransitionsIntoNativeSearch() async throws {
        for modifier: NSEvent.ModifierFlags in [.option, .command, [.control, .option]] {
            let controller = WindowSwitcherOverlayController()
            let value = WindowSwitcherSession(entries: [entry("text", title: "text")], selectedID: "text",
                isPersistent: false, originalWindowID: nil, invocationModifiers: modifier)
            controller.show(value, currentPID: 100, showsPreview: false)
            let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(try XCTUnwrap(panel.contentView))
            let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
            let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
            let first = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: modifier.contains(.option) ? "†" : "t",
                charactersIgnoringModifiers: "t", isARepeat: false, keyCode: UInt16(kVK_ANSI_T)))
            if modifier == .command { XCTAssertTrue(panel.performKeyEquivalent(with: first)) }
            else { table.keyDown(with: first) }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(controller.session?.query, "t")
            XCTAssertTrue(controller.session?.isPersistent == true)
            let second = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: modifier.contains(.option) ? "≈" : "x",
                charactersIgnoringModifiers: "x", isARepeat: false, keyCode: UInt16(kVK_ANSI_X)))
            panel.sendEvent(second)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(controller.session?.query, "tx")
            var closeCount = 0, quitCount = 0
            controller.onClose = { _ in closeCount += 1 }
            controller.onQuit = { _ in quitCount += 1 }
            for (text, code) in [("w", kVK_ANSI_W), ("q", kVK_ANSI_Q)] {
                let next = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier, timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: UInt16(code)))
                XCTAssertTrue(panel.performKeyEquivalent(with: next))
            }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(controller.session?.query, "txwq")
            XCTAssertEqual(closeCount, 0)
            XCTAssertEqual(quitCount, 0)
            let release = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: UInt16(kVK_Option)))
            panel.sendEvent(release)
            XCTAssertNotNil(search.currentEditor() as? NSTextView)
            // A newly pressed editing modifier is preserved after the original
            // invocation modifier's release. These events are never posted.
            let editingEvent = controller.filterSearchEvent(first)
            XCTAssertEqual(editingEvent.modifierFlags, modifier)
            XCTAssertEqual(editingEvent.characters, first.characters)
            controller.hide()
        }
    }

    func testWindowlessForegroundAppParticipatesInRecencyAndQuickSwitch() {
        let a = entry("a"), c = entry("c")
        let fallback = WindowSwitcherAppEntry(id: "app-b", processIdentifier: 200, bundleIdentifier: "test.b",
            appName: "Windowless", windowTitle: nil, icon: nil, windowElement: nil, isMinimized: false, shortcutToken: nil)
        var recency = WindowSwitcherRecency()
        recency.record(c.id)
        recency.observeForeground(entries: [a], focusedWindowID: a.id, unavailable: false)
        recency.observeForeground(entries: [fallback], focusedWindowID: nil, unavailable: false)
        XCTAssertEqual(recency.focusedID, fallback.id)
        XCTAssertEqual(recency.sort([a, fallback, c]).map(\.id), [fallback.id, a.id, c.id])
        var session = WindowSwitcherSession(entries: recency.sort([a, fallback, c]), selectedID: recency.focusedID,
            isPersistent: false, originalWindowID: recency.focusedID)
        session.advance(1)
        XCTAssertEqual(session.selectedID, a.id)
        recency.observeForeground(entries: [fallback], focusedWindowID: nil, unavailable: true)
        XCTAssertNil(recency.focusedID)
        XCTAssertEqual(recency.ids.first, fallback.id)
    }

    func testEmptyDisplayFilterRemainsVisibleInsteadOfShowingAllDisplays() throws {
        let controller = WindowSwitcherOverlayController()
        let value = WindowSwitcherSession(entries: [entry("a")], selectedID: nil, display: 99,
                                          isPersistent: true, originalWindowID: nil)
        controller.show(value, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let popup = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual((popup.selectedItem?.representedObject as? NSNumber)?.uint32Value, 99)
        XCTAssertTrue(controller.session?.results.isEmpty == true)
    }

    func testAXIdentitySurvivesReorderingButNotClosedOrRestartedLifetimes() {
        // Opaque AX handles suffice to exercise equality; no application is queried.
        let a = AXUIElementCreateApplication(101)
        let b = AXUIElementCreateApplication(102)
        var registry = WindowSwitcherWindowIdentities()
        let initial = registry.reconcile([a, b])
        XCTAssertEqual(registry.reconcile([b, a]), [initial[1], initial[0]])
        XCTAssertEqual(registry.reconcile([a, a]), [initial[0], initial[0]])
        let reopened = registry.reconcile([a, b])
        XCTAssertEqual(reopened[0], initial[0])
        XCTAssertNotEqual(reopened[1], initial[1])
        var restarted = WindowSwitcherWindowIdentities()
        XCTAssertNotEqual(restarted.reconcile([a])[0], initial[0])
    }

    private func entry(_ id: String, title: String = "Document", pid: pid_t = 100) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: pid, bundleIdentifier: "org.example.browser",
            appName: "Browser", windowTitle: title, icon: nil, windowElement: nil, isMinimized: false, shortcutToken: nil)
    }

    func testSelectionCannotMigrateWhenSnapshotReordersOrRenamesWindows() {
        let a = entry("a"), b = entry("b")
        var session = WindowSwitcherSession(entries: [a, b], selectedID: "b", isPersistent: false, originalWindowID: "a")
        session.reconcile([entry("b", title: "Renamed"), a, entry("c")])
        XCTAssertEqual(session.entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(session.selected?.id, "b")
        XCTAssertEqual(session.selected?.displayName, "Renamed")
    }

    func testClosingSelectedWindowNeverReusesItsIdentity() {
        var session = WindowSwitcherSession(entries: [entry("a"), entry("b")], selectedID: "b", isPersistent: false, originalWindowID: "a")
        session.reconcile([entry("a"), entry("replacement", title: "Document")])
        XCTAssertEqual(session.selectedID, "a")
        XCTAssertFalse(session.entries.contains { $0.id == "b" })
    }

    func testSixtySameTitleWindowsRemainReachableInBothDirections() {
        let entries = (0..<60).map { entry(String($0)) }
        var session = WindowSwitcherSession(entries: entries, selectedID: "0", isPersistent: false, originalWindowID: "0")
        var visited = Set<String>()
        for _ in 0..<60 { session.advance(1); visited.insert(session.selectedID!) }
        XCTAssertEqual(visited.count, 60)
        XCTAssertEqual(session.selectedID, "0")
        session.advance(-1)
        XCTAssertEqual(session.selectedID, "59")
    }

    func testPerWindowRecencyIncludesTwoWindowsOfOneApplication() {
        var recency = WindowSwitcherRecency()
        let entries = [entry("a"), entry("b"), entry("c")]
        recency.record("a"); recency.record("b"); recency.record("a")
        XCTAssertEqual(recency.sort(entries).map(\.id), ["a", "b", "c"])
        recency.record("c")
        recency.retain(["a", "b"])
        XCTAssertEqual(recency.ids, ["a", "b"])
    }

    func testSearchMatchesChineseAndAppNameWithoutCollapsingIdenticalTitles() {
        var session = WindowSwitcherSession(entries: [entry("a", title: "旅行计划"), entry("b", title: "旅行计划"), entry("c")],
            selectedID: "a", isPersistent: false, originalWindowID: "a")
        session.query = "browser 旅行"
        XCTAssertEqual(session.results.map(\.id), ["a", "b"])
        session.query = "no matching title"
        session.normalizeSelection()
        XCTAssertNil(session.selected)
        session.advance(1)
        XCTAssertNil(session.selectedID)
    }

    func testSearchRanksExactAndPrefixTitlesWithStableTiesAndHighlightsEveryTerm() {
        var session = WindowSwitcherSession(entries: [entry("substring", title: "My travel plan"),
            entry("prefix", title: "Travel plan"), entry("exact-a", title: "Travel"), entry("exact-b", title: "Travel")],
            selectedID: "substring", isPersistent: true, originalWindowID: nil)
        session.query = "travel"
        XCTAssertEqual(session.results.map(\.id), ["exact-a", "exact-b", "prefix", "substring"])
        XCTAssertEqual(session.selectedID, "substring")
        let text = "旅行 Browser 旅行"
        let ranges = WindowSwitcherOverlayController.matchRanges(in: text, query: "browser 旅行")
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["Browser", "旅行", "旅行"])
    }

    func testEnteringAndClearingSearchStaysPersistentUntilSessionEnds() {
        var session = WindowSwitcherSession(entries: [entry("a")], selectedID: "a", isPersistent: false, originalWindowID: "a")
        session.beginSearch()
        session.query = "a"
        session.query = ""
        XCTAssertTrue(session.isPersistent)
    }

    func testDisplayFilterDistinguishesIdenticallyNamedDisplays() {
        var a = entry("a"), b = entry("b")
        a.displayID = 10; a.displayNameContext = "Studio Display"
        b.displayID = 20; b.displayNameContext = "Studio Display"
        var session = WindowSwitcherSession(entries: [a, b], selectedID: "a", isPersistent: true, originalWindowID: nil)
        XCTAssertEqual(session.displays.count, 2)
        XCTAssertEqual(Set(session.displays.map(\.name)).count, 2)
        session.display = 20
        session.normalizeSelection()
        XCTAssertEqual(session.results.map(\.id), ["b"])
        XCTAssertEqual(session.selectedID, "b")
        b.displayNameContext = "Renamed display"
        session.reconcile([a, b])
        XCTAssertEqual(session.results.map(\.id), ["b"])
    }

    func testCurrentApplicationScopeUsesProcessRatherThanSharedBundleID() {
        var session = WindowSwitcherSession(entries: [entry("a", pid: 100), entry("b", pid: 200)],
            selectedID: "b", scope: .currentApplication(100), isPersistent: false, originalWindowID: "a")
        session.normalizeSelection()
        XCTAssertEqual(session.results.map(\.id), ["a"])
        XCTAssertEqual(session.selectedID, "a")
    }

    func testPanelFitsUsableFrameIncludingDisplaysWithNegativeOrigins() {
        for frame in [CGRect(x: -1280, y: -500, width: 1280, height: 720), CGRect(x: 0, y: 0, width: 800, height: 500), CGRect(x: 0, y: 0, width: 320, height: 480)] {
            for preview in [false, true] {
                let panel = WindowSwitcherSession.panelFrame(visibleFrame: frame, preview: preview)
                XCTAssertTrue(frame.contains(panel))
                XCTAssertLessThanOrEqual(panel.height, 610)
            }
        }
    }

    func testUnavailableMetadataAndWindowStatesTriggerSnapshotUpdates() {
        let initial = entry("a")
        var updated = initial
        updated.metadataUnavailable = true
        XCTAssertNotEqual(initial, updated)
        updated = initial; updated.isHidden = true
        XCTAssertNotEqual(initial, updated)
    }

    func testNewInstallDefaultsPreserveNativeCommandTab() {
        XCTAssertTrue(WindowSwitcherConfiguration.default.usesCompanionDefaults)
        XCTAssertEqual(WindowSwitcherConfiguration.default.mode, .directCycle)
        XCTAssertEqual(WindowSwitcherShortcutBindingStore.defaultBinding.modifiers, .option)
    }

    func testCurrentApplicationShortcutUsesAnAvailableCanonicalAction() throws {
        let plugin = WindowSwitcherPlugin(context: PluginRuntimeContext(
            pluginID: WindowSwitcherConstants.pluginID, storage: WindowSwitcherMemoryStorage()), accessibilityTrusted: { true })
        let action = try XCTUnwrap(plugin.actionDefinitions.first { $0.key.actionID == WindowSwitcherConstants.currentAppActionID })
        XCTAssertEqual(plugin.permissionRequirementIDs(for: action.key), [WindowSwitcherConstants.accessibilityPermissionID])
        XCTAssertTrue(plugin.actionAvailability(for: ActionReference(key: action.key)).isAvailable)
        XCTAssertEqual(action.externalInvocationPolicy, .unavailable)
    }

    func testLegacyConfigurationPreservesInheritedShortcutUntilExplicitMigration() throws {
        let decoded = try JSONDecoder().decode(WindowSwitcherConfiguration.self, from: Data(#"{"mode":"keyWindow","sortMode":"recentUse"}"#.utf8))
        XCTAssertFalse(decoded.usesCompanionDefaults)
        XCTAssertFalse(decoded.showsPreview)
        XCTAssertEqual(decoded.mode, .keyWindow)
    }

    func testCustomBindingsSurviveDefaultPresetChange() throws {
        let suite = "WindowSwitcherTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = ShortcutBinding(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])
        defaults.set(try JSONEncoder().encode(ShortcutCustomization.custom(custom)), forKey: "shortcut.customization.\(WindowSwitcherShortcutBindingStore.itemID)")
        for fallback in [WindowSwitcherShortcutBindingStore.defaultBinding, WindowSwitcherShortcutBindingStore.legacyBinding] {
            XCTAssertEqual(WindowSwitcherShortcutBindingStore.resolvedBinding(id: WindowSwitcherConstants.shortcutDefinitionID, defaultBinding: fallback, userDefaults: defaults), custom)
        }
    }
}
