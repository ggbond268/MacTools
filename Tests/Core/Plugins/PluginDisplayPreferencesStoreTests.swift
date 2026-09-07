import Foundation
import XCTest
@testable import MacTools

@MainActor
final class PluginDisplayPreferencesStoreTests: XCTestCase {
    private struct LegacyPreferences: Codable {
        let orderedPluginIDs: [String]
        let hiddenPluginIDs: Set<String>
    }

    private struct FuturePreferences: Codable {
        let version: Int
        let generalPluginOrder: [String]
        let futureOnlyValue: String
    }

    private struct FuturePreferencesWithLegacyKeys: Codable {
        let version: Int
        let orderedPluginIDs: [String]
        let hiddenPluginIDs: Set<String>
        let futureOnlyValue: String
    }

    private struct VersionTwoPreferences: Codable {
        let version: Int
        let generalPluginOrder: [String]
        let globallyHiddenPluginIDs: Set<String>
        let dashboardOrderedPluginIDs: [String]
        let featurePanelOrderedPluginIDs: [String]
        let isDashboardOrderInitialized: Bool
        let isFeaturePanelOrderInitialized: Bool
    }

    private struct VersionThreePreferences: Codable {
        let version: Int
        let generalPluginOrder: [String]
        let dashboardOrderedPluginIDs: [String]
        let featurePanelOrderedPluginIDs: [String]
        let isDashboardOrderInitialized: Bool
        let isFeaturePanelOrderInitialized: Bool
        let pendingLegacyDisabledPluginIDs: Set<String>
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: PluginDisplayPreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "PluginDisplayPreferencesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = PluginDisplayPreferencesStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testVersionOneMigrationPreservesOrderAndMapsHiddenPluginsToEachSurface() throws {
        try storeLegacyPreferences(
            order: ["display", "activity", "calendar"],
            hidden: ["activity"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(defaultPluginIDs: ["calendar", "display", "activity"]),
            ["display", "activity", "calendar"]
        )
        XCTAssertEqual(
            store.visiblePluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["calendar"]
        )
        XCTAssertEqual(
            store.hiddenPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "calendar"]),
            ["activity"]
        )
    }

    func testVersionTwoMigrationPreservesIndependentOrdersAndMapsGlobalHiddenPlugins() throws {
        let data = try JSONEncoder().encode(
            VersionTwoPreferences(
                version: 2,
                generalPluginOrder: ["calendar", "activity"],
                globallyHiddenPluginIDs: ["activity"],
                dashboardOrderedPluginIDs: ["activity", "calendar"],
                featurePanelOrderedPluginIDs: ["calendar", "activity"],
                isDashboardOrderInitialized: true,
                isFeaturePanelOrderInitialized: true
            )
        )
        defaults.set(data, forKey: "plugin.display.preferences")

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["calendar", "activity"]),
            ["activity", "calendar"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: ["calendar", "activity"]),
            ["calendar", "activity"]
        )
        XCTAssertEqual(
            store.hiddenPluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["activity"]
        )
        XCTAssertEqual(
            store.hiddenPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "calendar"]),
            ["activity"]
        )
    }

    func testVersionThreeMigrationMapsMigrationQueueToBothSurfaces() throws {
        let data = try JSONEncoder().encode(
            VersionThreePreferences(
                version: 3,
                generalPluginOrder: ["calendar", "activity"],
                dashboardOrderedPluginIDs: ["activity", "calendar"],
                featurePanelOrderedPluginIDs: ["calendar", "activity"],
                isDashboardOrderInitialized: true,
                isFeaturePanelOrderInitialized: true,
                pendingLegacyDisabledPluginIDs: ["activity"]
            )
        )
        defaults.set(data, forKey: "plugin.display.preferences")

        XCTAssertEqual(
            store.hiddenPluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["activity"]
        )
        XCTAssertEqual(
            store.hiddenPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "calendar"]),
            ["activity"]
        )
    }

    func testLegacyOrderSeedsEachSurfaceByCapabilityFilteredDefaults() throws {
        try storeLegacyPreferences(
            order: ["display", "activity", "calendar", "fan", "status"],
            hidden: []
        )

        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["activity", "calendar", "status"]
            ),
            ["activity", "calendar", "status"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .featurePanel,
                defaultPluginIDs: ["display", "activity", "fan"]
            ),
            ["display", "activity", "fan"]
        )
    }

    func testDeferredPluginLoadingDoesNotConsumeLegacySurfaceMigration() throws {
        try storeLegacyPreferences(
            order: ["display", "activity", "calendar"],
            hidden: []
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: []),
            []
        )
        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["activity", "calendar"]
            ),
            ["activity", "calendar"]
        )
    }

    func testSurfaceOrdersAreIndependent() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["activity", "calendar"]
        )
        store.setOrderedPluginIDs(
            ["fan", "activity"],
            for: .featurePanel,
            defaultPluginIDs: ["activity", "fan"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["calendar", "activity"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "fan"]),
            ["fan", "activity"]
        )
    }

    func testNewPluginsAppendInDefaultOrder() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["activity", "calendar"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["activity", "calendar", "status"]
            ),
            ["calendar", "activity", "status"]
        )
    }

    func testTemporarilyMissingPluginOrderRemainsRecoverable() {
        store.setOrderedPluginIDs(
            ["first", "missing", "second"],
            for: .dashboard,
            defaultPluginIDs: ["first", "missing", "second"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["first", "second"]),
            ["first", "second"]
        )

        store.setOrderedPluginIDs(
            ["second", "first"],
            for: .dashboard,
            defaultPluginIDs: ["first", "second"]
        )

        XCTAssertEqual(
            store.orderedPluginIDs(
                for: .dashboard,
                defaultPluginIDs: ["first", "missing", "second"]
            ),
            ["second", "missing", "first"]
        )
    }

    func testCorruptDataFallsBackToCapabilityFilteredDefaults() {
        let invalidData = Data("not-json".utf8)
        defaults.set(invalidData, forKey: "plugin.display.preferences")

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["calendar", "status"]),
            ["calendar", "status"]
        )
        XCTAssertEqual(defaults.data(forKey: "plugin.display.preferences"), invalidData)
    }

    func testUnknownFutureVersionFallsBackWithoutDeletingStoredPayload() throws {
        let futureData = try JSONEncoder().encode(
            FuturePreferences(
                version: 99,
                generalPluginOrder: ["future"],
                futureOnlyValue: "preserve-me"
            )
        )
        defaults.set(futureData, forKey: "plugin.display.preferences")

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["calendar", "status"]),
            ["calendar", "status"]
        )
        XCTAssertEqual(defaults.data(forKey: "plugin.display.preferences"), futureData)
    }

    func testResettingOneSurfaceDoesNotAffectTheOther() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["activity", "calendar"]
        )
        store.setOrderedPluginIDs(
            ["fan", "activity"],
            for: .featurePanel,
            defaultPluginIDs: ["activity", "fan"]
        )
        store.resetOrder(for: .dashboard, defaultPluginIDs: ["activity", "calendar"])

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: ["activity", "calendar"]),
            ["activity", "calendar"]
        )
        XCTAssertEqual(
            store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: ["activity", "fan"]),
            ["fan", "activity"]
        )
    }

    func testVisibilityIsIndependentForEachSurface() {
        store.setOrderedPluginIDs(
            ["calendar", "activity"],
            for: .dashboard,
            defaultPluginIDs: ["calendar", "activity"]
        )
        store.setPluginVisible(
            false,
            pluginID: "activity",
            on: .dashboard,
            defaultPluginIDs: ["calendar", "activity"]
        )

        XCTAssertEqual(
            store.visiblePluginIDs(for: .dashboard, defaultPluginIDs: ["calendar", "activity"]),
            ["calendar"]
        )
        XCTAssertEqual(
            store.visiblePluginIDs(for: .featurePanel, defaultPluginIDs: ["calendar", "activity"]),
            ["calendar", "activity"]
        )
    }

    func testReorderingVisiblePluginsPreservesHiddenPluginSlot() {
        let pluginIDs = ["first", "hidden", "second"]
        store.setOrderedPluginIDs(pluginIDs, for: .dashboard, defaultPluginIDs: pluginIDs)
        store.setPluginVisible(false, pluginID: "hidden", on: .dashboard, defaultPluginIDs: pluginIDs)

        store.setVisiblePluginIDs(["second", "first"], for: .dashboard, defaultPluginIDs: pluginIDs)

        XCTAssertEqual(
            store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: pluginIDs),
            ["second", "hidden", "first"]
        )
        store.setPluginVisible(true, pluginID: "hidden", on: .dashboard, defaultPluginIDs: pluginIDs)
        XCTAssertEqual(
            store.visiblePluginIDs(for: .dashboard, defaultPluginIDs: pluginIDs),
            ["second", "hidden", "first"]
        )
    }

    func testSetDashboardPluginOrderAndSetFeaturePanelPluginOrder() {
        let defaultIDs = ["a", "b", "c"]
        store.setDashboardPluginOrder(["c", "b", "a"], defaultPluginIDs: defaultIDs)
        XCTAssertEqual(store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), ["c", "b", "a"])
        XCTAssertEqual(store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: defaultIDs), ["a", "b", "c"])

        store.setFeaturePanelPluginOrder(["b", "c", "a"], defaultPluginIDs: defaultIDs)
        XCTAssertEqual(store.orderedPluginIDs(for: .featurePanel, defaultPluginIDs: defaultIDs), ["b", "c", "a"])
        XCTAssertEqual(store.orderedPluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), ["c", "b", "a"])
    }

    func testSetDashboardPluginVisibleAndSetFeaturePanelPluginVisible() {
        let defaultIDs = ["a", "b", "c"]
        store.setDashboardPluginVisible(false, pluginID: "b", defaultPluginIDs: defaultIDs)
        XCTAssertEqual(store.visiblePluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), ["a", "c"])
        XCTAssertEqual(store.hiddenPluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), ["b"])
        XCTAssertEqual(store.visiblePluginIDs(for: .featurePanel, defaultPluginIDs: defaultIDs), ["a", "b", "c"])

        store.setFeaturePanelPluginVisible(false, pluginID: "a", defaultPluginIDs: defaultIDs)
        XCTAssertEqual(store.visiblePluginIDs(for: .featurePanel, defaultPluginIDs: defaultIDs), ["b", "c"])
        XCTAssertEqual(store.hiddenPluginIDs(for: .featurePanel, defaultPluginIDs: defaultIDs), ["a"])
        XCTAssertEqual(store.visiblePluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), ["a", "c"])

        store.setDashboardPluginVisible(true, pluginID: "b", defaultPluginIDs: defaultIDs)
        XCTAssertEqual(store.visiblePluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), ["a", "b", "c"])
        XCTAssertEqual(store.hiddenPluginIDs(for: .dashboard, defaultPluginIDs: defaultIDs), [])
    }

    private func storeLegacyPreferences(order: [String], hidden: Set<String>) throws {
        let data = try JSONEncoder().encode(
            LegacyPreferences(orderedPluginIDs: order, hiddenPluginIDs: hidden)
        )
        defaults.set(data, forKey: "plugin.display.preferences")
    }
}
