import Combine
import Foundation
import MacToolsPluginKit

/// A complete Settings destination, including the currently selected Plugins
/// subpage. Instances are scoped to a single Settings window.
enum SettingsNavigationDestination: Hashable {
    case general
    case about
    case plugins(FeatureSettingsPane)

    var settingsDestination: SettingsDestination {
        switch self {
        case .general:
            .general
        case .about:
            .about
        case .plugins:
            .pluginConfiguration
        }
    }

    var featureSettingsPane: FeatureSettingsPane? {
        guard case let .plugins(pane) = self else {
            return nil
        }

        return pane
    }

}

extension SettingsNavigationDestination {
    static func settingsSidebarOrder(
        configurationIDs: some Sequence<String>
    ) -> [SettingsNavigationDestination] {
        let pluginPanes = FeatureSettingsPane.settingsSidebarOrder(
            configurationIDs: configurationIDs
        )

        return [
            .general,
            .plugins(.automation),
            .about
        ] + pluginPanes
            .filter { $0 != .automation }
            .map(SettingsNavigationDestination.plugins)
    }
}

enum SettingsSearchField: Equatable {
    case pluginMarketplace
    case pluginSettings(String)
}

enum UnifiedSearchPresentationOrigin: Equatable {
    case settingsSidebar
    case keyboard
    case globalShortcut(String)
}

enum SettingsSidebarMoveDirection: Equatable {
    case previous
    case next
}

extension FeatureSettingsPane {
    static func settingsSidebarOrder(
        configurationIDs: some Sequence<String>
    ) -> [FeatureSettingsPane] {
        [
            .actionsAndShortcuts,
            .automation,
            .dashboardLayout,
            .featurePanelLayout,
            .marketplace
        ] + configurationIDs.map(FeatureSettingsPane.configuration)
    }
}

struct SettingsSearchFocusRequest: Equatable {
    let id: UInt
    let field: SettingsSearchField
}

struct AboutUpdateActionRequest: Equatable {
    let id: UInt
    let version: String
}

enum GeneralSettingsSearchTarget: String, Hashable {
    case launchAtLogin
    case appearance
    case language
    case menuBarIcon
    case menuBarClickBehavior
    case appShortcuts
    case preferencesBackup

    var scrollID: String {
        "general-search-anchor.\(rawValue)"
    }
}

enum SettingsSearchRevealTarget: Hashable {
    case general(GeneralSettingsSearchTarget)
    case marketplace(MarketplacePluginSearchTarget)
    case plugin(PluginSettingsSearchTarget)
    case surface(SurfaceSettingsSearchTarget)
    case automation(AutomationWorkflowSearchTarget)
}

struct AutomationWorkflowSearchTarget: Hashable {
    let workflowID: UUID
}

struct SettingsSearchRevealRequest: Equatable {
    let id: UInt
    let target: SettingsSearchRevealTarget
}

struct SurfaceSettingsSearchTarget: Hashable {
    let surface: PluginDisplaySurface
    let pluginID: String

    func scrollID(isHidden: Bool) -> String {
        let surfaceID = switch surface {
        case .dashboard:
            "dashboard"
        case .featurePanel:
            "feature-panel"
        }
        return "surface-search-anchor.\(surfaceID).\(isHidden ? "hidden" : "visible").\(pluginID)"
    }
}

struct MarketplacePluginSearchTarget: Hashable {
    let pluginID: String

    var scrollID: String {
        "marketplace-search-anchor.\(pluginID)"
    }
}

enum MarketplacePluginSearchAvailability {
    static func contains(pluginID: String, in items: [PluginManagementItem]) -> Bool {
        items.contains { $0.id == pluginID }
    }
}

struct UnifiedSearchQuickSelectionRequest: Equatable {
    let id: UInt
    let number: Int
}

@MainActor
final class SettingsNavigationCoordinator: ObservableObject {
    private static let maximumHistoryCount = 128

    @Published private(set) var destination: SettingsNavigationDestination
    @Published private(set) var searchFocusRequest: SettingsSearchFocusRequest?
    @Published private(set) var aboutUpdateActionRequest: AboutUpdateActionRequest?
    @Published private(set) var isUnifiedSearchPresented = false
    @Published private(set) var unifiedSearchPresentationOrigin: UnifiedSearchPresentationOrigin?
    @Published private(set) var unifiedSearchFocusRequestID: UInt = 0
    @Published private(set) var unifiedSearchQuickSelectionRequest: UnifiedSearchQuickSelectionRequest?
    @Published private(set) var searchRevealRequest: SettingsSearchRevealRequest?

