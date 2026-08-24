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

    func testShortcutFormatterProvidesCompactNativeNotation() {
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: [.control, .option, .shift, .command]
        )

        XCTAssertEqual(
            ShortcutFormatter.displayString(for: binding),
            "⌃ + ⌥ + ⇧ + ⌘ + K"
        )
        XCTAssertEqual(
            ShortcutFormatter.compactDisplayString(for: binding),
            "⌃\u{2009}⌥\u{2009}⇧\u{2009}⌘\u{2009}K"
        )
        XCTAssertEqual(ShortcutFormatter.compactDisplayString(for: nil), "None")
    }

    func testAppShortcutsDefaultToUnboundAndRecordClearIndependently() throws {
        let defaults = try makeDefaults()
        let manager = GlobalShortcutManager()
        let host = makeHost(defaults: defaults, manager: manager)
        let dashboardBinding = ShortcutBinding(keyCode: 2, modifiers: [.command, .option])

        XCTAssertEqual(host.appShortcutItems.map(\.action), AppShortcutAction.allCases)
        XCTAssertEqual(host.appShortcutItems.count, 4)
        XCTAssertEqual(host.appShortcutItems.last?.action, .openCommandPalette)
        XCTAssertFalse(try item(.openCommandPalette, in: host).canClear)
        XCTAssertTrue(host.appShortcutItems.allSatisfy { !$0.canClear })
        XCTAssertTrue(
            host.appShortcutItems.allSatisfy {
                $0.bindingText == ShortcutFormatter.displayString(for: nil)
            }
        )

        XCTAssertNil(
            host.setAppShortcutBindingAndReturnError(dashboardBinding, for: .toggleDashboard)
        )
        XCTAssertEqual(
            try item(.toggleDashboard, in: host).bindingText,
            ShortcutFormatter.displayString(for: dashboardBinding)
        )
        XCTAssertTrue(try item(.toggleDashboard, in: host).canClear)
        XCTAssertFalse(try item(.toggleFeaturePanel, in: host).canClear)
        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains {
                $0.binding == dashboardBinding
                    && $0.shortcutID.hasPrefix("action-shortcut.")
            }
        )

        host.clearAppShortcut(.toggleDashboard)

        XCTAssertFalse(try item(.toggleDashboard, in: host).canClear)
        XCTAssertFalse(
            manager.debugRegistrationsForTests.contains {
                $0.binding == dashboardBinding
            }
        )
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

    func testOpenCommandPaletteRegistersGloballyOnlyWhenAssigned() throws {
        let manager = GlobalShortcutManager()
        let host = makeHost(defaults: try makeDefaults(), manager: manager)
        let binding = ShortcutBinding(keyCode: 35, modifiers: [.command, .option])

        XCTAssertFalse(
            manager.debugRegistrationsForTests.contains {
                $0.shortcutID == AppShortcutAction.openCommandPalette.rawValue
            }
        )

        XCTAssertNil(
            host.setAppShortcutBindingAndReturnError(binding, for: .openCommandPalette)
        )

        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains {
                $0.binding == binding
                    && $0.shortcutID.hasPrefix("action-shortcut.")
            }
        )
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

    func testCommonApplicationShortcutsWarnWhileSettingsNavigationShortcutsAreReserved() {
        let commandKeyCodes = [
            kVK_ANSI_Comma,
            kVK_ANSI_F,
            kVK_ANSI_K,
            kVK_ANSI_LeftBracket,
            kVK_ANSI_RightBracket
        ]

        for keyCode in commandKeyCodes {
            let binding = ShortcutBinding(
                keyCode: UInt16(keyCode),
                modifiers: .command
            )
            XCTAssertTrue(
                MacToolsReservedShortcutBindings.requiresConflictWarning(
                    for: binding
                )
            )
            XCTAssertNil(
                MacToolsReservedShortcutBindings.validationError(
                    for: binding
                )
            )
        }

        let reservedBindings = [
            kVK_ANSI_1,
            kVK_ANSI_2,
            kVK_ANSI_3,
            kVK_ANSI_4,
            kVK_ANSI_5,
            kVK_ANSI_6,
            kVK_ANSI_7,
            kVK_ANSI_8,
            kVK_ANSI_9,
        ].map {
            ShortcutBinding(keyCode: UInt16($0), modifiers: .command)
        } + [kVK_UpArrow, kVK_DownArrow].map {
            ShortcutBinding(keyCode: UInt16($0), modifiers: [.control, .command])
        }

        for binding in reservedBindings {
            XCTAssertFalse(
                MacToolsReservedShortcutBindings.requiresConflictWarning(
                    for: binding
                )
            )
            XCTAssertNotNil(
                MacToolsReservedShortcutBindings.validationError(
                    for: binding
                )
            )
        }

        XCTAssertNil(
            MacToolsReservedShortcutBindings.validationError(
                for: ShortcutBinding(
                    keyCode: UInt16(kVK_ANSI_K),
                    modifiers: [.option, .command]
                )
            )
        )
        XCTAssertNil(
            MacToolsReservedShortcutBindings.validationError(
                for: ShortcutBinding(
                    keyCode: UInt16(kVK_ANSI_L),
                    modifiers: .command
                )
            )
        )
    }

    func testAppAndPluginShortcutRecordersAllowCommonApplicationShortcuts() throws {
        let appBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: .command
        )
        let pluginBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_LeftBracket),
            modifiers: .command
        )
        let manager = GlobalShortcutManager()
        let host = makeHost(
            defaults: try makeDefaults(),
            plugins: [AppShortcutTestPlugin(defaultBinding: nil)],
            manager: manager
        )

        XCTAssertNil(
            host.setAppShortcutBindingAndReturnError(
                appBinding,
                for: .toggleDashboard
            ),
        )
        XCTAssertNil(
            host.setShortcutBindingAndReturnError(
                pluginBinding,
                for: AppShortcutTestPlugin.shortcutItemID
            ),
        )
        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains { $0.binding == appBinding }
        )
        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains { $0.binding == pluginBinding }
        )
    }

    func testAppAndPluginShortcutRecordersRejectSettingsNumberShortcuts() throws {
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_4),
            modifiers: .command
        )
        let manager = GlobalShortcutManager()
        let host = makeHost(
            defaults: try makeDefaults(),
            plugins: [AppShortcutTestPlugin(defaultBinding: nil)],
            manager: manager
        )
        let expectedError = ShortcutValidationError.duplicate(
            ownerDescription: AppMetadata.appName
        ).localizedDescription

        XCTAssertEqual(
            host.setAppShortcutBindingAndReturnError(binding, for: .toggleDashboard),
            expectedError
        )
        XCTAssertEqual(
            host.setShortcutBindingAndReturnError(
                binding,
                for: AppShortcutTestPlugin.shortcutItemID
            ),
            expectedError
        )
        XCTAssertFalse(
            manager.debugRegistrationsForTests.contains { $0.binding == binding }
        )
    }

    func testStoredCommonApplicationShortcutsRemainActive() throws {
        let defaults = try makeDefaults()
        let appBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: .command
        )
        let pluginBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_LeftBracket),
            modifiers: .command
        )
        let store = ShortcutStore(userDefaults: defaults)
        store.setCustomization(
            .custom(appBinding),
            for: AppShortcutAction.toggleDashboard.rawValue
        )
        store.setCustomization(
            .custom(pluginBinding),
            for: AppShortcutTestPlugin.shortcutItemID
        )
        let manager = GlobalShortcutManager()
        let host = makeHost(
            defaults: defaults,
            plugins: [AppShortcutTestPlugin(defaultBinding: nil)],
            manager: manager
        )

        XCTAssertNil(try item(.toggleDashboard, in: host).errorMessage)
        XCTAssertNil(
            host.shortcutItems.first {
                $0.id == AppShortcutTestPlugin.shortcutItemID
            }?.errorMessage
        )
        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains { $0.binding == appBinding }
        )
        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains { $0.binding == pluginBinding }
        )
    }

    func testStoredSettingsNumberShortcutIsDisabled() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_4),
            modifiers: .command
        )
        let store = ShortcutStore(userDefaults: defaults)
        store.setCustomization(
            .custom(binding),
            for: AppShortcutTestPlugin.shortcutItemID
        )
        let manager = GlobalShortcutManager()
        let host = makeHost(
            defaults: defaults,
            plugins: [AppShortcutTestPlugin(defaultBinding: nil)],
            manager: manager
        )

        XCTAssertEqual(
            host.shortcutItems.first {
                $0.id == AppShortcutTestPlugin.shortcutItemID
            }?.errorMessage,
            ShortcutValidationError.duplicate(
                ownerDescription: AppMetadata.appName
            ).localizedDescription
        )
        XCTAssertFalse(
            manager.debugRegistrationsForTests.contains { $0.binding == binding }
        )
    }

    func testImportAcceptsCommonApplicationShortcuts() throws {
        let plugin = AppShortcutTestPlugin(defaultBinding: nil)
        let host = makeHost(defaults: try makeDefaults(), plugins: [plugin])
        let appBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_K),
            modifiers: .command
        )
        let pluginBinding = ShortcutBinding(
            keyCode: UInt16(kVK_ANSI_LeftBracket),
            modifiers: .command
        )
        let appAssignment = ActionShortcutAssignmentRecord(
            reference: ActionReference(
                key: ActionKey(
                    providerID: "mactools",
                    actionID: AppShortcutAction.openSettings.rawValue
                )
            ),
            binding: appBinding
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [plugin.metadata.id],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [
                AppShortcutTestPlugin.shortcutItemID: .custom(pluginBinding)
            ],
            actionShortcutAssignments: [appAssignment]
        )

        let result = try host.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        let restoredBackup = host.makePreferencesBackup()
        XCTAssertEqual(
            restoredBackup.shortcutCustomizations,
            [
                AppShortcutTestPlugin.shortcutItemID: .custom(pluginBinding),
                AppShortcutAction.openSettings.rawValue: .custom(appBinding),
            ]
        )
        XCTAssertEqual(restoredBackup.actionShortcutAssignments, [appAssignment])
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

    func testStoredAppShortcutConflictWithGlobalPluginIsVisibleAndPluginKeepsPrecedence() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(keyCode: 7, modifiers: [.command, .option])
        let store = ShortcutStore(userDefaults: defaults)
        store.setCustomization(.custom(binding), for: AppShortcutAction.toggleDashboard.rawValue)
        let manager = GlobalShortcutManager()
        let host = makeHost(
            defaults: defaults,
            plugins: [AppShortcutTestPlugin(defaultBinding: binding)],
            manager: manager
        )

        XCTAssertEqual(
            try item(.toggleDashboard, in: host).errorMessage,
            pluginConflictError
        )
        XCTAssertTrue(try item(.toggleDashboard, in: host).canClear)
        XCTAssertEqual(
            host.makePreferencesBackup()
                .shortcutCustomizations[AppShortcutAction.toggleDashboard.rawValue],
            .custom(binding)
        )
        XCTAssertTrue(
            manager.debugRegistrationsForTests.contains(
                .init(shortcutID: AppShortcutTestPlugin.shortcutItemID, binding: binding)
            )
        )
        XCTAssertFalse(
            manager.debugRegistrationsForTests.contains {
                $0.shortcutID == AppShortcutAction.toggleDashboard.rawValue
            }
        )
    }

    func testStoredAppShortcutConflictWithLocalPluginIsVisibleAndNeitherRegistersGlobally() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command, .shift])
        let store = ShortcutStore(userDefaults: defaults)
        store.setCustomization(.custom(binding), for: AppShortcutAction.toggleFeaturePanel.rawValue)
        let manager = GlobalShortcutManager()
        let host = makeHost(
            defaults: defaults,
            plugins: [
                AppShortcutTestPlugin(
                    defaultBinding: binding,
                    scope: .whilePluginActive
                )
            ],
            manager: manager
        )

        XCTAssertEqual(
            try item(.toggleFeaturePanel, in: host).errorMessage,
            pluginConflictError
        )
        XCTAssertFalse(
            manager.debugRegistrationsForTests.contains {
                $0.shortcutID == AppShortcutTestPlugin.shortcutItemID
                    || $0.shortcutID == AppShortcutAction.toggleFeaturePanel.rawValue
            }
        )
    }

    func testStoredAppShortcutReactivatesWhenConflictingPluginIsAbsent() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(keyCode: 9, modifiers: [.control, .option])
        let store = ShortcutStore(userDefaults: defaults)
        store.setCustomization(.custom(binding), for: AppShortcutAction.toggleDashboard.rawValue)
        let conflictedManager = GlobalShortcutManager()
        let conflictedHost = makeHost(
            defaults: defaults,
            plugins: [AppShortcutTestPlugin(defaultBinding: binding)],
            manager: conflictedManager
        )

        XCTAssertEqual(
            try item(.toggleDashboard, in: conflictedHost).errorMessage,
            pluginConflictError
        )

        let restoredManager = GlobalShortcutManager()
        let restoredHost = makeHost(defaults: defaults, manager: restoredManager)

        XCTAssertNil(try item(.toggleDashboard, in: restoredHost).errorMessage)
        XCTAssertEqual(
            try item(.toggleDashboard, in: restoredHost).bindingText,
            ShortcutFormatter.displayString(for: binding)
        )
        XCTAssertTrue(
            restoredManager.debugRegistrationsForTests.contains {
                $0.binding == binding
                    && $0.shortcutID.hasPrefix("action-shortcut.")
            }
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
            menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
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
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
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
