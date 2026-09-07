import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditorTests: XCTestCase {
    private var suites: [String] = []

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

    func testDashboardRefreshWithStableGeometryKeepsFeatureDragControl() async throws {
        try await checkDrag(surface: .featurePanel, changeDashboardSpan: false)
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
        XCTAssertNotNil(session.begin(id: "a", ids: host.panelItems.map(\.id)))
        a.runtimeVisible = false
        a.onStateChange?()
        try await settle()
        XCTAssertEqual(host.panelItems.map(\.id), ["b"])
        XCTAssertNil(session.token)
    }

    func testCardBodyAndHandleReceivePointerDragsWhileMoveMenuRemainsSeparate() async throws {
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let host = makeHost([LayoutEditorTestPlugin("a", order: 0), LayoutEditorTestPlugin("b", order: 1)])
                let window = mount(PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {})
                    .environment(\.layoutDirection, direction))
                defer { window.close() }
                try await settle()
                let root = try XCTUnwrap(window.contentView)
                let source = try XCTUnwrap(descendants(root).compactMap { $0 as? PanelLayoutDragSourceView }
                    .first { $0.identifier?.rawValue == "panel.layout.drag.a" })
                var starts = 0
                source.onBegin = { starts += 1; return nil }
                for point in [CGPoint(x: source.bounds.midX, y: 8),
                              CGPoint(x: direction == .leftToRight ? source.bounds.width - 46 : 46,
                                      y: source.bounds.height - 18)] {
                    let location = source.convert(point, to: nil)
                    XCTAssertTrue(root.hitTest(location) === source)
                    sendMouse(.leftMouseDown, at: location, to: window)
                    sendMouse(.leftMouseDragged, at: CGPoint(x: location.x + 6, y: location.y), to: window)
                    sendMouse(.leftMouseUp, at: location, to: window)
                }
                XCTAssertEqual(starts, 2, "The card body and handle must both reach the native drag source")
                let menuLocation = source.convert(CGPoint(x: source.menuFrame.midX, y: source.menuFrame.midY), to: nil)
                XCTAssertNotNil(root.hitTest(menuLocation))
                XCTAssertFalse(root.hitTest(menuLocation) === source, "The overlay must not swallow the move menu")
            }
        }
    }

    func testUndoButtonRestoresPersistedOrderAndPreservesHiddenSlots() async throws {
        for surface in [PluginDisplaySurface.dashboard, .featurePanel] {
            let host = makeHost(["a", "hidden", "b", "c"].enumerated().map { LayoutEditorTestPlugin($0.element, order: $0.offset) })
            host.setPluginVisible(false, id: "hidden", on: surface)
            let session = PanelLayoutEditingSession()
            let window = mount(PanelLayoutEditor(pluginHost: host, surface: surface, onDismiss: {}, session: session))
            defer { window.close() }
            try await settle()
            let before = renderedIDs(host, surface: surface)
            host.moveRenderedPlugin(id: "a", toOffset: 3, on: surface)
            session.didSave(.init(id: "a", offset: 3), beforeIDs: before, afterIDs: renderedIDs(host, surface: surface))
            try await settle()
            let freshStore = PluginDisplayPreferencesStore(userDefaults: UserDefaults(suiteName: suites.last!)!)
            XCTAssertEqual(freshStore.visiblePluginIDs(for: surface, defaultPluginIDs: ["a", "hidden", "b", "c"]), ["b", "c", "a"])
            sendMouse(.leftMouseDown, at: CGPoint(x: 275, y: 20), to: window)
            sendMouse(.leftMouseUp, at: CGPoint(x: 275, y: 20), to: window)
            try await settle()
            XCTAssertEqual(renderedIDs(host, surface: surface), before)
            XCTAssertEqual(session.feedback, .undone)
            XCTAssertFalse(session.canUndo(ids: before))
            let restoredStore = PluginDisplayPreferencesStore(userDefaults: UserDefaults(suiteName: suites.last!)!)
            XCTAssertEqual(restoredStore.visiblePluginIDs(for: surface, defaultPluginIDs: ["a", "hidden", "b", "c"]), before)
            host.setPluginVisible(true, id: "hidden", on: surface)
            XCTAssertEqual(renderedIDs(host, surface: surface), ["a", "hidden", "b", "c"])
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
        let beforeIDs = host.panelItems.map(\.id)
        let beforePlacements = ComponentGridPlacementEngine.placements(for: host.componentItems)
        let token = try XCTUnwrap(session.begin(id: "a", ids: beforeIDs))
        session.preview(offset: 2, ids: beforeIDs)
        try await settle()
        XCTAssertEqual(session.token, token, "The mounted editor is editing the injected session")
        if changeDashboardSpan { a.spanHeight += 8 }
        a.subtitle = "Updated reading"
        a.onStateChange?()
        try await settle()
        let afterPlacements = ComponentGridPlacementEngine.placements(for: host.componentItems)
        XCTAssertEqual(host.panelItems.map(\.id), beforeIDs)
        XCTAssertEqual(beforePlacements != afterPlacements, changeDashboardSpan)
        if surface == .dashboard && changeDashboardSpan {
            XCTAssertNil(session.token, "Changed Dashboard geometry must cancel its own drag")
        } else {
            XCTAssertEqual(session.token, token, "Unrelated updates must not cancel the drag")
            XCTAssertEqual(session.finish(ids: beforeIDs), .init(id: "a", offset: 2))
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
        return AnyView(Text(metadata.title).frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    func handleAction(_ action: PluginPanelAction) {}
}

@MainActor
private final class LayoutScrollTestDocument: NSView {
    override var isFlipped: Bool { true }
}
