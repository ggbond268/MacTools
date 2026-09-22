import AppKit
import Carbon
import ApplicationServices
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherSessionTests: XCTestCase {

    func testFinalChooserGeometryRevealsSelectionAndMetadataRefreshPreservesScroll() throws {
        let entries = (0..<60).map { entry(String($0), title: "Window \($0)") }
        var session = WindowSwitcherSession(entries: entries, selectedID: "59", isPersistent: true,
                                            originalWindowID: nil)
        let controller = WindowSwitcherOverlayController()
        controller.show(session, currentPID: 100, showsPreview: true, preferredLayout: .grid)
        defer { controller.hide() }

        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
        })
        panel.contentView?.layoutSubtreeIfNeeded()
        func collection(in view: NSView) -> WindowSwitcherCardCollection? {
            if let value = view as? WindowSwitcherCardCollection { return value }
            return view.subviews.lazy.compactMap(collection).first
        }
        let cards = try XCTUnwrap(panel.contentView.flatMap(collection))
        cards.layoutSubtreeIfNeeded()
        let selectedPath = IndexPath(item: 59, section: 0)
        let selectedFrame = try XCTUnwrap(cards.layoutAttributesForItem(at: selectedPath)?.frame)
        XCTAssertTrue(cards.visibleRect.contains(selectedFrame.insetBy(dx: 0.5, dy: 0.5)))

        let clip = try XCTUnwrap(cards.enclosingScrollView?.contentView)
        clip.scroll(to: CGPoint(x: 0, y: 96))
        cards.enclosingScrollView?.reflectScrolledClipView(clip)
        let manualOrigin = clip.bounds.origin
        session.reconcile((0..<60).map { entry(String($0), title: "Updated \($0)") })
        controller.update(session)
        XCTAssertEqual(clip.bounds.origin.x, manualOrigin.x, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.origin.y, manualOrigin.y, accuracy: 0.5)
    }

    func testChooserRevealsSelectionAfterResizeLayoutPreviewAndScrollerChanges() throws {
        let entries = (0..<60).map { entry(String($0), title: "Window \($0)") }
        let session = WindowSwitcherSession(entries: entries, selectedID: "59", isPersistent: true,
                                            originalWindowID: nil)
        let controller = WindowSwitcherOverlayController()
        controller.show(session, currentPID: 100, showsPreview: true, preferredLayout: .grid)
        defer { controller.hide() }

        let panel = try chooserPanel()
        let cards = try XCTUnwrap(descendant(WindowSwitcherCardCollection.self, in: panel.contentView))
        let cardScroll = try XCTUnwrap(cards.enclosingScrollView)
        assertGridSelectionVisible(59, cards: cards, panel: panel)

        var constrainedFrame = panel.frame
        constrainedFrame.size.width = max(panel.contentMinSize.width, min(constrainedFrame.width, 620))
        constrainedFrame.size.height = max(panel.contentMinSize.height, min(constrainedFrame.height, 440))
        panel.setFrame(constrainedFrame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        assertGridSelectionVisible(59, cards: cards, panel: panel)
        let restoredGridPreviewSize = panel.frame.size

        for style in [NSScroller.Style.legacy, .overlay] {
            cardScroll.scrollerStyle = style
            cardScroll.tile()
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: panel))
            assertGridSelectionVisible(59, cards: cards, panel: panel)
        }

        let picker = try XCTUnwrap(descendant(NSSegmentedControl.self, in: panel.contentView) {
            $0.identifier?.rawValue == "window-switcher-layout"
        })
        picker.selectedSegment = 1
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        let table = try XCTUnwrap(descendant(NSTableView.self, in: panel.contentView))
        assertListSelectionVisible(59, table: table, panel: panel)

        picker.selectedSegment = 0
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        assertGridSelectionVisible(59, cards: cards, panel: panel)
        XCTAssertEqual(panel.frame.width, restoredGridPreviewSize.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, restoredGridPreviewSize.height, accuracy: 1)

        let previewShortcut = try keyEvent("p", code: kVK_ANSI_P, flags: .command, panel: panel)
        XCTAssertTrue(controller.handleChooserShortcut(previewShortcut))
        assertGridSelectionVisible(59, cards: cards, panel: panel)
        XCTAssertTrue(controller.handleChooserShortcut(previewShortcut))
        assertGridSelectionVisible(59, cards: cards, panel: panel)
        XCTAssertEqual(panel.frame.width, restoredGridPreviewSize.width, accuracy: 1)
        XCTAssertEqual(panel.frame.height, restoredGridPreviewSize.height, accuracy: 1)
    }

    func testKeyboardNavigationAfterManualScrollRevealsSelectionWithoutReloadingVisibleCards() throws {
        let entries = (0..<60).map { entry(String($0), title: "Window \($0)") }
        let session = WindowSwitcherSession(entries: entries, selectedID: "30", isPersistent: true,
                                            originalWindowID: nil)
        let controller = WindowSwitcherOverlayController()
        controller.show(session, currentPID: 100, showsPreview: true, preferredLayout: .grid)
        defer { controller.hide() }

        let panel = try chooserPanel()
        let cards = try XCTUnwrap(descendant(WindowSwitcherCardCollection.self, in: panel.contentView))
        let clip = try XCTUnwrap(cards.enclosingScrollView?.contentView)
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY - 24)))
        cards.enclosingScrollView?.reflectScrolledClipView(clip)
        panel.contentView?.layoutSubtreeIfNeeded()
        let previouslyVisible = Dictionary(uniqueKeysWithValues: cards.visibleItems().compactMap { item in
            cards.indexPath(for: item).map { ($0.item, item) }
        })

        cards.keyDown(with: try keyEvent("→", code: kVK_RightArrow, flags: [], panel: panel))
        XCTAssertEqual(controller.session?.selectedID, "31")
        assertGridSelectionVisible(31, cards: cards, panel: panel)
        for (index, item) in previouslyVisible where cards.item(at: index) != nil {
            XCTAssertTrue(cards.item(at: index) === item, "Selection-only navigation must not reload visible card controls")
        }
    }

    func testFindPromotesCyclingAndPreservesNativeSearchInput() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACTOOLS_RUN_DESKTOP_TESTS"] == "1",
            "Requires an active desktop; run with TEST_RUNNER_MACTOOLS_RUN_DESKTOP_TESTS=1."
        )
        let controller = WindowSwitcherOverlayController()
        controller.show(WindowSwitcherSession(entries: [entry("one")], selectedID: "one", isPersistent: false,
            originalWindowID: nil, invocationModifiers: .command), currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let resultsResponder = try XCTUnwrap(panel.firstResponder)
        func key(_ text: String, code: Int, flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)))
        }
        let find = try key("f", code: kVK_ANSI_F, flags: .command)
        XCTAssertTrue(panel.performKeyEquivalent(with: find))
        XCTAssertTrue(controller.isEditingSearch)
        XCTAssertEqual(controller.session?.isPersistent, true)
        XCTAssertEqual(controller.session?.query, "")
        XCTAssertEqual(controller.session?.selectedID, "one")

        // The invocation modifier remains suppressed for ordinary search typing.
        panel.sendEvent(try key("w", code: kVK_ANSI_W, flags: .command))
        XCTAssertEqual(controller.session?.query, "w")
        panel.sendEvent(find)
        XCTAssertEqual(controller.session?.query, "w")

        let release = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Command)))
        panel.sendEvent(release)
        XCTAssertTrue(panel.makeFirstResponder(resultsResponder))
        panel.sendEvent(find)
        XCTAssertTrue(controller.isEditingSearch)
        XCTAssertEqual(controller.session?.query, "w")
        XCTAssertEqual(controller.filterSearchEvent(find).modifierFlags, .command,
                       "Refocusing search must not start suppressing a released invocation modifier again")
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.selectAll(nil)
        panel.sendEvent(try key("f", code: kVK_ANSI_F, flags: []))
        XCTAssertEqual(controller.session?.query, "f", "Plain F remains ordinary text input")
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

    func testScopeNavigationTargetsHighlightedAppAndPreservesMode() {
        let windows = [entry("original", pid: 100), entry("chrome-1", pid: 200), entry("chrome-2", pid: 200)].enumerated().map { index, entry in
            var value = entry; value.windowNumber = UInt32(index + 1); return value
        }
        for persistent in [false, true] {
            var session = WindowSwitcherSession(entries: windows, selectedID: "chrome-1", isPersistent: persistent, originalWindowID: "original")
            session.navigateScope(currentApp: true, direction: 1)
            XCTAssertEqual(session.scope, .currentApplication(200))
            XCTAssertEqual(session.selectedID, "chrome-1")
            XCTAssertEqual(session.results.map(\.id), ["chrome-1", "chrome-2"])
            session.navigateScope(currentApp: true, direction: 1)
            XCTAssertEqual(session.selectedID, "chrome-2")
            session.navigateScope(currentApp: false, direction: 1)
            XCTAssertEqual(session.scope, .all)
            XCTAssertEqual(session.selectedID, "chrome-2")
            XCTAssertEqual(session.isPersistent, persistent)
            session.navigateScope(currentApp: false, direction: 1)
            XCTAssertEqual(session.selectedID, "original")
            session.navigateScope(currentApp: true, direction: 1)
            XCTAssertEqual(session.scope, .all, "A single-window app should not narrow the chooser")
        }
    }

    private func entry(_ id: String, title: String? = "Document", pid: pid_t = 100) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: pid, bundleIdentifier: "org.example.browser",
            appName: "Browser", windowTitle: title, icon: nil, windowElement: nil, isMinimized: false, shortcutToken: nil)
    }

    private func chooserPanel() throws -> NSPanel {
        try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
        } as? NSPanel)
    }

    private func descendant<T: NSView>(
        _ type: T.Type,
        in root: NSView?,
        where predicate: @escaping (T) -> Bool = { _ in true }
    ) -> T? {
        guard let root else { return nil }
        if let match = root as? T, predicate(match) { return match }
        return root.subviews.lazy.compactMap { self.descendant(type, in: $0, where: predicate) }.first
    }

    private func assertGridSelectionVisible(
        _ index: Int,
        cards: WindowSwitcherCardCollection,
        panel: NSPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        panel.contentView?.layoutSubtreeIfNeeded()
        cards.layoutSubtreeIfNeeded()
        guard let frame = cards.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else {
            XCTFail("Missing card layout attributes", file: file, line: line)
            return
        }
        XCTAssertTrue(cards.visibleRect.contains(frame.insetBy(dx: 0.5, dy: 0.5)), file: file, line: line)
    }

    private func assertListSelectionVisible(
        _ row: Int,
        table: NSTableView,
        panel: NSPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: row).insetBy(dx: 0.5, dy: 0.5)),
                      file: file, line: line)
    }

    private func keyEvent(
        _ text: String,
        code: Int,
        flags: NSEvent.ModifierFlags,
        panel: NSPanel
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)))
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

}