    private(set) var history: [SettingsNavigationDestination]
    private(set) var historyIndex: Int
    private(set) var focusedSearchField: SettingsSearchField?

    private let pluginSettingsLandingPage: () -> FeatureSettingsPane
    private let sidebarOrder: () -> [SettingsNavigationDestination]
    private let isPluginConfigurationAvailable: (String) -> Bool
    private let hasPluginSettingsSearchField: (String) -> Bool
    private let focusPluginSettingsSearch: (String) -> Bool
    private let isPluginSettingsSearchTargetAvailable: (PluginSettingsSearchTarget) -> Bool
    private let isPluginManagementAvailable: (String) -> Bool
    private let isPluginSurfaceAvailable: (SurfaceSettingsSearchTarget) -> Bool
    private let isAutomationWorkflowAvailable: (UUID) -> Bool
    private let selectPluginSettingsPane: (FeatureSettingsPane) -> Bool
    private var nextSearchFocusRequestID: UInt = 0
    private var nextAboutUpdateActionRequestID: UInt = 0
    private var nextSearchRevealRequestID: UInt = 0
    private var nextUnifiedSearchQuickSelectionRequestID: UInt = 0

    convenience init(
        pluginHost: PluginHost,
        sidebarPreferences: SettingsSidebarPreferencesStore? = nil
    ) {
        self.init(
            pluginSettingsLandingPage: { pluginHost.pluginSettingsLandingPage() },
            sidebarOrder: {
                let settingsItems = pluginHost.pluginSettingsItems
                let orderItems = settingsItems.map {
                    SettingsSidebarPluginOrderItem(
                        id: $0.id,
                        title: $0.title,
                        installedAt: $0.installedAt
                    )
                }
                let configurationIDs = sidebarPreferences?.orderedPluginIDs(for: orderItems)
                    ?? settingsItems.map(\.id)
                return SettingsNavigationDestination.settingsSidebarOrder(
                    configurationIDs: configurationIDs
                )
            },
            isPluginConfigurationAvailable: { pluginHost.hasPluginSettings(pluginID: $0) },
            hasPluginSettingsSearchField: { pluginHost.hasPluginSettingsSearchField(pluginID: $0) },
            focusPluginSettingsSearch: { pluginHost.focusPluginSettingsSearch(pluginID: $0) },
            isPluginSettingsSearchTargetAvailable: {
                pluginHost.hasPluginSettingsSearchTarget($0)
            },
            isPluginManagementAvailable: { pluginID in
                MarketplacePluginSearchAvailability.contains(
                    pluginID: pluginID,
                    in: pluginHost.pluginManagementItems
                )
            },
            isPluginSurfaceAvailable: { target in
                let items = switch target.surface {
                case .dashboard:
                    pluginHost.dashboardLayoutItems + pluginHost.dashboardHiddenLayoutItems
                case .featurePanel:
                    pluginHost.featurePanelLayoutItems + pluginHost.featurePanelHiddenLayoutItems
                }
                return items.contains { $0.id == target.pluginID }
            },
            isAutomationWorkflowAvailable: { workflowID in
                pluginHost.automationController.workflows.contains { $0.id == workflowID }
            },
            selectPluginSettingsPane: { pluginHost.selectFeatureSettingsPane($0) }
        )
    }

    init(
        initialDestination: SettingsNavigationDestination = .general,
        pluginSettingsLandingPage: @escaping () -> FeatureSettingsPane = { .marketplace },
        sidebarOrder: @escaping () -> [SettingsNavigationDestination] = { [] },
        isPluginConfigurationAvailable: @escaping (String) -> Bool = { _ in true },
        hasPluginSettingsSearchField: @escaping (String) -> Bool = { _ in false },
        focusPluginSettingsSearch: @escaping (String) -> Bool = { _ in false },
        isPluginSettingsSearchTargetAvailable: @escaping (PluginSettingsSearchTarget) -> Bool = { _ in true },
        isPluginManagementAvailable: @escaping (String) -> Bool = { _ in true },
        isPluginSurfaceAvailable: @escaping (SurfaceSettingsSearchTarget) -> Bool = { _ in true },
        isAutomationWorkflowAvailable: @escaping (UUID) -> Bool = { _ in true },
        selectPluginSettingsPane: @escaping (FeatureSettingsPane) -> Bool = { _ in true }
    ) {
        self.destination = initialDestination
        self.history = [initialDestination]
        self.historyIndex = 0
        self.pluginSettingsLandingPage = pluginSettingsLandingPage
        self.sidebarOrder = sidebarOrder
        self.isPluginConfigurationAvailable = isPluginConfigurationAvailable
        self.hasPluginSettingsSearchField = hasPluginSettingsSearchField
        self.focusPluginSettingsSearch = focusPluginSettingsSearch
        self.isPluginSettingsSearchTargetAvailable = isPluginSettingsSearchTargetAvailable
        self.isPluginManagementAvailable = isPluginManagementAvailable
        self.isPluginSurfaceAvailable = isPluginSurfaceAvailable
        self.isAutomationWorkflowAvailable = isAutomationWorkflowAvailable
        self.selectPluginSettingsPane = selectPluginSettingsPane
    }

