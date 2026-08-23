import Combine
import Foundation
import MacToolsPluginKit

enum SettingsSidebarPluginSortMode: String, CaseIterable, Identifiable {
    case installedOldestFirst
    case installedNewestFirst
    case nameAscending
    case nameDescending
    case custom

    var id: String { rawValue }
}

struct SettingsSidebarPluginOrderItem: Equatable {
    let id: String
    let title: String
    let installedAt: Date?
}

@MainActor
final class SettingsSidebarPreferencesStore: ObservableObject {
    private enum DefaultsKey {
        static let sortMode = "settings.sidebar.pluginSortMode"
        static let customOrder = "settings.sidebar.customPluginOrder"
    }

    static let didImportNotification = Notification.Name(
        "SettingsSidebarPreferencesStore.didImport"
    )

    @Published private(set) var sortMode: SettingsSidebarPluginSortMode
    @Published private(set) var customOrderedPluginIDs: [String]

    private let userDefaults: UserDefaults
    private let locale: () -> Locale
    private let preferencesBackupChangeReporter: PreferencesBackupChangeReporter?
    private var isCustomOrderInitialized: Bool
    private var importObserver: NSObjectProtocol?

    init(
        userDefaults: UserDefaults = .standard,
        locale: @escaping () -> Locale = { PluginRuntimeLocalization.locale },
        preferencesBackupChangeReporter: PreferencesBackupChangeReporter? = nil
    ) {
        self.userDefaults = userDefaults
        self.locale = locale
        self.preferencesBackupChangeReporter = preferencesBackupChangeReporter
        sortMode = Self.storedSortMode(in: userDefaults)
        customOrderedPluginIDs = Self.storedCustomOrder(in: userDefaults)
        isCustomOrderInitialized = userDefaults.object(forKey: DefaultsKey.customOrder) != nil
        importObserver = NotificationCenter.default.addObserver(
            forName: Self.didImportNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadFromUserDefaults()
            }
        }
    }

    isolated deinit {
        if let importObserver {
            NotificationCenter.default.removeObserver(importObserver)
        }
    }

    static func storedSortMode(in userDefaults: UserDefaults) -> SettingsSidebarPluginSortMode {
        switch userDefaults.string(forKey: DefaultsKey.sortMode) {
        case SettingsSidebarPluginSortMode.custom.rawValue:
            .custom
        case SettingsSidebarPluginSortMode.installedOldestFirst.rawValue:
            .installedOldestFirst
        case SettingsSidebarPluginSortMode.installedNewestFirst.rawValue:
            .installedNewestFirst
        case SettingsSidebarPluginSortMode.nameDescending.rawValue:
            .nameDescending
        default:
            // Migrate the previous `name` and `defaultOrder` values to the
            // explicit localized ascending-name mode.
            .nameAscending
        }
    }

    static func storedCustomOrder(in userDefaults: UserDefaults) -> [String] {
        var seen = Set<String>()
        return (userDefaults.stringArray(forKey: DefaultsKey.customOrder) ?? []).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func storedCustomOrderIfInitialized(in userDefaults: UserDefaults) -> [String]? {
        guard userDefaults.object(forKey: DefaultsKey.customOrder) != nil else {
            return nil
        }
        return storedCustomOrder(in: userDefaults)
    }

    static func applyImportedPreferences(
        sortMode: SettingsSidebarPluginSortMode,
        customOrderedPluginIDs: [String]?,
        to userDefaults: UserDefaults
    ) {
        userDefaults.set(sortMode.rawValue, forKey: DefaultsKey.sortMode)
        if let customOrderedPluginIDs {
            userDefaults.set(customOrderedPluginIDs, forKey: DefaultsKey.customOrder)
        } else {
            userDefaults.removeObject(forKey: DefaultsKey.customOrder)
        }
        NotificationCenter.default.post(name: didImportNotification, object: nil)
    }

    func orderedPluginIDs(for items: [SettingsSidebarPluginOrderItem]) -> [String] {
        switch sortMode {
        case .installedOldestFirst:
            orderedByInstallationDate(items, ascending: true)
        case .installedNewestFirst:
            orderedByInstallationDate(items, ascending: false)
        case .nameAscending:
            orderedByName(items, ascending: true)
        case .nameDescending:
            orderedByName(items, ascending: false)
        case .custom:
            normalizedCustomOrder(availableIDs: items.map(\.id))
        }
    }

    func setSortMode(
        _ sortMode: SettingsSidebarPluginSortMode,
        availableItems: [SettingsSidebarPluginOrderItem]
    ) {
        let previousSortMode = self.sortMode
        let previousCustomOrder = customOrderedPluginIDs
        if sortMode == .custom, !isCustomOrderInitialized {
            customOrderedPluginIDs = orderedPluginIDs(for: availableItems)
            isCustomOrderInitialized = true
            userDefaults.set(customOrderedPluginIDs, forKey: DefaultsKey.customOrder)
        }

        if self.sortMode != sortMode {
            self.sortMode = sortMode
            userDefaults.set(sortMode.rawValue, forKey: DefaultsKey.sortMode)
        }
        if previousSortMode != self.sortMode
            || previousCustomOrder != customOrderedPluginIDs {
            preferencesBackupChangeReporter?.didPersist(.settingsSidebar)
        }
    }

    @discardableResult
    func movePlugins(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        availableItems: [SettingsSidebarPluginOrderItem]
    ) -> Bool {
        let currentOrder = orderedPluginIDs(for: availableItems)
        guard
            !source.isEmpty,
            source.allSatisfy(currentOrder.indices.contains),
            (0...currentOrder.count).contains(destination)
        else {
            return false
        }

        let movingIDs = source.sorted().map { currentOrder[$0] }
        var remainingIDs = currentOrder.enumerated()
            .filter { !source.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            remainingIDs.count
        )
        remainingIDs.insert(contentsOf: movingIDs, at: insertionIndex)

        guard remainingIDs != currentOrder else { return false }
        let mergedOrder = mergedCustomOrder(
            reorderedAvailableIDs: remainingIDs,
            availableIDs: currentOrder
        )
        sortMode = .custom
        customOrderedPluginIDs = mergedOrder
        isCustomOrderInitialized = true
        userDefaults.set(
            SettingsSidebarPluginSortMode.custom.rawValue,
            forKey: DefaultsKey.sortMode
        )
        userDefaults.set(mergedOrder, forKey: DefaultsKey.customOrder)
        preferencesBackupChangeReporter?.didPersist(.settingsSidebar)
        return true
    }

    func resetCustomOrder() {
        let changed = sortMode != .nameAscending
            || isCustomOrderInitialized
            || !customOrderedPluginIDs.isEmpty
        sortMode = .nameAscending
        customOrderedPluginIDs = []
        isCustomOrderInitialized = false
        userDefaults.removeObject(forKey: DefaultsKey.sortMode)
        userDefaults.removeObject(forKey: DefaultsKey.customOrder)
        if changed {
            preferencesBackupChangeReporter?.didPersist(.settingsSidebar)
        }
    }

    private func reloadFromUserDefaults() {
        sortMode = Self.storedSortMode(in: userDefaults)
        customOrderedPluginIDs = Self.storedCustomOrder(in: userDefaults)
        isCustomOrderInitialized = userDefaults.object(forKey: DefaultsKey.customOrder) != nil
    }

    private func normalizedCustomOrder(availableIDs: [String]) -> [String] {
        let availableIDSet = Set(availableIDs)
        var seen = Set<String>()
        let savedIDs = customOrderedPluginIDs.filter {
            availableIDSet.contains($0) && seen.insert($0).inserted
        }
        return savedIDs + availableIDs.filter { seen.insert($0).inserted }
    }

    /// Replaces available IDs in their saved slots while retaining IDs for
    /// temporarily unavailable plugins so reinstalling can restore their order.
    private func mergedCustomOrder(
        reorderedAvailableIDs: [String],
        availableIDs: [String]
    ) -> [String] {
        let availableIDSet = Set(availableIDs)
        var reorderedIterator = reorderedAvailableIDs.makeIterator()
        var seen = Set<String>()
        var result: [String] = []

        for savedID in customOrderedPluginIDs {
            let nextID: String
            if availableIDSet.contains(savedID) {
                guard let reorderedID = reorderedIterator.next() else {
                    continue
                }
                nextID = reorderedID
            } else {
                nextID = savedID
            }

            if seen.insert(nextID).inserted {
                result.append(nextID)
            }
        }

        while let reorderedID = reorderedIterator.next() {
            if seen.insert(reorderedID).inserted {
                result.append(reorderedID)
            }
        }

        return result
    }

    private func orderedByName(
        _ items: [SettingsSidebarPluginOrderItem],
        ascending: Bool
    ) -> [String] {
        items.enumerated().sorted { lhs, rhs in
            let comparison = compareNames(lhs.element.title, rhs.element.title)
            if comparison == .orderedSame {
                return lhs.offset < rhs.offset
            }
            return ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
        .map(\.element.id)
    }

    private func orderedByInstallationDate(
        _ items: [SettingsSidebarPluginOrderItem],
        ascending: Bool
    ) -> [String] {
        items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.installedAt, rhs.element.installedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return ascending ? lhsDate < rhsDate : lhsDate > rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let comparison = compareNames(lhs.element.title, rhs.element.title)
                if comparison == .orderedSame {
                    return lhs.offset < rhs.offset
                }
                return comparison == .orderedAscending
            }
        }
        .map(\.element.id)
    }

    private func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .numeric],
            range: nil,
            locale: locale()
        )
    }
}
