import Foundation
import MacToolsPluginKit

struct SystemStatusMetricPreference: Codable, Equatable, Identifiable, Sendable {
    let kind: SystemStatusMetricKind
    var isVisible: Bool

    var id: String { kind.rawValue }
}

enum SystemStatusMenuBarLayout: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct SystemStatusConfiguration: Equatable, Sendable {
    var panelItems: [SystemStatusMetricPreference]
    var menuBarItems: [SystemStatusMetricPreference]
    var menuBarLayout: SystemStatusMenuBarLayout

    static let `default` = SystemStatusConfiguration(
        panelItems: SystemStatusComponentLayout.defaultPanelMetricKinds.map {
            SystemStatusMetricPreference(kind: $0, isVisible: true)
        },
        menuBarItems: SystemStatusComponentLayout.defaultMenuBarMetricKinds.map {
            SystemStatusMetricPreference(kind: $0, isVisible: false)
        },
        menuBarLayout: .horizontal
    )

    var visiblePanelMetricKinds: [SystemStatusMetricKind] {
        panelItems.filter(\.isVisible).map(\.kind)
    }

    var visibleMenuBarMetricKinds: [SystemStatusMetricKind] {
        menuBarItems.filter(\.isVisible).map(\.kind)
    }
}

@MainActor
protocol SystemStatusConfigurationStoring: AnyObject {
    func load() -> SystemStatusConfiguration
    func save(_ configuration: SystemStatusConfiguration)
}

@MainActor
final class SystemStatusPluginStorageConfigurationStore: SystemStatusConfigurationStoring {
    private enum Key {
        static let panelOrder = "settings.panel.order"
        static let panelHidden = "settings.panel.hidden"
        static let menuBarOrder = "settings.menuBar.order"
        static let menuBarVisible = "settings.menuBar.visible"
        static let menuBarLayout = "settings.menuBar.layout"
        static let legacyNetworkMenuBarLayout = "settings.menuBar.network.layout"
    }

    private let storage: PluginStorage

    init(storage: PluginStorage) {
        self.storage = storage
    }

    func load() -> SystemStatusConfiguration {
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

        return SystemStatusConfiguration(
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
                usesDefaultVisibility: menuBarVisible == nil
            ),
            menuBarLayout: menuBarLayout
        )
    }

    func save(_ configuration: SystemStatusConfiguration) {
        let panelItems = Self.normalizedItems(
            configuration.panelItems,
            defaults: SystemStatusComponentLayout.defaultPanelMetricKinds,
            defaultVisibility: true
        )
        let menuBarItems = Self.normalizedItems(
            configuration.menuBarItems,
            defaults: SystemStatusComponentLayout.defaultMenuBarMetricKinds,
            defaultVisibility: false
        )

        storage.set(panelItems.map { $0.kind.rawValue }, forKey: Key.panelOrder)
        storage.set(panelItems.filter { !$0.isVisible }.map { $0.kind.rawValue }, forKey: Key.panelHidden)
        storage.set(menuBarItems.map { $0.kind.rawValue }, forKey: Key.menuBarOrder)
        storage.set(menuBarItems.filter(\.isVisible).map { $0.kind.rawValue }, forKey: Key.menuBarVisible)
        storage.set(configuration.menuBarLayout.rawValue, forKey: Key.menuBarLayout)
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
    @Published private(set) var configuration: SystemStatusConfiguration

    var onConfigurationChange: (() -> Void)?

    private let store: SystemStatusConfigurationStoring

    init(store: SystemStatusConfigurationStoring) {
        self.store = store
        self.configuration = store.load()
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
        update { configuration in
            configuration.menuBarLayout = layout
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

        configuration = updatedConfiguration
        store.save(updatedConfiguration)
        onConfigurationChange?()
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
}
