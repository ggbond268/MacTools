import XCTest
@testable import MacTools

final class PluginMarketplaceSortModeTests: XCTestCase {
    func testPersistedRawValuesRemainStableForUserDefaults() {
        XCTAssertEqual(PluginMarketplaceSortMode.notInstalledFirst.rawValue, "statusThenName")
        XCTAssertEqual(PluginMarketplaceSortMode.installedFirst.rawValue, "installedThenName")
        XCTAssertEqual(PluginMarketplaceSortMode.nameAscending.rawValue, "nameAscending")
        XCTAssertEqual(PluginMarketplaceSortMode.nameDescending.rawValue, "nameDescending")
        XCTAssertEqual(
            PluginMarketplaceSortMode(rawValue: "statusThenName"),
            .notInstalledFirst
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode(rawValue: "installedThenName"),
            .installedFirst
        )
    }

    func testAllCasesOrderMatchesPickerOrder() {
        XCTAssertEqual(
            PluginMarketplaceSortMode.allCases,
            [
                .notInstalledFirst,
                .installedFirst,
                .nameAscending,
                .nameDescending
            ]
        )
    }

    func testNotInstalledFirstSortRankOrdersInstallableBeforeInstalled() {
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "a", title: "A", state: .available)),
            0
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "b", title: "B", state: .localDevelopment)),
            0
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(
                for: makeItem(
                    id: "c",
                    title: "C",
                    state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "1.1.0")
                )
            ),
            1
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "d", title: "D", state: .restartRequired)),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "e", title: "E", state: .failed("x"))),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "f", title: "F", state: .incompatible("old"))),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "g", title: "G", state: .revoked("gone"))),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "h", title: "H", state: .enabled)),
            3
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.notInstalledFirstSortRank(for: makeItem(id: "i", title: "I", state: .disabled)),
            3
        )
    }

    func testInstalledFirstSortRankPrioritizesUpdatesAndIssues() {
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(
                for: makeItem(
                    id: "u",
                    title: "U",
                    state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "1.1.0")
                )
            ),
            0
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(for: makeItem(id: "f", title: "F", state: .failed("x"))),
            1
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(for: makeItem(id: "e", title: "E", state: .enabled)),
            2
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.installedFirstSortRank(for: makeItem(id: "a", title: "A", state: .available)),
            3
        )
    }

    func testNotInstalledFirstGroupsByStatusThenSortsByTitle() {
        let sortedIDs = PluginMarketplaceSortMode.sorted(sampleStatusItems(), by: .notInstalledFirst).map(\.id)

        XCTAssertEqual(
            sortedIDs,
            [
                "available-a",
                "available-b",
                "update-a",
                "failed",
                "installed-a",
                "installed-z"
            ]
        )
    }

    func testInstalledFirstPrioritizesUpdatesThenIssuesThenInstalledThenAvailable() {
        let sortedIDs = PluginMarketplaceSortMode.sorted(sampleStatusItems(), by: .installedFirst).map(\.id)

        XCTAssertEqual(
            sortedIDs,
            [
                "update-a",
                "failed",
                "installed-a",
                "installed-z",
                "available-a",
                "available-b"
            ]
        )
    }

    func testNameAscendingAndDescendingIgnoreInstallStatus() {
        let items = [
            makeItem(id: "c", title: "Charlie", state: .enabled),
            makeItem(id: "a", title: "Alpha", state: .available),
            makeItem(id: "b", title: "Bravo", state: .updateAvailable(installedVersion: "1", catalogVersion: "2"))
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending).map(\.id),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameDescending).map(\.id),
            ["c", "b", "a"]
        )
    }

    func testNameSortUsesSimplifiedChineseCollation() {
        let items = [
            makeItem(id: "calendar", title: "日历", state: .available),
            makeItem(id: "fan-control", title: "风扇控制", state: .available),
            makeItem(id: "stage-manager", title: "台前调度", state: .available),
            makeItem(id: "right-click", title: "右键工具", state: .available),
            makeItem(id: "battery-limit", title: "电池充电上限", state: .available),
            makeItem(id: "auto-hide-dock", title: "自动隐藏程序坞", state: .available)
        ]
        let locale = Locale(identifier: "zh-Hans")

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending, locale: locale).map(\.id),
            ["battery-limit", "fan-control", "calendar", "stage-manager", "right-click", "auto-hide-dock"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameDescending, locale: locale).map(\.id),
            ["auto-hide-dock", "right-click", "stage-manager", "calendar", "fan-control", "battery-limit"]
        )
    }

    func testNameSortUsesJapaneseCollation() {
        let items = [
            makeItem(id: "right-click", title: "右クリック", state: .available),
            makeItem(id: "lock-screen", title: "画面をロック", state: .available),
            makeItem(id: "fix-damaged-app", title: "破損したアプリを修復", state: .available),
            makeItem(id: "launch-control", title: "起動項目", state: .available),
            makeItem(id: "translator", title: "翻訳", state: .available)
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending, locale: Locale(identifier: "ja")).map(\.id),
            ["right-click", "lock-screen", "launch-control", "fix-damaged-app", "translator"]
        )
    }

    func testNameSortSupportsEveryFixedAppLanguage() {
        let items = [
            makeItem(id: "calendar", title: "Calendar", state: .available),
            makeItem(id: "eject-disk", title: "Éjecter", state: .available),
            makeItem(id: "appearance", title: "Ändern", state: .available),
            makeItem(id: "battery-limit", title: "Батарея", state: .available),
            makeItem(id: "chinese-calendar", title: "日历", state: .available),
            makeItem(id: "japanese-calendar", title: "カレンダー", state: .available),
            makeItem(id: "korean-calendar", title: "달력", state: .available),
            makeItem(id: "arabic-calendar", title: "التقويم", state: .available)
        ]
        let fixedLanguages = AppLanguagePreference.allCases.filter { $0 != .system }

        for language in fixedLanguages {
            let locale = Locale(identifier: language.rawValue)
            let ascending = PluginMarketplaceSortMode.sorted(items, by: .nameAscending, locale: locale).map(\.id)
            let descending = PluginMarketplaceSortMode.sorted(items, by: .nameDescending, locale: locale).map(\.id)

            XCTAssertEqual(Set(ascending), Set(items.map(\.id)), "Missing item for \(language.rawValue)")
            XCTAssertEqual(descending, ascending.reversed(), "Descending order for \(language.rawValue)")
        }
    }

    func testNameSortUsesIDAsStableTieBreaker() {
        let items = [
            makeItem(id: "plugin-b", title: "Same", state: .available),
            makeItem(id: "plugin-a", title: "Same", state: .enabled)
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameAscending).map(\.id),
            ["plugin-a", "plugin-b"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .nameDescending).map(\.id),
            ["plugin-b", "plugin-a"]
        )
    }

    func testStatusModesStillGroupAcrossAlphabeticalCatalogOrder() {
        let items = [
            makeItem(id: "zebra-installed", title: "Zebra", state: .enabled),
            makeItem(id: "apple-available", title: "Apple", state: .available),
            makeItem(
                id: "mango-update",
                title: "Mango",
                state: .updateAvailable(installedVersion: "1", catalogVersion: "2")
            )
        ]

        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .notInstalledFirst).map(\.id),
            ["apple-available", "mango-update", "zebra-installed"]
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.sorted(items, by: .installedFirst).map(\.id),
            ["mango-update", "zebra-installed", "apple-available"]
        )
    }

    func testCompareIsSymmetricForDistinctRanks() {
        let available = makeItem(id: "a", title: "A", state: .available)
        let enabled = makeItem(id: "e", title: "E", state: .enabled)

        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(available, enabled, mode: .notInstalledFirst),
            .orderedAscending
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(enabled, available, mode: .notInstalledFirst),
            .orderedDescending
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(enabled, available, mode: .installedFirst),
            .orderedAscending
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(available, enabled, mode: .installedFirst),
            .orderedDescending
        )
    }

    func testNameComparePreservesOrderedSameWhenTitleAndIDMatch() {
        let item = makeItem(id: "same-id", title: "Same", state: .available)
        let duplicate = makeItem(id: "same-id", title: "Same", state: .enabled)

        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(item, duplicate, mode: .nameAscending),
            .orderedSame
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(item, duplicate, mode: .nameDescending),
            .orderedSame
        )
        XCTAssertEqual(
            PluginMarketplaceSortMode.compare(duplicate, item, mode: .nameDescending),
            .orderedSame
        )
    }

    private func sampleStatusItems() -> [PluginManagementItem] {
        [
            makeItem(id: "installed-z", title: "Zeta", state: .enabled),
            makeItem(id: "available-b", title: "Beta", state: .available),
            makeItem(
                id: "update-a",
                title: "Alpha Update",
                state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0")
            ),
            makeItem(id: "available-a", title: "Alpha", state: .available),
            makeItem(id: "failed", title: "Failed", state: .failed("boom")),
            makeItem(id: "installed-a", title: "Alpha Installed", state: .disabled)
        ]
    }

    private func makeItem(
        id: String,
        title: String,
        state: PluginManagementItem.State
    ) -> PluginManagementItem {
        PluginManagementItem(
            id: id,
            title: title,
            summary: nil,
            version: "1.0.0",
            state: state,
            packageURL: nil,
            requiresRestartToFullyUnload: false,
            releaseNotesURL: nil,
            category: "system"
        )
    }
}
