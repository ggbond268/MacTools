import Foundation
import MacToolsPluginKit

/// Display-only sort modes for the plugin marketplace list.
/// Does not affect menu-bar feature order or installed-plugin preferences.
enum PluginMarketplaceSortMode: String, CaseIterable, Identifiable {
    /// Not installed first. Raw value kept for existing UserDefaults.
    case notInstalledFirst = "statusThenName"
    /// Installed-oriented order: updates and issues first, then settled installs.
    case installedFirst = "installedThenName"
    case nameAscending
    case nameDescending

    static let userDefaultsKey = "plugin.marketplace.sortMode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notInstalledFirst:
            return AppL10n.plugins("plugin.marketplace.sort.notInstalledFirst", defaultValue: "未安装优先")
        case .installedFirst:
            return AppL10n.plugins("plugin.marketplace.sort.installedFirst", defaultValue: "已安装优先")
        case .nameAscending:
            return AppL10n.plugins("plugin.marketplace.sort.nameAscending", defaultValue: "名称（升序）")
        case .nameDescending:
            return AppL10n.plugins("plugin.marketplace.sort.nameDescending", defaultValue: "名称（降序）")
        }
    }

    /// Rank for `.notInstalledFirst` (lower appears first):
    /// not installed → updates → needs attention → settled installs.
    static func notInstalledFirstSortRank(for item: PluginManagementItem) -> Int {
        switch item.state {
        case .available, .localDevelopment:
            return 0
        case .updateAvailable:
            return 1
        case .restartRequired, .failed, .incompatible, .revoked:
            return 2
        case .enabled, .disabled:
            return 3
        }
    }

    /// Rank for `.installedFirst` (lower appears first):
    /// updates → needs attention → settled installs → not installed.
    /// Prioritizes management actions over pure reverse of not-installed-first.
    static func installedFirstSortRank(for item: PluginManagementItem) -> Int {
        switch item.state {
        case .updateAvailable:
            return 0
        case .restartRequired, .failed, .incompatible, .revoked:
            return 1
        case .enabled, .disabled:
            return 2
        case .available, .localDevelopment:
            return 3
        }
    }

    /// Backwards-compatible alias used by existing tests/callers.
    static func statusSortRank(for item: PluginManagementItem) -> Int {
        notInstalledFirstSortRank(for: item)
    }

    static func sorted(
        _ items: [PluginManagementItem],
        by mode: PluginMarketplaceSortMode,
        locale: Locale = PluginRuntimeLocalization.locale
    ) -> [PluginManagementItem] {
        items.sorted { lhs, rhs in
            compare(lhs, rhs, mode: mode, locale: locale) == .orderedAscending
        }
    }

    static func compare(
        _ lhs: PluginManagementItem,
        _ rhs: PluginManagementItem,
        mode: PluginMarketplaceSortMode,
        locale: Locale = PluginRuntimeLocalization.locale
    ) -> ComparisonResult {
        switch mode {
        case .notInstalledFirst, .installedFirst:
            let leftRank = effectiveStatusRank(for: lhs, mode: mode)
            let rightRank = effectiveStatusRank(for: rhs, mode: mode)
            if leftRank != rightRank {
                return leftRank < rightRank ? .orderedAscending : .orderedDescending
            }
            return compareByName(lhs, rhs, ascending: true, locale: locale)
        case .nameAscending:
            return compareByName(lhs, rhs, ascending: true, locale: locale)
        case .nameDescending:
            return compareByName(lhs, rhs, ascending: false, locale: locale)
        }
    }

    /// Rank used by status-based modes after applying mode-specific grouping.
    static func effectiveStatusRank(
        for item: PluginManagementItem,
        mode: PluginMarketplaceSortMode
    ) -> Int {
        switch mode {
        case .notInstalledFirst:
            return notInstalledFirstSortRank(for: item)
        case .installedFirst:
            return installedFirstSortRank(for: item)
        case .nameAscending, .nameDescending:
            return notInstalledFirstSortRank(for: item)
        }
    }

    private static func compareByName(
        _ lhs: PluginManagementItem,
        _ rhs: PluginManagementItem,
        ascending: Bool,
        locale: Locale
    ) -> ComparisonResult {
        let titleOrder = lhs.title.compare(
            rhs.title,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric],
            range: nil,
            locale: locale
        )
        if titleOrder != .orderedSame {
            return ascending ? titleOrder : inverted(titleOrder)
        }

        // IDs are stable, non-localized identifiers. A literal comparison ensures the
        // list has a deterministic order when localized titles compare as equal.
        let idOrder = lhs.id.compare(rhs.id, options: .literal)
        return ascending ? idOrder : inverted(idOrder)
    }

    /// Inverts ascending/descending while preserving `.orderedSame`.
    private static func inverted(_ order: ComparisonResult) -> ComparisonResult {
        switch order {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }
}
