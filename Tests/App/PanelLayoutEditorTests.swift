import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditorTests: XCTestCase {
    private var suites: [String] = []

    func testRepeatedAdditionsMoveRemoveAndRestoreIndependently() throws {
        for surface in PluginDisplaySurface.allCases {
            let unavailable = LayoutEditorTestPlugin("unavailable", order: 9)
            unavailable.runtimeVisible = false
            let a = LayoutEditorTestPlugin("a", order: 0)
            let host = makeHost([a, LayoutEditorTestPlugin("b", order: 1), unavailable])
            let other: PluginDisplaySurface = surface == .dashboard ? .featurePanel : .dashboard
            let template = MenuBarPanelEntry(pluginID: "a", surface: surface)
            let destination = try XCTUnwrap(host.addMenuBarPanel())
            XCTAssertEqual(PanelComponentLibraryItem.catalog(in: host).map(\.id), ["a", "b"])
            XCTAssertEqual(PanelComponentLibraryItem.catalog(in: host, matching: " A ").map(\.id), ["a"])
            XCTAssertTrue(a.contexts.isEmpty)
            for panel in [surface.defaultPanelID, surface.defaultPanelID, destination] {
                XCTAssertTrue(host.addPanelEntry(template, to: panel))
            }
            let originals = host.panelEntries(in: surface.defaultPanelID)
            XCTAssertEqual(originals.map(\.pluginID), ["a", "b", "a", "a"])
            XCTAssertEqual(Set(originals.map(\.id)).count, 4)
            let second = originals[3]
            let moved = originals[2]
            let session = PanelLayoutEditingSession()
            XCTAssertTrue(session.commit(.init(id: moved.id, offset: 0, sourcePanelID: surface.defaultPanelID),
                                         in: host, panelID: destination))
            XCTAssertEqual(host.panelEntries(in: destination).first, moved)
            XCTAssertTrue(host.panelEntries(in: surface.defaultPanelID).contains(second))
            session.undo(in: host, panelID: destination)
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID), originals)
            XCTAssertTrue(session.commit(.init(id: second.id, offset: 0), in: host, panelID: surface.defaultPanelID))
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID).first, second)
            session.undo(in: host, panelID: surface.defaultPanelID)
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID), originals)
            XCTAssertTrue(host.removePanelEntry(moved, from: surface.defaultPanelID))
            XCTAssertFalse(host.removePanelEntry(moved, from: surface.defaultPanelID))
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID), [originals[0], originals[1], second])
            XCTAssertTrue(host.removePanelEntry(template, from: surface.defaultPanelID))
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID), [originals[1], second])
            XCTAssertEqual(host.panelEntries(in: other.defaultPanelID).map(\.pluginID), ["a", "b"])
            XCTAssertFalse(host.addPanelEntry(.init(pluginID: "unavailable", surface: surface), to: destination))
            let backup = host.makePreferencesBackup()
            let restored = makeHost([LayoutEditorTestPlugin("a", order: 0), LayoutEditorTestPlugin("b", order: 1)])
            _ = try restored.importPreferences(backup)
            XCTAssertEqual(restored.menuBarPanelStore.configuration, host.menuBarPanelStore.configuration)
            XCTAssertEqual(restored.panelEntries(in: surface.defaultPanelID), host.panelEntries(in: surface.defaultPanelID))
            XCTAssertEqual(restored.panelEntries(in: destination), host.panelEntries(in: destination))
            let lastCopy = try XCTUnwrap(host.panelEntries(in: destination).first)
            XCTAssertNil(host.deleteMenuBarPanel(id: destination))
            XCTAssertTrue(host.panelEntries(in: surface.defaultPanelID).contains(lastCopy))
            XCTAssertFalse(host.panelEntries(in: surface.defaultPanelID).contains(template))
        }
    }

    func testAddingPreviouslyHiddenPluginDoesNotRestoreItsDefaultEntry() throws {
        let host = makeHost([LayoutEditorTestPlugin("a", order: 0)])
        host.setPluginVisible(false, id: "a", on: .dashboard)
        let destination = try XCTUnwrap(host.addMenuBarPanel())
        XCTAssertTrue(host.addPanelEntry(.init(pluginID: "a", surface: .dashboard), to: destination))
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

    func testLibraryMasonryPreservesPanelScaleAndFillsTheShorterColumn() {
        let panelWidth = ComponentPanelLayout.gridWidth
        let width = PanelComponentLibraryLayout.columnWidth(availableWidth: panelWidth + PanelComponentLibraryLayout.spacing)
        XCTAssertEqual(width, panelWidth / 2)
        let source = CGSize(width: panelWidth / 2, height: 200)
        XCTAssertEqual(PanelComponentLibraryLayout.previewSize(source, columnWidth: width),
                       CGSize(width: panelWidth / 4, height: 100))
        let sizes = [200, 50, 100, 50, 80].map { CGSize(width: panelWidth, height: CGFloat($0)) }
        let columns = PanelComponentLibraryLayout.columns(for: sizes, columnWidth: panelWidth)
        XCTAssertEqual(columns, [[0, 4], [1, 2, 3]])
        XCTAssertEqual(Set(columns.flatMap { $0 }).count, sizes.count)
        XCTAssertEqual(PanelComponentLibraryLayout.columns(for: [source, source, source, source], columnWidth: width),
                       [[0, 2], [1, 3]], "Equal-height columns place the next preview on the left")
        XCTAssertEqual(PanelComponentLibraryLayout.columns(for: [], columnWidth: width), [[], []])
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
            host.addPanelEntry($0, to: destination)
        })
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 660, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await settle()
        XCTAssertEqual(a.contexts.count, 1)
        XCTAssertTrue(a.contexts.allSatisfy { !$0.isPanelVisible })
        XCTAssertTrue(b.contexts.isEmpty)
        let location = hosting.convert(CGPoint(x: 310, y: 170), to: nil)
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
        XCTAssertNotEqual(copies[0].id, copies[1].id)
        XCTAssertEqual(host.panelEntries(in: "components").map(\.pluginID), ["a", "b"])
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: "/private/tmp/mactools-widget-thumbnails.png"))
        XCTAssertEqual(a.contexts.count, 1, "Adding must reuse the current preview")
        XCTAssertTrue(b.contexts.isEmpty)
    }

    func testCrossPanelDragCommitsAtInsertionAndUndoRestoresBothLayouts() throws {
        for surface in PluginDisplaySurface.allCases {
            let other: PluginDisplaySurface = surface == .dashboard ? .featurePanel : .dashboard
            let host = makeHost(["a", "hidden", "b", "c"].enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) })
            let destination = try XCTUnwrap(host.addMenuBarPanel())
            host.setPluginVisible(false, id: "hidden", on: surface)
            host.assignPanelEntry(pluginID: "b", surface: other, to: destination)
            host.assignPanelEntry(pluginID: "c", surface: surface, to: destination)
            let entry = MenuBarPanelEntry(pluginID: "a", surface: surface)
            let before = host.menuBarPanelStore.configuration
            let sourceIDs = host.panelEntries(in: surface.defaultPanelID).map(\.id)
            let destinationIDs = host.panelEntries(in: destination).map(\.id)
            let session = PanelLayoutEditingSession()
            let token = try XCTUnwrap(session.begin(entry: entry, panelID: surface.defaultPanelID, ids: sourceIDs))
            session.enterPanel(destination, ids: destinationIDs)
            XCTAssertTrue(session.validate(in: host, panelID: destination))
            session.preview(offset: 1, ids: destinationIDs)
            XCTAssertEqual(host.menuBarPanelStore.configuration, before, "Hover and insertion previews cannot write preferences")
            let move = try XCTUnwrap(session.finish(ids: destinationIDs))
            XCTAssertTrue(session.commit(move, in: host, panelID: destination))
            XCTAssertEqual(host.panelEntries(in: destination).map(\.id), [destinationIDs[0], entry.id, destinationIDs[1]])
            XCTAssertEqual(host.panelID(pluginID: "a", surface: other), other.defaultPanelID)
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
        let entry = MenuBarPanelEntry(pluginID: "a", surface: .dashboard)
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
        host.assignPanelEntry(pluginID: "a", surface: .featurePanel, to: intermediate)
        XCTAssertFalse(session.canUndo(in: host, panelID: destination), "Undo cannot overwrite another saved layout change")
        _ = session.begin(entry: entry, panelID: destination, ids: [entry.id])
        session.enterPanel(source, ids: [])
        host.setPluginVisible(false, id: "a", on: .dashboard)
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
        let window = mount(MenuBarUnifiedPanelContent(pluginHost: host, appUpdater: AppUpdater(startingUpdater: false),
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
        XCTAssertEqual(host.panelEntries(in: destination), [MenuBarPanelEntry(pluginID: "a", surface: .dashboard)])
        XCTAssertTrue(session.canUndo(in: host, panelID: destination))
        XCTAssertTrue(model.isEditingLayout)
    }

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    func testRenderedMovesMatchPreviewAndPreserveHiddenSlotsOnBothSurfaces() throws {
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            for (source, offset) in [("a", 2), ("c", 1), ("c", -5), ("a", 10), ("b", 1), ("b", 2)] {
                let plugins = ["runtime-leading", "a", "runtime-middle", "b", "preference-hidden", "c", "runtime-trailing"]
                    .enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) }
                for plugin in plugins where plugin.metadata.id.hasPrefix("runtime-") {
                    plugin.runtimeVisible = false
                }
                let host = makeHost(plugins)
                host.setPluginVisible(false, id: "preference-hidden", on: surface)
                let ids = renderedIDs(host, surface: surface)
                XCTAssertEqual(ids, ["a", "b", "c"])
                let preview = PanelLayoutDestination.moving(source, toOffset: offset, in: ids)
                host.moveRenderedPlugin(id: source, toOffset: offset, on: surface)
                XCTAssertEqual(renderedIDs(host, surface: surface), preview)
                let stored = surface == .dashboard ? host.dashboardLayoutItems.map(\.id) : host.featurePanelLayoutItems.map(\.id)
                XCTAssertEqual(stored, ["runtime-leading", preview[0], "runtime-middle", preview[1], preview[2], "runtime-trailing"])
                host.setPluginVisible(true, id: "preference-hidden", on: surface)
                let restored = surface == .dashboard ? host.dashboardLayoutItems.map(\.id) : host.featurePanelLayoutItems.map(\.id)
                XCTAssertEqual(restored, ["runtime-leading", preview[0], "runtime-middle", preview[1], "preference-hidden", preview[2], "runtime-trailing"])
                let otherSurface: PluginDisplaySurface = surface == .dashboard ? .featurePanel : .dashboard
                XCTAssertEqual(renderedIDs(host, surface: otherSurface), ["a", "b", "preference-hidden", "c"])
            }
        }
    }

    func testUnavailableRenderedSourceDoesNotChangeSavedOrder() {
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            let hidden = LayoutEditorTestPlugin("hidden", order: 0)
            hidden.runtimeVisible = false
            let host = makeHost([hidden, LayoutEditorTestPlugin("a", order: 1), LayoutEditorTestPlugin("b", order: 2)])
            for source in ["hidden", "missing"] {
                host.moveRenderedPlugin(id: source, toOffset: 3, on: surface)
                XCTAssertEqual(renderedIDs(host, surface: surface), ["a", "b"])
                let stored = surface == .dashboard ? host.dashboardLayoutItems.map(\.id) : host.featurePanelLayoutItems.map(\.id)
                XCTAssertEqual(stored, ["hidden", "a", "b"])
            }
        }
    }

    private func renderedIDs(_ host: PluginHost, surface: PluginDisplaySurface) -> [String] {
        surface == .dashboard ? host.componentItems.map(\.id) : host.panelItems.map(\.id)
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
        let window = mount(normal)
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView as? NSHostingView<AnyView>)
        try await settle()
        XCTAssertEqual(a.contexts.count, 1)
        XCTAssertEqual(h.contexts.count, 0)
        view.rootView = AnyView(PanelLayoutEditor(pluginHost: host, surface: .dashboard, onDismiss: { dismissCount += 1 }).frame(width: 304, height: 480))
        try await settle()
        h.runtimeVisible = true
        h.onStateChange?()
        try await settle()
        XCTAssertEqual(host.componentItems.map(\.id), ["a", "conditional", "b"])
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
        try await checkDrag(surface: .featurePanel, changeDashboardSpan: true)
    }

    func testDashboardSpanChangeCancelsDashboardDrag() async throws {
        try await checkDrag(surface: .dashboard, changeDashboardSpan: true)
    }

    func testFeatureItemDisappearanceCancelsFeatureDrag() async throws {
        let a = LayoutEditorTestPlugin("a", order: 1)
        let host = makeHost([a, LayoutEditorTestPlugin("b", order: 2)])
        let session = PanelLayoutEditingSession()
        let window = mount(PanelLayoutEditor(pluginHost: host, surface: .featurePanel, onDismiss: {}, session: session))
        defer { window.close() }
        try await settle()
        XCTAssertNotNil(session.begin(id: PluginDisplaySurface.featurePanel.panelEntryID(pluginID: "a"), ids: host.panelEntries(in: "features").map(\.id)))
        a.runtimeVisible = false
        a.onStateChange?()
        try await settle()
        XCTAssertEqual(host.panelItems.map(\.id), ["b"])
        XCTAssertNil(session.token)
    }

    func testRemovalRequiresConfirmationAndRemovesOnlyTheCurrentEntry() async throws {
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            let host = makeHost([LayoutEditorTestPlugin("a", order: 0), LayoutEditorTestPlugin("b", order: 1)])
            let window = mount(PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {}))
            defer { window.close() }
            try await settle()
            let root = try XCTUnwrap(window.contentView)
            let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }
                .first { $0.identifier?.rawValue == "panel.layout.drag.\(surface.panelEntryID(pluginID: "a"))" })
            setHover(source, inside: true)
            try await settle()
            let location = source.convert(CGPoint(x: source.menuFrame.minX + PanelLayoutItemControlsLayout(size: source.bounds.size).buttonSide / 2, y: source.menuFrame.midY), to: nil)
            XCTAssertFalse(root.hitTest(location) === source)
            sendMouse(.leftMouseDown, at: location, to: window)
            sendMouse(.leftMouseUp, at: location, to: window)
            try await settle()
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID).map(\.pluginID), ["a", "b"])
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
            XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID).map(\.pluginID), ["b"])
            XCTAssertFalse(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }.contains {
                $0.identifier?.rawValue == "panel.layout.drag.\(surface.panelEntryID(pluginID: "a"))"
            })
            XCTAssertTrue(PanelComponentLibraryItem.catalog(in: host).contains { $0.id == "a" })
            let other: PluginDisplaySurface = surface == .dashboard ? .featurePanel : .dashboard
            XCTAssertEqual(host.panelEntries(in: other.defaultPanelID).map(\.pluginID), ["a", "b"])
        }
    }

    func testUndoRestoresPersistedPanelOrderAndPreservesHiddenSlots() throws {
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            let host = makeHost(["a", "hidden", "b", "c"].enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) })
            host.setPluginVisible(false, id: "hidden", on: surface)
            let session = PanelLayoutEditingSession()
            let panelID = surface.defaultPanelID
            let before = host.panelEntries(in: panelID).map(\.id)
            host.movePanelEntry(pluginID: "a", surface: surface, panelID: panelID, toOffset: 3)
            let after = host.panelEntries(in: panelID).map(\.id)
            session.didSave(.init(id: surface.panelEntryID(pluginID: "a"), offset: 3), beforeIDs: before, afterIDs: after)
            XCTAssertEqual(host.panelEntries(in: panelID).map(\.pluginID), ["b", "c", "a"])
            let move = try XCTUnwrap(session.takeUndo(ids: after))
            host.movePanelEntry(pluginID: "a", surface: surface, panelID: panelID, toOffset: move.offset)
            session.didUndo()
            XCTAssertEqual(host.panelEntries(in: panelID).map(\.id), before)
            XCTAssertFalse(session.canUndo(ids: before))
            host.setPluginVisible(true, id: "hidden", on: surface)
            XCTAssertEqual(host.panelEntries(in: panelID).map(\.pluginID), ["a", "hidden", "b", "c"])
        }
    }

    func testEditingPreservesEnabledAppearanceWithoutInvokingCardControls() async throws {
        let plugin = LayoutEditorTestPlugin("a", order: 0)
        plugin.showsInteractionProbe = true
        plugin.spanWidth = 4
        plugin.spanHeight = 24
        let host = makeHost([plugin])
        let window = mount(PanelLayoutEditor(pluginHost: host, surface: .dashboard, onDismiss: {}))
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
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let plugins = ["a", "b", "c"].enumerated().map {
                    LayoutEditorTestPlugin($0.element, order: $0.offset)
                }
                // Moving the tall card past the full-width card packs this grid more tightly.
                plugins[0].spanWidth = 1
                plugins[0].spanHeight = 24
                plugins[1].spanWidth = 4
                plugins[2].spanWidth = 3
                let host = makeHost(plugins)
                let session = PanelLayoutEditingSession()
                let window = mount(PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {}, session: session)
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
                let ids = host.panelEntries(in: surface.defaultPanelID).map(\.id)
                let last = try XCTUnwrap(frames["panel.layout.drag.\(surface.panelEntryID(pluginID: "c"))"])
                let target = CGPoint(x: direction == .rightToLeft ? last.minX + 8 : last.maxX - 8,
                                     y: surface == .dashboard ? last.midY : last.maxY - 2)
                XCTAssertTrue(canvasBounds.contains(target))
                if surface == .dashboard {
                    let reordered = ComponentGridPlacementEngine.placements(for: [
                        host.componentItems[1], host.componentItems[2], host.componentItems[0]
                    ])
                    XCTAssertGreaterThan(target.y, ComponentPanelLayout.gridContentHeight(for: reordered)
                        + PanelLayoutDestination.dropTailHeight, "The fixture must exercise a shrinking preview")
                }

                _ = session.begin(id: surface.panelEntryID(pluginID: "a"), ids: ids)
                session.preview(offset: 3, ids: ids)
                try await settle()
                XCTAssertEqual(session.previewIDs(currentIDs: ids), ["b", "c", "a"].map { surface.panelEntryID(pluginID: $0) })
                XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID).map(\.id), ids)
                XCTAssertEqual(cardFrames(), frames)
                XCTAssertEqual(canvas.bounds, canvasBounds)
                XCTAssertTrue(canvas.bounds.contains(target), "A stationary drop target must remain valid")

                session.leave()
                try await settle()
                XCTAssertEqual(cardFrames(), frames)
                XCTAssertEqual(canvas.bounds, canvasBounds)
                session.preview(offset: 3, ids: ids)
                let move = try XCTUnwrap(session.finish(ids: ids))
                host.movePanelEntry(pluginID: "a", surface: surface, panelID: surface.defaultPanelID, toOffset: move.offset)
                try await settle()
                XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID).map(\.pluginID), ["b", "c", "a"])
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
        let token = try XCTUnwrap(session.begin(id: "0", ids: ids))
        var reportedPoint: CGPoint?
        scroller.start { point in
            reportedPoint = point
            session.preview(offset: PanelLayoutDestination.listOffset(at: point, count: ids.count), ids: ids)
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
        XCTAssertEqual(cursorAreas().count, 2)
        try checkCursor(at: center, expected: .arrow)
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
        XCTAssertEqual(cursorAreas().count, 2, "Layout changes replace tracking areas instead of accumulating them")
        try checkCursor(at: CGPoint(x: 35, y: 80), expected: .arrow)
        try checkCursor(at: CGPoint(x: 8, y: 80), expected: .openHand)
        source.isDraggable = false
        try checkCursor(at: CGPoint(x: 8, y: 80), expected: .arrow)
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

    private func checkDrag(surface: PluginDisplaySurface, changeDashboardSpan: Bool) async throws {
        let a = LayoutEditorTestPlugin("a", order: 1)
        let b = LayoutEditorTestPlugin("b", order: 2)
        let host = makeHost([a, b])
        let session = PanelLayoutEditingSession()
        let editor = PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {}, session: session)
        let window = mount(editor)
        defer { window.close() }
        try await settle()
        let beforeIDs = host.panelEntries(in: surface.defaultPanelID).map(\.id)
        let beforePlacements = ComponentGridPlacementEngine.placements(for: host.componentItems)
        let token = try XCTUnwrap(session.begin(id: surface.panelEntryID(pluginID: "a"), ids: beforeIDs))
        session.preview(offset: 2, ids: beforeIDs)
        try await settle()
        XCTAssertEqual(session.token, token, "The mounted editor is editing the injected session")
        if changeDashboardSpan { a.spanHeight += 8 }
        a.subtitle = "Updated reading"
        a.onStateChange?()
        try await settle()
        let afterPlacements = ComponentGridPlacementEngine.placements(for: host.componentItems)
        XCTAssertEqual(host.panelEntries(in: surface.defaultPanelID).map(\.id), beforeIDs)
        XCTAssertEqual(beforePlacements != afterPlacements, changeDashboardSpan)
        if surface == .dashboard && changeDashboardSpan {
            XCTAssertNil(session.token, "Changed Dashboard geometry must cancel its own drag")
        } else {
            XCTAssertEqual(session.token, token, "Unrelated updates must not cancel the drag")
            XCTAssertEqual(session.finish(ids: beforeIDs), .init(id: surface.panelEntryID(pluginID: "a"), offset: 2))
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
                          pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
                          preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
                          globalShortcutManager: GlobalShortcutManager())
    }


}

@MainActor
private final class LayoutEditorTestPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(controlStyle: .switch, menuActionBehavior: .keepPresented)
    var descriptor: PluginComponentDescriptor { .init(span: PluginComponentSpan(width: spanWidth, height: spanHeight)!) }
    var runtimeVisible = true
    var spanWidth = 2
    var spanHeight = 12
    var subtitle = "Reading"
    var contexts: [PluginComponentContext] = []
    var showsInteractionProbe = false
    var previewEnabledStates: [Bool] = []
    var controlInvocations = 0
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(_ id: String, order: Int) {
        metadata = PluginMetadata(id: id, title: id, iconName: "circle", iconTint: .blue, order: order, defaultDescription: id)
    }

    var primaryPanelState: PluginPanelState {
        .init(subtitle: subtitle, isOn: false, isExpanded: false, isEnabled: true, isVisible: runtimeVisible,
              detail: nil, errorMessage: nil)
    }

    var componentPanelState: PluginComponentState {
        .init(subtitle: subtitle, isActive: false, isEnabled: true, isVisible: runtimeVisible, errorMessage: nil)
    }

    func makeView(context: PluginComponentContext) -> AnyView {
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
