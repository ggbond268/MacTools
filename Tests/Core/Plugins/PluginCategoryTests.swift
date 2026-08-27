import XCTest
import MacToolsPluginKit
@testable import MacTools

final class PluginCategoryTests: XCTestCase {
    func testInitFromRawStringFallsBackToOther() {
        XCTAssertEqual(PluginCategory(rawString: nil), .other)
        XCTAssertEqual(PluginCategory(rawString: ""), .other)
        XCTAssertEqual(PluginCategory(rawString: "unknown-bucket"), .other)
    }

    func testOrderedCasesPlacesOtherLast() {
        let ordered = PluginCategory.orderedCases
        XCTAssertEqual(ordered.last, .other)
        XCTAssertEqual(ordered.first, .display)
    }
}

final class PluginCategoryFilterTests: XCTestCase {
    func testUnknownCategoryFallsIntoOther() {
        let otherFilter = PluginCategoryFilter.category(.other)

        XCTAssertTrue(otherFilter.contains(category: nil))
        XCTAssertTrue(otherFilter.contains(category: "not-a-real-category"))
        XCTAssertFalse(otherFilter.contains(category: "display"))
    }
}

final class PluginListFilterTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(PluginListFilter.matches(query: "", in: ["foo", "bar"]))
        XCTAssertTrue(PluginListFilter.matches(query: "  ", in: ["foo", "bar"]))
    }

    func testQueryMatchesIsCaseInsensitive() {
        XCTAssertTrue(PluginListFilter.matches(query: "ABC", in: ["xyz", "abcdef"]))
        XCTAssertFalse(PluginListFilter.matches(query: "abc", in: ["xyz", "no match"]))
    }

    func testManagementItemMatchesByTitleSummaryAndCategory() {
        let item = makeManagementItem(
            id: "keep-awake",
            title: "阻止休眠",
            summary: "阻止系统空闲休眠",
            category: "system"
        )

        XCTAssertTrue(PluginListFilter.matches(managementItem: item, query: "休眠", filter: .all))
        XCTAssertTrue(PluginListFilter.matches(managementItem: item, query: "Keep", filter: .all))
        XCTAssertTrue(PluginListFilter.matches(managementItem: item, query: "系统", filter: .all))
        XCTAssertFalse(PluginListFilter.matches(managementItem: item, query: "音频", filter: .all))
    }

    func testManagementItemRespectsCategoryFilter() {
        let item = makeManagementItem(
            id: "keep-awake",
            title: "阻止休眠",
            summary: "阻止系统空闲休眠",
            category: "system"
        )

        XCTAssertTrue(PluginListFilter.matches(managementItem: item, query: "", filter: .category(.system)))
        XCTAssertFalse(PluginListFilter.matches(managementItem: item, query: "", filter: .category(.display)))
    }

    func testManagementItemMatchesEnrichedProductKeywords() {
        let item = makeManagementItem(
            id: "keep-awake",
            title: "阻止休眠",
            summary: "阻止系统空闲休眠",
            category: "system",
            productSearchKeywords: ["presentation mode", "caffeine"]
        )

        XCTAssertTrue(
            PluginListFilter.matches(
                managementItem: item,
                query: "caffeine",
                filter: .all
            )
        )
    }

    func testCountsByFilterAggregatesCorrectly() {
        let items = [
            makeManagementItem(id: "a", title: "深色模式", summary: "切换", category: "display"),
            makeManagementItem(id: "b", title: "夜览", summary: "降低蓝光", category: "display"),
            makeManagementItem(id: "c", title: "麦克风静音", summary: "麦克风", category: "audio"),
            makeManagementItem(id: "d", title: "无分类插件", summary: "...", category: nil)
        ]

        let counts = PluginListFilter.countsByFilter(managementItems: items, query: "")

        XCTAssertEqual(counts[.all], 4)
        XCTAssertEqual(counts[.category(.display)], 2)
        XCTAssertEqual(counts[.category(.audio)], 1)
        XCTAssertEqual(counts[.category(.other)], 1)
        XCTAssertEqual(counts[.category(.system)], 0)
    }

    func testCountsByFilterRespectsSearchQuery() {
        let items = [
            makeManagementItem(id: "a", title: "深色模式", summary: "切换", category: "display"),
            makeManagementItem(id: "b", title: "夜览", summary: "降低蓝光", category: "display"),
            makeManagementItem(id: "c", title: "麦克风静音", summary: "麦克风", category: "audio")
        ]

        let counts = PluginListFilter.countsByFilter(managementItems: items, query: "麦克风")

        XCTAssertEqual(counts[.all], 1)
        XCTAssertEqual(counts[.category(.audio)], 1)
        XCTAssertEqual(counts[.category(.display)], 0)
    }

    private func makeManagementItem(
        id: String,
        title: String,
        summary: String?,
        category: String?,
        productSearchKeywords: [String] = []
    ) -> PluginManagementItem {
        let productMetadata = productSearchKeywords.isEmpty ? nil : PluginProductMetadata(
            presentation: nil,
            discovery: PluginProductMetadata.Discovery(
                keywords: productSearchKeywords,
                localizedSynonyms: [:],
                useCases: [],
                goalCategories: [],
                relatedPluginIDs: [],
                alternativePluginIDs: []
            ),
            requirements: nil,
            privacy: nil,
            actions: nil,
            setup: nil,
            relationships: nil
        )
        return PluginManagementItem(
            id: id,
            title: title,
            summary: summary,
            version: "1.0.0",
            state: .available,
            packageURL: nil,
            requiresRestartToFullyUnload: false,
            releaseNotesURL: nil,
            category: category,
            productMetadata: productMetadata
        )
    }
}
