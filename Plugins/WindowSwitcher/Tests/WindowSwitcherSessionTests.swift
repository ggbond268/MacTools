import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MacToolsPluginKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherSessionTests: XCTestCase {

    func testMoreMenuRetainsItsTargetWhenCatalogSelectionChanges() throws {
        let controller = WindowSwitcherOverlayController()
        var a = entry("a"), b = entry("b")
        a.windowNumber = 1; b.windowNumber = 2
        controller.show(WindowSwitcherSession(entries: [a, b], selectedID: a.id, isPersistent: true, originalWindowID: nil), currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let button = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.menu?.items.contains { $0.action == NSSelectorFromString("contextQuit:") } == true })
        let actions = try XCTUnwrap(button.menu).items.filter { ["contextClose:", "contextQuit:"].contains($0.action.map(NSStringFromSelector) ?? "") }
        XCTAssertEqual(actions.count, 2)
        controller.update(WindowSwitcherSession(entries: [b], selectedID: b.id, isPersistent: true, originalWindowID: nil))
        var acted: [String] = []
        controller.onClose = { acted.append($0.id) }; controller.onQuit = { acted.append($0.id) }
        for item in actions { NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item) }
        XCTAssertTrue(acted.isEmpty)
    }

    func testPreviewToggleClampsMovedChooserAndRestoresCompactSize() throws {
        let controller = WindowSwitcherOverlayController()
        controller.show(WindowSwitcherSession(entries: [entry("a")], selectedID: "a", isPersistent: true, originalWindowID: nil), currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        panel.setFrame(NSRect(x: visible.minX + 30, y: visible.minY + 30, width: 580, height: 440), display: true)
        let original = panel.frame
        for index in 0..<2 {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: UInt16(kVK_ANSI_P)))
            XCTAssertTrue(controller.handleChooserShortcut(event))
            XCTAssertTrue(visible.contains(panel.frame), "Expansion near a display edge must remain on screen")
            if index == 1 { XCTAssertEqual(panel.frame.size, original.size) }
        }
    }

    func testGridAndEditorNavigationUseActualColumnsWithEitherScrollerStyle() throws {
        let controller = WindowSwitcherOverlayController()
        let entries = (0..<40).map { entry("row-\($0)") }
        controller.show(WindowSwitcherSession(entries: entries, selectedID: entries[0].id, isPersistent: true, originalWindowID: nil), currentPID: 100, showsPreview: false, preferredLayout: .grid)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(panel.contentView!)
        let cards = try XCTUnwrap(views.compactMap { $0 as? NSCollectionView }.first)
        let scroll = try XCTUnwrap(cards.enclosingScrollView)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
        let editor = NSTextView()
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            for width: CGFloat in [560, 840, 1100] {
                panel.setContentSize(NSSize(width: width, height: 600))
                panel.contentView?.layoutSubtreeIfNeeded()
                controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: panel))
                cards.layoutSubtreeIfNeeded()
                let flow = try XCTUnwrap(cards.collectionViewLayout)
                let first = try XCTUnwrap(flow.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
                let columns = (0..<40).prefix { index in
                    flow.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY == first.frame.minY
                }.count
                XCTAssertGreaterThan(columns, 1)
                controller.update(WindowSwitcherSession(entries: entries, selectedID: entries[0].id, isPersistent: true, originalWindowID: nil))
                XCTAssertTrue(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
                XCTAssertEqual(controller.session?.selectedID, entries[0].id)
                XCTAssertTrue(controller.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
                XCTAssertEqual(controller.session?.selectedID, entries[columns].id)
            }
        }
    }

    func testSearchMatchHasContrastingColorPairInEveryAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let text = WindowSwitcherAppearance.highlighted("Project work", ranges: [NSRange(location: 8, length: 4)])
                XCTAssertNil(text.attribute(.backgroundColor, at: 0, effectiveRange: nil))
                let foreground = text.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor
                let background = text.attribute(.backgroundColor, at: 8, effectiveRange: nil) as? NSColor
                XCTAssertEqual(foreground?.usingColorSpace(.sRGB), NSColor.black.usingColorSpace(.sRGB))
                XCTAssertEqual(background?.usingColorSpace(.sRGB), NSColor.yellow.usingColorSpace(.sRGB))
            }
        }
    }

    func testAppOnlySearchMatchExplainsGridResultWithoutPermanentSubtitle() {
        XCTAssertEqual(WindowSwitcherOverlayController.gridTitle("Budget", appName: "Numbers", query: "numbers"), "Budget\nNumbers")
        XCTAssertEqual(WindowSwitcherOverlayController.gridTitle("Budget", appName: "Numbers", query: "budget"), "Budget")
        XCTAssertEqual(WindowSwitcherOverlayController.gridTitle("Budget", appName: "Numbers", query: ""), "Budget")
        XCTAssertEqual(WindowSwitcherOverlayController.gridTitle("Budget", appName: "Numbers", query: "budget num"), "Budget\nNumbers")
    }

    func testSelectedCardUpdatesAppearanceWithoutLosingBorderlessStyle() throws {
        let card = WindowSwitcherCardItem()
        _ = card.view
        card.isSelected = true
        card.view.appearance = NSAppearance(named: .aqua)
        (card.view as? WindowSwitcherAppearanceView)?.refreshAppearance()
        let light = try XCTUnwrap(card.view.layer?.backgroundColor)
        card.view.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        (card.view as? WindowSwitcherAppearanceView)?.refreshAppearance()
        let contrast = try XCTUnwrap(card.view.layer?.backgroundColor)
        XCTAssertGreaterThan(contrast.alpha, light.alpha)
        XCTAssertEqual(card.view.layer?.borderWidth, 0)
        card.isSelected = false
        XCTAssertEqual(card.view.layer?.backgroundColor?.alpha, 0)
    }

    func testCyclingStaysStableUntilSearchIsExplicitlyFocused() async throws {
        let controller = WindowSwitcherOverlayController()
        var session = WindowSwitcherSession(entries: [entry("one"), entry("two")], selectedID: "one", isPersistent: false, originalWindowID: nil)
        session.invocationModifiers = [.control, .option]
        controller.show(session, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(panel.contentView!)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
        let mode = try XCTUnwrap(views.first { $0.identifier?.rawValue == "window-switcher-mode" } as? NSTextField)
        let hint = try XCTUnwrap(views.first { $0.identifier?.rawValue == "window-switcher-mode-hint" } as? NSTextField)
        let button = try XCTUnwrap(views.first { $0.identifier?.rawValue == "window-switcher-enter-search" } as? NSButton)
        let initialPlaceholder = search.placeholderString
        let cyclingTitle = mode.stringValue
        XCTAssertTrue(hint.stringValue.contains("⌃⌥"))
        var opened = false
        controller.onSelect = { _ in opened = true }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(search.placeholderString, initialPlaceholder)
        XCTAssertEqual(controller.session?.isPersistent, false)
        XCTAssertFalse(opened)
        controller.update(session) // Metadata publication must not change the interaction mode.
        XCTAssertEqual(search.placeholderString, initialPlaceholder)
        controller.noteCyclingInput()
        XCTAssertEqual(search.placeholderString, initialPlaceholder)
        panel.makeFirstResponder(search)
        XCTAssertEqual(controller.session?.isPersistent, true)
        XCTAssertNotEqual(mode.stringValue, cyclingTitle)
        XCTAssertTrue(button.isHidden)
        XCTAssertTrue(hint.stringValue.contains("⌃⌥"))
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertFalse(hint.stringValue.contains("⌃⌥"))
        XCTAssertTrue(hint.stringValue.contains("Esc"))
        XCTAssertEqual(controller.session?.isPersistent, true)
        XCTAssertEqual(search.placeholderString, initialPlaceholder)
        XCTAssertFalse(opened)
        controller.hide()
        session.isPersistent = true
        controller.show(session, currentPID: 100, showsPreview: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(search.placeholderString, initialPlaceholder)
    }

    func testCyclePresentationChangesDoNotPromoteButTypingDoes() throws {
        let controller = WindowSwitcherOverlayController()
        var first = entry("one")
        first.windowNumber = 1
        var second = entry("two")
        second.windowNumber = 2
        var session = WindowSwitcherSession(entries: [first, second], selectedID: "one", isPersistent: false, originalWindowID: nil)
        session.invocationModifiers = .option
        controller.show(session, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func event(_ key: String, _ code: Int, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: UInt16(code)))
        }
        for value in [("2", kVK_ANSI_2, NSEvent.ModifierFlags([.command, .option])),
                      ("p", kVK_ANSI_P, .command), ("2", kVK_ANSI_2, [.command, .shift])] {
            XCTAssertTrue(controller.handleChooserShortcut(try event(value.0, value.1, value.2)))
            XCTAssertEqual(controller.session?.isPersistent, false)
        }
        panel.sendEvent(try event("x", kVK_ANSI_X, .option))
        XCTAssertEqual(controller.session?.isPersistent, true)
        XCTAssertEqual(controller.session?.query, "x")
        controller.update(controller.session!)
        XCTAssertEqual(controller.session?.isPersistent, true)
    }

    func testGridOmitsAppSubtitleAndDividerTracksPreviewVisibility() throws {
        let controller = WindowSwitcherOverlayController()
        var window = entry("one", title: "")
        window.windowNumber = 1
        let localization = PluginLocalization(bundle: .main)
        XCTAssertFalse(window.localizedGridTitle(using: localization).contains(window.appName))
        let session = WindowSwitcherSession(entries: [window], selectedID: window.id, isPersistent: true, originalWindowID: nil)
        controller.show(session, currentPID: 100, showsPreview: true)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(panel.contentView!)
        let divider = try XCTUnwrap(views.first { $0.identifier?.rawValue == "window-preview-divider" } as? NSBox)
        XCTAssertFalse(divider.isHidden)
        XCTAssertEqual(divider.boxType, .separator)
        XCTAssertFalse(views.contains { $0.identifier?.rawValue == "window-card-subtitle" })
        XCTAssertTrue(views.contains { $0.identifier?.rawValue == "window-card-title" })
        controller.hide()
        controller.show(session, currentPID: 100, showsPreview: false)
        XCTAssertTrue(divider.isHidden)
    }

    func testCurrentAppScopeRequiresTwoWindowsAndIgnoresSearchText() throws {
        var first = entry("one")
        first.windowNumber = 1
        var second = entry("two", title: "Other")
        second.windowNumber = 2
        var session = WindowSwitcherSession(entries: [first, entry("placeholder")], selectedID: first.id,
            isPersistent: true, originalWindowID: nil)
        XCTAssertFalse(session.canSwitchCurrentApplication(100))
        let controller = WindowSwitcherOverlayController()
        controller.show(session, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 0))
        XCTAssertTrue(controller.handleChooserShortcut(command))
        XCTAssertEqual(controller.session?.scope, .all)
        session.entries.append(second)
        session.query = "Other"
        XCTAssertTrue(session.canSwitchCurrentApplication(100))
        XCTAssertFalse(session.canSwitchCurrentApplication(101))
        XCTAssertFalse(session.canSwitchCurrentApplication(nil))
    }

    func testLayoutChoicePersistsAcrossStoreAndChooserRecreation() throws {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)
        XCTAssertNil(store.configuration.preferredLayout)
        let controller = WindowSwitcherOverlayController()
        controller.onLayoutChange = { store.setPreferredLayout($0) }
        let session = WindowSwitcherSession(entries: [entry("one")], selectedID: "one", isPersistent: true, originalWindowID: nil)
        controller.show(session, currentPID: 100, showsPreview: false)
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil, characters: "2", charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 0))
        XCTAssertTrue(controller.handleChooserShortcut(command))
        controller.hide()
        let restored = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(restored.configuration.preferredLayout, .list)
        let reopened = WindowSwitcherOverlayController()
        reopened.show(session, currentPID: 100, showsPreview: false, preferredLayout: restored.configuration.preferredLayout)
        defer { reopened.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? NSTableView }.first)
        XCTAssertFalse(table.enclosingScrollView!.isHidden)
        let old = try JSONDecoder().decode(WindowSwitcherConfiguration.self, from: Data("{}".utf8))
        XCTAssertNil(old.preferredLayout)
    }

    func testSearchEditorKeepsIconSpacingAndCentersPlaceholderAcrossAppearanceAndResize() throws {
        let controller = WindowSwitcherOverlayController()
        controller.show(WindowSwitcherSession(entries: [entry("one"), entry("two")], selectedID: "one", isPersistent: true, originalWindowID: nil),
                        currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let content = try XCTUnwrap(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = try XCTUnwrap(descendants(content).first { $0.identifier?.rawValue == "window-switcher-search" } as? NSTextField)
        let surface = try XCTUnwrap(search.superview)
        let icon = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSImageView }.first)
        let clear = try XCTUnwrap(surface.subviews.first { $0.identifier?.rawValue == "window-switcher-clear-search" } as? NSButton)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(560), CGFloat(840)] {
                panel.setContentSize(NSSize(width: width, height: 510))
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(search.frame.midY, surface.bounds.midY, accuracy: 1)
                XCTAssertEqual(search.frame.minX - icon.frame.maxX, 8, accuracy: 1)
                XCTAssertLessThanOrEqual(search.frame.maxX, clear.frame.minX - 8)
                for query in ["", "Search windows"] {
                    panel.makeFirstResponder(search)
                    let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
                    editor.string = query
                    search.stringValue = query
                    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
                    content.layoutSubtreeIfNeeded()
                    let editorFrame = editor.convert(editor.bounds, to: surface)
                    XCTAssertGreaterThanOrEqual(editorFrame.minX, icon.frame.maxX + 4)
                    XCTAssertLessThanOrEqual(editorFrame.maxX, clear.frame.minX)
                    XCTAssertEqual(clear.isHidden, query.isEmpty)
                    let image = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
                    surface.cacheDisplay(in: surface.bounds, to: image)
                    if let directory = ProcessInfo.processInfo.environment["MACTOOLS_SEARCH_LAYOUT_ARTIFACT_DIR"] {
                        let url = URL(fileURLWithPath: directory).appendingPathComponent("search-\(appearance.rawValue)-\(Int(width))-\(query.isEmpty ? "empty" : "editing").png")
                        try image.representation(using: .png, properties: [:])?.write(to: url)
                    }
                }
                clear.performClick(nil)
                XCTAssertEqual(controller.session?.query, "")
                XCTAssertEqual(search.stringValue, "")
                XCTAssertTrue(clear.isHidden)
                XCTAssertNotNil(search.currentEditor())
            }
        }
    }

    func testVisibleNumberShortcutsOpenMatchingWindowAcrossScrollAndLayout() throws {
        let controller = WindowSwitcherOverlayController()
        let entries = (0..<24).map { entry("window-\($0)", title: "Document \($0)") }
        controller.show(WindowSwitcherSession(entries: entries, selectedID: "window-0", isPersistent: true, originalWindowID: nil),
                        currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func command(_ key: String, _ flags: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0)!
        }
        let search = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
        XCTAssertEqual(search.superview?.frame.height ?? 0, 40, accuracy: 1)
        XCTAssertFalse(search.isBordered)
        let handle = try XCTUnwrap(descendants(content).first { $0 is WindowSwitcherDragHandle })
        let handleFrame = handle.convert(handle.bounds, to: content)
        XCTAssertEqual(content.bounds.maxY - handleFrame.maxY, 0, accuracy: 1)
        let options = try XCTUnwrap(descendants(content).first { $0.identifier?.rawValue == "window-switcher-options" } as? NSButton)
        XCTAssertNil(descendants(content).first { $0.identifier?.rawValue == "window-switcher-dismiss" })
        let dismiss = try XCTUnwrap(options.menu?.items.first { $0.identifier?.rawValue == "window-switcher-dismiss" })
        XCTAssertEqual(dismiss.keyEquivalent, "\u{1b}")
        XCTAssertEqual(dismiss.keyEquivalentModifierMask, [])
        var dismissed = false
        controller.onCancel = { dismissed = true }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(dismiss.action), to: dismiss.target, from: dismiss))
        XCTAssertTrue(dismissed)
        var opened: [String] = []
        controller.onSelect = { opened.append($0.id) }
        let visible = controller.visibleShortcutRows()
        XCTAssertGreaterThan(visible.count, 2)
        XCTAssertTrue(controller.handleChooserShortcut(command("2")))
        XCTAssertEqual(controller.session?.selectedID, entries[visible[1]].id)
        XCTAssertEqual(opened, [entries[visible[1]].id])
        XCTAssertTrue(controller.handleChooserShortcut(command("2", [.command, .option])))
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertFalse(table.enclosingScrollView!.isHidden)
        table.scrollRowToVisible(23)
        content.layoutSubtreeIfNeeded()
        let scrolled = controller.visibleShortcutRows()
        XCTAssertGreaterThan(try XCTUnwrap(scrolled.first), 0)
        XCTAssertTrue(controller.handleChooserShortcut(command("1")))
        XCTAssertEqual(controller.session?.selectedID, entries[scrolled[0]].id)
        XCTAssertTrue(controller.handleChooserShortcut(command("1", [.command, .option])))
        XCTAssertTrue(table.enclosingScrollView!.isHidden)
        XCTAssertEqual(opened, [entries[visible[1]].id, entries[scrolled[0]].id])
    }

    func testNumberAndLayoutShortcutsWorkWhileCommandCycleIsHeld() throws {
        let controller = WindowSwitcherOverlayController()
        var session = WindowSwitcherSession(entries: (0..<4).map { var value = entry("held-\($0)"); value.windowNumber = UInt32($0 + 1); return value }, selectedID: "held-0", isPersistent: false, originalWindowID: nil)
        session.invocationModifiers = .command
        controller.show(session, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        var activated = false
        controller.onSelect = { _ in activated = true }
        func command(_ code: CGKeyCode, _ flags: CGEventFlags) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = flags
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let collection = try XCTUnwrap(descendants(panel.contentView!).compactMap { $0 as? NSCollectionView }.first)
        XCTAssertFalse(collection.visibleItems().isEmpty)
        XCTAssertTrue(collection.visibleItems().compactMap { $0 as? WindowSwitcherCardItem }.allSatisfy { $0.shortcutNumber == nil })
        XCTAssertTrue(controller.handleChooserShortcut(try command(19, .maskCommand)))
        XCTAssertTrue(collection.visibleItems().compactMap { $0 as? WindowSwitcherCardItem }.allSatisfy { $0.shortcutNumber == nil })
        XCTAssertEqual(controller.session?.selectedID, "held-1")
        XCTAssertFalse(activated)
        XCTAssertEqual(controller.session?.isPersistent, false)
        XCTAssertTrue(controller.handleChooserShortcut(try command(19, [.maskCommand, .maskShift])))
        XCTAssertEqual(controller.session?.scope, .currentApplication(100))
        XCTAssertTrue(controller.handleChooserShortcut(try command(18, [.maskCommand, .maskShift])))
        XCTAssertEqual(controller.session?.scope, .all)
        XCTAssertTrue(controller.handleChooserShortcut(try command(19, [.maskCommand, .maskAlternate])))
    }

    func testLoadingMessageWaitsAndDisappearsWhenPreviewArrives() async throws {
        var resume: CheckedContinuation<NSImage?, Never>?
        let preview = WindowSwitcherPreview(hasPermission: { true }, capture: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        let target = WindowSwitcherAppEntry(id: "preview", processIdentifier: 100, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: "Preview", icon: nil, windowElement: AXUIElementCreateApplication(100), isMinimized: false, shortcutToken: nil)
        let controller = WindowSwitcherOverlayController(preview: preview)
        controller.show(WindowSwitcherSession(entries: [target], selectedID: target.id, isPersistent: true, originalWindowID: nil),
                        currentPID: 100, showsPreview: true)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let label = try XCTUnwrap(descendants(panel.contentView!).first { $0.identifier?.rawValue == "window-preview-status" })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(label.isHidden)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(label.isHidden)
        resume?.resume(returning: NSImage(size: NSSize(width: 100, height: 60)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(label.isHidden)
    }

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

        let search = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
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

    func testLargePreviewDoesNotImposeIntrinsicMinimumAndFitsSmallViewport() {
        let stage = WindowSwitcherPreviewStage()
        stage.image = NSImage(size: NSSize(width: 2400, height: 6000))
        XCTAssertEqual(stage.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(stage.intrinsicContentSize.height, NSView.noIntrinsicMetric)
        let bounds = NSRect(x: 0, y: 0, width: 520, height: 120)
        let fitted = WindowSwitcherPreviewStage.fittedFrame(imageSize: stage.image!.size, in: bounds)
        XCTAssertTrue(bounds.contains(fitted))
        XCTAssertEqual(fitted.width / fitted.height, 0.4, accuracy: 0.001)
    }

    func testPreviewToggleResizesAndRestoresSeparateUserSizes() throws {
        for layout in [WindowSwitcherLayout.grid, .list] {
            let controller = WindowSwitcherOverlayController()
            let value = WindowSwitcherSession(entries: [entry("one", title: "Document")],
                selectedID: "one", isPersistent: true, originalWindowID: nil)
            controller.show(value, currentPID: 100, showsPreview: true, preferredLayout: layout)
            defer { controller.hide() }
            let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
            let screen = try XCTUnwrap(panel.screen)
            guard screen.visibleFrame.height >= 764 else { throw XCTSkip("Requires enough room for both preview sizes") }
            let toggle = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "p",
                charactersIgnoringModifiers: "p", isARepeat: false, keyCode: UInt16(kVK_ANSI_P)))
            let expanded = panel.frame
            XCTAssertTrue(panel.performKeyEquivalent(with: toggle))
            let compact = panel.frame
            XCTAssertLessThan(compact.height, expanded.height)
            XCTAssertEqual(compact.maxY, expanded.maxY, accuracy: 1)
            XCTAssertTrue(panel.performKeyEquivalent(with: toggle))
            XCTAssertEqual(panel.frame.height, expanded.height, accuracy: 1)
            panel.setContentSize(NSSize(width: 720, height: 650))
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: panel))
            let customPreview = panel.frame.size
            XCTAssertTrue(panel.performKeyEquivalent(with: toggle))
            XCTAssertEqual(panel.frame.height, compact.height, accuracy: 1, "Automatic resizing must not overwrite the compact preference")
            panel.setContentSize(NSSize(width: 650, height: 450))
            controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: panel))
            let customCompact = panel.frame.size
            XCTAssertTrue(panel.performKeyEquivalent(with: toggle))
            XCTAssertEqual(panel.frame.size, customPreview)
            controller.hide()
            controller.show(value, currentPID: 100, showsPreview: false, preferredLayout: layout)
            XCTAssertEqual(panel.frame.size, customCompact, "Reopening must use the preference for the active preview mode")
            XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        }
    }

    func testCardLayoutKeepsSelectionAndShowsPreviewBelowWindows() throws {
        let controller = WindowSwitcherOverlayController()
        var value = WindowSwitcherSession(entries: (0..<12).map { entry("card-\($0)", title: $0 == 0 ? String(repeating: "Long window title 长标题 ", count: 8) : "Document \($0)") },
            selectedID: "card-0", isPersistent: true, originalWindowID: nil)
        controller.show(value, currentPID: 100, showsPreview: true)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let cards = try XCTUnwrap(descendants(content).compactMap { $0 as? NSCollectionView }.first)
        XCTAssertFalse(cards.enclosingScrollView?.isHidden ?? true)
        XCTAssertEqual(cards.numberOfItems(inSection: 0), 12)
        let firstCard = try XCTUnwrap(cards.item(at: IndexPath(item: 0, section: 0))?.view)
        for label in descendants(firstCard).compactMap({ $0 as? NSTextField }) where !label.isHidden {
            XCTAssertTrue(firstCard.bounds.contains(label.convert(label.bounds, to: firstCard)), "Long titles must stay inside their card")
        }
        XCTAssertEqual(content.bounds.width, panel.contentLayoutRect.width, accuracy: 1, "Content must fit the actual panel")
        XCTAssertLessThanOrEqual(panel.frame.width, 840, "A long title must not enlarge the panel")
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertNotNil(descendants(content).first { $0 is WindowSwitcherDragHandle })
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_RightArrow)))
        cards.keyDown(with: right)
        XCTAssertEqual(controller.session?.selectedID, "card-1")
        let selected = IndexPath(item: 7, section: 0)
        cards.selectionIndexPaths = [selected]
        controller.collectionView(cards, didSelectItemsAt: [selected])
        XCTAssertEqual(controller.session?.selectedID, "card-7")
        let image = try XCTUnwrap(descendants(content).compactMap { $0 as? WindowSwitcherPreviewStage }.first { $0.frame.height > 100 })
        let gridFrame = cards.enclosingScrollView!.convert(cards.enclosingScrollView!.bounds, to: content)
        let previewFrame = image.convert(image.bounds, to: content)
        XCTAssertLessThan(previewFrame.maxY, gridFrame.minY)
        XCTAssertGreaterThan(previewFrame.width, 500)
        let firstFrame = try XCTUnwrap(cards.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        let lastFrame = try XCTUnwrap(cards.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: 11, section: 0))).frame
        XCTAssertTrue(cards.visibleRect.contains(firstFrame), "Both rows should fit without clipping the first card")
        XCTAssertTrue(cards.visibleRect.contains(lastFrame))
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/window-switcher-cards-preview.png"))
        }
        image.image = NSImage(size: NSSize(width: 2400, height: 6000))
        panel.setContentSize(NSSize(width: 560, height: 420))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.width, 560, accuracy: 1)
        XCTAssertEqual(content.bounds.height, 420, accuracy: 1)
        XCTAssertGreaterThan(image.frame.height, 80)
        XCTAssertLessThanOrEqual(content.fittingSize.height, 420, "Preferred card rows must not constrain native live resizing")
        value.query = "Document 7"; value.normalizeSelection()
        controller.update(value)
        XCTAssertFalse(cards.enclosingScrollView?.isHidden ?? true)
        XCTAssertEqual(cards.numberOfItems(inSection: 0), 1)
    }

    func testNativeSearchEditorPastesChineseAndKeepsCompositionCommandsLocal() async throws {
        let controller = WindowSwitcherOverlayController()
        let value = WindowSwitcherSession(entries: [entry("travel", title: "旅行计划"), entry("work", title: "Work")],
            selectedID: "work", isPersistent: true, originalWindowID: "work")
        controller.show(value, currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
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

    func testHeldCommandLettersStartSearchInsteadOfRunningCommands() throws {
        for (text, code) in [("f", kVK_ANSI_F), ("w", kVK_ANSI_W), ("q", kVK_ANSI_Q)] {
            let controller = WindowSwitcherOverlayController()
            var session = WindowSwitcherSession(entries: [entry("one")], selectedID: "one", isPersistent: false, originalWindowID: nil)
            session.invocationModifiers = .command
            session.protectedCommandKeys = ["w", "q"]
            controller.show(session, currentPID: 100, showsPreview: false)
            defer { controller.hide() }
            var actionCount = 0
            controller.onClose = { _ in actionCount += 1 }
            controller.onQuit = { _ in actionCount += 1 }
            let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)))
            XCTAssertTrue(panel.performKeyEquivalent(with: event))
            XCTAssertEqual(controller.session?.query, text)
            XCTAssertEqual(controller.session?.isPersistent, true)
            XCTAssertEqual(actionCount, 0)
        }
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
            let search = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "window-switcher-search" })
            let first = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifier, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: modifier.contains(.option) ? "†" : "t",
                charactersIgnoringModifiers: "t", isARepeat: false, keyCode: UInt16(kVK_ANSI_T)))
            if modifier == .command { XCTAssertTrue(panel.performKeyEquivalent(with: first)) }
            else { panel.firstResponder?.keyDown(with: first) }
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
        let popup = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSPopUpButton }.first { !$0.pullsDown })
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

    func testContextActionsTargetClickedRowAndDisableUnavailableClose() throws {
        let controller = WindowSwitcherOverlayController()
        var first = entry("first"), second = entry("second")
        first.windowNumber = 1; second.windowNumber = 2
        var unavailable = entry("unavailable"); unavailable.metadataUnavailable = true
        controller.show(WindowSwitcherSession(entries: [first, second, unavailable], selectedID: first.id, isPersistent: true, originalWindowID: nil), currentPID: 100, showsPreview: false)
        defer { controller.hide() }
        var opened: String?, closed: String?, quit: String?
        controller.onSelect = { opened = $0.id }
        controller.onClose = { closed = $0.id }
        controller.onQuit = { quit = $0.id }
        let menu = try XCTUnwrap(controller.contextMenu(forRow: 1))
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[3].title.contains(second.appName))
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(opened, second.id)
        XCTAssertEqual(closed, second.id)
        XCTAssertEqual(quit, second.id)
        XCTAssertEqual(controller.session?.selectedID, first.id)
        XCTAssertFalse(try XCTUnwrap(controller.contextMenu(forRow: 2)).items[1].isEnabled)
        XCTAssertNil(controller.contextMenu(forRow: -1))
        // A context menu cannot act on an entry removed while it was open.
        controller.update(WindowSwitcherSession(entries: [first], selectedID: first.id, isPersistent: true, originalWindowID: nil))
        closed = nil
        NSApp.sendAction(try XCTUnwrap(menu.items[1].action), to: menu.items[1].target, from: menu.items[1])
        XCTAssertNil(closed)
    }

    func testGridOverflowButtonsFollowScrollAndFiltering() throws {
        let controller = WindowSwitcherOverlayController()
        var session = WindowSwitcherSession(entries: (0..<60).map { entry("overflow-\($0)", title: "Document \($0)") }, selectedID: "overflow-0", isPersistent: true, originalWindowID: nil)
        controller.show(session, currentPID: 100, showsPreview: false, preferredLayout: .grid)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible })
        let content = try XCTUnwrap(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        content.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(content).compactMap { $0 as? WindowSwitcherCardScrollView }.first)
        scroll.updateOverflow()
        XCTAssertFalse(scroll.hasContentAbove)
        XCTAssertTrue(scroll.hasContentBelow)
        let down = try XCTUnwrap(descendants(scroll).first { $0.identifier?.rawValue == "window-grid-more-below" } as? NSButton)
        down.performClick(nil)
        XCTAssertTrue(scroll.hasContentAbove)
        let up = try XCTUnwrap(descendants(scroll).first { $0.identifier?.rawValue == "window-grid-more-above" } as? NSButton)
        XCTAssertFalse(up.isAccessibilityHidden())
        up.performClick(nil)
        XCTAssertFalse(scroll.hasContentAbove)
        XCTAssertTrue(up.isAccessibilityHidden())
        XCTAssertFalse(up.isEnabled)
        session.selectedID = "overflow-59"
        controller.update(session)
        content.layoutSubtreeIfNeeded(); scroll.updateOverflow()
        XCTAssertTrue(scroll.hasContentAbove)
        XCTAssertFalse(scroll.hasContentBelow)
        XCTAssertTrue(down.isAccessibilityHidden())
        XCTAssertFalse(down.isEnabled)
        session.query = "Document 59"
        controller.update(session)
        content.layoutSubtreeIfNeeded(); scroll.updateOverflow()
        XCTAssertFalse(scroll.hasContentAbove)
        XCTAssertFalse(scroll.hasContentBelow)
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
                XCTAssertLessThanOrEqual(panel.height, preview ? 740 : 510)
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
        XCTAssertEqual(WindowSwitcherConfiguration.default.mode, .searchSelect)
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
