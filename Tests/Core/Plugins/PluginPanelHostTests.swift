import Combine
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginPanelHostTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func host(_ plugins: [PanelTestPlugin]) -> PluginHost {
        let suite = "PluginPanelHostTests-\(UUID().uuidString)"
        suites.append(suite)
        return makePluginHostForTests(plugins: plugins, suiteName: suite)
    }

    func testOnePluginContributesMultipleViewsAndRoutesIdenticalControlIDsToTheirItems() throws {
        let plugin = PanelTestPlugin()
        let host = host([plugin])
        XCTAssertEqual(host.availablePanelItems.map(\.key.itemID), ["first", "second", "chart", "history"])
        XCTAssertEqual(host.panelEntries(in: "features").map(\.itemID), ["first", "second"])
        XCTAssertEqual(host.panelEntries(in: "components").map(\.itemID), ["chart"])
        XCTAssertEqual(plugin.factoryCalls, 0)
        let rows = host.panelEntries(in: "features")
        host.invokePanelAction(controlID: "execute", for: rows[1].id)
        host.setSwitchValue(true, for: rows[0].id)
        XCTAssertEqual(plugin.actions.map(\.0), ["second", "first"])
        XCTAssertEqual(plugin.actions.map(\.1), [.invokeAction(controlID: "execute"), .setSwitch(true)])
        XCTAssertTrue(host.isSwitchOn(for: rows[0].id))
        XCTAssertFalse(host.isSwitchOn(for: rows[1].id))
    }

    func testCopiesHaveIndependentExpansionContextAndDetailAnchors() throws {
        let plugin = PanelTestPlugin()
        let host = host([plugin])
        let first = try XCTUnwrap(host.panelEntries(in: "features").first)
        XCTAssertTrue(host.panelItems.allSatisfy { !$0.isExpanded })
        XCTAssertTrue(host.addPanelItem(first.key, to: "features"))
        let copy = try XCTUnwrap(host.panelEntries(in: "features").last)
        host.setDisclosureExpanded(true, for: first.id)
        XCTAssertTrue(host.panelItems.first { $0.id == first.id }?.isExpanded == true)
        XCTAssertFalse(host.panelItems.first { $0.id == copy.id }?.isExpanded == true)

        let chart = try XCTUnwrap(host.panelEntries(in: "components").first)
        XCTAssertTrue(host.addPanelItem(chart.key, to: "components"))
        let chartCopy = try XCTUnwrap(host.panelEntries(in: "components").last)
        host.setVisibleMenuBarPanel("components")
        var requests: [String] = []
        host.componentDetailHandlersByPanelID["components"] = { id, _ in requests.append(id) }
        _ = host.componentViewItem(for: chart.id, dismiss: {})
        _ = host.componentViewItem(for: chartCopy.id, dismiss: {})
        XCTAssertEqual(plugin.contexts.map(\.placementID), [chart.placement.id, chartCopy.placement.id])
        plugin.contexts[0].presentDetail("cpu")
        plugin.contexts[1].presentDetail("cpu")
        XCTAssertEqual(requests, [chart.id, chartCopy.id])
    }

    func testMovingAndRemovingCopiesPreservesSharedPluginLifecycle() throws {
        let plugin = PanelTestPlugin()
        let host = host([plugin])
        let chart = try XCTUnwrap(host.panelEntries(in: "components").first)
        let custom = try XCTUnwrap(host.addMenuBarPanel())
        XCTAssertTrue(host.addPanelItem(chart.key, to: custom))
        host.setVisibleMenuBarPanel("components")
        host.setVisibleMenuBarPanel(custom)
        XCTAssertEqual(plugin.events, ["chart:true"])
        let copy = try XCTUnwrap(host.panelEntries(in: custom).first)
        XCTAssertTrue(host.removePanelEntry(copy, from: custom))
        XCTAssertEqual(plugin.events, ["chart:true", "chart:false"])
        XCTAssertEqual(plugin.deactivationCount, 0)
        XCTAssertNotNil(host.panelCoordinator.item(for: chart.key))
    }

    func testLibraryPreviewDoesNotStartVisibilityOrCreatePlacement() throws {
        let plugin = PanelTestPlugin()
        let host = host([plugin])
        let before = host.menuBarPanelStore.configuration
        XCTAssertNotNil(host.componentPreviewView(for: "example:history"))
        XCTAssertTrue(try XCTUnwrap(plugin.contexts.last).isPreview)
        XCTAssertTrue(plugin.events.isEmpty)
        XCTAssertEqual(host.menuBarPanelStore.configuration, before)
        XCTAssertTrue(host.addPanelItem(.init(pluginID: "example", itemID: "history"), to: "features"))
        XCTAssertEqual(host.panelEntries(in: "features").map(\.itemID), ["first", "second", "history"])
    }

    func testStateChangesReadOnlyDirtyPluginAndHiddenPanelDoesNotPublish() async throws {
        let changing = PanelTestPlugin()
        let stable = PanelTestPlugin(id: "stable")
        let host = host([changing, stable])
        let presentation = MenuBarPanelPresentationModel(host: host)
        let initialReads = stable.readCount
        let initialRevision = presentation.revision
        changing.subtitle = "Updated"
        changing.onStateChange?()
        changing.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(stable.readCount, initialReads)
        XCTAssertEqual(presentation.revision, initialRevision)
        presentation.setVisible(true)
        XCTAssertEqual(presentation.revision, initialRevision + 1)
        XCTAssertEqual(host.panelItems.first { $0.pluginID == "example" }?.description, "Updated")
    }

    func testLibraryFindsItemTitlesAndExposesEveryViewWithinItsPlugin() {
        let host = host([PanelTestPlugin()])
        XCTAssertEqual(PanelComponentLibraryItem.catalog(in: host).first?.items.count, 4)
        XCTAssertEqual(PanelComponentLibraryItem.catalog(in: host).first?.previewItems.map(\.key.itemID),
                       ["chart", "history", "first", "second"])
        let matches = PanelComponentLibraryItem.catalog(in: host, matching: "History")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.items.map(\.key.itemID), ["history"])
    }

    func testInvalidCatalogUpdatesPreserveTheLastValidSnapshotAndKindContract() async throws {
        let plugin = PanelTestPlugin()
        let host = host([plugin])
        let before = host.panelEntries(in: "features")
        plugin.changesFirstItemKind = true
        for _ in 0..<2 {
            plugin.onStateChange?()
            await host.waitForScheduledPluginStateRebuildForTests()
            XCTAssertEqual(host.panelEntries(in: "features"), before)
            XCTAssertEqual(host.availablePanelItems.first?.kind, .row)
        }
        plugin.changesFirstItemKind = false
        plugin.subtitle = "Recovered"
        plugin.onStateChange?()
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertEqual(host.panelItems.first?.description, "Recovered")
    }
}

