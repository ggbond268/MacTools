import Foundation
import XCTest
@testable import MacTools

@MainActor
final class SettingsSidebarPreferencesStoreTests: XCTestCase {
    func testNameSortingIsTheDefaultAndUsesAvailableItems() throws {
        let defaults = try makeDefaults()
        let store = SettingsSidebarPreferencesStore(
            userDefaults: defaults,
            locale: { Locale(identifier: "en_US") }
        )
        let items = makeItems()

        XCTAssertEqual(store.sortMode, .nameAscending)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["audio", "battery", "calendar"])
    }

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

    func testDraggingFromNameOrderEnablesAndPersistsCustomOrder() throws {
        let defaults = try makeDefaults()
        let items = makeItems()
        var store = SettingsSidebarPreferencesStore(userDefaults: defaults)

        XCTAssertTrue(
            store.movePlugins(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 3,
                availableItems: items
            )
        )
        XCTAssertEqual(store.sortMode, .custom)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["battery", "calendar", "audio"])

        store = SettingsSidebarPreferencesStore(userDefaults: defaults)
        XCTAssertEqual(store.sortMode, .custom)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["battery", "calendar", "audio"])
    }

    func testLegacyNamePreferencesMigrateToAscendingNameOrder() throws {
        let defaults = try makeDefaults()
        for legacyMode in ["defaultOrder", "name"] {
            defaults.set(legacyMode, forKey: "settings.sidebar.pluginSortMode")
            let store = SettingsSidebarPreferencesStore(userDefaults: defaults)

            XCTAssertEqual(store.sortMode, .nameAscending)
            XCTAssertEqual(
                store.orderedPluginIDs(for: makeItems()),
                ["audio", "battery", "calendar"]
            )
        }
    }

    func testNameModesUseLocalizedTitlesAndNaturalNumericOrder() throws {
        let defaults = try makeDefaults()
        let store = SettingsSidebarPreferencesStore(
            userDefaults: defaults,
            locale: { Locale(identifier: "en_US") }
        )
        let items = [
            SettingsSidebarPluginOrderItem(
                id: "plugin-a",
                title: "Tool 10",
                installedAt: nil
            ),
            SettingsSidebarPluginOrderItem(
                id: "plugin-z",
                title: "Tool 2",
                installedAt: nil
            )
        ]

        XCTAssertEqual(store.orderedPluginIDs(for: items), ["plugin-z", "plugin-a"])

        store.setSortMode(.nameDescending, availableItems: items)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["plugin-a", "plugin-z"])
    }

    func testInstallationDateModesSupportBothDirectionsAndKeepUnknownDatesLast() throws {
        let defaults = try makeDefaults()
        let store = SettingsSidebarPreferencesStore(userDefaults: defaults)
        let items = [
            SettingsSidebarPluginOrderItem(
                id: "newest",
                title: "Newest",
                installedAt: Date(timeIntervalSince1970: 300)
            ),
            SettingsSidebarPluginOrderItem(
                id: "unknown",
                title: "Unknown",
                installedAt: nil
            ),
            SettingsSidebarPluginOrderItem(
                id: "oldest",
                title: "Oldest",
                installedAt: Date(timeIntervalSince1970: 100)
            )
        ]

        store.setSortMode(.installedOldestFirst, availableItems: items)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["oldest", "newest", "unknown"])

        store.setSortMode(.installedNewestFirst, availableItems: items)
        XCTAssertEqual(store.orderedPluginIDs(for: items), ["newest", "oldest", "unknown"])
    }

    func testSidebarFeatureStringsCoverEverySupportedLanguage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Sources/Resources/Localization/Settings.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let supportedLanguages = Set(
            AppLanguagePreference.allCases
                .filter { $0 != .system }
                .map(\.rawValue)
        )
        let keys = [
            "settings.sidebar.customizeSection",
            "settings.sidebar.shortcutAccessibilityHint",
            "settings.sidebar.pluginSearch.prompt",
            "settings.sidebar.pluginSearch.noResults",
            "settings.sidebar.pluginSearch.clear",
            "settings.sidebar.pluginSearch.resultCountFormat",
            "settings.sidebar.section.collapseFormat",
            "settings.sidebar.section.expandFormat",
            "settings.sidebar.pluginSortHelp",
            "settings.sidebar.pluginSort.installedOldestFirst",
            "settings.sidebar.pluginSort.installedNewestFirst",
            "settings.sidebar.pluginSort.nameAscending",
            "settings.sidebar.pluginSort.nameDescending",
            "settings.sidebar.pluginSort.custom",
            "settings.sidebar.pluginSort.resetCustom",
            "settings.sidebar.pluginSort.scopeNote",
        ]

        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLanguages, key)

            for language in supportedLanguages {
                let localization = try XCTUnwrap(
                    localizations[language] as? [String: Any],
                    "\(key) [\(language)]"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) [\(language)]"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "\(key) [\(language)]"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key) [\(language)]"
                )
            }
        }
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
