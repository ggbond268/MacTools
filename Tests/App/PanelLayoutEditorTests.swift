import AppKit
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditorTests: XCTestCase {
    private var suites: [String] = []

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

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
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
        return AnyView(EmptyView())
    }

    func handleAction(_ action: PluginPanelAction) {}
}
