import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AppHostCommandTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for suiteName in suiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    func testFixedCatalogHasStableUniqueIDsAndFiltersCurrentState() {
        let defaults = makeDefaults()
        let service = CommandTestLaunchAtLoginService(initialRegistered: false)
        let context = makeContext(defaults: defaults, service: service)
        var discoveredIDs: Set<String> = []

        for preference in AppAppearancePreference.allCases {
            defaults.set(preference.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
            let definitions = AppHostCommandCatalog.applicableDefinitions(in: context)
            XCTAssertEqual(definitions.count, Set(definitions.map(\.id)).count)
            XCTAssertTrue(definitions.allSatisfy {
                !$0.title.isEmpty && !$0.description.isEmpty && !$0.systemImage.isEmpty
            })
            discoveredIDs.formUnion(definitions.map(\.id))
        }

        service.registered = true
        context.launchAtLoginController.refreshStatus()
        discoveredIDs.formUnion(
            AppHostCommandCatalog.applicableDefinitions(in: context).map(\.id)
        )

        XCTAssertTrue(discoveredIDs.isSuperset(of: [
            "app-command.toggle-dashboard",
            "app-command.toggle-feature-panel",
            "app-command.appearance.system",
            "app-command.appearance.dark",
            "app-command.appearance.light",
            "app-command.launch-at-login.enable",
            "app-command.launch-at-login.disable",
        ]))

        for preference in AppAppearancePreference.allCases {
            defaults.set(preference.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
            let definitions = AppHostCommandCatalog.applicableDefinitions(in: context)
            let appearanceTargets = definitions.compactMap { definition -> AppAppearancePreference? in
                guard case let .setAppearance(target) = definition.action else {
                    return nil
                }
                return target
            }
            XCTAssertEqual(Set(appearanceTargets), Set(AppAppearancePreference.allCases).subtracting([preference]))
        }
    }

    func testLaunchAtLoginCatalogShowsOnlyApplicableCommand() {
        let defaults = makeDefaults()
        let service = CommandTestLaunchAtLoginService(initialRegistered: false)
        let context = makeContext(defaults: defaults, service: service)

        XCTAssertEqual(launchTargets(in: context), [true])

        service.registered = true
        context.launchAtLoginController.refreshStatus()

        XCTAssertEqual(launchTargets(in: context), [false])
    }

    func testVisibilityCatalogGeneratesOneInverseCommandPerSupportedSurface() {
        let defaults = makeDefaults()
        let service = CommandTestLaunchAtLoginService(initialRegistered: false)
        let plugin = CommandTestCombinedPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let context = AppHostCommandContext(
            pluginHost: host,
            launchAtLoginController: LaunchAtLoginController(service: service),
            appearanceUserDefaults: defaults
        )

        XCTAssertEqual(
            visibilityTargets(pluginID: plugin.metadata.id, in: context),
            [
                VisibilityTarget(surface: .dashboard, isVisible: false),
                VisibilityTarget(surface: .featurePanel, isVisible: false),
            ]
        )

        host.setPluginVisible(false, id: plugin.metadata.id, on: .dashboard)

        XCTAssertEqual(
            visibilityTargets(pluginID: plugin.metadata.id, in: context),
            [
                VisibilityTarget(surface: .dashboard, isVisible: true),
                VisibilityTarget(surface: .featurePanel, isVisible: false),
            ]
        )
    }

    func testVisibilityCatalogDoesNotGenerateUnsupportedSurface() {
        let defaults = makeDefaults()
        let plugin = CommandTestFeatureOnlyPlugin()
        let context = AppHostCommandContext(
            pluginHost: makePluginHostForTests(plugins: [plugin]),
            launchAtLoginController: LaunchAtLoginController(
                service: CommandTestLaunchAtLoginService(initialRegistered: false)
            ),
            appearanceUserDefaults: defaults
        )

        XCTAssertEqual(
            visibilityTargets(pluginID: plugin.metadata.id, in: context),
            [VisibilityTarget(surface: .featurePanel, isVisible: false)]
        )
    }

    func testLaunchAtLoginExecutionUsesControllerAndSurfacesFailure() throws {
        let defaults = makeDefaults()
        let successfulService = CommandTestLaunchAtLoginService(initialRegistered: false)
        let successfulContext = makeContext(defaults: defaults, service: successfulService)
        let enable = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: successfulContext).first {
                $0.action == .setLaunchAtLogin(true)
            }
        )

        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: enable,
                context: successfulContext
            ),
            .performed(.refreshIndex)
        )
        XCTAssertTrue(successfulContext.launchAtLoginController.isEnabled)
        XCTAssertEqual(successfulService.registerCallCount, 1)

        let failingService = CommandTestLaunchAtLoginService(initialRegistered: false)
        failingService.registerError = CommandTestError.refused
        let failingContext = makeContext(defaults: defaults, service: failingService)
        let failingEnable = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: failingContext).first {
                $0.action == .setLaunchAtLogin(true)
            }
        )

        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: failingEnable,
                context: failingContext
            ),
            .failed
        )
        XCTAssertFalse(failingContext.launchAtLoginController.isEnabled)
        XCTAssertNotNil(failingContext.launchAtLoginController.lastErrorMessage)
    }

    func testLaunchAtLoginExecutionRejectsExternallyStaleDefinition() throws {
        let defaults = makeDefaults()
        let service = CommandTestLaunchAtLoginService(initialRegistered: false)
        let context = makeContext(defaults: defaults, service: service)
        let enable = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .setLaunchAtLogin(true)
            }
        )

        service.registered = true

        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: enable,
                context: context
            ),
            .unavailable
        )
        XCTAssertTrue(context.launchAtLoginController.isEnabled)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testVisibilityExecutionChangesOnlyRequestedSurfaceAndRejectsStaleResult() throws {
        let defaults = makeDefaults()
        let plugin = CommandTestCombinedPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let context = AppHostCommandContext(
            pluginHost: host,
            launchAtLoginController: LaunchAtLoginController(
                service: CommandTestLaunchAtLoginService(initialRegistered: false)
            ),
            appearanceUserDefaults: defaults
        )
        let hideDashboard = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .setPluginVisibility(
                    pluginID: plugin.metadata.id,
                    surface: .dashboard,
                    isVisible: false
                )
            }
        )

        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: hideDashboard,
                context: context
            ),
            .performed(.refreshIndex)
        )
        XCTAssertEqual(
            AppHostCommandCatalog.pluginVisibility(
                pluginID: plugin.metadata.id,
                surface: .dashboard,
                pluginHost: host
            ),
            false
        )
        XCTAssertEqual(
            AppHostCommandCatalog.pluginVisibility(
                pluginID: plugin.metadata.id,
                surface: .featurePanel,
                pluginHost: host
            ),
            true
        )
        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: hideDashboard,
                context: context
            ),
            .unavailable
        )
    }

    func testRelocalizedDefinitionIsRejectedWithoutChangingVisibility() throws {
        let defaults = makeDefaults()
        let plugin = CommandTestCombinedPlugin()
        let host = makePluginHostForTests(plugins: [plugin])
        let context = AppHostCommandContext(
            pluginHost: host,
            launchAtLoginController: LaunchAtLoginController(
                service: CommandTestLaunchAtLoginService(initialRegistered: false)
            ),
            appearanceUserDefaults: defaults
        )
        let current = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .setPluginVisibility(
                    pluginID: plugin.metadata.id,
                    surface: .dashboard,
                    isVisible: false
                )
            }
        )
        let stale = AppHostCommandDefinition(
            id: current.id,
            title: "\(current.title) (stale)",
            description: current.description,
            keywords: current.keywords,
            systemImage: current.systemImage,
            confirmation: current.confirmation,
            action: current.action
        )

        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: stale,
                context: context
            ),
            .unavailable
        )
        XCTAssertEqual(
            AppHostCommandCatalog.pluginVisibility(
                pluginID: plugin.metadata.id,
                surface: .dashboard,
                pluginHost: host
            ),
            true
        )
    }

    func testPresentationCommandUsesExistingRoutingAndDismissesPalette() throws {
        let defaults = makeDefaults()
        let context = makeContext(
            defaults: defaults,
            service: CommandTestLaunchAtLoginService(initialRegistered: false)
        )
        var requests: [AppPresentationRequest] = []
        context.pluginHost.appPresentationHandler = { requests.append($0) }
        let definition = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .appShortcut(.toggleDashboard)
            }
        )

        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: definition,
                context: context
            ),
            .performed(.dismissPalette)
        )
        XCTAssertEqual(requests, [.toggleDashboard])
    }

    func testCommandsIncludeEnglishAndChineseDiscoveryAliases() throws {
        let defaults = makeDefaults()
        defaults.set(
            AppAppearancePreference.system.rawValue,
            forKey: AppAppearancePreference.userDefaultsKey
        )
        let context = makeContext(
            defaults: defaults,
            service: CommandTestLaunchAtLoginService(initialRegistered: false)
        )
        let dark = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .setAppearance(.dark)
            }
        )
        let launch = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .setLaunchAtLogin(true)
            }
        )

        XCTAssertTrue(dark.keywords.contains("dark"))
        XCTAssertTrue(dark.keywords.contains("深色"))
        XCTAssertTrue(launch.keywords.contains("launch at login"))
        XCTAssertTrue(launch.keywords.contains("自启动"))
    }

    func testResetCommandPalettePositionExecution() throws {
        let defaults = makeDefaults()
        var resetCalled = false
        let context = AppHostCommandContext(
            pluginHost: makePluginHostForTests(plugins: []),
            launchAtLoginController: LaunchAtLoginController(
                service: CommandTestLaunchAtLoginService(initialRegistered: false)
            ),
            appearanceUserDefaults: defaults,
            resetCommandPalettePosition: { resetCalled = true }
        )

        let definition = try XCTUnwrap(
            AppHostCommandCatalog.applicableDefinitions(in: context).first {
                $0.action == .resetCommandPalettePosition
            }
        )

        XCTAssertTrue(definition.keywords.contains("reset"))
        XCTAssertTrue(definition.keywords.contains("重置"))
        XCTAssertEqual(
            AppHostCommandExecutor.perform(
                expectedDefinition: definition,
                context: context
            ),
            .performed(.refreshIndex)
        )
        XCTAssertTrue(resetCalled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppHostCommandTests-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeContext(
        defaults: UserDefaults,
        service: CommandTestLaunchAtLoginService
    ) -> AppHostCommandContext {
        AppHostCommandContext(
            pluginHost: makePluginHostForTests(plugins: []),
            launchAtLoginController: LaunchAtLoginController(service: service),
            appearanceUserDefaults: defaults
        )
    }

    private func launchTargets(
        in context: AppHostCommandContext
    ) -> [Bool] {
        AppHostCommandCatalog.applicableDefinitions(in: context).compactMap { definition in
            guard case let .setLaunchAtLogin(isEnabled) = definition.action else {
                return nil
            }
            return isEnabled
        }
    }

    private func visibilityTargets(
        pluginID: String,
        in context: AppHostCommandContext
    ) -> [VisibilityTarget] {
        AppHostCommandCatalog.applicableDefinitions(in: context).compactMap { definition in
            guard case let .setPluginVisibility(id, surface, isVisible) = definition.action,
                  id == pluginID
            else {
                return nil
            }
            return VisibilityTarget(surface: surface, isVisible: isVisible)
        }
    }
}

private struct VisibilityTarget: Equatable {
    let surface: PluginDisplaySurface
    let isVisible: Bool
}

@MainActor
private final class CommandTestLaunchAtLoginService: LaunchAtLoginServicing {
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var registerError: Error?
    var unregisterError: Error?
    var registered: Bool

    init(initialRegistered: Bool) {
        registered = initialRegistered
    }

    var isRegistered: Bool { registered }

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        registered = true
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        registered = false
    }
}

private enum CommandTestError: Error {
    case refused
}

@MainActor
private final class CommandTestCombinedPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel {
    let metadata = PluginMetadata(
        id: "command-test-combined",
        title: "组合插件",
        iconName: "square.grid.2x2",
        iconTint: .blue,
        order: 1,
        defaultDescription: "同时支持仪表盘和功能面板"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
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

    var componentPanelState: PluginComponentState {
        PluginComponentState(
            subtitle: metadata.defaultDescription,
            isActive: false,
            isEnabled: true,
            isVisible: true,
            errorMessage: nil
        )
    }

    func handleAction(_ action: PluginPanelAction) {}

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }
}

@MainActor
private final class CommandTestFeatureOnlyPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata = PluginMetadata(
        id: "command-test-feature-only",
        title: "功能插件",
        iconName: "switch.2",
        iconTint: .purple,
        order: 2,
        defaultDescription: "仅支持功能面板"
    )
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .button,
        menuActionBehavior: .keepPresented
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
