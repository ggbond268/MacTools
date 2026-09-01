import Foundation
import MacToolsPluginKit

struct SystemStatusMetricPreference: Codable, Equatable, Identifiable, Sendable {
    let kind: SystemStatusMetricKind
    var isVisible: Bool

    var id: String { kind.rawValue }
}

enum SystemStatusMenuBarValueArrangement: String, Codable, CaseIterable, Sendable {
    case automatic
    case stacked
    case inline
}

struct SystemStatusMenuBarMetricPreference: Codable, Equatable, Identifiable, Sendable {
    let kind: SystemStatusMetricKind
    var isVisible: Bool
    var values: [SystemStatusMenuBarValueKind]
    var style: SystemStatusMenuBarLayout
    var valueArrangement: SystemStatusMenuBarValueArrangement

    init(
        kind: SystemStatusMetricKind,
        isVisible: Bool,
        values: [SystemStatusMenuBarValueKind],
        style: SystemStatusMenuBarLayout = .horizontal,
        valueArrangement: SystemStatusMenuBarValueArrangement = .automatic
    ) {
        self.kind = kind
        self.isVisible = isVisible
        self.values = values
        self.style = style
        self.valueArrangement = valueArrangement
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case isVisible
        case values
        case style
        case valueArrangement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(SystemStatusMetricKind.self, forKey: .kind)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        values = try container.decode([SystemStatusMenuBarValueKind].self, forKey: .values)
        style = try container.decodeIfPresent(
            SystemStatusMenuBarLayout.self,
            forKey: .style
        ) ?? .horizontal
        valueArrangement = try container.decodeIfPresent(
            SystemStatusMenuBarValueArrangement.self,
            forKey: .valueArrangement
        ) ?? .automatic
    }

    var id: String { kind.rawValue }
}

enum SystemStatusMenuBarLayout: String, Codable, Sendable {
    case horizontal
    case vertical
    case minimal
}

struct SystemStatusConfiguration: Codable, Equatable, Sendable {
    var panelItems: [SystemStatusMetricPreference]
    var menuBarItems: [SystemStatusMenuBarMetricPreference]
    var menuBarLayout: SystemStatusMenuBarLayout
    var processSort: SystemStatusProcessSort

    static let `default` = SystemStatusConfiguration(
        panelItems: SystemStatusComponentLayout.defaultPanelMetricKinds.map {
            SystemStatusMetricPreference(kind: $0, isVisible: true)
        },
        menuBarItems: SystemStatusComponentLayout.defaultMenuBarMetricKinds.map {
            SystemStatusMenuBarMetricPreference(
                kind: $0,
                isVisible: false,
                values: SystemStatusMenuBarValueKind.defaultValues(for: $0)
            )
        },
        menuBarLayout: .horizontal,
        processSort: .cpu
    )

    var visiblePanelMetricKinds: [SystemStatusMetricKind] {
        panelItems.filter(\.isVisible).map(\.kind)
    }

    var visibleMenuBarMetricKinds: [SystemStatusMetricKind] {
        menuBarItems.filter(\.isVisible).map(\.kind)
    }
}

extension SystemStatusConfiguration {
    private enum CodingKeys: String, CodingKey {
        case panelItems
        case menuBarItems
        case menuBarLayout
        case processSort
    }

    private struct DecodedMenuBarMetricPreference: Decodable {
        let kind: SystemStatusMetricKind
        let isVisible: Bool
        let values: [SystemStatusMenuBarValueKind]
        let style: SystemStatusMenuBarLayout?
        let valueArrangement: SystemStatusMenuBarValueArrangement?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panelItems = try container.decode([SystemStatusMetricPreference].self, forKey: .panelItems)
        let decodedMenuBarLayout = try container.decodeIfPresent(
            SystemStatusMenuBarLayout.self,
            forKey: .menuBarLayout
        ) ?? .horizontal
        menuBarLayout = decodedMenuBarLayout
        let decodedMenuBarItems = try container.decode(
            [DecodedMenuBarMetricPreference].self,
            forKey: .menuBarItems
        )
        menuBarItems = decodedMenuBarItems.map { item in
            SystemStatusMenuBarMetricPreference(
                kind: item.kind,
                isVisible: item.isVisible,
                values: item.values,
                style: item.style ?? decodedMenuBarLayout,
                valueArrangement: item.valueArrangement ?? .automatic
            )
        }
        processSort = try container.decodeIfPresent(
            SystemStatusProcessSort.self,
            forKey: .processSort
        ) ?? .cpu
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(panelItems, forKey: .panelItems)
        try container.encode(menuBarItems, forKey: .menuBarItems)
        try container.encode(menuBarLayout, forKey: .menuBarLayout)
        try container.encode(processSort, forKey: .processSort)
    }
}

