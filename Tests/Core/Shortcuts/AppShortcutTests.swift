import AppKit
import Carbon
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AppShortcutTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AppShortcutTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPanelShortcutsFollowTabOrderAndPreserveBindingsAcrossRelaunch() async throws {
        let defaults = try makeDefaults()
        let legacyStore = ShortcutStore(userDefaults: defaults)
        let dashboardBinding = ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        let featureBinding = ShortcutBinding(keyCode: 3, modifiers: [.command, .option])
        legacyStore.setCustomization(.custom(dashboardBinding), for: AppShortcutAction.toggleDashboard.rawValue)
        legacyStore.setCustomization(.custom(featureBinding), for: AppShortcutAction.toggleFeaturePanel.rawValue)
        let initialHost = makeHost(defaults: defaults, manager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        let customID = try XCTUnwrap(initialHost.addMenuBarPanel())
        let anotherID = try XCTUnwrap(initialHost.addMenuBarPanel())
        _ = try XCTUnwrap(initialHost.addMenuBarPanel())
        let customReference = initialHost.panelActionReference(id: customID)
        let customBinding = ShortcutBinding(keyCode: 4, modifiers: [.command, .option])
        let alternateBinding = ShortcutBinding(keyCode: 5, modifiers: [.command, .option])
        XCTAssertNil(initialHost.setActionShortcutBindingAndReturnError(customBinding, for: customReference))
        let alternateAssignment = ActionShortcutAssignmentRecord(reference: customReference, binding: alternateBinding)
        XCTAssertEqual(ActionShortcutAssignmentStore(userDefaults: defaults).replaceAll(
            initialHost.shortcutAssignmentService.assignments + [alternateAssignment]
        ), .committed)
        let host = makeHost(defaults: defaults, manager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))
        let assignments = host.makePreferencesBackup().actionShortcutAssignments
        XCTAssertEqual(assignments.count, 4)

        host.moveMenuBarPanel(id: customID, toOffset: 0)
        host.moveMenuBarPanel(id: MenuBarPanelDefinition.featuresID, toOffset: 1)
        var changed = try XCTUnwrap(host.menuBarPanels.first { $0.id == customID })
        changed.name = "Previously named panel"
        changed.systemImage = "heart"
        host.updateMenuBarPanel(changed)
        _ = host.deleteMenuBarPanel(id: anotherID)

        for currentHost in [host, makeHost(defaults: defaults, manager: GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar()))] {
            let panels = currentHost.menuBarPanels
            let rows = currentHost.actionShortcutCatalogItems.filter { $0.reference.key.providerID == "mactools" }
            let panelRows = Array(rows.dropFirst(2))
            XCTAssertEqual(panels.map(\.title), (1...4).map { FeatureL10n.format("面板 %lld", $0) })
            XCTAssertEqual(Array(rows.prefix(2)).map { $0.reference.key.actionID }, [
                AppShortcutAction.openSettings.rawValue, AppShortcutAction.openCommandPalette.rawValue,
            ])
            XCTAssertEqual(panelRows.map(\.reference), [customReference] + panels.map {
                currentHost.panelActionReference(id: $0.id)
            })
            XCTAssertEqual(panelRows.map(\.title), [panels[0].title] + panels.map(\.title))
            XCTAssertEqual(panelRows.prefix(2).map(\.systemImage), ["heart", "heart"])
            XCTAssertEqual(currentHost.makePreferencesBackup().actionShortcutAssignments, assignments)
            XCTAssertEqual(try item(.toggleDashboard, in: currentHost).bindingText,
                           ShortcutFormatter.displayString(for: dashboardBinding))
            XCTAssertEqual(try item(.toggleFeaturePanel, in: currentHost).bindingText,
                           ShortcutFormatter.displayString(for: featureBinding))
            XCTAssertEqual(Set(panelRows.prefix(2).map(\.bindingText)), Set([
                ShortcutFormatter.displayString(for: customBinding),
                ShortcutFormatter.displayString(for: alternateBinding),
            ]))
        }

        var requests: [AppPresentationRequest] = []
        var requestedPanels: [String] = []
        host.appPresentationHandler = { requests.append($0) }
        host.menuBarPanelPresentationHandler = { id, toggle in
            XCTAssertTrue(toggle)
            requestedPanels.append(id)
        }
        for panel in host.menuBarPanels {
            let outcome = await host.actionExecutor.execute(ActionInvocation(
                reference: host.panelActionReference(id: panel.id), source: .test, mode: .foreground
            ))
            XCTAssertEqual(outcome, .completed(.succeeded()))
        }
        XCTAssertEqual(requests, [.toggleFeaturePanel, .toggleDashboard])
        XCTAssertEqual(requestedPanels, host.menuBarPanels.filter { !$0.isDefault }.map(\.id))
    }

    func testAppShortcutPersistsAcrossHostInstances() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(keyCode: 3, modifiers: [.command, .shift])
        let firstHost = makeHost(defaults: defaults)

        XCTAssertNil(
            firstHost.setAppShortcutBindingAndReturnError(binding, for: .openCommandPalette)
        )

        let restoredHost = makeHost(defaults: defaults)

        XCTAssertEqual(
            try item(.openCommandPalette, in: restoredHost).bindingText,
            ShortcutFormatter.displayString(for: binding)
        )
        XCTAssertFalse(try item(.toggleDashboard, in: restoredHost).canClear)
    }

    func testAppShortcutRejectsConflictWithAnotherAppShortcutIncludingOpenSettings() throws {
        let defaults = try makeDefaults()
        let host = makeHost(defaults: defaults)
        let binding = ShortcutBinding(keyCode: 4, modifiers: [.command, .option])

        XCTAssertNil(host.setAppShortcutBindingAndReturnError(binding, for: .openSettings))
        XCTAssertEqual(
            host.setAppShortcutBindingAndReturnError(binding, for: .toggleDashboard),
            ShortcutValidationError.duplicate(
                ownerDescription: AppShortcutAction.openSettings.title
            ).localizedDescription
        )
        XCTAssertFalse(try item(.toggleDashboard, in: host).canClear)
    }

    func testActivePluginShortcutConflictCanSwapOrReplaceWithoutDuplicateBindings() throws {
        let firstBinding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        let secondBinding = ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        let host = makeHost(
            defaults: try makeDefaults(),
            plugins: [TwoShortcutTestPlugin(first: firstBinding, second: secondBinding)]
        )

        let swapConflict = try XCTUnwrap(host.shortcutBindingConflict(
            for: secondBinding,
            targetShortcutID: TwoShortcutTestPlugin.firstItemID
        ))
        XCTAssertTrue(swapConflict.canSwap)
        XCTAssertNil(host.resolveShortcutBindingConflict(swapConflict, resolution: .swap))
        XCTAssertEqual(
            host.shortcutItems.first { $0.id == TwoShortcutTestPlugin.firstItemID }?.bindingText,
            ShortcutFormatter.displayString(for: secondBinding)
        )
        XCTAssertEqual(
            host.shortcutItems.first { $0.id == TwoShortcutTestPlugin.secondItemID }?.bindingText,
            ShortcutFormatter.displayString(for: firstBinding)
        )

        let replaceConflict = try XCTUnwrap(host.shortcutBindingConflict(
            for: firstBinding,
            targetShortcutID: TwoShortcutTestPlugin.firstItemID
        ))
        XCTAssertNil(host.resolveShortcutBindingConflict(replaceConflict, resolution: .replace))
        XCTAssertEqual(
            host.shortcutItems.first { $0.id == TwoShortcutTestPlugin.firstItemID }?.bindingText,
            ShortcutFormatter.displayString(for: firstBinding)
        )
        XCTAssertEqual(
            host.shortcutItems.first { $0.id == TwoShortcutTestPlugin.secondItemID }?.bindingText,
            ShortcutFormatter.displayString(for: nil)
        )
    }

    func testSharedBindingGroupConflictRejectsAmbiguousSwapWithoutMutation() throws {
        let targetBinding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        let sharedBinding = ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        let host = makeHost(
            defaults: try makeDefaults(),
            plugins: [SharedBindingConflictTestPlugin(target: targetBinding, shared: sharedBinding)]
        )
        let conflict = try XCTUnwrap(host.shortcutBindingConflict(
            for: sharedBinding,
            targetShortcutID: SharedBindingConflictTestPlugin.targetItemID
        ))

        XCTAssertFalse(conflict.canSwap)
        XCTAssertNotNil(host.resolveShortcutBindingConflict(conflict, resolution: .swap))
        XCTAssertEqual(
            host.shortcutItems.first {
                $0.id == SharedBindingConflictTestPlugin.targetItemID
            }?.bindingText,
            ShortcutFormatter.displayString(for: targetBinding)
        )
        for ownerID in [
            SharedBindingConflictTestPlugin.firstSharedItemID,
            SharedBindingConflictTestPlugin.secondSharedItemID,
        ] {
            XCTAssertEqual(
                host.shortcutItems.first { $0.id == ownerID }?.bindingText,
                ShortcutFormatter.displayString(for: sharedBinding)
            )
        }
    }

    func testAppAndPluginShortcutsRejectConflictsInBothDirections() throws {
        let pluginBinding = ShortcutBinding(keyCode: 5, modifiers: [.command, .option])
        let appBinding = ShortcutBinding(keyCode: 6, modifiers: [.command, .shift])
        let plugin = AppShortcutTestPlugin(defaultBinding: pluginBinding)
        let host = makeHost(defaults: try makeDefaults(), plugins: [plugin])

        XCTAssertNotNil(
            host.setAppShortcutBindingAndReturnError(pluginBinding, for: .toggleDashboard)
        )

        XCTAssertNil(
            host.setAppShortcutBindingAndReturnError(appBinding, for: .toggleFeaturePanel)
        )
        XCTAssertNotNil(
            host.setShortcutBindingAndReturnError(
                appBinding,
                for: AppShortcutTestPlugin.shortcutItemID
            )
        )
    }

    func testBackupRoundTripPreservesAppShortcutBindings() throws {
        let dashboardBinding = ShortcutBinding(keyCode: 7, modifiers: [.command, .option])
        let featureBinding = ShortcutBinding(keyCode: 8, modifiers: [.command, .shift])
        let paletteBinding = ShortcutBinding(keyCode: 11, modifiers: [.control, .option])
        let sourceHost = makeHost(defaults: try makeDefaults())
        XCTAssertNil(
            sourceHost.setAppShortcutBindingAndReturnError(dashboardBinding, for: .toggleDashboard)
        )
        XCTAssertNil(
            sourceHost.setAppShortcutBindingAndReturnError(featureBinding, for: .toggleFeaturePanel)
        )
        XCTAssertNil(
            sourceHost.setAppShortcutBindingAndReturnError(paletteBinding, for: .openCommandPalette)
        )

        let backup = sourceHost.makePreferencesBackup()
        XCTAssertEqual(
            backup.shortcutCustomizations[AppShortcutAction.toggleDashboard.rawValue],
            .custom(dashboardBinding)
        )
        XCTAssertEqual(
            backup.shortcutCustomizations[AppShortcutAction.toggleFeaturePanel.rawValue],
            .custom(featureBinding)
        )
        XCTAssertEqual(
            backup.shortcutCustomizations[AppShortcutAction.openCommandPalette.rawValue],
            .custom(paletteBinding)
        )

        let restoredHost = makeHost(defaults: try makeDefaults())
        let result = try restoredHost.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(
            try item(.toggleDashboard, in: restoredHost).bindingText,
            ShortcutFormatter.displayString(for: dashboardBinding)
        )
        XCTAssertEqual(
            try item(.toggleFeaturePanel, in: restoredHost).bindingText,
            ShortcutFormatter.displayString(for: featureBinding)
        )
        XCTAssertEqual(
            try item(.openCommandPalette, in: restoredHost).bindingText,
            ShortcutFormatter.displayString(for: paletteBinding)
        )
    }

    func testImportRejectsAppToAppAndAppToPluginConflictsAtomically() throws {
        let conflictBinding = ShortcutBinding(keyCode: 9, modifiers: [.command, .option])
        let plugin = AppShortcutTestPlugin(defaultBinding: conflictBinding)
        let host = makeHost(defaults: try makeDefaults(), plugins: [plugin])
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [plugin.metadata.id],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [
                AppShortcutAction.openSettings.rawValue: .custom(conflictBinding),
                AppShortcutAction.toggleDashboard.rawValue: .custom(conflictBinding),
                AppShortcutTestPlugin.shortcutItemID: .custom(conflictBinding)
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertEqual(
            Set(result.shortcutErrors.keys),
            [
                AppShortcutAction.openSettings.rawValue,
                AppShortcutAction.toggleDashboard.rawValue,
                AppShortcutTestPlugin.shortcutItemID
            ]
        )
        XCTAssertTrue(host.makePreferencesBackup().shortcutCustomizations.isEmpty)
    }

    func testGlobalAppShortcutTriggersEmitTypedPresentationRequests() throws {
        let manager = GlobalShortcutManager()
        let host = makeHost(defaults: try makeDefaults(), manager: manager)
        var requests: [AppPresentationRequest] = []
        host.appPresentationHandler = { requests.append($0) }

        manager.triggerForTests(shortcutID: AppShortcutAction.toggleDashboard.rawValue)
        manager.triggerForTests(shortcutID: AppShortcutAction.toggleFeaturePanel.rawValue)
        manager.triggerForTests(shortcutID: AppShortcutAction.openSettings.rawValue)
        manager.triggerForTests(shortcutID: AppShortcutAction.openCommandPalette.rawValue)

        XCTAssertEqual(
            requests,
            [
                .toggleDashboard,
                .toggleFeaturePanel,
                .settings(.settings),
                .toggleCommandPalette
            ]
        )
    }

    private var pluginConflictError: String {
        ShortcutValidationError.duplicate(
            ownerDescription: "Test Plugin · Plugin Action"
        ).localizedDescription
    }

    private var validApplicationPreferences: PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.system.rawValue,
            languagePreference: AppLanguagePreference.system.rawValue,
            menuBarClickBehavior: "standard"
        )
    }

    private func item(
        _ action: AppShortcutAction,
        in host: PluginHost
    ) throws -> AppShortcutSettingsItem {
        try XCTUnwrap(host.appShortcutItems.first { $0.action == action })
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeHost(
        defaults: UserDefaults,
        plugins: [any MacToolsPlugin] = [],
        manager: GlobalShortcutManager? = nil
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: manager ?? GlobalShortcutManager()
        )
    }
}

