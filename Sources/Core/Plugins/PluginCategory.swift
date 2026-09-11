import Foundation
import SwiftUI
import MacToolsPluginKit

enum PluginCategory: String, CaseIterable, Hashable, Identifiable {
    case display
    case audio
    case system
    case storage
    case productivity
    case monitoring
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .display: return AppL10n.plugins("plugin.category.display", defaultValue: "显示")
        case .audio: return AppL10n.plugins("plugin.category.audio", defaultValue: "音频")
        case .system: return AppL10n.plugins("plugin.category.system", defaultValue: "系统")
        case .storage: return AppL10n.plugins("plugin.category.storage", defaultValue: "清理")
        case .productivity: return AppL10n.plugins("plugin.category.productivity", defaultValue: "效率")
        case .monitoring: return AppL10n.plugins("plugin.category.monitoring", defaultValue: "监控")
        case .other: return AppL10n.plugins("plugin.category.other", defaultValue: "其他")
        }
    }

    var iconName: String {
        switch self {
        case .display: return "display"
        case .audio: return "speaker.wave.2"
        case .system: return "cpu"
        case .storage: return "internaldrive"
        case .productivity: return "wand.and.rays"
        case .monitoring: return "chart.line.uptrend.xyaxis"
        case .other: return "square.grid.2x2"
        }
    }

    var iconTint: Color {
        switch self {
        case .display: return .blue
        case .audio: return .purple
        case .system: return .gray
        case .storage: return .orange
        case .productivity: return .green
        case .monitoring: return .pink
        case .other: return .secondary
        }
    }

    var order: Int {
        switch self {
        case .display: return 0
        case .audio: return 1
        case .system: return 2
        case .storage: return 3
        case .productivity: return 4
        case .monitoring: return 5
        case .other: return 100
        }
    }

    static var orderedCases: [PluginCategory] {
        allCases.sorted { $0.order < $1.order }
    }

    init(rawString: String?) {
        guard
            let rawString,
            let value = PluginCategory(rawValue: rawString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else {
            self = .other
            return
        }

        self = value
    }
}

enum PluginCategoryFilter: Hashable, Identifiable {
    case all
    case category(PluginCategory)

    var id: String {
        switch self {
        case .all: return "__all__"
        case .category(let category): return category.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .all: return AppL10n.plugins("plugin.category.all", defaultValue: "全部")
        case .category(let category): return category.displayName
        }
    }

    var iconName: String {
        switch self {
        case .all: return "square.grid.3x3"
        case .category(let category): return category.iconName
        }
    }

    var iconTint: Color {
        switch self {
        case .all: return .accentColor
        case .category(let category): return category.iconTint
        }
    }

    func contains(category rawString: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .category(let category):
            return PluginCategory(rawString: rawString) == category
        }
    }
}

enum PluginListFilter {
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns true when any haystack contains the lowercased query, or when the query is empty.
    static func matches(query: String, in haystacks: [String?]) -> Bool {
        let needle = normalized(query)

        guard !needle.isEmpty else {
            return true
        }

        for haystack in haystacks {
            if let haystack, haystack.lowercased().contains(needle) {
                return true
            }
        }

        return false
    }

    static func matches(
        managementItem item: PluginManagementItem,
        query: String,
        filter: PluginCategoryFilter
    ) -> Bool {
        guard filter.contains(category: item.category) else {
            return false
        }

        let category = PluginCategory(rawString: item.category)
        return matches(query: query, in: [
            item.title,
            item.summary,
            item.id,
            category.displayName,
        ] + item.productSearchKeywords)
    }

    static func matches(
        featureItem item: PluginFeatureManagementItem,
        query: String,
        filter: PluginCategoryFilter
    ) -> Bool {
        guard filter.contains(category: item.category) else {
            return false
        }

        let category = PluginCategory(rawString: item.category)
        return matches(query: query, in: [
            item.title,
            item.description,
            item.id,
            category.displayName
        ])
    }

    static func matches(
        surfaceItem item: PluginSurfaceLayoutItem,
        query: String,
        filter: PluginCategoryFilter
    ) -> Bool {
        matches(
            id: item.id,
            title: item.title,
            description: item.description,
            category: item.category,
            query: query,
            filter: filter
        )
    }

    static func countsByFilter(managementItems items: [PluginManagementItem], query: String) -> [PluginCategoryFilter: Int] {
        var counts: [PluginCategoryFilter: Int] = [:]
        let allFiltered = items.filter { matches(managementItem: $0, query: query, filter: .all) }
        counts[.all] = allFiltered.count

        for category in PluginCategory.allCases {
            let filter = PluginCategoryFilter.category(category)
            counts[filter] = allFiltered.filter { filter.contains(category: $0.category) }.count
        }

        return counts
    }

    static func countsByFilter(featureItems items: [PluginFeatureManagementItem], query: String) -> [PluginCategoryFilter: Int] {
        var counts: [PluginCategoryFilter: Int] = [:]
        let allFiltered = items.filter { matches(featureItem: $0, query: query, filter: .all) }
        counts[.all] = allFiltered.count

        for category in PluginCategory.allCases {
            let filter = PluginCategoryFilter.category(category)
            counts[filter] = allFiltered.filter { filter.contains(category: $0.category) }.count
        }

        return counts
    }

    static func countsByFilter(surfaceItems items: [PluginSurfaceLayoutItem], query: String) -> [PluginCategoryFilter: Int] {
        countsByFilter(
            categories: items.map(\.category),
            matchingIndices: items.indices.filter {
                matches(surfaceItem: items[$0], query: query, filter: .all)
            }
        )
    }

    private static func matches(
        id: String,
        title: String,
        description: String,
        category rawCategory: String?,
        query: String,
        filter: PluginCategoryFilter
    ) -> Bool {
        guard filter.contains(category: rawCategory) else {
            return false
        }

        let category = PluginCategory(rawString: rawCategory)
        return matches(query: query, in: [title, description, id, category.displayName])
    }

    private static func countsByFilter(
        categories: [String?],
        matchingIndices: [Int]
    ) -> [PluginCategoryFilter: Int] {
        var counts: [PluginCategoryFilter: Int] = [.all: matchingIndices.count]

        for category in PluginCategory.allCases {
            let filter = PluginCategoryFilter.category(category)
            counts[filter] = matchingIndices.filter {
                categories.indices.contains($0) && filter.contains(category: categories[$0])
            }.count
        }

        return counts
    }
}
