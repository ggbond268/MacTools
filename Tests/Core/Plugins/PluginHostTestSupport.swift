import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
func makePluginHostForTests(
    plugins: [any MacToolsPlugin],
    suiteName: String = "PluginHostTestSupport-\(UUID().uuidString)",
    dynamicPluginManager: DynamicPluginManager? = nil,
    loadDynamicPluginsOnInit: Bool = true,
    globalShortcutManager: GlobalShortcutManager? = nil,
    focusedApplicationTargetProvider: (any FocusedApplicationTargetProviding)? = nil,
    pluginStateChangeRebuildDelay: Duration = .milliseconds(80)
) -> PluginHost {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    return PluginHost(
        plugins: plugins,
        dynamicPluginManager: dynamicPluginManager,
        shortcutStore: ShortcutStore(userDefaults: defaults),
        pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
        preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
        globalShortcutManager: globalShortcutManager ?? GlobalShortcutManager(),
        focusedApplicationTargetProvider: focusedApplicationTargetProvider,
        pluginStateChangeRebuildDelay: pluginStateChangeRebuildDelay,
        loadDynamicPluginsOnInit: loadDynamicPluginsOnInit
    )
}

extension PluginPanelItemKind {
    var testItemID: String { self == .widget ? "widget" : "control" }
    var testPanelID: String { self == .widget ? "components" : "features" }
}

@MainActor
extension PluginHost {
    func testEntry(pluginID: String, kind: PluginPanelItemKind) -> MenuBarPanelEntry {
        let entries = menuBarPanels.flatMap { panelEntries(in: $0.id) }
        return entries.first { $0.pluginID == pluginID && $0.kind == kind }!
    }

    func testPanelID(pluginID: String, kind: PluginPanelItemKind) -> String? {
        menuBarPanels.first { panel in
            panelEntries(in: panel.id).contains { $0.pluginID == pluginID && $0.kind == kind }
        }?.id
    }

    func moveTestItem(pluginID: String, kind: PluginPanelItemKind, to panelID: String) {
        let entry = testEntry(pluginID: pluginID, kind: kind)
        let source = testPanelID(pluginID: pluginID, kind: kind)!
        _ = transferPanelEntry(entry, from: source, to: panelID, at: panelEntries(in: panelID).count)
    }

    func removeTestItem(pluginID: String, kind: PluginPanelItemKind) {
        let entry = testEntry(pluginID: pluginID, kind: kind)
        _ = removePanelEntry(entry, from: testPanelID(pluginID: pluginID, kind: kind)!)
    }

    func reorderTestItem(pluginID: String, kind: PluginPanelItemKind, toOffset: Int) {
        let entry = testEntry(pluginID: pluginID, kind: kind)
        movePanelEntry(entry, panelID: testPanelID(pluginID: pluginID, kind: kind)!, toOffset: toOffset)
    }
}
