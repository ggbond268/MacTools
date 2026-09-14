import XCTest

@testable import MacTools

@MainActor
final class MenuBarPanelStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: MenuBarPanelStore!

    override func setUp() {
        super.setUp()
        suite = "MenuBarPanelStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = MenuBarPanelStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testNewPluginsUseBothOriginalSurfacesWithoutMigrationWrites() {
        XCTAssertEqual(store.configuration.panels, MenuBarPanelDefinition.defaults)
        XCTAssertEqual(store.configuration.panelID(pluginID: "new", surface: .dashboard), "components")
        XCTAssertEqual(store.configuration.panelID(pluginID: "new", surface: .featurePanel), "features")
        XCTAssertNil(defaults.data(forKey: MenuBarPanelStore.storageKey))
    }

    func testLegacyClickSwapMigratesOnceForDefaultAndCustomLayouts() throws {
        defaults.set("swapped", forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(migrated.configuration.panels.map(\.id), ["features", "components"])
        XCTAssertEqual(migrated.lastSelectedPanelID, "features")
        XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey))
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).configuration, migrated.configuration)

        let customID = try XCTUnwrap(migrated.addPanel())
        migrated.assign(pluginID: "dual", surface: .dashboard, to: customID)
        migrated.rememberSelection(id: "components")
        let before = migrated.configuration
        defaults.set("swapped", forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey)
        let customMigration = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(customMigration.configuration.panels.map(\.id), before.panels.reversed().map(\.id))
        XCTAssertEqual(customMigration.configuration.assignments, before.assignments)
        XCTAssertEqual(customMigration.lastSelectedPanelID, "components")
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).configuration, customMigration.configuration)
        XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey))
    }

    func testStandardLegacyClickSettingIsRemovedWithoutWritingDefaultLayout() {
        defaults.set("standard", forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(migrated.configuration, MenuBarPanelConfiguration())
        XCTAssertNil(defaults.data(forKey: MenuBarPanelStore.storageKey))
        XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey))
    }

    func testMovesOnlyCurrentEntryAndPersistsAcrossRelaunch() throws {
        let id = try XCTUnwrap(store.addPanel())
        store.assign(pluginID: "dual", surface: .dashboard, to: id)
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.panelID(pluginID: "dual", surface: .dashboard), id)
        XCTAssertEqual(reloaded.configuration.panelID(pluginID: "dual", surface: .featurePanel), "features")
        XCTAssertEqual(reloaded.configuration.panelID(pluginID: "new", surface: .dashboard), "components")
    }

    func testSelectionPersistsAcrossRelaunchWithoutChangingPortableLayout() throws {
        let custom = try XCTUnwrap(store.addPanel())
        let layoutData = defaults.data(forKey: MenuBarPanelStore.storageKey)
        store.rememberSelection(id: custom)
        store.rememberSelection(id: "missing")
        XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.storageKey), layoutData)
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.lastSelectedPanelID, custom)
        reloaded.movePanel(id: custom, toOffset: 0)
        XCTAssertEqual(reloaded.lastSelectedPanelID, custom)
        reloaded.rememberSelection(id: "features")
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).lastSelectedPanelID, "features")
    }

    func testSelectionFallsBackWhenItsPanelIsHiddenOrDeleted() throws {
        let custom = try XCTUnwrap(store.addPanel())
        store.rememberSelection(id: custom)
        var hidden = try XCTUnwrap(store.configuration.panels.first { $0.id == custom })
        hidden.isHidden = true
        store.updatePanel(hidden)
        XCTAssertEqual(store.lastSelectedPanelID, "components")
        hidden.isHidden = false
        store.updatePanel(hidden)
        XCTAssertEqual(store.lastSelectedPanelID, "components")
        store.rememberSelection(id: custom)
        store.deletePanel(id: custom)
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).lastSelectedPanelID, "components")
    }

    func testDeletingMixedPanelRestoresEntriesToTheirOwnDefaults() throws {
        let id = try XCTUnwrap(store.addPanel())
        store.assign(pluginID: "dual", surface: .dashboard, to: id)
        store.assign(pluginID: "dual", surface: .featurePanel, to: id)
        store.deletePanel(id: id)
        XCTAssertEqual(store.configuration.panelID(pluginID: "dual", surface: .dashboard), "components")
        XCTAssertEqual(store.configuration.panelID(pluginID: "dual", surface: .featurePanel), "features")
        XCTAssertFalse(store.configuration.panels.contains { $0.id == id })
        XCTAssertTrue(store.configuration.assignments.isEmpty)
    }

    func testDefaultsAllowReorderAndIconChangesButCannotBeDeleted() {
        var panel = store.configuration.panels[0]
        panel.systemImage = "heart"
        store.updatePanel(panel)
        store.movePanel(id: panel.id, toOffset: 2)
        store.deletePanel(id: panel.id)
        XCTAssertEqual(store.configuration.panels.map(\.id), ["features", "components"])
        XCTAssertEqual(store.configuration.panels.last?.systemImage, "heart")
    }

    func testMaximumCountIncludesBothDefaultPanels() {
        XCTAssertNotNil(store.addPanel())
        XCTAssertNotNil(store.addPanel())
        XCTAssertNotNil(store.addPanel())
        XCTAssertNil(store.addPanel())
        XCTAssertEqual(store.configuration.panels.count, 5)
    }

    func testDefaultNamesCanBeEditedAndImportedWithoutChangingTheirRoles() throws {
        for original in MenuBarPanelDefinition.defaults {
            var changed = original
            changed.name = "  Renamed \(original.id)  "
            changed.systemImage = "heart"
            store.updatePanel(changed)
            let reloaded = MenuBarPanelStore(userDefaults: defaults)
            let stored = try XCTUnwrap(reloaded.configuration.panels.first { $0.id == original.id })
            XCTAssertEqual(stored.title, "Renamed \(original.id)")
            XCTAssertEqual(stored.systemImage, "heart")
            XCTAssertTrue(stored.isDefault)
            store.deletePanel(id: original.id)
            XCTAssertTrue(store.configuration.panels.contains { $0.id == original.id })

            var imported = store.configuration
            let index = try XCTUnwrap(imported.panels.firstIndex { $0.id == original.id })
            imported.panels[index].name = "Imported name"
            store.replace(imported)
            XCTAssertEqual(store.configuration.panels[index].title, "Imported name")
        }
        XCTAssertEqual(store.configuration.panelID(pluginID: "new", surface: .dashboard), "components")
        XCTAssertEqual(store.configuration.panelID(pluginID: "new", surface: .featurePanel), "features")
    }

    func testEmptyDefaultNamesKeepLocalizedFallbacksAndReserveEditedNumbers() throws {
        var panel = store.configuration.panels[0]
        panel.name = "  "
        store.updatePanel(panel)
        XCTAssertEqual(store.configuration.panels[0].title, MenuBarPanelDefinition.defaults[0].title)
        panel.name = FeatureL10n.format("面板 %lld", 1)
        store.updatePanel(panel)
        let custom = try XCTUnwrap(store.addPanel())
        XCTAssertEqual(store.configuration.panels.first { $0.id == custom }?.title, FeatureL10n.format("面板 %lld", 2))
    }

    func testMixedOrderPersistsAndRetainsHiddenOrUnavailableSlots() throws {
        let panelID = try XCTUnwrap(store.addPanel())
        let entries = [
            MenuBarPanelEntry(pluginID: "dual", surface: .dashboard),
            MenuBarPanelEntry(pluginID: "hidden", surface: .featurePanel),
            MenuBarPanelEntry(pluginID: "dual", surface: .featurePanel),
            MenuBarPanelEntry(pluginID: "another", surface: .dashboard),
        ]
        for entry in entries { store.assign(pluginID: entry.pluginID, surface: entry.surface, to: panelID) }
        store.setOrder(entries, panelID: panelID)
        store.setOrder([entries[3], entries[2], entries[0]], panelID: panelID)
        let expected = [entries[3], entries[1], entries[2], entries[0]]
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.orderedEntries(entries, panelID: panelID), expected)
        let backup = PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: [],
                                                   panelConfiguration: store.configuration)
        let restored = try JSONDecoder().decode(PluginDisplayPreferencesBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(restored.panelConfiguration?.orderedEntries(entries, panelID: panelID), expected)
        store.assign(pluginID: "dual", surface: .featurePanel, to: "features")
        XCTAssertEqual(store.configuration.panelID(pluginID: "dual", surface: .dashboard), panelID)
        XCTAssertEqual(store.configuration.orderedEntries(entries, panelID: panelID), [entries[3], entries[1], entries[0]])
    }

    func testCustomPanelsGetAvailableNumbersAndRetainEditedNames() throws {
        let first = try XCTUnwrap(store.addPanel())
        let second = try XCTUnwrap(store.addPanel())
        XCTAssertEqual(store.configuration.panels.first { $0.id == first }?.title, FeatureL10n.format("面板 %lld", 1))
        XCTAssertEqual(store.configuration.panels.first { $0.id == second }?.title, FeatureL10n.format("面板 %lld", 2))
        var changed = try XCTUnwrap(store.configuration.panels.first { $0.id == first })
        changed.name = "  Work  "
        store.updatePanel(changed)
        let third = try XCTUnwrap(store.addPanel())
        let customNames = store.configuration.panels.filter { !$0.isDefault }.map(\.title)
        XCTAssertEqual(Set(customNames).count, 3)
        XCTAssertNotNil(store.configuration.panels.first { $0.id == third })
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.panels.first { $0.id == first }?.title, "Work")
        XCTAssertEqual(reloaded.configuration.panels.first { $0.id == second }?.title, FeatureL10n.format("面板 %lld", 2))
    }

    func testHiddenPanelRetainsAssignmentAndAtLeastOnePanelStaysVisible() throws {
        let id = try XCTUnwrap(store.addPanel())
        store.assign(pluginID: "one", surface: .dashboard, to: id)
        for var panel in store.configuration.panels {
            panel.isHidden = true
            store.updatePanel(panel)
        }
        XCTAssertEqual(store.configuration.panels.filter { !$0.isHidden }.count, 1)
        XCTAssertEqual(store.configuration.panelID(pluginID: "one", surface: .dashboard), id)
    }

    func testSurfaceOrdersRemainIndependentWithinMixedPanel() throws {
        let id = try XCTUnwrap(store.addPanel())
        for plugin in ["first", "second"] {
            for surface in PluginDisplaySurface.allCases { store.assign(pluginID: plugin, surface: surface, to: id) }
        }
        store.setOrder(["second", "first"], surface: .dashboard, panelID: id)
        store.setOrder(["first", "second"], surface: .featurePanel, panelID: id)
        XCTAssertEqual(
            store.configuration.orderedIDs(["first", "second"], surface: .dashboard, panelID: id), ["second", "first"])
        XCTAssertEqual(
            store.configuration.orderedIDs(["first", "second"], surface: .featurePanel, panelID: id),
            ["first", "second"])
        XCTAssertTrue(
            store.configuration.orderedIDs(["first", "second"], surface: .dashboard, panelID: "components").isEmpty)
    }

    func testReorderingVisibleEntriesPreservesRememberedHiddenSlots() {
        store.setOrder(["one", "hidden", "two"], surface: .dashboard, panelID: "components")
        store.setOrder(["two", "one"], surface: .dashboard, panelID: "components")
        XCTAssertEqual(
            store.configuration.orderedIDs(["one", "hidden", "two"], surface: .dashboard, panelID: "components"),
            ["two", "hidden", "one"])
    }

    func testUninstallClearsOnlyTheRemovedPluginsAssignments() throws {
        let panelID = try XCTUnwrap(store.addPanel())
        store.assign(pluginID: "one", surface: .dashboard, to: panelID)
        store.assign(pluginID: "two", surface: .dashboard, to: panelID)
        store.removePlugin(id: "one")
        XCTAssertEqual(store.configuration.panelID(pluginID: "one", surface: .dashboard), "components")
        XCTAssertEqual(store.configuration.panelID(pluginID: "two", surface: .dashboard), panelID)
    }

    func testInvalidAssignmentFallsBackAndMalformedDefaultsAreRepaired() {
        var configuration = MenuBarPanelConfiguration()
        configuration.panels = [.init(id: "custom", name: "  Work  ", systemImage: "", isHidden: true)]
        configuration.assignments = ["dashboard:missing": "deleted"]
        configuration.orders = ["custom": ["dashboard:one", "dashboard:one"]]
        store.replace(configuration)
        XCTAssertEqual(store.configuration.panels.count, 3)
        XCTAssertEqual(store.configuration.panels[0].name, "Work")
        XCTAssertEqual(store.configuration.orders["custom"], ["dashboard:one"])
        XCTAssertEqual(store.configuration.panelID(pluginID: "missing", surface: .dashboard), "components")
    }

    func testUnknownSchemaIsNotOverwrittenByPassiveRead() {
        let data = Data(#"{"version":99,"future":"value"}"#.utf8)
        defaults.set("swapped", forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey)
        defaults.set(data, forKey: MenuBarPanelStore.storageKey)
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.panels, MenuBarPanelDefinition.defaults)
        XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.storageKey), data)
    }

    func testConfigurationSurvivesBackupEncodingAndLegacyBackupRemainsReadable() throws {
        _ = store.addPanel()
        let backup = PluginDisplayPreferencesBackup(
            orderedPluginIDs: [], hiddenPluginIDs: [], panelConfiguration: store.configuration)
        let restored = try JSONDecoder().decode(PluginDisplayPreferencesBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(restored.panelConfiguration, store.configuration)
        let legacy = try JSONDecoder().decode(
            PluginDisplayPreferencesBackup.self, from: Data(#"{"orderedPluginIDs":[],"hiddenPluginIDs":[]}"#.utf8))
        XCTAssertNil(legacy.panelConfiguration)
    }
}
