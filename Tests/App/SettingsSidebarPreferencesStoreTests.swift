import Foundation
import XCTest
@testable import MacTools

@MainActor
final class SettingsSidebarPreferencesStoreTests: XCTestCase {

    func testCustomModeSeedsCurrentSortAndPersistsMoves() throws {
        let defaults = try makeDefaults()
        let items = makeItems()
        var store = SettingsSidebarPreferencesStore(userDefaults: defaults)
        store.setSortMode(.nameAscending, availableItems: items)
        store.setSortMode(.custom, availableItems: items)

        XCTAssertEqual(store.orderedPluginIDs(for: items), ["audio", "battery", "calendar"])
        XCTAssertTrue(
            store.movePlugins(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 3,
                availableItems: items
            )
        )
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["battery", "calendar", "audio"])

        store = SettingsSidebarPreferencesStore(userDefaults: defaults)
        XCTAssertEqual(store.sortMode, .custom)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["battery", "calendar", "audio"])
    }

    func testCustomOrderPreservesUnavailableIDsWhileReorderingVisibleItems() throws {
        let defaults = try makeDefaults()
        defaults.set(SettingsSidebarPluginSortMode.custom.rawValue, forKey: "settings.sidebar.pluginSortMode")
        defaults.set(["removed", "battery", "calendar"], forKey: "settings.sidebar.customPluginOrder")
        let store = SettingsSidebarPreferencesStore(userDefaults: defaults)
        let availableItems = makeItems()

        XCTAssertEqual(
            store.orderedPluginIDs(for: availableItems),
            ["battery", "calendar", "audio"]
        )
        XCTAssertTrue(
            store.movePlugins(
                fromOffsets: IndexSet(integer: 2),
                toOffset: 0,
                availableItems: availableItems
            )
        )
        XCTAssertEqual(
            store.customOrderedPluginIDs,
            ["removed", "audio", "battery", "calendar"]
        )

        let restoredItems = availableItems + [
            SettingsSidebarPluginOrderItem(
                id: "removed",
                title: "Restored",
                installedAt: nil
            )
        ]
        XCTAssertEqual(
            store.orderedPluginIDs(for: restoredItems),
            ["removed", "audio", "battery", "calendar"]
        )
    }

    func testSwitchingSortModesPreservesCustomOrderUntilReset() throws {
        let defaults = try makeDefaults()
        let items = makeItems()
        let store = SettingsSidebarPreferencesStore(userDefaults: defaults)
        store.setSortMode(.custom, availableItems: items)
        XCTAssertTrue(
            store.movePlugins(
                fromOffsets: IndexSet(integer: 2),
                toOffset: 0,
                availableItems: items
            )
        )

        store.setSortMode(.nameAscending, availableItems: items)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["audio", "battery", "calendar"])
        store.setSortMode(.custom, availableItems: items)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["calendar", "audio", "battery"])

        store.resetCustomOrder()
        XCTAssertEqual(store.sortMode, .nameAscending)
        XCTAssertTrue(store.customOrderedPluginIDs.isEmpty)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["audio", "battery", "calendar"])
    }

    private func makeItems() -> [SettingsSidebarPluginOrderItem] {
        [
            SettingsSidebarPluginOrderItem(
                id: "calendar",
                title: "Calendar",
                installedAt: Date(timeIntervalSince1970: 300)
            ),
            SettingsSidebarPluginOrderItem(
                id: "battery",
                title: "Battery",
                installedAt: Date(timeIntervalSince1970: 100)
            ),
            SettingsSidebarPluginOrderItem(
                id: "audio",
                title: "Audio",
                installedAt: Date(timeIntervalSince1970: 200)
            )
        ]
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SettingsSidebarPreferencesStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