@MainActor
protocol SystemStatusConfigurationStoring: AnyObject {
    func load() -> SystemStatusConfiguration
    @discardableResult
    func save(_ configuration: SystemStatusConfiguration) -> Bool
}

@MainActor
final class SystemStatusPluginStorageConfigurationStore: SystemStatusConfigurationStoring {
    private enum Key {
        static let configuration = "settings.configuration.v1"
        static let panelOrder = "settings.panel.order"
        static let panelHidden = "settings.panel.hidden"
        static let menuBarOrder = "settings.menuBar.order"
        static let menuBarVisible = "settings.menuBar.visible"
        static let menuBarLayout = "settings.menuBar.layout"
        static let menuBarValues = "settings.menuBar.values.v1"
        static let processSort = "settings.process.sort"
        static let legacyNetworkMenuBarLayout = "settings.menuBar.network.layout"
    }

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
    }

    func load() -> SystemStatusConfiguration {
        if let data = storage.data(forKey: Key.configuration),
           let configuration = try? JSONDecoder().decode(SystemStatusConfiguration.self, from: data) {
            return Self.normalizedConfiguration(configuration)
        }

        storage.migrateValueIfNeeded(
            fromLegacyKey: Key.legacyNetworkMenuBarLayout,
            to: Key.menuBarLayout
        )

        let panelOrder = storage.stringArray(forKey: Key.panelOrder)
        let panelHidden = storage.stringArray(forKey: Key.panelHidden)
        let menuBarOrder = storage.stringArray(forKey: Key.menuBarOrder)
        let menuBarVisible = storage.stringArray(forKey: Key.menuBarVisible)
        let menuBarLayout = storage.string(forKey: Key.menuBarLayout)
            .flatMap(SystemStatusMenuBarLayout.init(rawValue:))
            ?? .horizontal
        let menuBarValues = Self.decodeMenuBarValues(storage.data(forKey: Key.menuBarValues))
        let processSort = storage.string(forKey: Key.processSort)
            .flatMap(SystemStatusProcessSort.init(rawValue:))
            ?? .cpu

        let configuration = SystemStatusConfiguration(
            panelItems: Self.normalizedItems(
                storedOrder: panelOrder,
                visibilityIDs: Set(panelHidden ?? []),
                defaults: SystemStatusComponentLayout.defaultPanelMetricKinds,
                defaultVisibility: true,
                visibilityMode: .hiddenSet,
                usesDefaultVisibility: panelHidden == nil
            ),
            menuBarItems: Self.normalizedItems(
                storedOrder: menuBarOrder,
                visibilityIDs: Set(menuBarVisible ?? []),
                defaults: SystemStatusComponentLayout.defaultMenuBarMetricKinds,
                defaultVisibility: false,
                visibilityMode: .visibleSet,
                usesDefaultVisibility: menuBarVisible == nil,
                storedValues: menuBarValues,
                style: menuBarLayout
            ),
            menuBarLayout: menuBarLayout,
            processSort: processSort
        )
        _ = save(configuration)
        return configuration
    }

    @discardableResult
    func save(_ configuration: SystemStatusConfiguration) -> Bool {
        let normalizedConfiguration = Self.normalizedConfiguration(configuration)
        guard let data = try? JSONEncoder().encode(normalizedConfiguration) else {
            return false
        }

        storage.set(data, forKey: Key.configuration)
        return storage.data(forKey: Key.configuration) == data
    }

    private enum VisibilityMode {
        case hiddenSet
        case visibleSet
    }

    private static func normalizedItems(
        storedOrder: [String]?,
        visibilityIDs: Set<String>,
        defaults: [SystemStatusMetricKind],
        defaultVisibility: Bool,
        visibilityMode: VisibilityMode,
        usesDefaultVisibility: Bool
    ) -> [SystemStatusMetricPreference] {
        let storedKinds = storedOrder?
            .compactMap(SystemStatusMetricKind.init(rawValue:))
            .filter { defaults.contains($0) } ?? []
        let orderedKinds = normalizedKinds(storedKinds, defaults: defaults)

        return orderedKinds.map { kind in
            let isVisible: Bool
            switch visibilityMode {
            case .hiddenSet:
                isVisible = !visibilityIDs.contains(kind.rawValue)
            case .visibleSet:
                isVisible = visibilityIDs.contains(kind.rawValue)
            }

            return SystemStatusMetricPreference(
                kind: kind,
                isVisible: usesDefaultVisibility ? defaultVisibility : isVisible
            )
        }
    }

    private static func normalizedConfiguration(
        _ configuration: SystemStatusConfiguration
    ) -> SystemStatusConfiguration {
        SystemStatusConfiguration(
            panelItems: normalizedItems(
                configuration.panelItems,
                defaults: SystemStatusComponentLayout.defaultPanelMetricKinds,
                defaultVisibility: true
            ),
            menuBarItems: normalizedItems(
                configuration.menuBarItems,
                defaults: SystemStatusComponentLayout.defaultMenuBarMetricKinds,
                defaultVisibility: false
            ),
            menuBarLayout: configuration.menuBarLayout,
            processSort: configuration.processSort
        )
    }

    private static func normalizedItems(
        storedOrder: [String]?,
        visibilityIDs: Set<String>,
        defaults: [SystemStatusMetricKind],
        defaultVisibility: Bool,
        visibilityMode: VisibilityMode,
        usesDefaultVisibility: Bool,
        storedValues: [String: [String]],
        style: SystemStatusMenuBarLayout
    ) -> [SystemStatusMenuBarMetricPreference] {
        let storedKinds = storedOrder?
            .compactMap(SystemStatusMetricKind.init(rawValue:))
            .filter { defaults.contains($0) } ?? []
        let orderedKinds = normalizedKinds(storedKinds, defaults: defaults)

        return orderedKinds.map { kind in
            let isVisible: Bool
            switch visibilityMode {
            case .hiddenSet:
                isVisible = !visibilityIDs.contains(kind.rawValue)
            case .visibleSet:
                isVisible = visibilityIDs.contains(kind.rawValue)
            }

            return SystemStatusMenuBarMetricPreference(
                kind: kind,
                isVisible: usesDefaultVisibility ? defaultVisibility : isVisible,
                values: normalizedValues(
                    storedValues[kind.rawValue]?.compactMap(SystemStatusMenuBarValueKind.init(rawValue:)),
                    for: kind
                ),
                style: style
            )
        }
    }

    private static func normalizedItems(
        _ items: [SystemStatusMetricPreference],
        defaults: [SystemStatusMetricKind],
        defaultVisibility: Bool
    ) -> [SystemStatusMetricPreference] {
        let visibilityByKind = Dictionary(uniqueKeysWithValues: items.map { ($0.kind, $0.isVisible) })
        return normalizedKinds(items.map(\.kind), defaults: defaults).map { kind in
            SystemStatusMetricPreference(
                kind: kind,
                isVisible: visibilityByKind[kind] ?? defaultVisibility
            )
        }
    }

    private static func normalizedItems(
        _ items: [SystemStatusMenuBarMetricPreference],
        defaults: [SystemStatusMetricKind],
        defaultVisibility: Bool
    ) -> [SystemStatusMenuBarMetricPreference] {
        let itemsByKind = Dictionary(uniqueKeysWithValues: items.map { ($0.kind, $0) })
        return normalizedKinds(items.map(\.kind), defaults: defaults).map { kind in
            let item = itemsByKind[kind]
            return SystemStatusMenuBarMetricPreference(
                kind: kind,
                isVisible: item?.isVisible ?? defaultVisibility,
                values: normalizedValues(item?.values, for: kind),
                style: item?.style ?? .horizontal,
                valueArrangement: item?.valueArrangement ?? .automatic
            )
        }
    }

    private static func normalizedValues(
        _ values: [SystemStatusMenuBarValueKind]?,
        for metric: SystemStatusMetricKind
    ) -> [SystemStatusMenuBarValueKind] {
        let available = SystemStatusMenuBarValueKind.availableValues(for: metric)
        var seen: Set<SystemStatusMenuBarValueKind> = []
        let normalized = (values ?? [])
            .filter { available.contains($0) && seen.insert($0).inserted }
            .prefix(2)
        let result = Array(normalized)
        return result.isEmpty ? SystemStatusMenuBarValueKind.defaultValues(for: metric) : result
    }

    private static func decodeMenuBarValues(_ data: Data?) -> [String: [String]] {
        guard let data,
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return values
    }

    private static func normalizedKinds(
        _ kinds: [SystemStatusMetricKind],
        defaults: [SystemStatusMetricKind]
    ) -> [SystemStatusMetricKind] {
        var seen: Set<SystemStatusMetricKind> = []
        var result: [SystemStatusMetricKind] = []

        for kind in kinds where defaults.contains(kind) && !seen.contains(kind) {
            result.append(kind)
            seen.insert(kind)
        }

        for kind in defaults where !seen.contains(kind) {
            result.append(kind)
            seen.insert(kind)
        }

        return result
    }
}

