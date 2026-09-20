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

    func testLegacyBackupClickOrderMigratesWithoutChangingPanelShortcuts() throws {
        let host = makeHost(defaults: try makeDefaults())
        let binding = ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: "swapped"
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [AppShortcutAction.toggleDashboard.rawValue: .custom(binding)]
        )
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        legacyJSON["formatVersion"] = 5
        legacyJSON.removeValue(forKey: "actionShortcutAssignments")
        let legacyBackup = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertFalse(legacyBackup.actionShortcutAssignmentsWereEncoded)
        let result = try host.importPreferences(legacyBackup)
        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(host.menuBarPanels.map(\.id), ["features", "components"])
        XCTAssertEqual(try item(.toggleDashboard, in: host).bindingText,
                       ShortcutFormatter.displayString(for: binding))
        let exported = host.makePreferencesBackup()
        XCTAssertNil(exported.application.menuBarClickBehavior)
        let application = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(exported.application)) as? [String: Any])
        XCTAssertNil(application["menuBarClickBehavior"])
        _ = try host.importPreferences(exported)
        XCTAssertEqual(host.menuBarPanels.map(\.id), ["features", "components"])
        XCTAssertEqual(try item(.toggleDashboard, in: host).bindingText,
                       ShortcutFormatter.displayString(for: binding))
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

    func testSharedBindingGroupConflictReplacementClearsEveryOwner() throws {
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
        XCTAssertEqual(
            Set(conflict.conflictingShortcutIDs),
            Set([
                SharedBindingConflictTestPlugin.firstSharedItemID,
                SharedBindingConflictTestPlugin.secondSharedItemID,
            ])
        )
        XCTAssertNil(host.resolveShortcutBindingConflict(conflict, resolution: .replace))
        XCTAssertEqual(
            host.shortcutItems.first {
                $0.id == SharedBindingConflictTestPlugin.targetItemID
            }?.bindingText,
            ShortcutFormatter.displayString(for: sharedBinding)
        )
        for ownerID in [
            SharedBindingConflictTestPlugin.firstSharedItemID,
            SharedBindingConflictTestPlugin.secondSharedItemID,
        ] {
            XCTAssertEqual(
                host.shortcutItems.first { $0.id == ownerID }?.bindingText,
                ShortcutFormatter.displayString(for: nil)
            )
        }
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

    func testLaterPluginDefaultCannotDisplaceAnExistingCustomShortcut() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(keyCode: 7, modifiers: [.command, .option])
        let laterDefault = GlobalConflictTestPlugin(id: "later-default", order: 1, defaultBinding: binding)
        let existingCustom = GlobalConflictTestPlugin(id: "existing-custom", order: 2, defaultBinding: nil)
        ShortcutStore(userDefaults: defaults).setCustomization(
            .custom(binding), for: existingCustom.shortcutItemID
        )
        let manager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let host = makeHost(defaults: defaults, plugins: [laterDefault, existingCustom], manager: manager)

        XCTAssertEqual(manager.debugRegistrationsForTests.filter { $0.binding == binding }.map(\.shortcutID),
                       [existingCustom.shortcutItemID])
        XCTAssertNotNil(host.shortcutItems.first { $0.id == laterDefault.shortcutItemID }?.errorMessage)
        XCTAssertNil(host.shortcutItems.first { $0.id == existingCustom.shortcutItemID }?.errorMessage)
    }

    func testExplicitlySharedPluginDefaultsStillUseOneHotkey() throws {
        let defaults = try makeDefaults()
        let binding = ShortcutBinding(keyCode: 8, modifiers: [.command, .option])
        let first = GlobalConflictTestPlugin(
            id: "shared-first", order: 1, defaultBinding: binding, sharedBindingGroupID: "shared"
        )
        let second = GlobalConflictTestPlugin(
            id: "shared-second", order: 2, defaultBinding: binding, sharedBindingGroupID: "shared"
        )
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let host = makeHost(defaults: defaults, plugins: [first, second], manager: manager)

        XCTAssertEqual(Set(manager.debugRegistrationsForTests.map(\.shortcutID)),
                       [first.shortcutItemID, second.shortcutItemID])
        XCTAssertEqual(registrar.registeredBindings, [binding])
        XCTAssertTrue(host.shortcutItems.allSatisfy { $0.errorMessage == nil })
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

@MainActor
private final class GlobalConflictTestPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var shortcutItemID: String { "\(metadata.id).shortcut.run" }

    init(id: String, order: Int, defaultBinding: ShortcutBinding?, sharedBindingGroupID: String? = nil) {
        metadata = PluginMetadata(
            id: id, title: id, iconName: "keyboard", iconTint: .blue,
            order: order, defaultDescription: "Tests global shortcut conflicts"
        )
        shortcutDefinitions = [PluginShortcutDefinition(
            id: "run", title: "Run", description: "Run the test action", actionID: "run",
            scope: .global, defaultBinding: defaultBinding, isRequired: false,
            sharedBindingGroupID: sharedBindingGroupID
        )]
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
