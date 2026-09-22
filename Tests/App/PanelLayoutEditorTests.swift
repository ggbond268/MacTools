import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditorTests: XCTestCase {
    private var suites: [String] = []

    func testMoveToMenuKeepsDestinationIconsVisible() async throws {
        let host = makeHost([LayoutEditorTestPlugin("a", order: 0)])
        _ = try XCTUnwrap(host.addMenuBarPanel())
        let window = mount(PanelLayoutEditor(pluginHost: host, panelID: "components", onDismiss: {}))
        defer { window.close() }
        try await settle()
        let source = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView))
            .compactMap { $0 as? PanelLayoutDragSourceView }.first)
        setHover(source, inside: true)
        try await settle()
        let menuOpened = expectation(description: "Move To menu opens")
        let destinationCount = host.menuBarPanels.count - 1
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let menu = notification.object as? NSMenu else { return }
                let destinationItems = menu.items.filter { $0.image != nil }
                XCTAssertEqual(destinationItems.count, destinationCount)
                if #available(macOS 27.0, *) {
                    for item in destinationItems {
                        // Keep this test buildable with the macOS 26 SDK used by CI.
                        let visibility = item.value(forKey: "preferredImageVisibility") as? NSNumber
                        XCTAssertEqual(visibility?.intValue, 1)
                    }
                }
                menuOpened.fulfill()
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated { menu.cancelTrackingWithoutAnimation() }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let point = source.convert(CGPoint(x: source.menuFrame.midX, y: source.menuFrame.midY), to: nil)
        sendMouse(.leftMouseDown, at: point, to: window)
        sendMouse(.leftMouseUp, at: point, to: window)
        await fulfillment(of: [menuOpened], timeout: 1)
    }

    func testRepeatedAdditionsMoveRemoveAndRestoreIndependently() throws {
        for surface in PluginPanelItemKind.allCases {
            let unavailable = LayoutEditorTestPlugin("unavailable", order: 9)
            unavailable.runtimeVisible = false
            let a = LayoutEditorTestPlugin("a", order: 0)
            let host = makeHost([a, LayoutEditorTestPlugin("b", order: 1), unavailable])
            let other: PluginPanelItemKind = surface == .widget ? .row : .widget
            let template = host.testEntry(pluginID: "a", kind: surface)
            let destination = try XCTUnwrap(host.addMenuBarPanel())
            XCTAssertEqual(PanelComponentLibraryItem.catalog(in: host).map(\.id), ["a", "b"])
            XCTAssertEqual(PanelComponentLibraryItem.catalog(in: host, matching: " A ").map(\.id), ["a"])
            XCTAssertTrue(a.contexts.isEmpty)
            for panel in [surface.testPanelID, surface.testPanelID, destination] {
                XCTAssertTrue(host.addPanelItem(template.key, to: panel))
            }
            let originals = host.panelEntries(in: surface.testPanelID)
            XCTAssertEqual(originals.map(\.pluginID), ["a", "b", "a", "a"])
            XCTAssertEqual(Set(originals.map(\.id)).count, 4)
            let second = originals[3]
            let moved = originals[2]
            let session = PanelLayoutEditingSession()
            XCTAssertTrue(session.commit(.init(id: moved.id, offset: 0, sourcePanelID: surface.testPanelID),
                                         in: host, panelID: destination))
            XCTAssertEqual(host.panelEntries(in: destination).first, moved)
            XCTAssertTrue(host.panelEntries(in: surface.testPanelID).contains(second))
            session.undo(in: host, panelID: destination)
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID), originals)
            XCTAssertTrue(session.commit(.init(id: second.id, offset: 0), in: host, panelID: surface.testPanelID))
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID).first, second)
            session.undo(in: host, panelID: surface.testPanelID)
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID), originals)
            XCTAssertTrue(host.removePanelEntry(moved, from: surface.testPanelID))
            XCTAssertFalse(host.removePanelEntry(moved, from: surface.testPanelID))
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID), [originals[0], originals[1], second])
            XCTAssertTrue(host.removePanelEntry(template, from: surface.testPanelID))
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID), [originals[1], second])
            XCTAssertEqual(host.panelEntries(in: other.testPanelID).map(\.pluginID), ["a", "b"])
            XCTAssertFalse(host.addPanelItem(.init(pluginID: "unavailable", itemID: surface.testItemID), to: destination))
            let backup = host.makePreferencesBackup()
            let restored = makeHost([LayoutEditorTestPlugin("a", order: 0), LayoutEditorTestPlugin("b", order: 1)])
            _ = try restored.importPreferences(backup)
            XCTAssertEqual(restored.menuBarPanelStore.configuration, host.menuBarPanelStore.configuration)
            XCTAssertEqual(restored.panelEntries(in: surface.testPanelID), host.panelEntries(in: surface.testPanelID))
            XCTAssertEqual(restored.panelEntries(in: destination), host.panelEntries(in: destination))
            let lastCopy = try XCTUnwrap(host.panelEntries(in: destination).first)
            XCTAssertNil(host.deleteMenuBarPanel(id: destination))
            XCTAssertTrue(host.panelEntries(in: "components").contains(lastCopy))
            XCTAssertFalse(host.panelEntries(in: surface.testPanelID).contains(template))
        }
    }

    func testAddingPreviouslyHiddenPluginDoesNotRestoreItsDefaultEntry() throws {
        let host = makeHost([LayoutEditorTestPlugin("a", order: 0)])
        host.removeTestItem(pluginID: "a", kind: .widget)
        let destination = try XCTUnwrap(host.addMenuBarPanel())
        XCTAssertTrue(host.addPanelItem(.init(pluginID: "a", itemID: "widget"), to: destination))
        XCTAssertTrue(host.panelEntries(in: "components").isEmpty)
        XCTAssertEqual(host.panelEntries(in: destination).map(\.pluginID), ["a"])
        XCTAssertEqual(host.panelEntries(in: "features").map(\.pluginID), ["a"])
    }

    func testBottomFollowerTracksResizingAndStopsWhenUserScrollsAway() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let document = LayoutScrollTestDocument(frame: CGRect(x: 0, y: 0, width: 300, height: 800))
        let anchor = NSView(frame: document.bounds)
        let follower = PanelLayoutBottomFollower()
        let request = UUID()
        follower.update(request: request, anchor: anchor)
        document.addSubview(anchor)
        scroll.documentView = document
        follower.attach(to: anchor)
        func assertBottom() {
            XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1)
        }
        assertBottom()
        document.setFrameSize(CGSize(width: 300, height: 1400))
        assertBottom()
        scroll.contentView.setBoundsSize(CGSize(width: 300, height: 350))
        assertBottom()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 100))
        document.setFrameSize(CGSize(width: 300, height: 1600))
        follower.update(request: request, anchor: anchor)
        XCTAssertEqual(scroll.contentView.bounds.minY, 100, accuracy: 1)
        follower.update(request: UUID(), anchor: anchor)
        assertBottom()
        follower.detach()
    }

    func testLibraryCanReopenAfterDismissingFocusedSearch() async throws {
        let host = makeHost([LayoutEditorTestPlugin("a", order: 0)])
        let presentation = LibraryPopoverTestPresentation()
        let anchorWindow = mount(Color.clear)
        let anchor = try XCTUnwrap(anchorWindow.contentView)
        let panel = NSPopover()
        panel.behavior = .applicationDefined
        panel.animates = false
        panel.contentViewController = NSHostingController(rootView:
            LibraryPopoverTestContent(host: host, presentation: presentation))
        panel.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        defer { panel.close(); anchorWindow.close() }
        try await settle()
        let panelWindow = try XCTUnwrap(panel.contentViewController?.view.window)

        for cycle in 0..<3 {
            presentation.isPresented = true
            try await settle()
            let libraryWindow = try XCTUnwrap(panelWindow.childWindows?.first { $0.isVisible })
            libraryWindow.makeKey()
            let search = try XCTUnwrap(descendants(try XCTUnwrap(libraryWindow.contentView))
                .compactMap { $0 as? NSTextField }.first { $0.isEditable })
            XCTAssertTrue(libraryWindow.makeFirstResponder(search))
            XCTAssertTrue(libraryWindow.firstResponder is NSTextView, "Exercise an active search field editor")

            if cycle == 1 {
                presentation.isPresented = false
            } else {
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: libraryWindow.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53))
                libraryWindow.sendEvent(escape)
                XCTAssertFalse(libraryWindow.firstResponder is NSTextView,
                    "Release the search editor before the dismissal tears down SwiftUI content")
            }
            try await settle()
            XCTAssertFalse(presentation.isPresented)
            XCTAssertFalse(libraryWindow.isVisible)
            XCTAssertFalse(libraryWindow.firstResponder is NSTextView, "A closed library must release its field editor")
            XCTAssertTrue(panel.isShown, "Closing the library must leave panel editing open")
        }
    }

    func testLibraryMountsOnlySelectedPreviewAndClickAddsWithoutInvokingItsControls() async throws {
        let a = LayoutEditorTestPlugin("a", order: 0)
        a.showsInteractionProbe = true
        a.spanWidth = 4
        a.spanHeight = 16
        let b = LayoutEditorTestPlugin("b", order: 1)
        let host = makeHost([a, b])
        let destination = try XCTUnwrap(host.addMenuBarPanel())
        let hosting = NSHostingView(rootView: PanelComponentLibrary(pluginHost: host, panelID: destination) {
            host.addPanelItem($0, to: destination)
        })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 660, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle()
        XCTAssertEqual(a.contexts.count, 1)
        XCTAssertTrue(a.contexts.allSatisfy { $0.isPreview })
        XCTAssertTrue(b.contexts.isEmpty)
        let location = hosting.convert(CGPoint(x: 300, y: 170), to: nil)
        sendMouse(.leftMouseDown, at: location, to: window)
        sendMouse(.leftMouseUp, at: location, to: window)
        try await settle()
        XCTAssertEqual(a.controlInvocations, 0)
        XCTAssertEqual(host.panelEntries(in: destination).map(\.pluginID), ["a"])
        sendMouse(.leftMouseDown, at: location, to: window)
        sendMouse(.leftMouseUp, at: location, to: window)
        try await settle()
        let copies = host.panelEntries(in: destination)
        XCTAssertEqual(copies.count, 2)
        XCTAssertNotEqual(try XCTUnwrap(copies.first).id, try XCTUnwrap(copies.last).id)
        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["a", "b"])
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: "/private/tmp/mactools-widget-thumbnails.png"))
        XCTAssertEqual(a.contexts.count, 1, "Adding must reuse the current preview")
        XCTAssertTrue(b.contexts.isEmpty)
    }

    func testLibraryNarrowPreviewUsesOnlyItsBoundsAndAdjacentRowRemainsClickable() async throws {
        try await assertLibraryNarrowPreview(grid: .standard, height: 11)
    }

    func testLibraryCompactPreviewUsesFiveColumnWidthAndDoesNotInvokeControls() async throws {
        try await assertLibraryNarrowPreview(grid: .compact, height: 8)
    }

    private func assertLibraryNarrowPreview(grid: PluginPanelWidgetGrid, height: Int) async throws {
        let plugin = LayoutEditorTestPlugin("a", order: 0)
        plugin.spanWidth = 1
        plugin.spanHeight = height
        plugin.grid = grid
        let host = makeHost([plugin])
        var added: [String] = []
        let hosting = NSHostingView(rootView: PanelComponentLibrary(pluginHost: host, panelID: "components") {
            added.append($0.itemID)
            return true
        })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 660, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle()
        let scroll = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSScrollView }.first { $0.bounds.width > 400 })
        let document = try XCTUnwrap(scroll.documentView)
        let layout = PanelComponentLibraryLayout(sourceSizes: [CGSize(width: grid == .standard ? 70 : 52.8,
                                                                      height: CGFloat(height) * 8)],
            availableWidth: scroll.bounds.width - PanelComponentLibraryLayout.horizontalPadding * 2)
        let icon = try XCTUnwrap(layout.frames.first)
        func click(x: CGFloat, y: CGFloat) {
            let location = document.convert(CGPoint(x: x + PanelComponentLibraryLayout.horizontalPadding, y: y + 8), to: nil)
            sendMouse(.leftMouseDown, at: location, to: window)
            sendMouse(.leftMouseUp, at: location, to: window)
        }
        click(x: icon.maxX + PanelComponentLibraryLayout.spacing / 2, y: 10)
        XCTAssertTrue(added.isEmpty, "The gap beside an icon is not part of its add target")
        click(x: icon.maxX + PanelComponentLibraryLayout.spacing + 20, y: 10)
        XCTAssertEqual(added, ["control"], "The row starts immediately after the narrow preview")
        click(x: icon.midX, y: icon.midY)
        XCTAssertEqual(added, ["control", "widget"])
        XCTAssertEqual(plugin.contexts.count, 1)
        XCTAssertEqual(plugin.controlInvocations, 0)
    }

    func testLibraryScrollLoadsNearbyPreviewsAndReusesSnapshotsOnReturn() async throws {
        let plugin = LayoutEditorTestPlugin("a", order: 0)
        plugin.libraryWidgetCount = 100
        plugin.spanWidth = 4
        plugin.spanHeight = 50
        let host = makeHost([plugin])
        let hosting = NSHostingView(rootView: PanelComponentLibrary(pluginHost: host, panelID: "components", onAdd: { _ in true }))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 660, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await settle()
        XCTAssertTrue(plugin.contexts.contains { $0.itemID == "widget" })
        XCTAssertLessThan(plugin.contexts.count, 20, "Opening the library must not render the whole catalog")
        let scroll = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSScrollView }.first { $0.bounds.width > 400 })
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertTrue(plugin.contexts.contains { $0.itemID == "widget-99" })
        XCTAssertLessThan(plugin.contexts.count, 30)
        let count = plugin.contexts.count
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        XCTAssertEqual(plugin.contexts.count, count, "Returning to rendered previews must reuse their bitmaps")
        XCTAssertTrue(plugin.contexts.allSatisfy(\.isPreview))
        XCTAssertEqual(plugin.controlInvocations, 0)
    }

    func testPartialCompactRowHorizontalDropCommitsAndUndoRestoresBothDirections() throws {
        for rtl in [false, true] {
            let plugins = ["a", "b", "c"].enumerated().map { index, id in
                let plugin = LayoutEditorTestPlugin(id, order: index)
                plugin.grid = .compact
                plugin.spanWidth = 1
                plugin.spanHeight = 8
                return plugin
            }
            let host = makeHost(plugins)
            let entries = host.panelEntries(in: "components")
            let ids = entries.map(\.id)
            let before = host.menuBarPanelStore.configuration
            let placement = ConfiguredMenuBarPanelLayout.placement(entries: entries,
                components: host.componentItems(in: "components"), features: [])
            let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
            XCTAssertEqual(Set(frames.map(\.frame.minY)), [0])
            let session = PanelLayoutEditingSession()
            XCTAssertNotNil(session.begin(entry: entries[0], panelID: "components", ids: ids))
            let target = PanelLayoutDropGeometry(frames: frames)
                .target(at: CGPoint(x: rtl ? 10 : 294, y: 32), rightToLeft: rtl)
            session.preview(target: target, ids: ids)
            XCTAssertEqual(host.menuBarPanelStore.configuration, before, "Hover must not persist a reordered layout")
            let move = try XCTUnwrap(session.finish(ids: ids))
            XCTAssertTrue(session.commit(move, in: host, panelID: "components"))
            XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["b", "c", "a"])
            XCTAssertTrue(session.canUndo(in: host, panelID: "components"))
            session.undo(in: host, panelID: "components")
            XCTAssertEqual(host.menuBarPanelStore.configuration, before)
        }
    }

    func testMovingMiddleWidgetAwayLeavesFillableSpaceThatPersistsAndUndoes() throws {
        for crossPanel in [false, true] {
            for rtl in [false, true] {
                let plugins = ["a", "b", "c", "full", "d"].enumerated().map { index, id in
                    let plugin = LayoutEditorTestPlugin(id, order: index)
                    plugin.grid = id == "full" ? .standard : .compact
                    plugin.spanWidth = id == "full" ? 4 : 1
                    plugin.spanHeight = id == "full" ? 12 : 8
                    return plugin
                }
                let host = makeHost(plugins)
                let otherPanel = try XCTUnwrap(host.addMenuBarPanel())
                let session = PanelLayoutEditingSession()
                let middle = host.testEntry(pluginID: "b", kind: .widget)
                if crossPanel {
                    XCTAssertTrue(session.commit(.init(id: middle.id, offset: 0, sourcePanelID: "components"),
                                                 in: host, panelID: otherPanel))
                } else {
                    XCTAssertTrue(session.commit(.init(id: middle.id, offset: 5), in: host, panelID: "components"))
                }
                let beforeFill = host.menuBarPanelStore.configuration
                let entries = host.panelEntries(in: "components")
                let components = host.componentItems(in: "components")
                let placement = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: components, features: [])
                let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
                let point = CGPoint(x: 152, y: 32)
                XCTAssertFalse(frames.contains { $0.frame.contains(point) })
                let sourcePanel = crossPanel ? otherPanel : "components"
                let sourceID = crossPanel ? middle.id : host.testEntry(pluginID: "d", kind: .widget).id
                let source = try XCTUnwrap(host.componentItems(in: sourcePanel).first { $0.id == sourceID })
                let sourceEntry = try XCTUnwrap(host.panelEntries(in: sourcePanel).first { $0.id == sourceID })
                XCTAssertNotNil(session.begin(entry: sourceEntry, panelID: sourcePanel,
                                               ids: host.panelEntries(in: sourcePanel).map(\.id)))
                if crossPanel { session.enterPanel("components", ids: entries.map(\.id)) }
                let geometry = PanelLayoutDropGeometryCache().geometry(entries: entries, components: components,
                    features: [], frames: frames, source: source)
                let target = geometry.target(at: CGPoint(x: rtl ? 304 - point.x : point.x, y: point.y), rightToLeft: rtl)
                XCTAssertTrue(target.isVacancy)
                session.preview(target: target, ids: entries.map(\.id))
                XCTAssertTrue(session.dragPreview.target?.isVacancy == true)
                XCTAssertEqual(host.menuBarPanelStore.configuration, beforeFill)
                let move = try XCTUnwrap(session.finish(ids: entries.map(\.id)))
                XCTAssertTrue(session.commit(move, in: host, panelID: "components"))
                let result = ConfiguredMenuBarPanelLayout.placement(entries: host.panelEntries(in: "components"),
                    components: host.componentItems(in: "components"), features: [])
                let filled = PanelLayoutDestination.frame(try XCTUnwrap(result.components.first { $0.id == sourceID }))
                XCTAssertTrue(filled.contains(point))
                XCTAssertEqual(filled.minX, 125.6, accuracy: 0.001)
                XCTAssertEqual(filled.minY, 0)
                let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(suites.last)))
                XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).configuration, host.menuBarPanelStore.configuration,
                               "The filled order must survive reopening the store")
                XCTAssertTrue(session.canUndo(in: host, panelID: "components"))
                session.undo(in: host, panelID: "components")
                XCTAssertEqual(host.menuBarPanelStore.configuration, beforeFill)
            }
        }
    }

    func testCrossPanelDragCommitsAtInsertionAndUndoRestoresBothLayouts() throws {
        for surface in PluginPanelItemKind.allCases {
            let other: PluginPanelItemKind = surface == .widget ? .row : .widget
            let host = makeHost(["a", "hidden", "b", "c"].enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) })
            let destination = try XCTUnwrap(host.addMenuBarPanel())
            host.removeTestItem(pluginID: "hidden", kind: surface)
            host.moveTestItem(pluginID: "b", kind: other, to: destination)
            host.moveTestItem(pluginID: "c", kind: surface, to: destination)
            let entry = host.testEntry(pluginID: "a", kind: surface)
            let before = host.menuBarPanelStore.configuration
            let sourceIDs = host.panelEntries(in: surface.testPanelID).map(\.id)
            let destinationIDs = host.panelEntries(in: destination).map(\.id)
            let session = PanelLayoutEditingSession()
            let token = try XCTUnwrap(session.begin(entry: entry, panelID: surface.testPanelID, ids: sourceIDs))
            session.enterPanel(destination, ids: destinationIDs)
            XCTAssertTrue(session.validate(in: host, panelID: destination))
            session.preview(offset: 1, ids: destinationIDs)
            XCTAssertEqual(host.menuBarPanelStore.configuration, before, "Hover and insertion previews cannot write preferences")
            let move = try XCTUnwrap(session.finish(ids: destinationIDs))
            XCTAssertTrue(session.commit(move, in: host, panelID: destination))
            XCTAssertEqual(host.panelEntries(in: destination).map(\.id), [destinationIDs[0], entry.id, destinationIDs[1]])
            XCTAssertEqual(host.testPanelID(pluginID: "a", kind: other), other.testPanelID)
            session.sourceEnded(token: token)
            XCTAssertTrue(session.canUndo(in: host, panelID: destination))
            session.undo(in: host, panelID: destination)
            XCTAssertEqual(host.menuBarPanelStore.configuration, before, "Undo restores assignments and hidden order slots exactly")
            XCTAssertEqual(session.feedback, .undone)
        }
    }

    func testCrossPanelDragCancellationEmptyDestinationAndExternalChanges() throws {
        let host = makeHost([LayoutEditorTestPlugin("a", order: 0)])
        let destination = try XCTUnwrap(host.addMenuBarPanel())
        let intermediate = try XCTUnwrap(host.addMenuBarPanel())
        let source = MenuBarPanelDefinition.componentsID
        let entry = host.testEntry(pluginID: "a", kind: .widget)
        let session = PanelLayoutEditingSession()
        let before = host.menuBarPanelStore.configuration
        let token = try XCTUnwrap(session.begin(entry: entry, panelID: source, ids: [entry.id]))
        for panelID in [intermediate, source, destination] {
            session.enterPanel(panelID, ids: host.panelEntries(in: panelID).map(\.id))
            XCTAssertTrue(session.validate(in: host, panelID: panelID))
            XCTAssertEqual(session.token, token)
        }
        session.sourceEnded(token: token)
        XCTAssertEqual(host.menuBarPanelStore.configuration, before)
        _ = session.begin(entry: entry, panelID: source, ids: [entry.id])
        session.enterPanel(destination, ids: [])
        session.preview(offset: 0, ids: [])
        let move = try XCTUnwrap(session.finish(ids: []))
        XCTAssertTrue(session.commit(move, in: host, panelID: destination))
        XCTAssertEqual(host.panelEntries(in: destination), [entry])
        host.moveTestItem(pluginID: "a", kind: .row, to: intermediate)
        XCTAssertFalse(session.canUndo(in: host, panelID: destination), "Undo cannot overwrite another saved layout change")
        _ = session.begin(entry: entry, panelID: destination, ids: [entry.id])
        session.enterPanel(source, ids: [])
        host.removeTestItem(pluginID: "a", kind: .widget)
        XCTAssertFalse(session.validate(in: host, panelID: source))
        XCTAssertNil(session.token)
    }

    func testDragSessionSurvivesTabContentReplacementAndAcceptsEmptyPanel() async throws {
        let host = makeHost([LayoutEditorTestPlugin("a", order: 0)])
        let destination = try XCTUnwrap(host.addMenuBarPanel())
        let suite = "PanelCrossDragFixture.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = MenuBarUnifiedPanelModel(selectedTab: .components, contentHeight: 400,
                                             maximumFeatureListHeight: 400, isPanelVisible: true)
        model.onTabSelection = { tab in
            model.update(selectedTab: tab, contentHeight: 400, maximumFeatureListHeight: 400, isPanelVisible: true)
        }
        model.beginLayoutEditing(visibleItemCount: 1)
        let window = mount(MenuBarUnifiedPanelContent(pluginHost: host,
            presentation: MenuBarPanelPresentationModel(host: host, isVisible: true),
            appUpdater: AppUpdater(startingUpdater: false),
            menuBarPanelThemeStore: MenuBarPanelThemeStore(userDefaults: defaults), model: model,
            onDismiss: { XCTFail("Dragging cannot dismiss editing") }, onOpenUpdate: {}, onOpenSettings: {},
            onPresentDiskCleanConfiguration: {}, onPresentLaunchControlConfiguration: {}))
        window.makeKeyAndOrderFront(nil)
        defer { model.onTabSelection = nil; window.close() }
        try await settle()
        let root = try XCTUnwrap(window.contentView)
        let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }.first)
        let strip = try XCTUnwrap(descendants(root).compactMap { $0 as? MenuBarPanelTabStripView }.first)
        let session = try XCTUnwrap(strip.itemDragSession)
        let token = try XCTUnwrap(source.onBegin?())
        session.nativeDragSource.begin { [weak session] in session?.sourceEnded(token: token) }
        strip.updateItemDragHover(panelID: destination)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.selectedTab.id, destination)
        XCTAssertNil(source.window, "Switching tabs must detach the original card view")
        XCTAssertEqual(session.token, token, "The panel owns the drag independently of its original card")
        let canvas = try XCTUnwrap(descendants(root).first { $0.identifier?.rawValue == "panel.layout.canvas" })
        XCTAssertGreaterThan(canvas.bounds.height, 100, "The empty panel needs a visible drop target")
        XCTAssertTrue(session.validate(in: host, panelID: destination))
        session.preview(offset: 0, ids: [])
        let move = try XCTUnwrap(session.finish(ids: []))
        XCTAssertTrue(session.commit(move, in: host, panelID: destination))
        session.nativeDragSource.finish()
        try await settle()
        XCTAssertEqual(host.panelEntries(in: destination), [host.testEntry(pluginID: "a", kind: .widget)])
        XCTAssertTrue(session.canUndo(in: host, panelID: destination))
        XCTAssertTrue(model.isEditingLayout)
    }

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    func testRenderedMovesPreserveUnavailableSlotsAndOtherPanelOrder() throws {
        for kind in PluginPanelItemKind.allCases {
            for (source, offset) in [("a", 2), ("c", 1), ("c", -5), ("a", 10), ("b", 1), ("b", 2)] {
                let plugins = ["runtime-leading", "a", "runtime-middle", "b", "removed", "c", "runtime-trailing"]
                    .enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) }
                for plugin in plugins where plugin.metadata.id.hasPrefix("runtime-") { plugin.runtimeVisible = false }
                let host = makeHost(plugins)
                host.removeTestItem(pluginID: "removed", kind: kind)
                let ids = renderedIDs(host, surface: kind)
                let preview = PanelLayoutDestination.moving(source, toOffset: offset, in: ids)
                host.reorderTestItem(pluginID: source, kind: kind, toOffset: offset)
                XCTAssertEqual(renderedIDs(host, surface: kind), preview)
                let saved = host.menuBarPanelStore.configuration.placementsByPanelID[kind.testPanelID, default: []]
                XCTAssertEqual(saved.map(\.item.pluginID),
                    ["runtime-leading", preview[0], "runtime-middle", preview[1], preview[2], "runtime-trailing"])
                XCTAssertTrue(host.addPanelItem(.init(pluginID: "removed", itemID: kind.testItemID), to: kind.testPanelID))
                XCTAssertEqual(renderedIDs(host, surface: kind), preview + ["removed"])
                let other: PluginPanelItemKind = kind == .widget ? .row : .widget
                XCTAssertEqual(renderedIDs(host, surface: other), ["a", "b", "removed", "c"])
            }
        }
    }

    func testUnavailableRenderedSourceDoesNotChangeSavedOrder() throws {
        for kind in PluginPanelItemKind.allCases {
            let hidden = LayoutEditorTestPlugin("hidden", order: 0)
            hidden.runtimeVisible = false
            let host = makeHost([hidden, LayoutEditorTestPlugin("a", order: 1), LayoutEditorTestPlugin("b", order: 2)])
            let before = host.menuBarPanelStore.configuration
            let placement = try XCTUnwrap(before.placementsByPanelID[kind.testPanelID]?.first)
            let entry = MenuBarPanelEntry(placement: placement, kind: kind)
            host.movePanelEntry(entry, panelID: kind.testPanelID, toOffset: 3)
            XCTAssertEqual(host.menuBarPanelStore.configuration, before)
            XCTAssertEqual(renderedIDs(host, surface: kind), ["a", "b"])
        }
    }

    private func renderedIDs(_ host: PluginHost, surface: PluginPanelItemKind) -> [String] {
        surface == .widget ? host.componentItems.map(\.pluginID) : host.panelItems.map(\.pluginID)
    }

    func testCardFirstAppearingDuringEditingRetainsWorkingDismissAfterDone() async throws {
        let a = LayoutEditorTestPlugin("a", order: 1)
        let h = LayoutEditorTestPlugin("conditional", order: 2)
        let b = LayoutEditorTestPlugin("b", order: 3)
        h.runtimeVisible = false
        let host = makeHost([a, h, b])
        var dismissCount = 0
        let normal = ComponentPanelContent(pluginHost: host, contentBodyHeight: 480,
                                           isPanelVisible: true, onDismiss: { dismissCount += 1 })
            .environmentObject(MenuBarPanelPresentationModel(host: host, isVisible: true))
        let window = mount(normal)
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView as? NSHostingView<AnyView>)
        try await settle()
        XCTAssertEqual(a.contexts.count, 1)
        XCTAssertEqual(h.contexts.count, 0)
        view.rootView = AnyView(PanelLayoutEditor(pluginHost: host, panelID: "components", onDismiss: { dismissCount += 1 }).frame(width: 304, height: 480))
        try await settle()
        h.runtimeVisible = true
        h.onStateChange?()
        try await settle()
        XCTAssertEqual(host.componentItems.map(\.pluginID), ["a", "conditional", "b"])
        XCTAssertEqual(h.contexts.count, 1, "The actual editor must have created the new card")
        view.rootView = AnyView(normal.frame(width: 304, height: 480))
        try await settle()
        XCTAssertEqual(h.contexts.count, 1, "Normal Dashboard reuses the editor-created cache")
        try XCTUnwrap(a.contexts.last).dismiss()
        XCTAssertEqual(dismissCount, 1, "A normal-created card remains a positive control")
        try XCTUnwrap(h.contexts.last).dismiss()
        XCTAssertEqual(dismissCount, 2, "A card created during editing must still dismiss after Done")
    }

    func testDashboardSpanChangeDoesNotCancelFeatureDrag() async throws {
        try await checkDrag(surface: .row, changeDashboardSpan: true)
    }

    func testDashboardSpanChangeCancelsDashboardDrag() async throws {
        try await checkDrag(surface: .widget, changeDashboardSpan: true)
    }

    func testFeatureItemDisappearanceCancelsFeatureDrag() async throws {
        let a = LayoutEditorTestPlugin("a", order: 1)
        let host = makeHost([a, LayoutEditorTestPlugin("b", order: 2)])
        let session = PanelLayoutEditingSession()
        let window = mount(PanelLayoutEditor(pluginHost: host, panelID: "features", onDismiss: {}, session: session))
        defer { window.close() }
        try await settle()
        XCTAssertNotNil(session.begin(id: host.testEntry(pluginID: "a", kind: .row).id, ids: host.panelEntries(in: "features").map(\.id)))
        a.runtimeVisible = false
        a.onStateChange?()
        try await settle()
        XCTAssertEqual(host.panelItems.map(\.pluginID), ["b"])
        XCTAssertNil(session.token)
    }

    func testRemovalRequiresConfirmationAndRemovesOnlyTheCurrentEntry() async throws {
        for (surface, compact) in [(PluginPanelItemKind.widget, false), (.row, false), (.widget, true)] {
            let plugin = LayoutEditorTestPlugin("a", order: 0)
            if compact { plugin.spanWidth = 1; plugin.spanHeight = 6; plugin.grid = .compact }
            let host = makeHost([plugin, LayoutEditorTestPlugin("b", order: 1)])
            let entryID = host.testEntry(pluginID: "a", kind: surface).id
            let window = mount(PanelLayoutEditor(pluginHost: host, panelID: surface.testPanelID, onDismiss: {}))
            defer { window.close() }
            try await settle()
            let root = try XCTUnwrap(window.contentView)
            let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }
                .first { $0.identifier?.rawValue == "panel.layout.drag.\(entryID)" })
            setHover(source, inside: true)
            try await settle()
            let menuInvoked = compact ? expectation(description: "Compact menu invokes removal") : nil
            let observer = compact ? NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { notification in
                MainActor.assumeIsolated {
                    guard let menu = notification.object as? NSMenu,
                          let index = menu.items.firstIndex(where: { $0.title == FeatureL10n.string("移除组件") }) else { return }
                    XCTAssertTrue(menu.items.contains { $0.title == PanelLayoutCopy.earlier })
                    XCTAssertTrue(menu.items.contains { $0.submenu != nil })
                    let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            menu.cancelTrackingWithoutAnimation()
                            menu.performActionForItem(at: index)
                            menuInvoked?.fulfill()
                        }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                }
            } : nil
            defer { if let observer { NotificationCenter.default.removeObserver(observer) } }
            let removeButton = PanelLayoutItemControlsLayout(size: source.bounds.size).buttonFrame(at: 0)
            let location = source.convert(CGPoint(x: source.menuFrame.minX + removeButton.midX,
                                                  y: source.menuFrame.minY + removeButton.midY), to: nil)
            XCTAssertFalse(root.hitTest(location) === source)
            sendMouse(.leftMouseDown, at: location, to: window)
            sendMouse(.leftMouseUp, at: location, to: window)
            if let menuInvoked { await fulfillment(of: [menuInvoked], timeout: 1) }
            try await settle()
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID).map(\.pluginID), ["a", "b"])
            let confirmation = try XCTUnwrap(NSApp.windows.first {
                $0.isVisible && MenuBarPanelWindowRegistry.isEditingPopover($0)
            })
            XCTAssertNil(NSApp.modalWindow)
            confirmation.makeKey()
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: confirmation.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(confirmation.performKeyEquivalent(with: enter))
            try await settle()
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(host.panelEntries(in: surface.testPanelID).map(\.pluginID), ["b"])
            XCTAssertFalse(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }.contains {
                $0.identifier?.rawValue == "panel.layout.drag.\(entryID)"
            })
            XCTAssertTrue(PanelComponentLibraryItem.catalog(in: host).contains { $0.id == "a" })
            let other: PluginPanelItemKind = surface == .widget ? .row : .widget
            XCTAssertEqual(host.panelEntries(in: other.testPanelID).map(\.pluginID), ["a", "b"])
        }
    }

    func testUndoRestoresPersistedPanelOrderAndPreservesHiddenSlots() throws {
        for surface in [PluginPanelItemKind.widget, .row] {
            let host = makeHost(["a", "hidden", "b", "c"].enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) })
            host.removeTestItem(pluginID: "hidden", kind: surface)
            let session = PanelLayoutEditingSession()
            let panelID = surface.testPanelID
            let before = host.panelEntries(in: panelID).map(\.id)
            host.reorderTestItem(pluginID: "a", kind: surface, toOffset: 3)
            let after = host.panelEntries(in: panelID).map(\.id)
            session.didSave(.init(id: host.testEntry(pluginID: "a", kind: surface).id, offset: 3), beforeIDs: before, afterIDs: after)
            XCTAssertEqual(host.panelEntries(in: panelID).map(\.pluginID), ["b", "c", "a"])
            let move = try XCTUnwrap(session.takeUndo(ids: after))
            host.reorderTestItem(pluginID: "a", kind: surface, toOffset: move.offset)
            session.didUndo()
            XCTAssertEqual(host.panelEntries(in: panelID).map(\.id), before)
            XCTAssertFalse(session.canUndo(ids: before))
            host.addPanelItem(.init(pluginID: "hidden", itemID: surface.testItemID), to: surface.testPanelID)
            XCTAssertEqual(host.panelEntries(in: panelID).map(\.pluginID), ["a", "b", "c", "hidden"])
        }
    }

    func testEditingPreservesEnabledAppearanceWithoutInvokingCardControls() async throws {
        let plugin = LayoutEditorTestPlugin("a", order: 0)
        plugin.showsInteractionProbe = true
        plugin.spanWidth = 4
        plugin.spanHeight = 24
        let host = makeHost([plugin])
        let window = mount(PanelLayoutEditor(pluginHost: host, panelID: "components", onDismiss: {}))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle()
        XCTAssertEqual(plugin.previewEnabledStates.last, true, "Editing must not gray out the original content")
        let root = try XCTUnwrap(window.contentView)
        let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }.first)
        for y in stride(from: 40.0, through: Double(source.bounds.height - 8), by: 16) {
            let location = source.convert(CGPoint(x: source.bounds.midX, y: y), to: nil)
            XCTAssertTrue(root.hitTest(location) === source)
            sendMouse(.leftMouseDown, at: location, to: window)
            sendMouse(.leftMouseUp, at: location, to: window)
        }
        window.makeFirstResponder(nil)
        for _ in 0..<8 {
            window.selectNextKeyView(nil)
            // Plugin fields must not participate in keyboard navigation while editing.
            XCTAssertFalse(window.firstResponder is NSTextView)
        }
        XCTAssertEqual(plugin.controlInvocations, 0)
    }

    func testDragPreviewKeepsCardFramesAndDropCanvasStableUntilCommit() async throws {
        for surface in [PluginPanelItemKind.widget, .row] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let plugins = ["a", "b", "c"].enumerated().map {
                    LayoutEditorTestPlugin($0.element, order: $0.offset)
                }
                // Moving past the full-width card lets the equal-height cards share a row.
                plugins[0].spanWidth = 1
                plugins[0].spanHeight = 24
                plugins[1].spanWidth = 4
                plugins[2].spanWidth = 3
                plugins[2].spanHeight = 24
                let host = makeHost(plugins)
                let session = PanelLayoutEditingSession()
                let window = mount(PanelLayoutEditor(pluginHost: host, panelID: surface.testPanelID, onDismiss: {}, session: session)
                    .environment(\.layoutDirection, direction))
                defer { window.close() }
                try await settle()
                let root = try XCTUnwrap(window.contentView)
                let canvas = try XCTUnwrap(descendants(root).first {
                    $0.identifier?.rawValue == "panel.layout.canvas"
                })
                let scroll = try XCTUnwrap(canvas.enclosingScrollView)
                XCTAssertFalse(scroll.hasVerticalScroller, "Editing must not show a clipped vertical scrollbar")
                XCTAssertFalse(scroll.hasHorizontalScroller)
                func cardFrames() -> [String: CGRect] {
                    Dictionary(uniqueKeysWithValues: descendants(root)
                        .compactMap { $0 as? PanelLayoutDragSourceView }
                        .map { ($0.identifier!.rawValue, $0.convert($0.bounds, to: canvas)) })
                }
                let frames = cardFrames()
                XCTAssertEqual(frames.count, 3)
                let canvasBounds = canvas.bounds
                let ids = host.panelEntries(in: surface.testPanelID).map(\.id)
                let last = try XCTUnwrap(frames["panel.layout.drag.\(host.testEntry(pluginID: "c", kind: surface).id)"])
                let target = CGPoint(x: direction == .rightToLeft ? last.minX + 8 : last.maxX - 8,
                                     y: surface == .widget ? last.midY : last.maxY - 2)
                XCTAssertTrue(canvasBounds.contains(target))
                if surface == .widget {
                    let reordered = ComponentGridPlacementEngine.placements(for: [
                        host.componentItems[1], host.componentItems[2], host.componentItems[0]
                    ])
                    XCTAssertGreaterThan(target.y, ComponentPanelLayout.gridContentHeight(for: reordered)
                        + PanelLayoutDestination.dropTailHeight, "The fixture must exercise a shrinking preview")
                }

                _ = session.begin(id: host.testEntry(pluginID: "a", kind: surface).id, ids: ids)
                session.preview(offset: 3, ids: ids)
                try await settle()
                XCTAssertEqual(session.previewIDs(currentIDs: ids), ["b", "c", "a"].map { host.testEntry(pluginID: $0, kind: surface).id })
                XCTAssertEqual(host.panelEntries(in: surface.testPanelID).map(\.id), ids)
                XCTAssertEqual(cardFrames(), frames)
                XCTAssertEqual(canvas.bounds, canvasBounds)
                XCTAssertTrue(canvas.bounds.contains(target), "A stationary drop target must remain valid")

                session.leave()
                try await settle()
                XCTAssertEqual(cardFrames(), frames)
                XCTAssertEqual(canvas.bounds, canvasBounds)
                session.preview(offset: 3, ids: ids)
                let move = try XCTUnwrap(session.finish(ids: ids))
                host.reorderTestItem(pluginID: "a", kind: surface, toOffset: move.offset)
                try await settle()
                XCTAssertEqual(host.panelEntries(in: surface.testPanelID).map(\.pluginID), ["b", "c", "a"])
                XCTAssertNotEqual(cardFrames(), frames, "Cards should move after the drop is committed")
            }
        }
    }

    func testScrollingCannotClearPendingDropAndUsesScrolledCoordinates() throws {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 304, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 304, height: 200))
        let document = LayoutScrollTestDocument(frame: CGRect(x: 0, y: 0, width: 304, height: 1040))
        scroll.documentView = document
        window.contentView = scroll
        window.orderFront(nil)
        let scroller = PanelLayoutDragScroller()
        scroller.anchor = document
        let session = PanelLayoutEditingSession()
        let ids = (0..<20).map(String.init)
        let geometry = PanelLayoutDropGeometry(frames: ids.enumerated().map { index, id in
            .init(entry: .init(placement: .init(item: .init(pluginID: id, itemID: "control")), kind: .row),
                  frame: CGRect(x: 0, y: index * 52, width: 304, height: 44))
        })
        let token = try XCTUnwrap(session.begin(id: "0", ids: ids))
        var reportedPoint: CGPoint?
        scroller.start { point in
            reportedPoint = point
            session.preview(target: geometry.target(at: point, rightToLeft: false), ids: ids)
        }
        defer { scroller.stop() }
        let clip = scroll.contentView
        let local = CGPoint(x: 30, y: clip.isFlipped ? clip.bounds.maxY - 2 : clip.bounds.minY + 2)
        let screenPoint = window.convertPoint(toScreen: clip.convert(local, to: nil))
        for _ in 0..<5 { scroller.scroll(at: screenPoint) }
        XCTAssertGreaterThan(clip.bounds.minY, 0)
        XCTAssertGreaterThan(try XCTUnwrap(reportedPoint).y, 200)
        XCTAssertEqual(session.token, token, "Scrolling never owns drag cancellation, even after physical release")
        XCTAssertNotNil(session.finish(ids: ids))
        session.sourceEnded(token: token)
        XCTAssertNil(session.token)
    }

    func testCursorTracksCardControlsClippingAndDraggability() async throws {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
        let document = LayoutScrollTestDocument(frame: CGRect(x: 0, y: 0, width: 240, height: 800))
        let source = PanelLayoutDragSourceView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        document.addSubview(source)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        let previousCursor = NSCursor.current
        defer { window.close(); previousCursor.set() }
        try await settle()

        func checkCursor(at point: CGPoint, expected: NSCursor, line: UInt = #line) throws {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate,
                location: source.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
            NSCursor.iBeam.set()
            source.cursorUpdate(with: event)
            XCTAssertEqual(NSCursor.current, expected, line: line)
        }
        func cursorAreas() -> [NSTrackingArea] {
            source.trackingAreas.filter { $0.options.contains(.cursorUpdate) }
        }

        let center = CGPoint(x: source.bounds.midX, y: source.bounds.midY)
        try checkCursor(at: center, expected: .openHand)
        source.showsControls = true
        XCTAssertEqual(cursorAreas().count, 4)
        let previousAreas = cursorAreas()
        for _ in 0..<20 { source.updateTrackingAreas() }
        XCTAssertTrue(zip(previousAreas, cursorAreas()).allSatisfy { $0 === $1 },
                      "Unchanged layouts must reuse native tracking areas")
        try checkCursor(at: center, expected: .arrow)
        let gap = CGPoint(x: (source.controlFrames[0].maxX + source.controlFrames[1].minX) / 2, y: center.y)
        try checkCursor(at: gap, expected: .openHand)
        XCTAssertTrue(source.hitTest(source.convert(gap, to: source.superview)) === source)
        for point in [CGPoint(x: 8, y: 8), CGPoint(x: 232, y: 8),
                      CGPoint(x: 8, y: 152), CGPoint(x: 232, y: 152)] {
            try checkCursor(at: point, expected: .openHand)
        }
        source.showsControls = false
        XCTAssertEqual(cursorAreas().count, 1)
        try checkCursor(at: center, expected: .openHand)
        source.showsControls = true

        scroll.contentView.scroll(to: CGPoint(x: 0, y: 80))
        try await settle()
        let visible = source.bounds.intersection(source.visibleRect)
        XCTAssertGreaterThan(visible.minY, 0)
        XCTAssertTrue(cursorAreas().allSatisfy { visible.contains($0.rect) })
        try checkCursor(at: CGPoint(x: 8, y: 152), expected: .openHand)
        try checkCursor(at: CGPoint(x: center.x, y: 90), expected: .arrow)

        scroll.contentView.scroll(to: .zero)
        source.setFrameSize(CGSize(width: 70, height: 160))
        try await settle()
        XCTAssertEqual(cursorAreas().count, 4, "Layout changes replace tracking areas instead of accumulating them")
        try checkCursor(at: CGPoint(x: 35, y: 80), expected: .arrow)
        try checkCursor(at: CGPoint(x: 8, y: 80), expected: .openHand)
        source.isDraggable = false
        try checkCursor(at: CGPoint(x: 8, y: 80), expected: .arrow)
    }

    func testCompactNativeHitMapLeavesTheIconSidesAndTitleDraggable() async throws {
        let plugin = LayoutEditorTestPlugin("compact", order: 0)
        plugin.grid = .compact
        plugin.spanWidth = 1
        plugin.spanHeight = 8
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = makeHost([plugin])
            let window = mount(PanelLayoutEditor(pluginHost: host, panelID: "components", onDismiss: {})
                .environment(\.layoutDirection, direction))
            defer { window.close() }
            try await settle()
            let root = try XCTUnwrap(window.contentView)
            let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }.first)
            setHover(source, inside: true)
            try await settle()
            XCTAssertTrue(source.showsControls)
            XCTAssertEqual(source.controlFrames.count, 1)
            let bounds = source.bounds
            for point in [CGPoint(x: 6, y: bounds.midY), CGPoint(x: bounds.maxX - 6, y: bounds.midY),
                          CGPoint(x: bounds.midX, y: 6), CGPoint(x: bounds.midX, y: bounds.maxY - 6)] {
                XCTAssertTrue(root.hitTest(source.convert(point, to: nil)) === source)
            }
            XCTAssertFalse(root.hitTest(source.convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)) === source)
            XCTAssertEqual(source.bounds, bounds, "Hover must not resize the widget or its drag map")
        }
    }

    private func setHover(_ source: PanelLayoutDragSourceView, inside: Bool) {
        let point = inside ? source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            : CGPoint(x: -10_000, y: -10_000)
        source.hover?.trackingView?.pointerLocationInWindow = { _ in point }
        source.hover?.trackingView?.refresh()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: CGPoint, to window: NSWindow) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(event)
    }

    private func checkDrag(surface: PluginPanelItemKind, changeDashboardSpan: Bool) async throws {
        let a = LayoutEditorTestPlugin("a", order: 1)
        let b = LayoutEditorTestPlugin("b", order: 2)
        let host = makeHost([a, b])
        let session = PanelLayoutEditingSession()
        let editor = PanelLayoutEditor(pluginHost: host, panelID: surface.testPanelID, onDismiss: {}, session: session)
        let window = mount(editor)
        defer { window.close() }
        try await settle()
        let beforeIDs = host.panelEntries(in: surface.testPanelID).map(\.id)
        let beforePlacements = ComponentGridPlacementEngine.placements(for: host.componentItems)
        let token = try XCTUnwrap(session.begin(id: host.testEntry(pluginID: "a", kind: surface).id, ids: beforeIDs))
        session.preview(offset: 2, ids: beforeIDs)
        try await settle()
        XCTAssertEqual(session.token, token, "The mounted editor is editing the injected session")
        if changeDashboardSpan { a.spanHeight += 8 }
        a.subtitle = "Updated reading"
        a.onStateChange?()
        try await settle()
        let afterPlacements = ComponentGridPlacementEngine.placements(for: host.componentItems)
        XCTAssertEqual(host.panelEntries(in: surface.testPanelID).map(\.id), beforeIDs)
        XCTAssertEqual(beforePlacements != afterPlacements, changeDashboardSpan)
        if surface == .widget && changeDashboardSpan {
            XCTAssertNil(session.token, "Changed Dashboard geometry must cancel its own drag")
        } else {
            XCTAssertEqual(session.token, token, "Unrelated updates must not cancel the drag")
            XCTAssertEqual(session.finish(ids: beforeIDs), .init(id: host.testEntry(pluginID: "a", kind: surface).id, offset: 2))
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func mount<V: View>(_ content: V) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 304, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnyView(content.frame(width: 304, height: 480)))
        window.orderFront(nil)
        return window
    }

    private func makeHost(_ plugins: [LayoutEditorTestPlugin]) -> PluginHost {
        let suite = "PanelLayoutEditorTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return PluginHost(plugins: plugins, shortcutStore: ShortcutStore(userDefaults: defaults),
                          pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
                          preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                          globalShortcutManager: GlobalShortcutManager())
    }


}