@MainActor
private final class AppShortcutTestPlugin: MacToolsPlugin {
    static let shortcutItemID = "app-shortcut-test.shortcut.action"

    let metadata = PluginMetadata(
        id: "app-shortcut-test",
        title: "Test Plugin",
        iconName: "puzzlepiece",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Test plugin"
    )
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(
        defaultBinding: ShortcutBinding?,
        scope: ShortcutScope = .global
    ) {
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: "action",
                title: "Plugin Action",
                description: "Run the plugin action.",
                actionID: "action",
                scope: scope,
                defaultBinding: defaultBinding,
                isRequired: false
            )
        ]
    }
}

@MainActor
private final class TwoShortcutTestPlugin: MacToolsPlugin {
    static let firstItemID = "two-shortcut-test.shortcut.first"
    static let secondItemID = "two-shortcut-test.shortcut.second"

    let metadata = PluginMetadata(
        id: "two-shortcut-test",
        title: "Two Shortcut Test",
        iconName: "keyboard",
        iconTint: .blue,
        order: 2,
        defaultDescription: "Tests scoped shortcut conflicts"
    )
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(first: ShortcutBinding, second: ShortcutBinding) {
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: "first",
                title: "First",
                description: "First command",
                actionID: "first",
                scope: .whilePluginActive,
                defaultBinding: first,
                isRequired: false
            ),
            PluginShortcutDefinition(
                id: "second",
                title: "Second",
                description: "Second command",
                actionID: "second",
                scope: .whilePluginActive,
                defaultBinding: second,
                isRequired: false
            ),
        ]
    }
}