    var canGoBack: Bool {
        traversableHistoryIndex(startingAt: historyIndex - 1, step: -1) != nil
    }

    var canGoForward: Bool {
        traversableHistoryIndex(startingAt: historyIndex + 1, step: 1) != nil
    }

    func selectSettingsDestination(_ destination: SettingsDestination) {
        guard self.destination.settingsDestination != destination else {
            return
        }

        switch destination {
        case .general:
            navigate(to: .general)
        case .about:
            navigate(to: .about)
        case .pluginConfiguration:
            navigate(to: .plugins(pluginSettingsLandingPage()))
        }
    }

    func navigate(to destination: SettingsNavigationDestination) {
        guard isAvailable(destination), destination != self.destination else {
            return
        }

        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }

        history.append(destination)
        if history.count > Self.maximumHistoryCount {
            history.removeFirst(history.count - Self.maximumHistoryCount)
        }
        historyIndex = history.count - 1
        activate(destination)
    }

    @discardableResult
    func moveSidebarSelection(
        _ direction: SettingsSidebarMoveDirection,
        in orderedDestinations: [SettingsNavigationDestination]
    ) -> Bool {
        guard
            let currentIndex = orderedDestinations.firstIndex(of: destination)
        else {
            return false
        }

        let step = switch direction {
        case .previous:
            -1
        case .next:
            1
        }
        var adjacentIndex = currentIndex + step

        while orderedDestinations.indices.contains(adjacentIndex) {
            let candidate = orderedDestinations[adjacentIndex]
            if isAvailable(candidate) {
                navigate(to: candidate)
                return true
            }
            adjacentIndex += step
        }
        return false
    }

    @discardableResult
    func moveSidebarSelection(_ direction: SettingsSidebarMoveDirection) -> Bool {
        moveSidebarSelection(direction, in: sidebarOrder())
    }

    @discardableResult
    func selectSidebarDestination(number: Int) -> Bool {
        guard (1...9).contains(number) else { return false }
        let availableDestinations = sidebarOrder().filter(isAvailable)
        let index = number - 1
        guard availableDestinations.indices.contains(index) else { return false }

        navigate(to: availableDestinations[index])
        return true
    }

    func requestAboutUpdateAction(version: String) {
        navigate(to: .about)
        nextAboutUpdateActionRequestID &+= 1
        aboutUpdateActionRequest = AboutUpdateActionRequest(
            id: nextAboutUpdateActionRequestID,
            version: version
        )
    }

    func presentUnifiedSearch(origin: UnifiedSearchPresentationOrigin) {
        unifiedSearchPresentationOrigin = origin
        isUnifiedSearchPresented = true
        unifiedSearchFocusRequestID &+= 1
    }

    func dismissUnifiedSearch() {
        isUnifiedSearchPresented = false
        unifiedSearchPresentationOrigin = nil
        unifiedSearchQuickSelectionRequest = nil
    }

    @discardableResult
    func requestUnifiedSearchQuickSelection(number: Int) -> Bool {
        guard isUnifiedSearchPresented, (1...9).contains(number) else {
            return false
        }

        nextUnifiedSearchQuickSelectionRequestID &+= 1
        unifiedSearchQuickSelectionRequest = UnifiedSearchQuickSelectionRequest(
            id: nextUnifiedSearchQuickSelectionRequestID,
            number: number
        )
        return true
    }

    @discardableResult
    func consumeUnifiedSearchQuickSelectionRequest(
        _ request: UnifiedSearchQuickSelectionRequest
    ) -> Bool {
        guard unifiedSearchQuickSelectionRequest == request else {
            return false
        }

        unifiedSearchQuickSelectionRequest = nil
        return true
    }

    @discardableResult
    func navigateFromSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        guard canNavigateFromSearch(to: destination, target: target) else {
            return false
        }

        dismissUnifiedSearch()
        navigate(to: destination)

        guard let target else {
            searchRevealRequest = nil
            return true
        }

        nextSearchRevealRequestID &+= 1
        searchRevealRequest = SettingsSearchRevealRequest(
            id: nextSearchRevealRequestID,
            target: target
        )
        return true
    }

    func canNavigateFromSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        isAvailable(destination)
            && (target.map(isAvailable) ?? true)
            && (target.map { isCompatible($0, with: destination) } ?? true)
    }

    func clearSearchRevealRequest(_ request: SettingsSearchRevealRequest) {
        guard searchRevealRequest == request else {
            return
        }

        searchRevealRequest = nil
    }

    func clearSearchRevealRequest(matching target: SettingsSearchRevealTarget) {
        guard searchRevealRequest?.target == target else {
            return
        }

        searchRevealRequest = nil
    }

    @discardableResult
    func consumeAboutUpdateActionRequest(_ request: AboutUpdateActionRequest) -> Bool {
        guard aboutUpdateActionRequest == request else {
            return false
        }

        aboutUpdateActionRequest = nil
        return true
    }

    func goBack() {
        traverseHistory(startingAt: historyIndex - 1, step: -1)
    }

    func goForward() {
        traverseHistory(startingAt: historyIndex + 1, step: 1)
    }

    func reconcileCurrentDestinationAvailability() {
        guard !isAvailable(destination) else {
            return
        }

        navigate(to: .plugins(.marketplace))
    }

    @discardableResult
    func requestSearchFocus() -> Bool {
        guard
            !isUnifiedSearchPresented,
            let field = searchField(for: destination),
            focusedSearchField != field
        else {
            return false
        }

        if case let .pluginSettings(pluginID) = field {
            return focusPluginSettingsSearch(pluginID)
        }

        nextSearchFocusRequestID &+= 1
        searchFocusRequest = SettingsSearchFocusRequest(
            id: nextSearchFocusRequestID,
            field: field
        )
        return true
    }

    @discardableResult
    func requestSearch() -> Bool {
        guard !isUnifiedSearchPresented else {
            return false
        }

        if let searchField = searchField(for: destination) {
            if focusedSearchField == searchField {
                return true
            }
            return requestSearchFocus()
        }

        presentUnifiedSearch(origin: .keyboard)
        return true
    }

    func setSearchField(_ field: SettingsSearchField, focused: Bool) {
        if focused {
            focusedSearchField = field
        } else if focusedSearchField == field {
            focusedSearchField = nil
        }
    }

    private func searchField(for destination: SettingsNavigationDestination) -> SettingsSearchField? {
        switch destination {
        case .plugins(.marketplace):
            .pluginMarketplace
        case let .plugins(.configuration(pluginID)) where hasPluginSettingsSearchField(pluginID):
            .pluginSettings(pluginID)
        default:
            nil
        }
    }

    private func traverseHistory(startingAt index: Int, step: Int) {
        guard let index = traversableHistoryIndex(startingAt: index, step: step) else {
            return
        }

        let destination = history[index]
        historyIndex = index
        activate(destination)
    }

    private func traversableHistoryIndex(startingAt index: Int, step: Int) -> Int? {
        var index = index

        while history.indices.contains(index) {
            let candidate = history[index]
            if isAvailable(candidate), candidate != destination {
                return index
            }

            index += step
        }

        return nil
    }

    private func isAvailable(_ destination: SettingsNavigationDestination) -> Bool {
        guard case let .plugins(.configuration(pluginID)) = destination else {
            return true
        }

        return isPluginConfigurationAvailable(pluginID)
    }

    private func isAvailable(_ target: SettingsSearchRevealTarget) -> Bool {
        switch target {
        case .general:
            true
        case let .marketplace(target):
            isPluginManagementAvailable(target.pluginID)
        case let .plugin(target):
            isPluginSettingsSearchTargetAvailable(target)
        case let .surface(target):
            isPluginSurfaceAvailable(target)
        case let .automation(target):
            isAutomationWorkflowAvailable(target.workflowID)
        }
    }

    private func isCompatible(
        _ target: SettingsSearchRevealTarget,
        with destination: SettingsNavigationDestination
    ) -> Bool {
        switch (target, destination) {
        case (.general, .general):
            true
        case (.marketplace, .plugins(.marketplace)):
            true
        case let (.plugin(target), .plugins(.configuration(pluginID))):
            target.pluginID == pluginID
        case let (.surface(target), .plugins(pane)):
            switch (target.surface, pane) {
            case (.dashboard, .dashboardLayout), (.featurePanel, .featurePanelLayout):
                true
            default:
                false
            }
        case (.automation, .plugins(.automation)):
            true
        default:
            false
        }
    }

    private func activate(_ destination: SettingsNavigationDestination) {
        if let pane = destination.featureSettingsPane {
            _ = selectPluginSettingsPane(pane)
        }

        self.destination = destination
    }
}