@MainActor
private final class LibraryPopoverTestPresentation: ObservableObject {
    @Published var isPresented = false
}

private struct LibraryPopoverTestContent: View {
    let host: PluginHost
    @ObservedObject var presentation: LibraryPopoverTestPresentation

    var body: some View {
        Color.clear.frame(width: 304, height: 180)
            .popover(isPresented: $presentation.isPresented, arrowEdge: .trailing) {
                PanelComponentLibrary(pluginHost: host, panelID: "components", onAdd: { _ in true })
            }
    }
}

@MainActor
private final class LayoutEditorTestPlugin: MacToolsPlugin {
    var panelItems: [PluginPanelItem] {
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: rowState,
                 action: { [weak self] in self?.handleAction($0) }),
        ] + (0..<libraryWidgetCount).map { index in
            .widget(id: index == 0 ? "widget" : "widget-\(index)", initialPlacement: index == 0 ? .dashboard : nil,
                    descriptor: descriptor, state: widgetState,
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
        }
    }

    let metadata: PluginMetadata
    let rowDescriptor = PluginPanelRowDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented)
    var descriptor: PluginPanelWidgetDescriptor {
        .init(span: PluginPanelWidgetSpan(width: spanWidth, height: spanHeight, grid: grid)!)
    }
    var runtimeVisible = true
    var spanWidth = 2
    var spanHeight = 12
    var grid: PluginPanelWidgetGrid = .standard
    var libraryWidgetCount = 1
    var subtitle = "Reading"
    var contexts: [PluginPanelWidgetContext] = []
    var showsInteractionProbe = false
    var previewEnabledStates: [Bool] = []
    var controlInvocations = 0
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(_ id: String, order: Int) {
        metadata = PluginMetadata(id: id, title: id, iconName: "circle", iconTint: .blue, order: order, defaultDescription: id)
    }

    var rowState: PluginPanelRowState {
        .init(subtitle: subtitle, isOn: false, isEnabled: true, isAvailable: runtimeVisible,
              detail: nil, errorMessage: nil)
    }

    var widgetState: PluginPanelWidgetState {
        .init(subtitle: subtitle, isActive: false, isEnabled: true, isAvailable: runtimeVisible, errorMessage: nil)
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        contexts.append(context)
        if showsInteractionProbe { return AnyView(LayoutEditorInteractionProbe(plugin: self)) }
        return AnyView(Text(metadata.title).frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    func handleAction(_ action: PluginPanelAction) {}
}

private struct LayoutEditorInteractionProbe: View {
    let plugin: LayoutEditorTestPlugin
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack {
            Button("Run") { plugin.controlInvocations += 1 }
            Toggle("Enabled", isOn: Binding(get: { true }, set: { _ in plugin.controlInvocations += 1 }))
            TextField("Value", text: Binding(get: { "Original value" }, set: { _ in plugin.controlInvocations += 1 }))
        }
        .onAppear { plugin.previewEnabledStates.append(isEnabled) }
        .onChange(of: isEnabled) { _, enabled in plugin.previewEnabledStates.append(enabled) }
    }
}

@MainActor
private final class LayoutScrollTestDocument: NSView {
    override var isFlipped: Bool { true }
}
