import Combine
import Carbon
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class MacToolsSearchTests: XCTestCase {
    func testIndexIncludesNavigationDeclarativeSettingsCustomSettingsAndCommands() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin, SurfaceOnlySearchTestPlugin()])
        let appCommand = appHostCommandDefinition(
            id: "app-command.toggle-dashboard",
            action: .appShortcut(.toggleDashboard)
        )
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: host,
            appHostCommandDefinitions: [appCommand]
        )

        XCTAssertTrue(index.items.contains {
            $0.kind == .navigation && $0.title == plugin.metadata.title
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "自动切换"
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .setting && $0.title == "暂不可用设置"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "辅助功能授权"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "降低亮度"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .setting && $0.title == "快捷键目标"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .command && $0.title == "让显示器休眠"
        })
        XCTAssertTrue(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.toggleDashboard.title
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.openCommandPalette.title
        })
        XCTAssertFalse(index.items.contains {
            $0.kind == .command && $0.title == AppShortcutAction.openSettings.title
        })
        XCTAssertFalse(index.items.contains {
            $0.id == "app-command.open-command-palette"
        })
        XCTAssertFalse(index.items.contains {
            $0.id == "app-command.open-settings"
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.appearance" && $0.kind == .setting
        })
        XCTAssertTrue(index.items.contains {
            $0.id == "general-setting.preferencesBackup" && $0.kind == .setting
        })
    }

    func testCommandResultsCarryCanonicalActionReferences() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == "让显示器休眠"
            }
        )

        guard case let .executeAction(reference) = result.action else {
            return XCTFail("Expected the shared action executor route")
        }
        XCTAssertEqual(reference.key, ActionKey(providerID: "searchable", actionID: "sleep"))
        XCTAssertNotNil(try? host.actionRegistry.registeredAction(for: reference).get())
        XCTAssertEqual(
            host.actionShortcutCatalogItems.first(where: { $0.reference == reference })?.status,
            .unassigned
        )
    }

    func testActionSubtitleKeepsOwnerMetadataCompactAndDistinct() {
        XCTAssertEqual(
            MacToolsSearchSupportingText.actionSubtitle(
                ownerTitle: "MacTools",
                catalogSubtitle: "  mAcToOlS  "
            ),
            "MacTools"
        )
        XCTAssertEqual(
            MacToolsSearchSupportingText.actionSubtitle(
                ownerTitle: "IP Check",
                catalogSubtitle: "Copy Address"
            ),
            "IP Check · Copy Address"
        )
        XCTAssertEqual(
            MacToolsSearchSupportingText.actionSubtitle(
                ownerTitle: "MacTools",
                catalogSubtitle: "  "
            ),
            "MacTools"
        )
    }

    func testMacToolsSearchActionExecutesThroughPresentationRouting() async throws {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == AppShortcutAction.toggleDashboard.title
            }
        )
        guard case let .executeAction(reference) = result.action else {
            return XCTFail("Expected a canonical action")
        }

        let outcome = await host.actionExecutor.execute(
            ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground)
        )

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertEqual(requests, [.toggleDashboard])
    }

    func testExcludedAppShortcutsDoNotLeakIntoSearchKeywords() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [])
        )

        for action in [AppShortcutAction.openSettings, .openCommandPalette] {
            XCTAssertFalse(
                index.results(matching: action.title).contains {
                    $0.id == "general-setting.appShortcuts"
                },
                "\(action.title) must not be indexed through shortcut keywords"
            )
        }
    }

    func testAppShortcutsAreNotAutomaticallyPromotedIntoCommands() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [])
        )

        XCTAssertFalse(index.items.contains {
            if case .appHostCommand = $0.action {
                return true
            }
            return false
        })
    }

    func testAppHostCommandCarriesExpectedDefinitionConfirmationAndKeywords() throws {
        let confirmation = MacToolsCommandConfirmation(
            title: "确认命令",
            message: "确认执行此命令。",
            confirmButtonTitle: "执行"
        )
        let definition = AppHostCommandDefinition(
            id: "app-command.test-confirmed",
            title: "测试命令",
            description: "用于验证确认流程。",
            keywords: ["confirmed", "确认"],
            systemImage: "checkmark.circle",
            confirmation: confirmation,
            action: .setLaunchAtLogin(true)
        )
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: []),
            appHostCommandDefinitions: [definition]
        )
        let result = try XCTUnwrap(index.items.first { $0.id == definition.id })

        XCTAssertEqual(result.action, .appHostCommand(expectedDefinition: definition))
        XCTAssertEqual(result.confirmation, confirmation)
        XCTAssertEqual(
            MacToolsSearchActivationDecision.resolve(for: result),
            .confirm(confirmation)
        )
        XCTAssertEqual(index.results(matching: "confirmed").first?.id, definition.id)
        XCTAssertEqual(index.results(matching: "确认").first?.id, definition.id)
    }

    func testModelAutomaticallyRebuildsAfterPluginVisibilityChanges() async throws {
        let plugin = SurfaceOnlySearchTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let suiteName = "MacToolsSearchModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = AppHostCommandContext(
            pluginHost: host,
            launchAtLoginController: LaunchAtLoginController(
                service: SearchTestLaunchAtLoginService()
            ),
            appearanceUserDefaults: defaults
        )
        let model = UnifiedSearchPaletteModel(
            commandContext: context,
            recentStore: CommandPaletteRecentStore(userDefaults: defaults)
        )
        model.updateQuery(plugin.metadata.title)
        let hideAction = AppHostCommandAction.setPluginVisibility(
            pluginID: plugin.metadata.id,
            surface: .featurePanel,
            isVisible: false
        )
        let showAction = AppHostCommandAction.setPluginVisibility(
            pluginID: plugin.metadata.id,
            surface: .featurePanel,
            isVisible: true
        )
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == hideAction
        })
        let (rebuild, cancellable) = expectModelResults(
            model,
            description: "Visibility change rebuilds the command index"
        ) { results in
            results.contains { result in
                guard case let .appHostCommand(definition) = result.action else {
                    return false
                }
                return definition.action == showAction
            }
        }

        host.setPluginVisible(false, id: plugin.metadata.id, on: .featurePanel)

        await fulfillment(of: [rebuild], timeout: 1)
        withExtendedLifetime(cancellable) {}
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == showAction
        })
        XCTAssertFalse(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == hideAction
        })
    }

    func testModelAutomaticallyRebuildsAfterLaunchAtLoginChanges() async {
        let suiteName = "MacToolsSearchLaunchModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = SearchTestLaunchAtLoginService()
        let controller = LaunchAtLoginController(service: service)
        let context = AppHostCommandContext(
            pluginHost: makePluginHostForTests(plugins: []),
            launchAtLoginController: controller,
            appearanceUserDefaults: defaults
        )
        let model = UnifiedSearchPaletteModel(
            commandContext: context,
            recentStore: CommandPaletteRecentStore(userDefaults: defaults)
        )
        model.updateQuery("launch at login")
        let (rebuild, cancellable) = expectModelResults(
            model,
            description: "Launch-at-login change rebuilds the command index"
        ) { results in
            results.contains { result in
                guard case let .appHostCommand(definition) = result.action else {
                    return false
                }
                return definition.action == .setLaunchAtLogin(false)
            }
        }

        service.isRegistered = true
        controller.refreshStatus()

        await fulfillment(of: [rebuild], timeout: 1)
        withExtendedLifetime(cancellable) {}
        XCTAssertTrue(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == .setLaunchAtLogin(false)
        })
        XCTAssertFalse(model.results.contains { result in
            guard case let .appHostCommand(definition) = result.action else {
                return false
            }
            return definition.action == .setLaunchAtLogin(true)
        })
    }

    func testModelMigratesPersistedRecentReferencesThroughTheLiveRegistry() {
        let plugin = MigratingRecentSearchTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let suiteName = "MacToolsSearchRecentMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CommandPaletteRecentStore(userDefaults: defaults)
        let legacyReference = ActionReference(key: plugin.actionKey, schemaVersion: 1)
        let currentReference = ActionReference(key: plugin.actionKey, schemaVersion: 2)
        XCTAssertTrue(store.recordSuccessful(legacyReference))

        let model = UnifiedSearchPaletteModel(
            commandContext: AppHostCommandContext(
                pluginHost: host,
                launchAtLoginController: LaunchAtLoginController(
                    service: SearchTestLaunchAtLoginService()
                ),
                appearanceUserDefaults: defaults
            ),
            recentStore: store
        )

        XCTAssertEqual(store.references, [currentReference])
        XCTAssertEqual(model.sections.first?.kind, .recent)
        XCTAssertEqual(model.sections.first?.results.count, 1)
        XCTAssertEqual(
            model.sections.first?.results.first?.action,
            .executeAction(currentReference)
        )
    }

    func testModelExposesAndCanRepairRejectedRecentPayload() {
        let suiteName = "MacToolsSearchRecentRepairTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data("not-json".utf8),
            forKey: "command-palette.recent-actions.v1"
        )
        let store = CommandPaletteRecentStore(userDefaults: defaults)
        let model = UnifiedSearchPaletteModel(
            commandContext: AppHostCommandContext(
                pluginHost: makePluginHostForTests(plugins: []),
                launchAtLoginController: LaunchAtLoginController(
                    service: SearchTestLaunchAtLoginService()
                ),
                appearanceUserDefaults: defaults
            ),
            recentStore: store
        )

        XCTAssertTrue(model.recentActionsNeedRepair)
        XCTAssertFalse(model.hasRecentActions)
        XCTAssertTrue(model.clearRecentActions())
        XCTAssertFalse(model.recentActionsNeedRepair)
        XCTAssertNil(defaults.object(forKey: "command-palette.recent-actions.v1"))
    }

    private func expectModelResults(
        _ model: UnifiedSearchPaletteModel,
        description: String,
        matching predicate: @escaping ([MacToolsSearchResult]) -> Bool
    ) -> (XCTestExpectation, AnyCancellable) {
        let expectation = expectation(description: description)
        let cancellable = model.$results
            .dropFirst()
            .first(where: predicate)
            .sink { _ in expectation.fulfill() }
        return (expectation, cancellable)
    }

    func testCustomSettingResultCarriesPluginPageAndExactSearchTarget() throws {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == "快捷键目标"
            }
        )

        guard case let .navigate(destination, target) = result.action else {
            return XCTFail("Expected a navigation action")
        }

        XCTAssertEqual(destination, .plugins(.configuration(plugin.metadata.id)))
        XCTAssertEqual(
            target,
            .plugin(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: SearchableTestPlugin.customEntryID
                )
            )
        )
    }

    func testEmbeddedActionShortcutSearchResultNavigatesToSharedRevealAnchor() throws {
        let plugin = ActionShortcutSearchTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == plugin.actionShortcutSettingsConfiguration.title
            }
        )
        let expectedTarget = PluginSettingsSearchTarget(
            pluginID: plugin.metadata.id,
            entryID: PluginActionShortcutSettingsConfiguration.settingsSearchEntryID
        )

        guard case let .navigate(destination, target) = result.action else {
            return XCTFail("Expected a navigation action")
        }
        XCTAssertEqual(destination, .plugins(.configuration(plugin.metadata.id)))
        XCTAssertEqual(target, .plugin(expectedTarget))
        XCTAssertTrue(host.hasPluginSettingsSearchTarget(expectedTarget))

        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == plugin.metadata.id }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)
        XCTAssertTrue(coordinator.navigateFromSearch(to: destination, target: target))
        XCTAssertEqual(coordinator.destination, destination)
        XCTAssertEqual(coordinator.searchRevealRequest?.target, .plugin(expectedTarget))
    }

    func testGeneralSettingResultCarriesGeneralPageAndExactSearchTarget() throws {
        let host = makePluginHostForTests(plugins: [])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.id == "general-setting.language"
            }
        )

        XCTAssertEqual(
            result.action,
            .navigate(destination: .general, target: .general(.language))
        )
    }

    func testSurfaceOnlyPluginNavigatesToAndRevealsItsFeaturePanelRow() throws {
        let plugin = SurfaceOnlySearchTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.title == plugin.metadata.title
            }
        )

        XCTAssertEqual(
            result.action,
            .navigate(
                destination: .plugins(.featurePanelLayout),
                target: .surface(
                    SurfaceSettingsSearchTarget(
                        surface: .featurePanel,
                        pluginID: plugin.metadata.id
                    )
                )
            )
        )
    }

    func testSearchUsesTitleDescriptionAndKeywordsWithAllTokenMatching() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)

        XCTAssertEqual(
            index.results(matching: "快捷键 目标").first?.title,
            "快捷键目标"
        )
        XCTAssertTrue(
            index.results(matching: "外接 屏幕").contains {
                $0.title == "快捷键目标"
            }
        )
        XCTAssertTrue(index.results(matching: "不存在 屏幕").isEmpty)
    }

    func testEmptyQueryReturnsOnlyOrderedSuggestedDestinations() {
        let host = makePluginHostForTests(plugins: [SearchableTestPlugin()])
        let results = MacToolsSearchIndexBuilder.build(pluginHost: host)
            .results(matching: "  ")

        XCTAssertEqual(
            results.map(\.id),
            [
                "navigation.dashboard",
                "navigation.feature-panel",
                "navigation.actions-and-shortcuts",
                "navigation.automation",
                "navigation.marketplace",
                "navigation.general",
                "navigation.about"
            ]
        )
        XCTAssertTrue(results.allSatisfy { $0.kind == .navigation })
    }

    func testFeatureNavigationUsesRuntimeLocalizedTitles() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [])
        )

        XCTAssertEqual(
            index.results(matching: FeatureL10n.string("操作与快捷键")).first?.id,
            "navigation.actions-and-shortcuts"
        )
        XCTAssertEqual(
            index.results(matching: FeatureL10n.string("自动化")).first?.id,
            "navigation.automation"
        )
    }

    func testTypedPresentationPreservesRelevanceOrderAndQuickSelectionNumbers() {
        let navigation = searchResult(id: "navigation", kind: .navigation)
        let setting = searchResult(id: "setting", kind: .setting)
        let command = searchResult(id: "command", kind: .command)
        let ordered = [
            command,
            navigation,
            setting
        ]
        let sections = MacToolsSearchPresentation.sections(
            query: "command",
            results: ordered,
            recentResults: []
        )

        XCTAssertEqual(sections.map(\.kind), [.results])
        XCTAssertEqual(sections.flatMap(\.results).map(\.id), [
            "command", "navigation", "setting"
        ])
        XCTAssertEqual(
            MacToolsSearchPresentation.quickSelectionNumber(
                for: "setting",
                in: ordered
            ),
            3
        )
        XCTAssertNil(
            MacToolsSearchPresentation.quickSelectionNumber(
                for: "missing",
                in: ordered
            )
        )
    }

    func testExactCommandMatchIsNotRegroupedBelowNavigation() {
        let exactCommand = MacToolsSearchResult(
            id: "command.dark",
            kind: .command,
            title: "Dark",
            subtitle: "Appearance",
            detail: "Use Dark appearance.",
            keywords: [],
            systemImage: "moon",
            action: .executeAction(
                ActionReference(key: ActionKey(providerID: "app", actionID: "dark"))
            ),
            confirmation: nil,
            suggestionPriority: nil
        )
        let navigation = MacToolsSearchResult(
            id: "navigation.dark-settings",
            kind: .navigation,
            title: "Dark Settings",
            subtitle: "Settings",
            detail: "Open appearance settings.",
            keywords: [],
            systemImage: "gearshape",
            action: .navigate(destination: .general, target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )
        let index = MacToolsSearchIndex(items: [navigation, exactCommand])

        XCTAssertEqual(index.results(matching: "dark").map(\.id), [
            "command.dark", "navigation.dark-settings"
        ])
    }

    func testRecencyOnlyBreaksEquivalentLexicalMatches() {
        let exact = MacToolsSearchResult(
            id: "exact",
            kind: .command,
            title: "Display",
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "display",
            action: .executeAction(
                ActionReference(key: ActionKey(providerID: "plugin", actionID: "exact"))
            ),
            confirmation: nil,
            suggestionPriority: nil
        )
        let recentPrefixReference = ActionReference(
            key: ActionKey(providerID: "plugin", actionID: "prefix")
        )
        let recentPrefix = MacToolsSearchResult(
            id: "prefix",
            kind: .command,
            title: "Display Settings",
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "display",
            action: .executeAction(recentPrefixReference),
            confirmation: nil,
            suggestionPriority: nil
        )
        let index = MacToolsSearchIndex(items: [recentPrefix, exact])

        XCTAssertEqual(
            index.results(
                matching: "display",
                recentReferences: [recentPrefixReference]
            ).map(\.id),
            ["exact", "prefix"]
        )
    }

    func testTypedSearchUsesTheDocumentedMatchTierOrder() {
        let query = "display"
        let exact = rankedSearchResult(id: "exact", title: "Display")
        let prefix = rankedSearchResult(id: "prefix", title: "Display Settings")
        let title = rankedSearchResult(id: "title", title: "Open Display Panel")
        let keyword = rankedSearchResult(
            id: "keyword",
            title: "Monitor Tools",
            keywords: [query]
        )
        let subtitle = rankedSearchResult(
            id: "subtitle",
            title: "Monitor",
            subtitle: query
        )
        let detail = rankedSearchResult(
            id: "detail",
            title: "Screen",
            detail: query
        )
        let index = MacToolsSearchIndex(
            items: [detail, subtitle, keyword, title, prefix, exact]
        )

        XCTAssertEqual(index.results(matching: query).map(\.id), [
            "exact", "prefix", "title", "keyword", "subtitle", "detail"
        ])
    }

    func testRecencyBreaksEquivalentRelevanceTies() {
        let olderReference = ActionReference(
            key: ActionKey(providerID: "plugin", actionID: "older")
        )
        let newerReference = ActionReference(
            key: ActionKey(providerID: "plugin", actionID: "newer")
        )
        let older = rankedSearchResult(
            id: "older",
            title: "Display Older",
            reference: olderReference
        )
        let newer = rankedSearchResult(
            id: "newer",
            title: "Display Newer",
            reference: newerReference
        )
        let index = MacToolsSearchIndex(items: [older, newer])

        XCTAssertEqual(
            index.results(
                matching: "display",
                recentReferences: [newerReference, olderReference]
            ).map(\.id),
            ["newer", "older"]
        )
    }

    func testZeroQuerySectionsDeduplicateRecentFromSuggested() {
        let recent = searchResult(id: "recent", kind: .command)
        let suggested = searchResult(id: "suggested", kind: .navigation)

        let sections = MacToolsSearchPresentation.sections(
            query: "",
            results: [recent, suggested],
            recentResults: [recent]
        )

        XCTAssertEqual(sections.map(\.kind), [.recent, .suggested])
        XCTAssertEqual(sections[0].results.map(\.id), ["recent"])
        XCTAssertEqual(sections[1].results.map(\.id), ["suggested"])
    }

    func testParameterlessActionResultIDDoesNotDependOnCatalogPosition() throws {
        let plugin = SearchableTestPlugin()
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(
                pluginHost: makePluginHostForTests(plugins: [plugin])
            ).items.first { item in
                guard case let .executeAction(reference) = item.action else { return false }
                return reference.key == ActionKey(providerID: "searchable", actionID: "sleep")
            }
        )

        XCTAssertEqual(result.id, "action.parameterless.searchable/sleep")
    }

    func testParameterizedAndParameterlessActionResultIDsUseDisjointNamespaces() throws {
        let parameterized = ActionReference(
            key: ActionKey(providerID: "foo", actionID: "bar"),
            parameters: try ActionParameterSet(["value": .boolean(true)])
        )
        let parameterless = ActionReference(
            key: ActionKey(providerID: "foo", actionID: "bar.0")
        )

        XCTAssertNotEqual(
            MacToolsSearchResultID.action(reference: parameterized, catalogIndex: 0),
            MacToolsSearchResultID.action(reference: parameterless, catalogIndex: 1)
        )
        XCTAssertEqual(
            MacToolsSearchResultID.action(reference: parameterless, catalogIndex: 99),
            "action.parameterless.foo/bar.0"
        )
    }

    func testSearchIndexUsesUniqueStableIdentifiers() {
        let index = MacToolsSearchIndexBuilder.build(
            pluginHost: makePluginHostForTests(plugins: [SearchableTestPlugin()])
        )

        XCTAssertEqual(Set(index.items.map(\.id)).count, index.items.count)
    }

    func testUnifiedSearchFieldLeavesTabForInlineControlNavigation() {
        XCTAssertNil(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertTab(_:)),
                hasMarkedText: false
            )
        )
        XCTAssertNil(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertBacktab(_:)),
                hasMarkedText: false
            )
        )
        XCTAssertEqual(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false,
                modifierFlags: .command
            ),
            .openOwner
        )
        XCTAssertEqual(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                hasMarkedText: false
            ),
            .openOwner
        )
        XCTAssertTrue(UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
            keyCode: 36,
            modifierFlags: .command
        ))
        XCTAssertTrue(UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
            keyCode: 76,
            modifierFlags: [.command, .shift]
        ))
        XCTAssertFalse(UnifiedSearchTextField.isOpenOwnerKeyEquivalent(
            keyCode: 36,
            modifierFlags: []
        ))
        XCTAssertNil(
            UnifiedSearchTextField.command(
                for: #selector(NSResponder.insertTab(_:)),
                hasMarkedText: true
            )
        )
    }

    func testUnifiedSearchFocusRetriesUntilFocusCanBeClaimed() {
        let parent = UnifiedSearchTextField(
            text: .constant(""),
            placeholder: "Search",
            accessibilityLabel: "Search",
            focusRequestID: 1,
            onCommand: { _ in }
        )
        var focusAttempts = 0
        let coordinator = UnifiedSearchTextField.Coordinator(
            parent: parent,
            focusClaim: { _ in
                focusAttempts += 1
                return focusAttempts == 3
            }
        )
        let field = UnifiedSearchTextField.SearchTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 28)
        )
        defer {
            coordinator.cancelPendingFocus()
        }

        coordinator.focus(field, for: 1)
        for _ in 0 ..< 100 where focusAttempts < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(focusAttempts, 3)

        coordinator.focus(field, for: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(focusAttempts, 3)
    }

    func testUnifiedSearchSelectionResetsToTopResultWhenNormalizedQueryChanges() {
        XCTAssertTrue(UnifiedSearchSelectionPolicy.shouldResetForQueryChange(
            from: "",
            to: "IP Check"
        ))
        XCTAssertEqual(
            UnifiedSearchSelectionPolicy.selection(
                currentID: "recent.copy-public-ip",
                availableIDs: ["navigation.ip-check", "recent.copy-public-ip"],
                resetToFirst: true
            ),
            "navigation.ip-check"
        )
    }

    func testUnifiedSearchSelectionPreservesDeliberateSelectionForEquivalentQuery() {
        XCTAssertFalse(UnifiedSearchSelectionPolicy.shouldResetForQueryChange(
            from: " IP CHECK ",
            to: "ip check"
        ))
        XCTAssertEqual(
            UnifiedSearchSelectionPolicy.selection(
                currentID: "command.copy-public-ip",
                availableIDs: ["navigation.ip-check", "command.copy-public-ip"],
                resetToFirst: false
            ),
            "command.copy-public-ip"
        )
    }

    func testUnifiedSearchShowsCommandAccessoriesOnlyForSelectedActionRows() {
        let action = MacToolsSearchAction.executeAction(
            ActionReference(key: ActionKey(providerID: "sidecar", actionID: "connect"))
        )
        let navigation = MacToolsSearchAction.navigate(destination: .general, target: nil)

        XCTAssertTrue(UnifiedSearchResultRowLayout.showsInlineActions(
            for: action,
            isSelected: true
        ))
        XCTAssertFalse(UnifiedSearchResultRowLayout.showsInlineActions(
            for: action,
            isSelected: false
        ))
        XCTAssertFalse(UnifiedSearchResultRowLayout.showsInlineActions(
            for: navigation,
            isSelected: true
        ))
        XCTAssertEqual(UnifiedSearchResultRowLayout.quickSelectionColumnWidth, 32)
        XCTAssertEqual(UnifiedSearchResultRowLayout.primaryActionColumnWidth, 56)
        XCTAssertEqual(UnifiedSearchResultRowLayout.minimumShortcutRecorderWidth, 60)

        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option, .shift, .command]
        )
        XCTAssertEqual(
            UnifiedSearchResultRowLayout.shortcutRecorderDisplayText(for: binding),
            "⌃\u{2009}⌥\u{2009}⇧\u{2009}⌘\u{2009}K"
        )
    }

    func testPluginHostPerformsOnlyDeclaredCommands() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let definition = plugin.commandDefinitions[0]

        XCTAssertTrue(
            host.performCommand(
                pluginID: plugin.metadata.id,
                expectedDefinition: definition
            )
        )
        XCTAssertFalse(
            host.performCommand(
                pluginID: "missing",
                expectedDefinition: definition
            )
        )

        XCTAssertEqual(plugin.performedCommandIDs, ["sleep"])
    }

    func testPluginHostValidatesLiveExactSettingsTargets() {
        let plugin = SearchableTestPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)
        let targets = index.items.compactMap { item -> PluginSettingsSearchTarget? in
            guard
                case let .navigate(_, .plugin(target)) = item.action,
                target.pluginID == plugin.metadata.id
            else {
                return nil
            }
            return target
        }

        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.allSatisfy(host.hasPluginSettingsSearchTarget))
        XCTAssertFalse(
            host.hasPluginSettingsSearchTarget(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: "removed-entry"
                )
            )
        )
        XCTAssertFalse(
            host.hasPluginSettingsSearchTarget(
                PluginSettingsSearchTarget(
                    pluginID: plugin.metadata.id,
                    entryID: "hidden-row"
                )
            )
        )
    }

    func testAvailablePluginIsDiscoverableByCatalogOnlyKeywords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacToolsSearchTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(
            suiteName: "MacToolsSearchTests-\(UUID().uuidString)"
        )!
        let store = PluginPackageStore(
            rootDirectory: root,
            userDefaults: defaults,
            hostVersion: "1.2.1"
        )
        let manager = DynamicPluginManager(packageStore: store)
        let entry = PluginCatalogEntry(
            id: "com.example.presentation",
            displayName: "Presentation Helper",
            summary: "Keeps a Mac ready for presenting",
            version: "1.0.0",
            minimumHostVersion: "1.2.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/PresentationHelper.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            ),
            discovery: PluginProductMetadata.Discovery(
                keywords: ["caffeine"],
                localizedSynonyms: [:],
                useCases: [],
                goalCategories: [],
                relatedPluginIDs: [],
                alternativePluginIDs: []
            )
        )
        manager.rebuildManagementItems(
            catalogSnapshot: PluginCatalogSnapshot(
                catalog: PluginCatalog(
                    catalogID: "com.example.catalog",
                    generatedAt: Date(timeIntervalSince1970: 0),
                    minimumHostVersion: "1.2.1",
                    plugins: [entry]
                ),
                sourceURL: URL(fileURLWithPath: "/tmp/catalog.json"),
                sourceKind: .production,
                loadedAt: Date(timeIntervalSince1970: 0)
            )
        )
        let host = makePluginHostForTests(
            plugins: [],
            dynamicPluginManager: manager,
            loadDynamicPluginsOnInit: false
        )

        let results = MacToolsSearchIndexBuilder.build(pluginHost: host)
            .results(matching: "caffeine")

        XCTAssertEqual(results.map(\.id), ["plugin.marketplace.com.example.presentation"])
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .available)
    }

    func testInstalledIncompatiblePluginIsDiscoverableInMarketplace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacToolsSearchTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults(
            suiteName: "MacToolsSearchTests-\(UUID().uuidString)"
        )!
        let store = PluginPackageStore(
            rootDirectory: root,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let packageURL = store.installedDirectory
            .appendingPathComponent(
                "com.example.future.mactoolsplugin",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        let manifest = PluginPackageManifest(
            id: "com.example.future",
            displayName: "Future Plugin",
            version: "2.0.0",
            minHostVersion: "99.0.0",
            bundleRelativePath: "Future.bundle"
        )
        try JSONEncoder().encode(manifest).write(
            to: packageURL.appendingPathComponent("plugin.json")
        )

        let manager = DynamicPluginManager(packageStore: store)
        let host = makePluginHostForTests(
            plugins: [],
            dynamicPluginManager: manager,
            loadDynamicPluginsOnInit: false
        )
        let result = try XCTUnwrap(
            MacToolsSearchIndexBuilder.build(pluginHost: host).items.first {
                $0.id == "plugin.marketplace.com.example.future"
            }
        )

        XCTAssertEqual(result.title, "Future Plugin")
        XCTAssertEqual(
            result.action,
            .navigate(
                destination: .plugins(.marketplace),
                target: .marketplace(
                    MarketplacePluginSearchTarget(
                        pluginID: "com.example.future"
                    )
                )
            )
        )
        XCTAssertTrue(result.detail.contains("99.0.0"))
    }

    func testAppCommandUsesExistingPresentationRouting() {
        let host = makePluginHostForTests(plugins: [])
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        XCTAssertTrue(host.performAppCommand(.toggleDashboard))

        XCTAssertEqual(requests, [.toggleDashboard])
    }

    func testAppCommandFailsWithoutPresentationRouting() {
        let host = makePluginHostForTests(plugins: [])

        XCTAssertFalse(host.performAppCommand(.toggleDashboard))
    }

    private func searchResult(
        id: String,
        kind: MacToolsSearchResultKind
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: kind,
            title: id,
            subtitle: "",
            detail: "",
            keywords: [],
            systemImage: "magnifyingglass",
            action: .navigate(destination: .general, target: nil),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private func rankedSearchResult(
        id: String,
        title: String,
        subtitle: String = "",
        detail: String = "",
        keywords: [String] = [],
        reference: ActionReference? = nil
    ) -> MacToolsSearchResult {
        MacToolsSearchResult(
            id: id,
            kind: .command,
            title: title,
            subtitle: subtitle,
            detail: detail,
            keywords: keywords,
            systemImage: "command",
            action: .executeAction(
                reference ?? ActionReference(
                    key: ActionKey(providerID: "plugin", actionID: id)
                )
            ),
            confirmation: nil,
            suggestionPriority: nil
        )
    }

    private func appHostCommandDefinition(
        id: String,
        action: AppHostCommandAction
    ) -> AppHostCommandDefinition {
        AppHostCommandDefinition(
            id: id,
            title: AppShortcutAction.toggleDashboard.title,
            description: AppShortcutAction.toggleDashboard.description,
            keywords: [],
            systemImage: AppShortcutAction.toggleDashboard.systemImage,
            confirmation: nil,
            action: action
        )
    }
}

@MainActor
private final class SearchTestLaunchAtLoginService: LaunchAtLoginServicing {
    var isRegistered = false

    func register() throws {
        isRegistered = true
    }

    func unregister() throws {
        isRegistered = false
    }
}

@MainActor
private final class SearchableTestPlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginSettingsSearchProviding,
    PluginCommandProviding
{
    static let customEntryID = "shortcut-target"

    let metadata = PluginMetadata(
        id: "searchable",
        title: "显示工具",
        iconName: "display",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "管理内建和外接显示器亮度"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var performedCommandIDs: [String] = []
    var commandTitle = "让显示器休眠"

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "automatic",
                    title: "自动切换",
                    rows: [
                        PluginSettingsRow(
                            id: "automatic-status",
                            title: "自动切换",
                            description: "根据屏幕状态自动切换亮度。",
                            control: .status(
                                text: "已开启",
                                systemImage: "checkmark.circle",
                                tone: .positive,
                                actionTitle: nil
                            )
                        )
                    ]
                ),
                PluginSettingsSection(
                    id: "temporarily-unavailable",
                    title: "暂不可用设置",
                    isVisible: false,
                    rows: [
                        PluginSettingsRow(
                            id: "hidden-row",
                            title: "暂不可用设置",
                            control: .toggle(isOn: false)
                        )
                    ]
                )
            ]
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: "accessibility",
                kind: .accessibility,
                title: "辅助功能授权",
                description: "允许控制显示器。"
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: "decrease",
                title: "降低亮度",
                description: "降低目标显示器亮度。",
                actionID: "decrease",
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: Self.customEntryID,
                title: "快捷键目标",
                description: "选择亮度快捷键控制的外接显示器。",
                keywords: ["屏幕", "作用范围"],
                systemImage: "display.2"
            )
        ]
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "sleep",
                title: commandTitle,
                description: "立即让所有屏幕进入休眠。",
                systemImage: "display"
            )
        ]
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handleAction(_ action: PluginPanelAction) {}

    func handleCommand(id: String) {
        performedCommandIDs.append(id)
    }
}