@MainActor
private final class PanelTestPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var readCount = 0
    var factoryCalls = 0
    var deactivationCount = 0
    var subtitle = "Ready"
    var changesFirstItemKind = false
    var states: [String: Bool] = [:]
    var actions: [(String, PluginPanelAction)] = []
    var events: [String] = []
    var contexts: [PluginPanelWidgetContext] = []

    init(id: String = "example", order: Int = 0) {
        metadata = PluginMetadata(id: id, title: id, iconName: "star", iconTint: .blue,
                                  order: order, defaultDescription: "Example plugin")
    }

    var panelItems: [PluginPanelItem] {
        readCount += 1
        return [changesFirstItemKind ? widget("first", initial: .featurePanel) : row("first"),
                row("second"), widget("chart", initial: .dashboard), widget("history", initial: nil)]
    }

    private func row(_ id: String) -> PluginPanelItem {
        .row(id: id, title: id, initialPlacement: .featurePanel,
             descriptor: .init(controlStyle: .disclosure, menuActionBehavior: .keepPresented),
             state: .init(subtitle: subtitle, isOn: states[id] == true, isEnabled: true,
                          isAvailable: true, detail: nil, errorMessage: nil),
             action: { [weak self] action in
                 self?.actions.append((id, action))
                 if case let .setSwitch(value) = action { self?.states[id] = value }
             })
            .onVisibilityChange { [weak self] in self?.events.append("\(id):\($0)") }
    }

    private func widget(_ id: String, initial: PluginPanelInitialPlacement?) -> PluginPanelItem {
        .widget(id: id, title: id == "history" ? "History" : "Chart", initialPlacement: initial,
                descriptor: .init(span: .oneByOne),
                state: .init(subtitle: subtitle, isActive: false, isEnabled: true, isAvailable: true, errorMessage: nil)) {
                    [weak self] context in
                    self?.factoryCalls += 1
                    self?.contexts.append(context)
                    return Text(id)
                }
                .onVisibilityChange { [weak self] in self?.events.append("\(id):\($0)") }
    }

    func deactivate(reason: PluginDeactivationReason) { deactivationCount += 1 }
}
