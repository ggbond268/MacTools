import MacToolsPluginKit
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

    private func key(_ plugin: String = "example", _ item: String = "control") -> PluginPanelItemKey {
        PluginPanelItemKey(pluginID: plugin, itemID: item)
    }

    func testDefaultsDoNotWriteUntilItemsAreDiscovered() {
        XCTAssertEqual(store.configuration.panels, MenuBarPanelDefinition.defaults)
        XCTAssertTrue(store.configuration.placementsByPanelID.isEmpty)
        XCTAssertNil(defaults.data(forKey: MenuBarPanelStore.storageKey))
    }

    func testLegacyDisabledMarkerWaitsForDiscoveryWithoutSuppressingFutureViews() {
        XCTAssertTrue(store.migrateLegacyHiddenPlugins(["example"]))
        XCTAssertTrue(store.configuration.initializedItems.isEmpty)
        store.reconcile([(key("example", "widget"), .dashboard)])
        XCTAssertTrue(store.configuration.placementsByPanelID.isEmpty)
        XCTAssertNil(store.configuration.legacySeed)
        store.reconcile([(key("example", "widget"), .dashboard), (key(), .featurePanel)])
        XCTAssertEqual(store.configuration.placementsByPanelID["features"]?.map(\.item), [key()])
    }

    func testMigrationRetiresLegacyStoreOnlyAfterBothNewStoresAreWritten() throws {
        let data = Data(#"{"version":1,"orderedPluginIDs":["example"],"hiddenPluginIDs":["example"]}"#.utf8)
        defaults.set(data, forKey: MenuBarPanelStore.legacyDisplayStorageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertNil(migrated.loadError)
        XCTAssertNotNil(defaults.data(forKey: MenuBarPanelStore.storageKey))
        XCTAssertEqual(defaults.stringArray(forKey: PluginOrderingStore.storageKey), ["example"])
        XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyDisplayStorageKey))
        XCTAssertEqual(migrated.configuration.legacySeed?.dashboardHidden, ["example"])
    }

    func testInitialPlacementIsAppliedOnceIncludingLibraryOnlyItems() throws {
        let row = key()
        let widget = key("example", "widget")
        XCTAssertTrue(store.reconcile([(row, .featurePanel), (widget, nil)]))
        let placement = try XCTUnwrap(store.configuration.placementsByPanelID["features"]?.first)
        XCTAssertEqual(placement.item, row)
        XCTAssertEqual(store.configuration.initializedItems, [row, widget])
        store.removePlacement(id: placement.id)
        XCTAssertFalse(store.reconcile([(row, .dashboard), (widget, .dashboard)]))
        XCTAssertTrue(store.configuration.placementsByPanelID.values.flatMap { $0 }.isEmpty)
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertFalse(reloaded.reconcile([(row, .featurePanel), (widget, .dashboard)]))
        XCTAssertEqual(reloaded.configuration.initializedItems, [row, widget])
    }

    func testNewItemSeedsWithoutRestoringRemovedItems() throws {
        store.reconcile([(key(), .featurePanel)])
        let placement = try XCTUnwrap(store.configuration.placementsByPanelID["features"]?.first)
        store.removePlacement(id: placement.id)
        store.reconcile([(key(), .featurePanel), (key("example", "statistics"), .dashboard)])
        XCTAssertEqual(store.configuration.placementsByPanelID["components"]?.map(\.item.itemID), ["statistics"])
        XCTAssertNil(store.configuration.placementsByPanelID["features"])
    }

    func testManualAdditionAcknowledgesDefaultAndCopiesHaveIndependentIDs() throws {
        let first = try XCTUnwrap(store.addItem(key(), to: "components"))
        let second = try XCTUnwrap(store.addItem(key(), to: "components"))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(store.reconcile([(key(), .featurePanel)]))
        store.movePlacement(id: first.id, to: "features", visibleOrder: [first.id])
        XCTAssertEqual(store.configuration.panelID(for: first.id), "features")
        XCTAssertEqual(store.configuration.panelID(for: second.id), "components")
        store.removePlacement(id: first.id)
        XCTAssertEqual(store.configuration.placementsByPanelID["components"], [second])
    }

    func testReorderPreservesUnavailableSlotsAcrossRelaunch() throws {
        let first = try XCTUnwrap(store.addItem(key("first"), to: "features"))
        let missing = try XCTUnwrap(store.addItem(key("missing"), to: "features"))
        let last = try XCTUnwrap(store.addItem(key("last"), to: "features"))
        store.setOrder([last.id, first.id], panelID: "features")
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["features"], [last, missing, first])
    }

    func testDeletingCustomPanelPreservesEveryPlacementAndSelectionFallsBack() throws {
        let panel = try XCTUnwrap(store.addPanel())
        let row = try XCTUnwrap(store.addItem(key(), to: panel))
        let missing = try XCTUnwrap(store.addItem(key("missing", "widget"), to: panel))
        store.rememberSelection(id: panel)
        store.deletePanel(id: panel)
        XCTAssertEqual(store.configuration.placementsByPanelID["components"], [row, missing])
        XCTAssertEqual(store.lastSelectedPanelID, "components")
        store.deletePanel(id: "components")
        XCTAssertTrue(store.configuration.panels.contains { $0.id == "components" })
    }

    func testPanelLimitsAndMetadataSurviveReload() throws {
        let id = try XCTUnwrap(store.addPanel())
        XCTAssertNotNil(store.addPanel())
        XCTAssertNotNil(store.addPanel())
        XCTAssertNil(store.addPanel())
        var panel = try XCTUnwrap(store.configuration.panels.first { $0.id == id })
        panel.name = " Custom "
        panel.systemImage = "heart"
        store.updatePanel(panel)
        store.movePanel(id: id, toOffset: 0)
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.configuration.panels.first?.id, id)
        XCTAssertEqual(reloaded.configuration.panels.first?.name, "Custom")
        XCTAssertEqual(reloaded.configuration.panels.first?.systemImage, "heart")
    }

    func testSelectionDoesNotMutatePortableLayout() throws {
        let custom = try XCTUnwrap(store.addPanel())
        let before = defaults.data(forKey: MenuBarPanelStore.storageKey)
        store.rememberSelection(id: custom)
        store.rememberSelection(id: "missing")
        XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.storageKey), before)
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).lastSelectedPanelID, custom)
    }

    func testFutureAndCorruptPayloadsArePreservedUntilExplicitReset() throws {
        for data in [Data(#"{"version":99,"panels":[]}"#.utf8), Data("not JSON".utf8)] {
            defaults.set(data, forKey: MenuBarPanelStore.storageKey)
            let unreadable = MenuBarPanelStore(userDefaults: defaults)
            XCTAssertNotNil(unreadable.loadError)
            XCTAssertFalse(unreadable.reconcile([(key(), .featurePanel)]))
            XCTAssertNil(unreadable.addPanel())
            XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.storageKey), data)
            XCTAssertTrue(unreadable.replace(MenuBarPanelConfiguration(), replacingUnreadable: true))
            XCTAssertNil(unreadable.loadError)
        }
    }

    func testExplicitReplacementRetiresUnreadableLegacyDataAcrossRelaunch() throws {
        for data in [Data("not JSON".utf8), Data(#"{"version":99}"#.utf8)] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(data, forKey: MenuBarPanelStore.legacyDisplayStorageKey)
            defaults.set("swapped", forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey)
            let unreadable = MenuBarPanelStore(userDefaults: defaults)
            XCTAssertNotNil(unreadable.loadError)
            XCTAssertNil(unreadable.addPanel())
            XCTAssertEqual(defaults.data(forKey: MenuBarPanelStore.legacyDisplayStorageKey), data)

            var replacement = MenuBarPanelConfiguration()
            let placement = MenuBarPanelPlacement(item: key())
            replacement.placementsByPanelID["features"] = [placement]
            XCTAssertTrue(unreadable.replace(replacement, replacingUnreadable: true))
            XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyDisplayStorageKey))
            XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyClickBehaviorStorageKey))
            let reloaded = MenuBarPanelStore(userDefaults: defaults)
            XCTAssertNil(reloaded.loadError)
            XCTAssertEqual(reloaded.configuration.placementsByPanelID["features"], [placement])
            XCTAssertNotNil(reloaded.addPanel())
        }
    }

    func testExplicitResetPreservesReadableManagementOrder() throws {
        let existingOrders: [[String]?] = [nil, ["current"]]
        for existingOrder in existingOrders {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(Data("not JSON".utf8), forKey: MenuBarPanelStore.storageKey)
            defaults.set(Data(#"{"version":1,"orderedPluginIDs":["legacy"]}"#.utf8),
                         forKey: MenuBarPanelStore.legacyDisplayStorageKey)
            if let existingOrder { defaults.set(existingOrder, forKey: PluginOrderingStore.storageKey) }
            let unreadable = MenuBarPanelStore(userDefaults: defaults)
            XCTAssertTrue(unreadable.replace(MenuBarPanelConfiguration(), replacingUnreadable: true))
            XCTAssertEqual(defaults.stringArray(forKey: PluginOrderingStore.storageKey), existingOrder ?? ["legacy"])
            XCTAssertNil(defaults.object(forKey: MenuBarPanelStore.legacyDisplayStorageKey))
            XCTAssertNil(MenuBarPanelStore(userDefaults: defaults).loadError)
        }
    }

    func testMigrationPreservesMixedOrderCopiesAndMissingPlugins() throws {
        let copyID = UUID()
        let legacy: [String: Any] = [
            "version": 2,
            "panels": [
                ["id": "components", "name": "", "systemImage": "square.grid.2x2", "isHidden": false],
                ["id": "features", "name": "", "systemImage": "switch.2", "isHidden": false],
                ["id": "custom", "name": "Custom", "systemImage": "star", "isHidden": false],
            ],
            "assignments": ["dashboard:missing": "custom", "featurePanel:row": "custom",
                            "instance:\(copyID.uuidString)": "custom"],
            "orders": ["custom": ["featurePanel:row", "dashboard:missing", "instance:\(copyID.uuidString)"]],
            "instances": [["pluginID": "missing", "surface": "dashboard", "instanceID": copyID.uuidString]],
            "removedDefaultEntries": ["featurePanel:removed"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: MenuBarPanelStore.storageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        let placements = try XCTUnwrap(migrated.configuration.placementsByPanelID["custom"])
        XCTAssertEqual(placements.map(\.item), [key("row"), key("missing", "widget"), key("missing", "widget")])
        XCTAssertEqual(placements.last?.id, copyID)
        XCTAssertTrue(migrated.configuration.initializedItems.contains(key("removed")))
        XCTAssertFalse(migrated.reconcile([(key("removed"), .featurePanel)]))
        XCTAssertEqual(MenuBarPanelStore(userDefaults: defaults).configuration, migrated.configuration)
    }

    func testSharedLegacyOrderWaitsForCapabilitiesWithoutInventingViews() throws {
        let legacy: [String: Any] = ["orderedPluginIDs": ["later", "first", "hidden"], "hiddenPluginIDs": ["hidden"]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: MenuBarPanelStore.legacyDisplayStorageKey)
        let migrated = MenuBarPanelStore(userDefaults: defaults)
        migrated.reconcile([(key("first"), .featurePanel), (key("hidden"), .featurePanel)])
        XCTAssertEqual(migrated.configuration.placementsByPanelID["features"]?.map(\.item.pluginID), ["first"])
        XCTAssertFalse(migrated.configuration.initializedItems.contains(key("first", "widget")))
        let reloaded = MenuBarPanelStore(userDefaults: defaults)
        reloaded.reconcile([(key("later"), .featurePanel)])
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["features"]?.map(\.item.pluginID), ["later", "first"])
        XCTAssertNil(reloaded.configuration.legacySeed)
        reloaded.reconcile([(key("first", "widget"), .dashboard)])
        XCTAssertEqual(reloaded.configuration.placementsByPanelID["components"]?.map(\.item), [key("first", "widget")])
    }

    func testOldBackupCombinesPanelAssignmentWithSurfaceVisibility() throws {
        let json = Data(#"""
        {
          "orderedPluginIDs":["hidden","shown"],
          "hiddenPluginIDs":[],
          "dashboardHiddenPluginIDs":["hidden"],
          "featurePanelHiddenPluginIDs":[],
          "dashboardOrderedPluginIDs":["hidden","shown"],
          "featurePanelOrderedPluginIDs":[],
          "panelConfiguration":{
            "version":2,
            "panels":[{"id":"components","name":"","systemImage":"star","isHidden":false}],
            "assignments":{},
            "orders":{"components":["dashboard:hidden","dashboard:shown"]},
            "instances":[],
            "removedDefaultEntries":[]
          }
        }
        """#.utf8)
        let backup = try JSONDecoder().decode(PluginDisplayPreferencesBackup.self, from: json)
        XCTAssertEqual(backup.panelConfiguration?.placementsByPanelID["components"]?.map(\.item.pluginID), ["shown"])
        XCTAssertTrue(backup.panelConfiguration?.initializedItems.contains(key("hidden", "widget")) == true)
    }

    func testNewBackupEncodesOnlyCanonicalLayoutAndManagementOrder() throws {
        store.reconcile([(key(), .featurePanel)])
        let backup = PluginDisplayPreferencesBackup(orderedPluginIDs: ["example"], hiddenPluginIDs: [],
                                                   panelConfiguration: store.configuration)
        let data = try JSONEncoder().encode(backup)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["orderedPluginIDs", "panelConfiguration"])
        let restored = try JSONDecoder().decode(PluginDisplayPreferencesBackup.self, from: data)
        XCTAssertEqual(restored.panelConfiguration, store.configuration)
    }

    func testNormalizationPreservesMissingContainerEntriesAndDeduplicatesIDs() {
        let placement = MenuBarPanelPlacement(item: key())
        var configuration = MenuBarPanelConfiguration()
        configuration.placementsByPanelID = ["missing": [placement], "features": [placement]]
        let normalized = configuration.normalized()
        XCTAssertEqual(normalized.placementsByPanelID.values.flatMap { $0 }, [placement])
        XCTAssertTrue(normalized.initializedItems.contains(key()))
    }
}
