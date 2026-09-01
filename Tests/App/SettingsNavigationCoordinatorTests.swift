import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class SettingsNavigationCoordinatorTests: XCTestCase {
    func testPluginSidebarOrderPlacesBuiltInPanesBeforeDisplayedConfigurations() {
        XCTAssertEqual(
            FeatureSettingsPane.settingsSidebarOrder(
                configurationIDs: ["calendar", "fan-control"]
            ),
            [
                .actionsAndShortcuts,
                .automation,
                .dashboardLayout,
                .featurePanelLayout,
                .marketplace,
                .configuration("calendar"),
                .configuration("fan-control")
            ]
        )
    }

    func testSettingsSidebarOrderGroupsAppCustomizeAndPluginPages() {
        XCTAssertEqual(
            SettingsNavigationDestination.settingsSidebarOrder(
                configurationIDs: ["calendar", "fan-control"]
            ),
            [
                .general,
                .permissions,
                .about,
                .plugins(.actionsAndShortcuts),
                .plugins(.automation),
                .plugins(.dashboardLayout),
                .plugins(.featurePanelLayout),
                .plugins(.marketplace),
                .plugins(.configuration("calendar")),
                .plugins(.configuration("fan-control"))
            ]
        )
    }

    func testMovesSidebarSelectionInSuppliedVisualOrder() {
        let orderedDestinations: [SettingsNavigationDestination] = [
            .general,
            .plugins(.automation),
            .about,
            .plugins(.actionsAndShortcuts)
        ]
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.automation)
        )

        coordinator.moveSidebarSelection(.previous, in: orderedDestinations)
        XCTAssertEqual(coordinator.destination, .general)

        coordinator.moveSidebarSelection(.next, in: orderedDestinations)
        XCTAssertEqual(coordinator.destination, .plugins(.automation))

        coordinator.moveSidebarSelection(.next, in: orderedDestinations)
        XCTAssertEqual(coordinator.destination, .about)

        coordinator.moveSidebarSelection(.next, in: orderedDestinations)
        XCTAssertEqual(coordinator.destination, .plugins(.actionsAndShortcuts))
    }

    func testSidebarSelectionMovementStopsAtBothBoundaries() {
        let orderedDestinations: [SettingsNavigationDestination] = [
            .general,
            .plugins(.marketplace),
            .about
        ]
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .general
        )

        coordinator.moveSidebarSelection(.previous, in: orderedDestinations)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])

        coordinator.navigate(to: .about)
        coordinator.moveSidebarSelection(.next, in: orderedDestinations)
        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertEqual(
            coordinator.history,
            [.general, .about]
        )
    }

    func testSidebarSelectionMovementSkipsUnavailablePluginConfigurations() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { _ in false }
        )

        coordinator.moveSidebarSelection(
            .next,
            in: [
                .general,
                .plugins(.configuration("removed-plugin")),
                .about
            ]
        )

        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertEqual(coordinator.history, [.general, .about])
    }

    func testSidebarSelectionMovementRecordsHistoryAndInvalidatesForwardHistory() {
        let orderedDestinations: [SettingsNavigationDestination] = [
            .general,
            .plugins(.automation),
            .about
        ]
        let coordinator = SettingsNavigationCoordinator()
        coordinator.navigate(to: .plugins(.automation))
        coordinator.navigate(to: .about)
        coordinator.goBack()

        coordinator.moveSidebarSelection(.previous, in: orderedDestinations)

        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(
            coordinator.history,
            [
                .general,
                .plugins(.automation),
                .general
            ]
        )
        XCTAssertFalse(coordinator.canGoForward)
    }

    func testSidebarSelectionMovementPublishesARepeatableUIRequest() {
        let coordinator = SettingsNavigationCoordinator(
            sidebarOrder: {
                [.general, .plugins(.automation), .about]
            }
        )

        XCTAssertTrue(coordinator.moveSidebarSelection(.next))
        XCTAssertEqual(
            coordinator.sidebarMoveShortcutRequest,
            SidebarMoveShortcutRequest(id: 1, direction: .next)
        )
        XCTAssertEqual(coordinator.destination, .general)

        XCTAssertTrue(coordinator.moveSidebarSelection(.previous))
        XCTAssertEqual(
            coordinator.sidebarMoveShortcutRequest,
            SidebarMoveShortcutRequest(id: 2, direction: .previous)
        )
    }

    func testNumberSelectionPublishesRepeatableDynamicSidebarRequests() {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertTrue(coordinator.performSidebarNumberShortcut(number: 3))
        XCTAssertEqual(
            coordinator.sidebarNumberShortcutRequest,
            SidebarNumberShortcutRequest(id: 1, number: 3)
        )
        XCTAssertFalse(coordinator.performSidebarNumberShortcut(number: 0))
        XCTAssertFalse(coordinator.performSidebarNumberShortcut(number: 10))
        XCTAssertTrue(coordinator.performSidebarNumberShortcut(number: 9))
        XCTAssertEqual(
            coordinator.sidebarNumberShortcutRequest,
            SidebarNumberShortcutRequest(id: 2, number: 9)
        )
    }

    func testPluginSidebarSearchHasDedicatedRepeatableRequest() {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertEqual(coordinator.pluginSidebarSearchFocusRequestID, 0)
        XCTAssertTrue(coordinator.requestPluginSidebarSearch())
        XCTAssertEqual(coordinator.pluginSidebarSearchFocusRequestID, 1)
        XCTAssertTrue(coordinator.requestPluginSidebarSearch())
        XCTAssertEqual(coordinator.pluginSidebarSearchFocusRequestID, 2)
    }

    func testPluginSidebarSearchDismissesUnifiedSearchBeforeRequestingFocus() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertTrue(coordinator.requestPluginSidebarSearch())

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertNil(coordinator.unifiedSearchPresentationOrigin)
        XCTAssertEqual(coordinator.pluginSidebarSearchFocusRequestID, 1)
    }

    func testDynamicNumberingUsesVisibleRowsCollapsedHeadersAndSearchResults() {
        let app: [SettingsNavigationDestination] = [.general, .permissions, .about]
        let customize: [SettingsNavigationDestination] = [
            .plugins(.actionsAndShortcuts), .plugins(.automation)
        ]
        let plugins: [SettingsNavigationDestination] = (1...8).map {
            .plugins(.configuration("plugin-\($0)"))
        }

        XCTAssertEqual(
            SettingsSidebarNumberingPolicy.targets(
                appDestinations: app,
                customizeDestinations: customize,
                pluginDestinations: plugins,
                appExpanded: false,
                customizeExpanded: true,
                pluginSettingsExpanded: false,
                pluginSearchIsActive: false
            ),
            [
                .collapsedSection(.app),
                .destination(.plugins(.actionsAndShortcuts)),
                .destination(.plugins(.automation)),
                .collapsedSection(.pluginSettings)
            ]
        )

        XCTAssertEqual(
            SettingsSidebarNumberingPolicy.targets(
                appDestinations: app,
                customizeDestinations: customize,
                pluginDestinations: plugins,
                appExpanded: false,
                customizeExpanded: false,
                pluginSettingsExpanded: true,
                pluginSearchIsActive: true
            ),
            plugins.prefix(9).map(SettingsSidebarNumberTarget.destination)
        )

        XCTAssertEqual(
            SettingsSidebarNumberingPolicy.targets(
                appDestinations: app,
                customizeDestinations: customize,
                pluginDestinations: plugins,
                appExpanded: false,
                customizeExpanded: false,
                pluginSettingsExpanded: false,
                pluginSearchIsActive: true
            ),
            [.collapsedSection(.pluginSettings)]
        )

        let collapsedSearchTargets = SettingsSidebarNumberingPolicy.targets(
            appDestinations: app,
            customizeDestinations: customize,
            pluginDestinations: plugins,
            appExpanded: false,
            customizeExpanded: false,
            pluginSettingsExpanded: false,
            pluginSearchIsActive: true
        )
        let expandedSearchTargets = SettingsSidebarNumberingPolicy.targets(
            appDestinations: app,
            customizeDestinations: customize,
            pluginDestinations: plugins,
            appExpanded: false,
            customizeExpanded: false,
            pluginSettingsExpanded: true,
            pluginSearchIsActive: true
        )
        XCTAssertEqual(collapsedSearchTargets.first, .collapsedSection(.pluginSettings))
        XCTAssertEqual(expandedSearchTargets.first, .destination(plugins[0]))
    }

    func testCollapsedHeaderAccessibilityIncludesKeyboardHighlight() {
        XCTAssertTrue(SettingsSidebarHeaderAccessibility.isActive(
            containsSelection: false,
            isKeyboardHighlighted: true
        ))
        XCTAssertTrue(SettingsSidebarHeaderAccessibility.isActive(
            containsSelection: true,
            isKeyboardHighlighted: false
        ))
        XCTAssertFalse(SettingsSidebarHeaderAccessibility.isActive(
            containsSelection: false,
            isKeyboardHighlighted: false
        ))
    }

    func testFilteredSidebarMovementStartsFromTheVisibleHighlight() {
        let first = SettingsSidebarNumberTarget.destination(
            .plugins(.configuration("homebrew"))
        )
        let second = SettingsSidebarNumberTarget.destination(
            .plugins(.configuration("launch-control"))
        )
        let targets = [first, second]

        XCTAssertEqual(
            SettingsSidebarNumberingPolicy.movedTarget(
                from: first,
                direction: .next,
                in: targets
            ),
            second
        )
        XCTAssertEqual(
            SettingsSidebarNumberingPolicy.movedTarget(
                from: .destination(.general),
                direction: .next,
                in: targets
            ),
            first
        )
        XCTAssertNil(
            SettingsSidebarNumberingPolicy.movedTarget(
                from: first,
                direction: .previous,
                in: targets
            )
        )
    }

    func testRecordsCompletePluginDestinationsAndRestoresExactPaneDuringTraversal() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        coordinator.navigate(to: .plugins(.dashboardLayout))
        coordinator.navigate(to: .plugins(.featurePanelLayout))
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        coordinator.navigate(to: .about)

        XCTAssertEqual(
            coordinator.history,
            [
                .general,
                .plugins(.dashboardLayout),
                .plugins(.featurePanelLayout),
                .plugins(.marketplace),
                .plugins(.configuration("fan-control")),
                .about
            ]
        )

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))

        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))
        XCTAssertEqual(coordinator.history.count, 6)
        XCTAssertEqual(coordinator.historyIndex, 4)
    }

    func testMarketplaceDetailParticipatesInHistoryAndKeepsMarketplaceSidebarSelection() {
        let target = MarketplacePluginDetailTarget(pluginID: "fan-control")
        let coordinator = SettingsNavigationCoordinator(
            isMarketplaceDetailAvailable: { $0 == target }
        )

        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.navigate(to: .marketplaceDetail(target))
        coordinator.navigate(to: .about)

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .marketplaceDetail(target))
        XCTAssertEqual(coordinator.destination.sidebarDestination, .plugins(.marketplace))
        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .marketplaceDetail(target))
    }

    func testMarketplaceDetailFallsBackToMarketplaceWhenCatalogItemDisappears() {
        var isAvailable = true
        let coordinator = SettingsNavigationCoordinator(
            isMarketplaceDetailAvailable: { _ in isAvailable }
        )
        coordinator.navigate(to: .marketplaceDetail(.init(pluginID: "fan-control")))

        isAvailable = false
        coordinator.reconcileCurrentDestinationAvailability()

        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
    }

    func testSuppressesConsecutiveDuplicateDestinations() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)
        coordinator.navigate(to: .about)

        XCTAssertEqual(coordinator.history, [.general, .about])
        XCTAssertEqual(coordinator.historyIndex, 1)
    }

    func testNormalNavigationAfterBackInvalidatesForwardHistory() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.goBack()
        coordinator.navigate(to: .plugins(.dashboardLayout))

        XCTAssertEqual(
            coordinator.history,
            [.general, .about, .plugins(.dashboardLayout)]
        )
        XCTAssertEqual(coordinator.destination, .plugins(.dashboardLayout))
        XCTAssertFalse(coordinator.canGoForward)
    }

    func testTraversalSkipsPluginConfigurationsThatAreNoLongerAvailable() {
        var availableConfigurationIDs: Set<String> = ["fan-control"]
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { availableConfigurationIDs.contains($0) }
        )

        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        coordinator.navigate(to: .plugins(.marketplace))
        availableConfigurationIDs.remove("fan-control")

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertTrue(coordinator.canGoForward)

        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
    }

    func testSearchFocusRequestsAreContextualAndRepeatOnlyAfterFocusLeaves() {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertFalse(coordinator.requestSearchFocus())
        XCTAssertNil(coordinator.searchFocusRequest)

        coordinator.navigate(to: .plugins(.marketplace))
        XCTAssertTrue(coordinator.requestSearchFocus())
        let firstRequest = coordinator.searchFocusRequest
        XCTAssertEqual(firstRequest?.field, .pluginMarketplace)

        coordinator.setSearchField(.pluginMarketplace, focused: true)
        XCTAssertFalse(coordinator.requestSearchFocus())
        XCTAssertEqual(coordinator.searchFocusRequest, firstRequest)

        coordinator.setSearchField(.pluginMarketplace, focused: false)
        XCTAssertTrue(coordinator.requestSearchFocus())
        XCTAssertNotEqual(coordinator.searchFocusRequest, firstRequest)
    }

    func testSearchRequestDoesNotFallBackWithoutContextualSearch() {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertFalse(coordinator.requestSearch())

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertNil(coordinator.unifiedSearchPresentationOrigin)
        XCTAssertNil(coordinator.searchFocusRequest)
    }

    func testSearchRequestPrefersAndRetainsContextualSearch() {
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.marketplace)
        )

        XCTAssertTrue(coordinator.requestSearch())
        let firstRequest = coordinator.searchFocusRequest
        XCTAssertEqual(firstRequest?.field, .pluginMarketplace)
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)

        coordinator.setSearchField(.pluginMarketplace, focused: true)
        XCTAssertTrue(coordinator.requestSearch())
        XCTAssertEqual(coordinator.searchFocusRequest, firstRequest)
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
    }

    func testSearchRequestDoesNotTreatMarketplaceDetailAsLocalSearch() {
        let target = MarketplacePluginDetailTarget(pluginID: "fan-control")
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .marketplaceDetail(target)
        )

        XCTAssertFalse(coordinator.requestSearch())
        XCTAssertNil(coordinator.searchFocusRequest)
    }

    func testSearchRequestFocusesPluginContextualSearch() {
        var focusedPluginIDs: [String] = []
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .plugins(.configuration("apple-shortcuts")),
            hasPluginSettingsSearchField: { $0 == "apple-shortcuts" },
            focusPluginSettingsSearch: {
                focusedPluginIDs.append($0)
                return true
            }
        )

        XCTAssertTrue(coordinator.requestSearch())
        XCTAssertEqual(focusedPluginIDs, ["apple-shortcuts"])
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertNil(coordinator.searchFocusRequest)
    }

    func testAboutUpdateActionNavigatesAndCanOnlyBeConsumedOnce() throws {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.requestAboutUpdateAction(version: "1.2.3")

        XCTAssertEqual(coordinator.destination, .about)
        let request = try XCTUnwrap(coordinator.aboutUpdateActionRequest)
        XCTAssertEqual(request.version, "1.2.3")
        XCTAssertTrue(coordinator.consumeAboutUpdateActionRequest(request))
        XCTAssertNil(coordinator.aboutUpdateActionRequest)
        XCTAssertFalse(coordinator.consumeAboutUpdateActionRequest(request))
    }

    func testRegularAboutNavigationDoesNotRequestAutomaticUpdateAction() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)

        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertNil(coordinator.aboutUpdateActionRequest)
    }

    func testUnifiedSearchPresentationTracksOriginAndRepeatedFocusRequests() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.presentUnifiedSearch(origin: .settingsSidebar)
        let firstFocusRequestID = coordinator.unifiedSearchFocusRequestID

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.unifiedSearchPresentationOrigin, .settingsSidebar)

        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.unifiedSearchPresentationOrigin, .keyboard)
        XCTAssertGreaterThan(coordinator.unifiedSearchFocusRequestID, firstFocusRequestID)

        coordinator.presentUnifiedSearch(origin: .globalShortcut("⌥⌘P"))
        XCTAssertEqual(
            coordinator.unifiedSearchPresentationOrigin,
            .globalShortcut("⌥⌘P")
        )

        coordinator.dismissUnifiedSearch()

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertNil(coordinator.unifiedSearchPresentationOrigin)
    }

    func testLocalSearchFocusDoesNotMoveBehindUnifiedSearch() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertFalse(coordinator.requestSearchFocus())
        XCTAssertNil(coordinator.searchFocusRequest)
    }

    func testUnifiedSearchQuickSelectionRequestsAreValidatedAndRepeatable() throws {
        let coordinator = SettingsNavigationCoordinator()

        XCTAssertFalse(coordinator.requestUnifiedSearchQuickSelection(number: 1))
        coordinator.presentUnifiedSearch(origin: .keyboard)
        XCTAssertFalse(coordinator.requestUnifiedSearchQuickSelection(number: 0))
        XCTAssertFalse(coordinator.requestUnifiedSearchQuickSelection(number: 10))

        XCTAssertTrue(coordinator.requestUnifiedSearchQuickSelection(number: 1))
        let firstRequest = try XCTUnwrap(coordinator.unifiedSearchQuickSelectionRequest)
        XCTAssertEqual(firstRequest.number, 1)

        XCTAssertTrue(coordinator.requestUnifiedSearchQuickSelection(number: 1))
        let secondRequest = try XCTUnwrap(coordinator.unifiedSearchQuickSelectionRequest)
        XCTAssertNotEqual(firstRequest.id, secondRequest.id)

        coordinator.dismissUnifiedSearch()
        XCTAssertNil(coordinator.unifiedSearchQuickSelectionRequest)
    }

    func testSearchNavigationKeepsPaletteOpenForUnavailablePlugin() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { _ in false }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("removed-plugin")),
            target: .plugin(
                PluginSettingsSearchTarget(
                    pluginID: "removed-plugin",
                    entryID: "setting"
                )
            )
        )

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationRejectsMismatchedTargetAndDestination() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertFalse(
            coordinator.navigateFromSearch(
                to: .plugins(.featurePanelLayout),
                target: .surface(
                    SurfaceSettingsSearchTarget(
                        surface: .dashboard,
                        pluginID: "display"
                    )
                )
            )
        )
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationRevealsAvailableMarketplacePlugin() throws {
        let target = MarketplacePluginSearchTarget(pluginID: "failed-plugin")
        let coordinator = SettingsNavigationCoordinator(
            isPluginManagementAvailable: { $0 == target.pluginID }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertTrue(
            coordinator.navigateFromSearch(
                to: .plugins(.marketplace),
                target: .marketplace(target)
            )
        )
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
        XCTAssertEqual(
            try XCTUnwrap(coordinator.searchRevealRequest).target,
            .marketplace(target)
        )
    }

    func testAvailableManagementItemCanBeRevealedFromMarketplaceSearch() {
        let item = PluginManagementItem(
            id: "available-plugin",
            title: "Available Plugin",
            summary: nil,
            version: "1.0.0",
            state: .available,
            packageURL: nil,
            requiresRestartToFullyUnload: false,
            releaseNotesURL: nil
        )

        XCTAssertTrue(
            MarketplacePluginSearchAvailability.contains(
                pluginID: item.id,
                in: [item]
            )
        )
    }

    func testSearchNavigationDismissesPaletteAndPublishesExactRevealTarget() throws {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "keep-awake" }
        )
        let target = PluginSettingsSearchTarget(
            pluginID: "keep-awake",
            entryID: "keep-display-on"
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("keep-awake")),
            target: .plugin(target)
        )

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(
            coordinator.destination,
            .plugins(.configuration("keep-awake"))
        )
        let request = try XCTUnwrap(coordinator.searchRevealRequest)
        XCTAssertEqual(request.target, .plugin(target))

        coordinator.clearSearchRevealRequest(request)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testPageLevelSearchNavigationClearsPreviousRevealTarget() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "keep-awake" }
        )
        let target = PluginSettingsSearchTarget(
            pluginID: "keep-awake",
            entryID: "keep-display-on"
        )

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("keep-awake")),
            target: .plugin(target)
        )
        coordinator.navigateFromSearch(to: .about, target: nil)

        XCTAssertEqual(coordinator.destination, .about)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testGeneralSettingSearchNavigationPublishesExactRevealTarget() throws {
        let coordinator = SettingsNavigationCoordinator(
            initialDestination: .about
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .general,
            target: .general(.language)
        )

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        let request = try XCTUnwrap(coordinator.searchRevealRequest)
        XCTAssertEqual(request.target, .general(.language))
    }
}