@MainActor
final class SystemStatusSettingsController: ObservableObject {
    private struct PortablePreferences: Codable {
        let formatVersion: Int
        let configuration: SystemStatusConfiguration
    }

    private static let portablePreferencesFormatVersion = 1
    private static let maximumPortablePreferencesSize = 32 * 1_024

    @Published private(set) var configuration: SystemStatusConfiguration

    var onConfigurationChange: (() -> Void)?

    private let store: SystemStatusConfigurationStoring

    init(store: SystemStatusConfigurationStoring) {
        self.store = store
        self.configuration = store.load()
    }

    func makePortablePreferencesBackup() -> Data? {
        let payload = PortablePreferences(
            formatVersion: Self.portablePreferencesFormatVersion,
            configuration: configuration
        )
        guard Self.isValidPortableConfiguration(configuration),
              let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maximumPortablePreferencesSize else {
            return nil
        }
        return data
    }

    @discardableResult
    func restorePortablePreferences(from data: Data) -> Bool {
        guard data.count <= Self.maximumPortablePreferencesSize,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data),
              payload.formatVersion == Self.portablePreferencesFormatVersion,
              Self.isValidPortableConfiguration(payload.configuration) else {
            return false
        }

        let previousConfiguration = configuration
        guard payload.configuration != previousConfiguration else {
            return true
        }