@MainActor
private final class ActionShortcutSearchTestPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginActionShortcutSettingsProviding,
    PluginSettingsSearchProviding
{
    private static let actionID = "switch-source"

    let metadata = PluginMetadata(
        id: "action-shortcut-search",
        title: "Input Source",
        iconName: "keyboard",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "Switch input sources"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [])
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: Self.actionID),
                title: "Switch Input Source",
                description: "Switch directly to an input source.",
                systemImage: "keyboard"
            ),
        ]
    }

    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration {
        PluginActionShortcutSettingsConfiguration(
            title: "Input Source Shortcuts",
            actionIDs: [Self.actionID]
        )
    }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: PluginActionShortcutSettingsConfiguration.settingsSearchEntryID,
                title: actionShortcutSettingsConfiguration.title,
                description: "Assign shortcuts to input sources.",
                systemImage: "command"
            ),
        ]
    }

    func handleAction(_ action: PluginPanelAction) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class MigratingRecentSearchTestPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "migrating-recent-search",
        title: "Migrating Recent Search",
        iconName: "arrow.triangle.2.circlepath",
        iconTint: Color(nsColor: .systemBlue),
        order: 1,
        defaultDescription: "Tests recent action migrations"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionKey: ActionKey {
        ActionKey(providerID: metadata.id, actionID: "migrate")
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: actionKey,
                parameterSchemaVersion: 2,
                title: "Migrate Recent Action",
                description: "Tests recent action migrations.",
                systemImage: "arrow.triangle.2.circlepath"
            )
        ]
    }

    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference? {
        guard reference.key == actionKey,
              reference.schemaVersion == 1,
              schemaVersion == 2,
              reference.parameters.entries.isEmpty else {
            return nil
        }
        return ActionReference(key: actionKey, schemaVersion: schemaVersion)
    }

    func handleAction(_ action: PluginPanelAction) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

@MainActor
private final class SurfaceOnlySearchTestPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "surface-only",
        title: "锁定屏幕",
        iconName: "lock",
        iconTint: Color(nsColor: .systemGray),
        order: 2,
        defaultDescription: "立即锁定屏幕"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .dismissBeforeHandling
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {}
}
