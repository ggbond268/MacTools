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

    func testMenusActOnAddressedTabWithoutOfferingDeletion() {
        let strip = makeStrip()
        var moves: [(String, Int)] = []
        var openedPanels: [String] = []
        strip.onMove = { moves.append(($0, $1)) }
        strip.onChangeIcon = { openedPanels.append($0) }
        let customMenu = strip.menu(forPanelID: "media")
        customMenu.performActionForItem(at: 0)
        customMenu.performActionForItem(at: 1)
        customMenu.performActionForItem(at: 3)
        XCTAssertEqual(customMenu.items[3].title, FeatureL10n.string("更换图标"))
        XCTAssertEqual(customMenu.items.count, 4)
        XCTAssertEqual(openedPanels, ["media"])
        XCTAssertEqual(moves.map(\.0), ["media", "media"])
        XCTAssertEqual(moves.map(\.1), [2, 5])

        let firstMenu = strip.menu(forPanelID: "components")
        XCTAssertFalse(firstMenu.items[0].isEnabled)
        XCTAssertTrue(firstMenu.items[3].isEnabled)
        XCTAssertEqual(firstMenu.items.count, 4)
        firstMenu.performActionForItem(at: 3)
        XCTAssertEqual(openedPanels, ["media", "components"])
        XCTAssertFalse(strip.menu(forPanelID: "travel").items[1].isEnabled)
    }

    func testFixedWidthTabsRevealSelectionAndRetainFullAccessibleNames() throws {
        let strip = makeStrip()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 310, height: 44))
        scroll.documentView = strip
        strip.update(panels: panels, selectedPanelID: "travel")
        strip.layoutSubtreeIfNeeded()
        XCTAssertTrue(strip.visibleRect.contains(MenuBarPanelTabLayout.frame(at: 4)))
        let button = try button(in: strip, identifier: "menuBarPanel.tab.work")
        XCTAssertEqual(button.accessibilityLabel(), "Frequently Used Tools")
        XCTAssertEqual(button.toolTip, "Frequently Used Tools")
        XCTAssertEqual(button.frame, button.superview?.bounds)
        XCTAssertEqual(button.superview?.subviews.compactMap { $0 as? MenuBarPanelIconControl }.count, 1)
        XCTAssertEqual(button.superview?.frame.size, CGSize(width: MenuBarPanelTabLayout.width, height: MenuBarPanelLayout.tabItemHeight))
        scroll.setFrameSize(CGSize(width: 740, height: 44))
        strip.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.superview?.frame.size, CGSize(width: MenuBarPanelTabLayout.width, height: MenuBarPanelLayout.tabItemHeight))
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
        func backgroundAlpha(_ id: String) throws -> CGFloat {
            let tab = try button(in: strip, identifier: "menuBarPanel.tab.\(id)")
            return try XCTUnwrap(tab.layer?.backgroundColor).alpha
        }
        XCTAssertGreaterThan(try backgroundAlpha("work"), 0)
        try click("work")
        XCTAssertEqual(iconChanges, ["work"])
        XCTAssertTrue(selections.isEmpty)
        XCTAssertGreaterThan(try backgroundAlpha("work"), 0)
        strip.update(panels: panels, selectedPanelID: "work")
        XCTAssertGreaterThan(try backgroundAlpha("work"), 0, "Closing the icon picker preserves selection")
        try click("media")
        XCTAssertEqual(selections, ["media"])
        XCTAssertEqual(iconChanges, ["work"])
        XCTAssertGreaterThan(try backgroundAlpha("media"), 0, "Switching tabs highlights the selected panel")
        XCTAssertEqual(try backgroundAlpha("work"), 0)
        try click("media")
        XCTAssertEqual(selections, ["media"])
        XCTAssertEqual(iconChanges, ["work", "media"])
        try click("components")
        try click("components")
        XCTAssertEqual(selections, ["media", "components"])
        XCTAssertEqual(iconChanges, ["work", "media", "components"])
        XCTAssertGreaterThan(try backgroundAlpha("components"), 0)
        strip.menu(forPanelID: "media").performActionForItem(at: 3)
        XCTAssertGreaterThan(try backgroundAlpha("components"), 0)
        XCTAssertEqual(try backgroundAlpha("media"), 0, "Editing another icon must not move the selected background")
    }

    func testOverflowButtonsScrollWithoutShrinkingTabsAndDisappearWhenAllTabsFit() throws {
        let navigation = MenuBarPanelTabNavigationView(frame: CGRect(x: 0, y: 0, width: 100, height: MenuBarPanelLayout.headerHeight))
        let strip = navigation.strip
        strip.reduceMotion = true
        strip.update(panels: panels, selectedPanelID: "components")
        navigation.layoutSubtreeIfNeeded()
        var selections: [String] = []
        strip.onSelect = { selections.append($0) }
        let left = try button(in: navigation, identifier: "menuBarPanel.scrollLeft")
        let right = try button(in: navigation, identifier: "menuBarPanel.scrollRight")
        XCTAssertFalse(left.isHidden)
        XCTAssertFalse(left.isEnabled)
        XCTAssertTrue(right.isEnabled)
        _ = right.accessibilityPerformPress()
        XCTAssertGreaterThan(strip.visibleRect.minX, 0)
        XCTAssertTrue(left.isEnabled)
        for _ in 0..<5 { _ = right.accessibilityPerformPress() }
        XCTAssertFalse(right.isEnabled)
        XCTAssertTrue(selections.isEmpty)
        navigation.setFrameSize(CGSize(width: 170, height: MenuBarPanelLayout.headerHeight))
        navigation.layoutSubtreeIfNeeded()
        XCTAssertTrue(left.isHidden)
        XCTAssertTrue(right.isHidden)
        XCTAssertEqual(strip.tabWidth, MenuBarPanelTabLayout.width)
        XCTAssertLessThanOrEqual(strip.frame.width, 170)
        XCTAssertEqual(strip.visibleRect.minX, 0, accuracy: 0.5)
        for panel in panels {
            let tab = try button(in: strip, identifier: "menuBarPanel.tab.\(panel.id)")
            XCTAssertEqual(tab.superview?.frame.width, strip.tabWidth)
        }
    }

    func testNormalAndEditingTabsShareSelectionHoverAndCenteredBorder() throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let visiblePanels = Array(panels.prefix(3))
        let navigation = MenuBarPanelTabNavigationView(frame: CGRect(x: 0, y: 0, width: 92, height: MenuBarPanelLayout.headerHeight))
        navigation.appearance = NSAppearance(named: .aqua)
        let strip = navigation.strip
        let theme = MenuBarPanelThemeResolver.resolve(definition: nil, colorScheme: .light, contrast: .standard)
        strip.selectionColor = NSColor(theme.surfaces.tabSelection)
        strip.hoverColor = NSColor(theme.surfaces.hover)
        strip.update(panels: visiblePanels, selectedPanelID: "work")
        navigation.configure(theme: theme, contrast: .standard)
        navigation.layoutSubtreeIfNeeded()
        let capsule = try XCTUnwrap(navigation.layer?.sublayers?.first as? CAShapeLayer)
        let borderColor = capsule.strokeColor
        XCTAssertEqual(try XCTUnwrap(capsule.path).boundingBoxOfPath.midX, navigation.bounds.midX, accuracy: 0.5)

        let selected = try button(in: navigation, identifier: "menuBarPanel.tab.work")
        let other = try button(in: navigation, identifier: "menuBarPanel.tab.features")
        XCTAssertFalse(descendants(navigation).contains { $0.accessibilityIdentifier() == "menuBarPanel.add" })
        let selectedBackground = selected.layer?.backgroundColor
        XCTAssertTrue(selected.isSelected)
        XCTAssertEqual(selected.bounds.size, CGSize(width: 26, height: 26))
        XCTAssertEqual(selected.layer?.cornerRadius, MenuBarPanelLayout.tabItemHeight / 2)
        XCTAssertEqual(other.layer?.backgroundColor?.alpha, 0)
        XCTAssertFalse(strip.beginReordering("work"), "Normal mode cannot start a panel drag")
        XCTAssertTrue(strip.menu(forPanelID: "work").items.isEmpty)
        var iconChanges: [String] = []
        strip.onChangeIcon = { iconChanges.append($0) }
        strip.selectPanel("work")
        XCTAssertTrue(iconChanges.isEmpty)

        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        other.mouseEntered(with: hover)
        let hoverBackground = other.layer?.backgroundColor
        XCTAssertNotEqual(hoverBackground?.alpha, 0)
        selected.mouseEntered(with: hover)
        XCTAssertEqual(selected.layer?.backgroundColor, selectedBackground, "Hover preserves the selected background")
        other.mouseExited(with: hover)
        XCTAssertEqual(other.layer?.backgroundColor?.alpha, 0)

        strip.isEditing = true
        strip.update(panels: visiblePanels, selectedPanelID: "work")
        navigation.setFrameSize(CGSize(width: 160, height: MenuBarPanelLayout.headerHeight))
        navigation.layoutSubtreeIfNeeded()
        let capsuleFrame = try XCTUnwrap(capsule.path).boundingBoxOfPath
        XCTAssertEqual(capsuleFrame.midX, navigation.bounds.midX, accuracy: 0.5)
        XCTAssertEqual(capsule.strokeColor, borderColor, "Editing keeps the normal capsule border")
        XCTAssertTrue(selected === (try button(in: navigation, identifier: "menuBarPanel.tab.work")))
        XCTAssertEqual(selected.layer?.backgroundColor, selectedBackground)
        XCTAssertEqual(selected.layer?.cornerRadius, MenuBarPanelLayout.tabItemHeight / 2)
        XCTAssertEqual(MenuBarPanelTabLayout.spacing, 2)
        XCTAssertEqual(MenuBarPanelLayout.headerAccessorySpacing, 0)
        strip.selectPanel("work")
        XCTAssertEqual(iconChanges, ["work"])

    }

    func testDragPreviewRendersTheVacatedSlotAndInsertionPosition() throws {
        let strip = makeStrip()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        XCTAssertTrue(strip.beginReordering("components"))
        strip.previewReordering(centerX: MenuBarPanelTabLayout.frame(at: 2).midX)
        strip.layoutSubtreeIfNeeded()
        let movedButton = try button(in: strip, identifier: "menuBarPanel.tab.components")
        XCTAssertEqual(movedButton.superview?.alphaValue, 0.22)
        XCTAssertEqual(movedButton.superview?.frame, MenuBarPanelTabLayout.frame(at: 2))
        let bitmap = try XCTUnwrap(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
        strip.cacheDisplay(in: strip.bounds, to: bitmap)
        let image = NSImage(size: strip.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Panel tab drag insertion preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/mactools-panel-tabs-drag.png"))
        strip.finishReordering(commit: false)
        XCTAssertEqual(movedButton.superview?.alphaValue, 1)
    }

    func testRightClickAndControlClickKeepTheContextMenuWithoutActivatingTab() async throws {
        let strip = makeStrip()
        let window = makeWindow(strip: strip)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        var openedMenus: [[String]] = []
        strip.onSelect = { _ in XCTFail("A context menu must not switch tabs") }
        strip.onChangeIcon = { _ in XCTFail("A context menu must not open the icon picker") }
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                              object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                openedMenus.append(menu.items.compactMap { $0.representedObject as? String })
                // Tracking begins after the notification; use its run-loop mode so
                // cancellation cannot run too early or wait for the menu to close.
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak menu] timer in
                    MainActor.assumeIsolated {
                        guard let menu else { timer.invalidate(); return }
                        menu.cancelTrackingWithoutAnimation()
                    }
                }
                RunLoop.main.add(timer, forMode: .eventTracking)
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { timer.invalidate() }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let tab = try button(in: strip, identifier: "menuBarPanel.tab.media")
        let point = tab.convert(CGPoint(x: 12, y: 14), to: nil)
        tab.rightMouseDown(with: mouseEvent(.rightMouseDown, at: point, window: window))
        let controlClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        tab.mouseDown(with: controlClick)
        XCTAssertEqual(openedMenus, [Array(repeating: "media", count: 3), Array(repeating: "media", count: 3)])
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
