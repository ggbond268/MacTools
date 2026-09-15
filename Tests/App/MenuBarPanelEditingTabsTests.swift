import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelEditingTabsTests: XCTestCase {
    func testItemDragHoverCoalescesAndRejectsEndedOrRemovedTargets() async throws {
        let strip = makeStrip()
        strip.isEditing = true
        strip.update(panels: panels, selectedPanelID: "components")
        let session = PanelLayoutEditingSession()
        strip.itemDragSession = session
        var selections: [String] = []
        strip.onItemDragHover = { selections.append($0) }
        let entry = MenuBarPanelEntry(pluginID: "a", surface: .dashboard)
        _ = session.begin(entry: entry, panelID: "components", ids: [entry.id])
        strip.updateItemDragHover(panelID: "work")
        try await Task.sleep(for: .milliseconds(180))
        for _ in 0..<100 { strip.updateItemDragHover(panelID: "work") }
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertEqual(selections, ["work"], "Pointer updates must not postpone or repeat activation")
        strip.updateItemDragHover(panelID: "media")
        strip.updateItemDragHover(panelID: nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(selections, ["work"])
        strip.updateItemDragHover(panelID: "media")
        session.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(selections, ["work"], "An ended drag cannot switch panels later")
        _ = session.begin(entry: entry, panelID: "components", ids: [entry.id])
        strip.updateItemDragHover(panelID: "media")
        strip.update(panels: panels.filter { $0.id != "media" }, selectedPanelID: "components")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(selections, ["work"])
        strip.updateItemDragHover(panelID: "work")
        strip.isEditing = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(selections, ["work"])
    }

    private var panels: [MenuBarPanelDefinition] {
        MenuBarPanelDefinition.defaults + [
            MenuBarPanelDefinition(id: "work", name: "Frequently Used Tools", systemImage: "star"),
            MenuBarPanelDefinition(id: "media", name: "Media", systemImage: "headphones"),
            MenuBarPanelDefinition(id: "travel", name: "Travel", systemImage: "airplane"),
        ]
    }

    func testDragPreviewAndCancellationPreserveSavedOrderAndSelection() {
        let strip = makeStrip()
        strip.isEditing = false
        XCTAssertFalse(strip.beginReordering("work"))
        XCTAssertTrue(strip.menu(forPanelID: "work").items.isEmpty)
        strip.isEditing = true
        var moves: [String] = []
        var selections: [String] = []
        var iconChanges: [String] = []
        strip.onChangeIcon = { iconChanges.append($0) }
        strip.onMove = { id, _ in moves.append(id) }
        strip.onSelect = { selections.append($0) }

        XCTAssertTrue(strip.beginReordering("work"))
        strip.selectPanel("work")
        XCTAssertTrue(iconChanges.isEmpty)
        strip.finishReordering(commit: false)

        XCTAssertTrue(strip.beginReordering("components"))
        strip.previewReordering(centerX: 740)
        XCTAssertEqual(strip.previewIDs, ["features", "work", "media", "travel", "components"])
        XCTAssertEqual(strip.panels, panels)
        XCTAssertTrue(moves.isEmpty)
        XCTAssertTrue(selections.isEmpty)

        strip.finishReordering(commit: false)
        XCTAssertNil(strip.draggedID)
        XCTAssertEqual(strip.previewIDs, panels.map(\.id))
        XCTAssertTrue(moves.isEmpty)
        XCTAssertTrue(selections.isEmpty)
    }

    func testDropPersistsDefaultPanelMoveOnceAndNoOpDoesNotWrite() throws {
        let suite = "MenuBarPanelEditingTabsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarPanelStore(userDefaults: defaults)
        var configuration = MenuBarPanelConfiguration()
        configuration.panels = panels
        store.replace(configuration)
        let strip = makeStrip()
        var moveCount = 0
        strip.onMove = { id, offset in
            moveCount += 1
            store.movePanel(id: id, toOffset: offset)
            strip.update(panels: store.configuration.panels, selectedPanelID: "work")
        }

        XCTAssertTrue(strip.beginReordering("components"))
        strip.previewReordering(centerX: 740)
        strip.finishReordering(commit: true)
        strip.finishReordering(commit: false) // Native drag cleanup follows the successful drop.
        XCTAssertEqual(moveCount, 1)
        XCTAssertEqual(store.configuration.panels.map(\.id), ["features", "work", "media", "travel", "components"])
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).configuration.panels, store.configuration.panels)

        XCTAssertTrue(strip.beginReordering("components"))
        strip.finishReordering(commit: true)
        XCTAssertEqual(moveCount, 1)
    }

    func testExternalRemovalInvalidatesDragInsteadOfApplyingStaleIndices() {
        let strip = makeStrip()
        var didMove = false
        strip.onMove = { _, _ in didMove = true }
        XCTAssertTrue(strip.beginReordering("work"))
        strip.previewReordering(centerX: 740)
        let remaining = panels.filter { $0.id != "work" }
        strip.update(panels: remaining, selectedPanelID: "components")
        strip.finishReordering(commit: true)
        XCTAssertFalse(didMove)
        XCTAssertNil(strip.draggedID)
        XCTAssertEqual(strip.previewIDs, remaining.map(\.id))
    }

    func testMenusActOnAddressedTab() {
        let strip = makeStrip()
        var moves: [(String, Int)] = []
        var openedPanels: [String] = []
        strip.onMove = { moves.append(($0, $1)) }
        strip.onChangeIcon = { openedPanels.append($0) }
        let customMenu = strip.menu(forPanelID: "media")
        customMenu.performActionForItem(at: 0)
        customMenu.performActionForItem(at: 1)
        customMenu.performActionForItem(at: 3)
        XCTAssertEqual(openedPanels, ["media"])
        XCTAssertEqual(moves.map(\.0), ["media", "media"])
        XCTAssertEqual(moves.map(\.1), [2, 5])

        let firstMenu = strip.menu(forPanelID: "components")
        XCTAssertFalse(firstMenu.items[0].isEnabled)
        XCTAssertTrue(firstMenu.items[3].isEnabled)
        firstMenu.performActionForItem(at: 3)
        XCTAssertEqual(openedPanels, ["media", "components"])
        XCTAssertFalse(strip.menu(forPanelID: "travel").items[1].isEnabled)
    }

    func testMouseAndKeyboardSelectTabsWithoutReordering() async throws {
        let strip = makeStrip()
        let window = makeWindow(strip: strip)
        defer { window.close() }
        var selections: [String] = []
        var moves: [String] = []
        strip.onSelect = { selections.append($0) }
        strip.onMove = { id, _ in moves.append(id) }
        try await Task.sleep(for: .milliseconds(100))
        let tab = try button(in: strip, identifier: "menuBarPanel.tab.media")
        let point = tab.convert(CGPoint(x: 12, y: 14), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(mouseEvent(type, at: point, window: window))
        }
        XCTAssertEqual(selections, ["media"])
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        window.sendEvent(key)
        XCTAssertEqual(selections, ["media", "travel"])
        XCTAssertTrue(moves.isEmpty)
    }

    func testClickSwitchesOtherTabsAndEditsOnlyTheSelectedIcon() async throws {
        let strip = makeStrip()
        let window = makeWindow(strip: strip)
        defer { window.close() }
        var selections: [String] = []
        var iconChanges: [String] = []
        strip.onSelect = { [weak strip] id in
            guard let strip else { return }
            selections.append(id)
            strip.update(panels: self.panels, selectedPanelID: id)
        }
        strip.onChangeIcon = { id in
            iconChanges.append(id)
        }
        try await Task.sleep(for: .milliseconds(100))
        func click(_ id: String) throws {
            let tab = try button(in: strip, identifier: "menuBarPanel.tab.\(id)")
            let point = tab.convert(CGPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(mouseEvent(type, at: point, window: window))
            }
        }
        try click("work")
        XCTAssertEqual(iconChanges, ["work"])
        XCTAssertTrue(selections.isEmpty)
        try click("media")
        XCTAssertEqual(selections, ["media"])
        XCTAssertEqual(iconChanges, ["work"])
        try click("media")
        XCTAssertEqual(selections, ["media"])
        XCTAssertEqual(iconChanges, ["work", "media"])
        try click("components")
        try click("components")
        XCTAssertEqual(selections, ["media", "components"])
        XCTAssertEqual(iconChanges, ["work", "media", "components"])
    }

    private func makeStrip() -> MenuBarPanelTabStripView {
        let strip = MenuBarPanelTabStripView()
        strip.reduceMotion = true
        strip.isEditing = true
        strip.update(panels: panels, selectedPanelID: "work")
        strip.layoutSubtreeIfNeeded()
        return strip
    }

    private func makeWindow(strip: MenuBarPanelTabStripView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 750, height: 44),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = strip
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func button(in view: NSView, identifier: String) throws -> MenuBarPanelIconControl {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return try XCTUnwrap(descendants(view).compactMap { $0 as? MenuBarPanelIconControl }.first {
            $0.accessibilityIdentifier() == identifier
        })
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
}