@MainActor
private final class SharedBindingConflictTestPlugin: MacToolsPlugin {
    static let targetItemID = "shared-binding-conflict-test.shortcut.target"
    static let firstSharedItemID = "shared-binding-conflict-test.shortcut.first-shared"
    static let secondSharedItemID = "shared-binding-conflict-test.shortcut.second-shared"

    let metadata = PluginMetadata(
        id: "shared-binding-conflict-test",
        title: "Shared Binding Conflict Test",
        iconName: "keyboard",
        iconTint: .blue,
        order: 3,
        defaultDescription: "Tests shared shortcut conflict resolution"
    )
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(target: ShortcutBinding, shared: ShortcutBinding) {
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: "target",
                title: "Target",
                description: "Target command",
                actionID: "target",
                scope: .whilePluginActive,
                defaultBinding: target,
                isRequired: false
            ),
            PluginShortcutDefinition(
                id: "first-shared",
                title: "First Shared",
                description: "First shared command",
                actionID: "first-shared",
                scope: .whilePluginActive,
                defaultBinding: shared,
                isRequired: false,
                sharedBindingGroupID: "shared-group"
            ),
            PluginShortcutDefinition(
                id: "second-shared",
                title: "Second Shared",
                description: "Second shared command",
                actionID: "second-shared",
                scope: .whilePluginActive,
                defaultBinding: shared,
                isRequired: false,
                sharedBindingGroupID: "shared-group"
            ),
        ]
    }
}