        guard store.save(payload.configuration) else {
            return false
        }
        let persistedConfiguration = store.load()
        guard persistedConfiguration == payload.configuration else {
            _ = store.save(previousConfiguration)
            return false
        }

        configuration = persistedConfiguration
        onConfigurationChange?()
        return true
    }

    func setPanelMetric(_ kind: SystemStatusMetricKind, visible isVisible: Bool) {
        update { configuration in
            guard let index = configuration.panelItems.firstIndex(where: { $0.kind == kind }) else {
                return
            }

            configuration.panelItems[index].isVisible = isVisible
        }
    }

    func setMenuBarMetric(_ kind: SystemStatusMetricKind, visible isVisible: Bool) {
        update { configuration in
            guard let index = configuration.menuBarItems.firstIndex(where: { $0.kind == kind }) else {
                return
            }

            configuration.menuBarItems[index].isVisible = isVisible
        }
    }

    func setMenuBarLayout(_ layout: SystemStatusMenuBarLayout) {
        applyMenuBarStyleToAll(layout)
    }

    func setMenuBarStyle(_ kind: SystemStatusMetricKind, style: SystemStatusMenuBarLayout) {
        update { configuration in
            guard let index = configuration.menuBarItems.firstIndex(where: { $0.kind == kind }) else {
                return
            }
            configuration.menuBarItems[index].style = style
        }
    }

    func applyMenuBarStyleToAll(_ style: SystemStatusMenuBarLayout) {
        update { configuration in
            configuration.menuBarLayout = style
            for index in configuration.menuBarItems.indices {
                configuration.menuBarItems[index].style = style
            }
        }
    }

    func resetMenuBarAppearances() {
        update { configuration in
            configuration.menuBarLayout = SystemStatusConfiguration.default.menuBarLayout
            for index in configuration.menuBarItems.indices {
                configuration.menuBarItems[index].style = .horizontal
                configuration.menuBarItems[index].valueArrangement = .automatic
            }
        }
    }

    func resetMenuBarConfiguration() {
        update { configuration in
            configuration.menuBarItems = SystemStatusConfiguration.default.menuBarItems
            configuration.menuBarLayout = SystemStatusConfiguration.default.menuBarLayout
        }
    }

    func setMenuBarValues(_ kind: SystemStatusMetricKind, values: [SystemStatusMenuBarValueKind]) {
        update { configuration in
            guard let index = configuration.menuBarItems.firstIndex(where: { $0.kind == kind }) else {
                return
            }

            let available = SystemStatusMenuBarValueKind.availableValues(for: kind)
            var seen: Set<SystemStatusMenuBarValueKind> = []
            let normalized = values
                .filter { available.contains($0) && seen.insert($0).inserted }
                .prefix(2)
            guard !normalized.isEmpty else {
                return
            }
            configuration.menuBarItems[index].values = Array(normalized)
        }
    }

    func setMenuBarValueArrangement(
        _ kind: SystemStatusMetricKind,
        arrangement: SystemStatusMenuBarValueArrangement
    ) {
        update { configuration in
            guard let index = configuration.menuBarItems.firstIndex(where: { $0.kind == kind }) else {
                return
            }
            configuration.menuBarItems[index].valueArrangement = arrangement
        }
    }

    func setProcessSort(_ sort: SystemStatusProcessSort) {
        update { configuration in
            configuration.processSort = sort
        }
    }

    func movePanelMetric(_ kind: SystemStatusMetricKind, toOffset targetOffset: Int) {
        update { configuration in
            move(kind, in: &configuration.panelItems, toOffset: targetOffset)
        }
    }

    func moveMenuBarMetric(_ kind: SystemStatusMetricKind, toOffset targetOffset: Int) {
        update { configuration in
            move(kind, in: &configuration.menuBarItems, toOffset: targetOffset)
        }
    }

    private func update(_ body: (inout SystemStatusConfiguration) -> Void) {
        var updatedConfiguration = configuration
        body(&updatedConfiguration)

        guard updatedConfiguration != configuration else {
            return
        }

        guard store.save(updatedConfiguration), store.load() == updatedConfiguration else {
            return
        }

        configuration = updatedConfiguration
        onConfigurationChange?()
    }

    private static func isValidPortableConfiguration(_ configuration: SystemStatusConfiguration) -> Bool {
        let panelKinds = configuration.panelItems.map(\.kind)
        guard panelKinds.count == SystemStatusComponentLayout.defaultPanelMetricKinds.count,
              Set(panelKinds) == Set(SystemStatusComponentLayout.defaultPanelMetricKinds) else {
            return false
        }

        let menuBarKinds = configuration.menuBarItems.map(\.kind)
        guard menuBarKinds.count == SystemStatusComponentLayout.defaultMenuBarMetricKinds.count,
              Set(menuBarKinds) == Set(SystemStatusComponentLayout.defaultMenuBarMetricKinds) else {
            return false
        }

        return configuration.menuBarItems.allSatisfy { item in
            let availableValues = SystemStatusMenuBarValueKind.availableValues(for: item.kind)
            return (1 ... 2).contains(item.values.count)
                && Set(item.values).count == item.values.count
                && item.values.allSatisfy(availableValues.contains)
        }
    }

    private func move(
        _ kind: SystemStatusMetricKind,
        in items: inout [SystemStatusMetricPreference],
        toOffset targetOffset: Int
    ) {
        guard let currentIndex = items.firstIndex(where: { $0.kind == kind }) else {
            return
        }

        let clampedOffset = min(max(targetOffset, 0), items.count)
        guard currentIndex != clampedOffset, currentIndex + 1 != clampedOffset else {
            return
        }

        let item = items.remove(at: currentIndex)
        let insertionIndex = currentIndex < clampedOffset ? clampedOffset - 1 : clampedOffset
        items.insert(item, at: insertionIndex)
    }

    private func move(
        _ kind: SystemStatusMetricKind,
        in items: inout [SystemStatusMenuBarMetricPreference],
        toOffset targetOffset: Int
    ) {
        guard let currentIndex = items.firstIndex(where: { $0.kind == kind }) else {
            return
        }

        let clampedOffset = min(max(targetOffset, 0), items.count)
        guard currentIndex != clampedOffset, currentIndex + 1 != clampedOffset else {
            return
        }

        let item = items.remove(at: currentIndex)
        let insertionIndex = currentIndex < clampedOffset ? clampedOffset - 1 : clampedOffset
        items.insert(item, at: insertionIndex)
    }
}
