import Carbon.HIToolbox
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import SystemStatusPlugin

@MainActor
final class PreferencesBackupTests: XCTestCase {
    private let suiteName = "PreferencesBackupTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testExportContainsOnlyPortableHostAndKnownPluginPreferences() throws {
        let defaults = makeDefaults()
        defaults.set(AppAppearancePreference.dark.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        defaults.set(AppLanguagePreference.en.rawValue, forKey: AppLanguagePreference.userDefaultsKey)
        defaults.set(MenuBarClickBehaviorPreference.swapped.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
        SettingsSidebarPreferencesStore.applyImportedPreferences(
            sortMode: .custom,
            customOrderedPluginIDs: ["second", "first"],
            to: defaults
        )
        defaults.set("api-key-value", forKey: "translator.apiKey")

        let firstPlugin = BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle")
        let secondPlugin = BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
        let host = makeHost(plugins: [firstPlugin, secondPlugin], defaults: defaults)
        host.moveFeatureManagementItem(id: secondPlugin.metadata.id, by: -1)
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]),
            for: "first.shortcut.toggle"
        )
        let openSettingsBinding = ShortcutBinding(keyCode: 13, modifiers: [.command, .option])
        XCTAssertNil(host.setAppShortcutBindingAndReturnError(openSettingsBinding, for: .openSettings))

        let backup = host.makePreferencesBackup()
        let decodedBackup = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decodedBackup.formatVersion, PreferencesBackup.currentFormatVersion)
        XCTAssertEqual(decodedBackup.application, backup.application)
        XCTAssertEqual(decodedBackup.pluginDisplay, backup.pluginDisplay)
        XCTAssertEqual(decodedBackup.shortcutCustomizations, backup.shortcutCustomizations)
        XCTAssertEqual(backup.application.appearancePreference, AppAppearancePreference.dark.rawValue)
        XCTAssertEqual(backup.application.languagePreference, AppLanguagePreference.en.rawValue)
        XCTAssertEqual(backup.application.menuBarClickBehavior, MenuBarClickBehaviorPreference.swapped.rawValue)
        XCTAssertEqual(
            backup.application.settingsSidebarPluginSortMode,
            SettingsSidebarPluginSortMode.custom.rawValue
        )
        XCTAssertEqual(
            backup.application.settingsSidebarCustomPluginOrder,
            ["second", "first"]
        )
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["second", "first"])
        XCTAssertTrue(backup.pluginDisplay.hiddenPluginIDs.isEmpty)
        XCTAssertEqual(backup.pluginDisplay.dashboardOrderedPluginIDs, [])
        XCTAssertEqual(backup.pluginDisplay.featurePanelOrderedPluginIDs, ["first", "second"])
        XCTAssertEqual(
            backup.shortcutCustomizations["first.shortcut.toggle"],
            .custom(ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]))
        )
        XCTAssertEqual(backup.shortcutCustomizations["app.open-settings"], .custom(openSettingsBinding))
        XCTAssertNil(backup.shortcutCustomizations["second.shortcut.open"])
        XCTAssertFalse(try XCTUnwrap(String(data: backup.encodedJSON(), encoding: .utf8)).contains("api-key-value"))
    }

    func testSystemStatusSettingsRoundTripThroughHostPreferencesBackup() throws {
        let sourceDefaults = makeDefaults(suiteName: "\(suiteName)-system-status-source")
        let sourceStorage = UserDefaultsPluginStorage(
            pluginID: "system-status",
            userDefaults: sourceDefaults
        )
        let sourceController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: sourceStorage)
        )
        sourceController.movePanelMetric(.battery, toOffset: 0)
        sourceController.setPanelMetric(.gpu, visible: false)
        sourceController.setMenuBarMetric(.memory, visible: true)
        sourceController.setMenuBarValues(.memory, values: [.swap, .usage])
        sourceController.setMenuBarLayout(.vertical)
        sourceController.setProcessSort(.memory)
        let sourcePlugin = SystemStatusPlugin(
            settingsController: sourceController,
            storage: sourceStorage
        )
        let sourceHost = makeHost(plugins: [sourcePlugin], defaults: sourceDefaults)

        let backup = sourceHost.makePreferencesBackup()
        XCTAssertNotNil(backup.pluginPreferences["system-status"])
        XCTAssertTrue(backup.effectiveSelection.pluginPreferenceIDs.contains("system-status"))

        let destinationDefaults = makeDefaults(suiteName: "\(suiteName)-system-status-destination")
        let destinationStorage = UserDefaultsPluginStorage(
            pluginID: "system-status",
            userDefaults: destinationDefaults
        )
        let destinationController = SystemStatusSettingsController(
            store: SystemStatusPluginStorageConfigurationStore(storage: destinationStorage)
        )
        let destinationPlugin = SystemStatusPlugin(
            settingsController: destinationController,
            storage: destinationStorage
        )
        let destinationHost = makeHost(plugins: [destinationPlugin], defaults: destinationDefaults)

        let result = try destinationHost.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(destinationController.configuration, sourceController.configuration)
    }

    func testSettingsSidebarOrderRoundTripsAndUpdatesTheActiveStore() async throws {
        let sourceDefaults = makeDefaults(suiteName: "\(suiteName)-source")
        SettingsSidebarPreferencesStore.applyImportedPreferences(
            sortMode: .custom,
            customOrderedPluginIDs: ["calendar", "battery"],
            to: sourceDefaults
        )
        let sourceStore = PreferencesBackupStore(userDefaults: sourceDefaults)
        let applicationPreferences = sourceStore.applicationPreferences()

        let destinationDefaults = makeDefaults(suiteName: "\(suiteName)-destination")
        SettingsSidebarPreferencesStore.applyImportedPreferences(
            sortMode: .nameDescending,
            customOrderedPluginIDs: [],
            to: destinationDefaults
        )
        let activeSidebarStore = SettingsSidebarPreferencesStore(userDefaults: destinationDefaults)
        let destinationStore = PreferencesBackupStore(userDefaults: destinationDefaults)

        XCTAssertTrue(destinationStore.validates(applicationPreferences))
        destinationStore.apply(applicationPreferences)
        await Task.yield()

        XCTAssertEqual(activeSidebarStore.sortMode, .custom)
        XCTAssertEqual(activeSidebarStore.customOrderedPluginIDs, ["calendar", "battery"])
    }

    func testUntouchedSidebarBackupPreservesUninitializedCustomOrder() async throws {
        let sourceDefaults = makeDefaults(suiteName: "\(suiteName)-uninitialized-source")
        let applicationPreferences = PreferencesBackupStore(
            userDefaults: sourceDefaults
        ).applicationPreferences()

        XCTAssertEqual(
            applicationPreferences.settingsSidebarPluginSortMode,
            SettingsSidebarPluginSortMode.nameAscending.rawValue
        )
        XCTAssertNil(applicationPreferences.settingsSidebarCustomPluginOrder)

        let destinationDefaults = makeDefaults(
            suiteName: "\(suiteName)-uninitialized-destination"
        )
        SettingsSidebarPreferencesStore.applyImportedPreferences(
            sortMode: .custom,
            customOrderedPluginIDs: ["calendar", "battery"],
            to: destinationDefaults
        )
        let activeSidebarStore = SettingsSidebarPreferencesStore(
            userDefaults: destinationDefaults,
            locale: { Locale(identifier: "en_US") }
        )
        let destinationStore = PreferencesBackupStore(userDefaults: destinationDefaults)

        XCTAssertTrue(destinationStore.validates(applicationPreferences))
        destinationStore.apply(applicationPreferences)
        await Task.yield()

        XCTAssertEqual(activeSidebarStore.sortMode, .nameAscending)
        XCTAssertTrue(activeSidebarStore.customOrderedPluginIDs.isEmpty)

        let availableItems = [
            SettingsSidebarPluginOrderItem(id: "calendar", title: "Calendar", installedAt: nil),
            SettingsSidebarPluginOrderItem(id: "battery", title: "Battery", installedAt: nil),
            SettingsSidebarPluginOrderItem(id: "audio", title: "Audio", installedAt: nil),
        ]
        activeSidebarStore.setSortMode(.custom, availableItems: availableItems)

        XCTAssertEqual(
            activeSidebarStore.orderedPluginIDs(for: availableItems),
            ["audio", "battery", "calendar"]
        )
    }

    func testLegacyApplicationPreferencesLeaveSettingsSidebarOrderUnchanged() async throws {
        let defaults = makeDefaults(suiteName: "\(suiteName)-legacy")
        SettingsSidebarPreferencesStore.applyImportedPreferences(
            sortMode: .installedNewestFirst,
            customOrderedPluginIDs: ["battery", "calendar"],
            to: defaults
        )
        let activeSidebarStore = SettingsSidebarPreferencesStore(userDefaults: defaults)
        let backupStore = PreferencesBackupStore(userDefaults: defaults)
        let legacyPreferences = PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.system.rawValue,
            languagePreference: AppLanguagePreference.system.rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
        )

        XCTAssertTrue(backupStore.validates(legacyPreferences))
        backupStore.apply(legacyPreferences)
        await Task.yield()

        XCTAssertEqual(activeSidebarStore.sortMode, .installedNewestFirst)
        XCTAssertEqual(activeSidebarStore.customOrderedPluginIDs, ["battery", "calendar"])
    }

    func testPortablePluginPreferencesRoundTripThroughBackup() throws {
        let portableData = Data("sidecar-portable-settings".utf8)
        let sourcePlugin = BackupTestPlugin(
            id: "sidecar",
            order: 1,
            shortcutID: "toggle",
            portablePreferences: portableData
        )
        let sourceHost = makeHost(plugins: [sourcePlugin], defaults: makeDefaults())

        let backup = sourceHost.makePreferencesBackup()
        XCTAssertEqual(backup.pluginPreferences["sidecar"], portableData)

        let restoredPlugin = BackupTestPlugin(id: "sidecar", order: 1, shortcutID: "toggle")
        let restoredHost = makeHost(plugins: [restoredPlugin], defaults: makeDefaults())
        _ = try restoredHost.importPreferences(backup)

        XCTAssertEqual(restoredPlugin.restoredPortablePreferences, portableData)
    }

    func testSelectiveExportContainsOnlyChosenCategoriesAndPluginSettings() throws {
        let defaults = makeDefaults()
        let first = BackupTestPlugin(
            id: "first",
            order: 1,
            shortcutID: "toggle",
            portablePreferences: Data("first".utf8)
        )
        let second = BackupTestPlugin(
            id: "second",
            order: 2,
            shortcutID: "open",
            portablePreferences: Data("second".utf8)
        )
        let host = makeHost(plugins: [first, second], defaults: defaults)
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: ["first"]
        )

        let backup = host.makePreferencesBackup(selection: selection)
        let decoded = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decoded.effectiveSelection, selection)
        XCTAssertEqual(decoded.pluginPreferences, ["first": Data("first".utf8)])
        XCTAssertTrue(decoded.shortcutCustomizations.isEmpty)
        XCTAssertTrue(decoded.actionShortcutAssignments.isEmpty)
        XCTAssertEqual(decoded.actionInvocationPresets, [])
        XCTAssertEqual(decoded.workflows, [])
        XCTAssertEqual(decoded.automationRules, [])
    }

    func testSelectiveImportRestoresOnlyChosenPluginSettings() throws {
        let first = BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle")
        let second = BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
        let host = makeHost(plugins: [first, second], defaults: makeDefaults())
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["second", "first"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [
                "first": Data("restore-first".utf8),
                "second": Data("restore-second".utf8),
            ]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: ["first"]
        )

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertEqual(first.restoredPortablePreferences, Data("restore-first".utf8))
        XCTAssertNil(second.restoredPortablePreferences)
        XCTAssertEqual(host.featureManagementItems.map(\.id), ["first", "second"])
    }

    func testImportCannotSelectCategoryThatWasNotExported() throws {
        let host = makeHost(plugins: [], defaults: makeDefaults())
        let existingWorkflow = try XCTUnwrap(host.automationController.createWorkflow())
        let exportedSelection = PreferencesBackupSelection(
            includesApplicationPreferences: true,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: []
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            selection: exportedSelection
        )
        var requestedSelection = exportedSelection
        requestedSelection.includesAutomation = true
        requestedSelection.includesRunLinks = true
        requestedSelection.includesShortcuts = true

        _ = try host.importPreferences(backup, selection: requestedSelection)

        XCTAssertEqual(host.automationController.workflows.map(\.id), [existingWorkflow.id])
    }

    func testWorkflowRunLinkIdentityPersistsThroughBackupEncoding() throws {
        let workflowID = UUID(uuidString: "00000000-0000-4000-8000-000000000262")!
        let workflow = WorkflowDefinition(
            id: workflowID,
            name: "Readable Name",
            systemImage: "bolt",
            isEnabled: true,
            steps: []
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            workflows: [workflow]
        )

        let decoded = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decoded.workflows?.first?.id, workflowID)
        XCTAssertEqual(decoded.workflows?.first?.actionReference, workflow.actionReference)
    }

    func testRunLinkPresetsWorkflowsAndRulesRoundTripThroughBackup() throws {
        let plugin = BackupActionProviderPlugin()
        let portableReference = try XCTUnwrap(plugin.references().first)
        let workflow = WorkflowDefinition(
            id: UUID(),
            name: "Morning Setup",
            systemImage: "sunrise",
            isEnabled: true,
            steps: []
        )
        let rule = AutomationRule(
            id: UUID(),
            name: "Weekday Morning",
            workflowID: workflow.id,
            isEnabled: true,
            trigger: .schedule(.init(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6])),
            conditions: []
        )
        let preset = ActionInvocationPreset(
            id: UUID(),
            reference: portableReference,
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [plugin.metadata.id: Data("provider-settings".utf8)],
            actionInvocationPresets: [preset],
            workflows: [workflow],
            automationRules: [rule]
        )

        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let result = try host.importPreferences(backup)
        XCTAssertTrue(result.shortcutErrors.isEmpty)

        let restored = host.makePreferencesBackup()
        XCTAssertEqual(restored.actionInvocationPresets, [preset])
        XCTAssertEqual(restored.workflows, [workflow])
        XCTAssertEqual(restored.automationRules, [rule])
    }

    func testExportExcludesKnownLocalAndSensitiveActionReferencesAcrossFeatures() throws {
        let plugin = BackupActionProviderPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let references = try plugin.references()

        for (offset, reference) in references.enumerated() {
            let result = host.setActionShortcutBinding(
                ShortcutBinding(keyCode: UInt16(30 + offset), modifiers: [.command, .control]),
                to: reference
            )
            guard case .success = result else {
                return XCTFail("Expected action shortcut assignment for \(reference.key.actionID)")
            }
        }

        guard case .success = host.createActionRunLink(for: references[0]),
              case .success = host.createActionRunLink(for: references[1]) else {
            return XCTFail("Expected portable and local Run Link presets to be created")
        }
        guard case .failure(.sensitiveParametersUnsupported) = host.createActionRunLink(
            for: references[2]
        ) else {
            return XCTFail("Sensitive Run Link presets must be rejected at creation time")
        }

        var workflowIDs: [UUID] = []
        var ruleIDs: [UUID] = []
        for reference in references {
            let workflow = try XCTUnwrap(host.automationController.createWorkflow())
            host.automationController.addStep(workflowID: workflow.id, reference: reference)
            let rule = try XCTUnwrap(
                host.automationController.createRule(workflowID: workflow.id)
            )
            workflowIDs.append(workflow.id)
            ruleIDs.append(rule.id)
        }
        let localChild = try XCTUnwrap(
            host.automationController.workflows.first { $0.id == workflowIDs[1] }
        )
        let nestedParent = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(
            workflowID: nestedParent.id,
            reference: localChild.actionReference
        )
        let nestedRule = try XCTUnwrap(
            host.automationController.createRule(workflowID: nestedParent.id)
        )
        workflowIDs.append(nestedParent.id)
        ruleIDs.append(nestedRule.id)
        let nestedShortcutResult = host.setActionShortcutBinding(
            ShortcutBinding(keyCode: 40, modifiers: [.command, .control]),
            to: nestedParent.actionReference
        )
        guard case .success = nestedShortcutResult else {
            return XCTFail("Expected nested workflow shortcut, got \(nestedShortcutResult)")
        }

        let backup = host.makePreferencesBackup()

        XCTAssertEqual(backup.actionShortcutAssignments.map(\.reference), [references[0]])
        XCTAssertEqual(backup.actionInvocationPresets?.map(\.reference), [references[0]])
        XCTAssertEqual(backup.workflows?.map(\.id), [workflowIDs[0]])
        XCTAssertEqual(backup.automationRules?.map(\.id), [ruleIDs[0]])
    }

    func testRepeatedExportFiltersShortcutsAndRunLinksIndependently() throws {
        let defaults = makeDefaults()
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: defaults)
        let references = try provider.references()

        for (offset, reference) in references.prefix(2).enumerated() {
            guard case .success = host.setActionShortcutBinding(
                ShortcutBinding(keyCode: UInt16(30 + offset), modifiers: [.command, .control]),
                to: reference
            ), case .success = host.createActionRunLink(for: reference) else {
                return XCTFail("Expected portable and local actions to be saved")
            }
        }

        // The 1.2.0 optimized binary reused a weak capture's storage for the
        // appearance string before filtering these shortcuts and Run Links.
        for appearance in AppAppearancePreference.allCases {
            defaults.set(appearance.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
            let all = PreferencesBackupSelection.all(pluginPreferenceIDs: [provider.metadata.id])
            var shortcutsOnly = all
            shortcutsOnly.includesRunLinks = false
            var runLinksOnly = all
            runLinksOnly.includesShortcuts = false
            var withoutProviderSettings = all
            withoutProviderSettings.pluginPreferenceIDs = []
            let selections: [PreferencesBackupSelection?] = [
                nil, shortcutsOnly, runLinksOnly, withoutProviderSettings, nil,
            ]

            for selection in selections {
                let backup = host.makePreferencesBackup(selection: selection)
                let decoded = try PreferencesBackup.decodeJSON(backup.encodedJSON())
                let effectiveSelection = selection ?? all
                let includesProvider = effectiveSelection.pluginPreferenceIDs.contains(provider.metadata.id)

                XCTAssertEqual(decoded.application.appearancePreference, appearance.rawValue)
                XCTAssertEqual(
                    decoded.actionShortcutAssignments.map(\.reference),
                    effectiveSelection.includesShortcuts && includesProvider ? [references[0]] : []
                )
                XCTAssertEqual(
                    decoded.actionInvocationPresets?.map(\.reference),
                    effectiveSelection.includesRunLinks && includesProvider ? [references[0]] : []
                )
            }
        }
    }

    func testActionSurfacePreferencesExcludeNestedNonPortableWorkflowReferences() throws {
        let provider = BackupActionProviderPlugin()
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let localReference = try provider.references()[1]
        let child = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(workflowID: child.id, reference: localReference)
        let parent = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(workflowID: parent.id, reference: child.actionReference)
        surface.references = [parent.actionReference]

        let backup = host.makePreferencesBackup()
        let data = try XCTUnwrap(backup.pluginPreferences[surface.metadata.id])
        let references = try JSONDecoder().decode([ActionReference].self, from: data)

        XCTAssertTrue(references.isEmpty)
    }

    func testExportOmitsRulesBoundToLocalDisplayOrCalendarIdentifiersAndReportsTheirCount() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let workflow = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(
            workflowID: workflow.id,
            reference: try provider.references()[0]
        )

        var portable = try XCTUnwrap(
            host.automationController.createRule(workflowID: workflow.id)
        )
        portable.trigger = .display(DisplayAutomationTrigger(
            event: .connected,
            displayNameContains: "Studio"
        ))
        host.automationController.saveRule(portable)

        var localTrigger = try XCTUnwrap(
            host.automationController.createRule(workflowID: workflow.id)
        )
        localTrigger.trigger = .display(DisplayAutomationTrigger(
            event: .connected,
            displayIdentifier: "742311",
            displayNameContains: "Studio"
        ))
        host.automationController.saveRule(localTrigger)

        var localCondition = try XCTUnwrap(
            host.automationController.createRule(workflowID: workflow.id)
        )
        localCondition.conditions = [
            .connectedDisplay(ConnectedDisplayCondition(displayIdentifier: "991200")),
        ]
        host.automationController.saveRule(localCondition)

        var localCalendar = try XCTUnwrap(
            host.automationController.createRule(workflowID: workflow.id)
        )
        localCalendar.trigger = .calendar(CalendarAutomationTrigger(
            phase: .starts,
            calendarIdentifier: "eventkit-calendar-id"
        ))
        host.automationController.saveRule(localCalendar)

        let backup = host.makePreferencesBackup()

        XCTAssertEqual(backup.automationRules?.map(\.id), [portable.id])
        XCTAssertEqual(host.deviceLocalAutomationRuleCount, 3)
    }

    func testImportDropsDeviceLocalDisplayAndCalendarRulesFromEditedBackup() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let workflow = WorkflowDefinition(
            name: "Imported",
            steps: [WorkflowStep(reference: try provider.references()[0])]
        )
        let portableRule = AutomationRule(
            name: "Portable",
            workflowID: workflow.id,
            trigger: .display(DisplayAutomationTrigger(
                event: .connected,
                displayNameContains: "Studio"
            ))
        )
        let localRule = AutomationRule(
            name: "Local",
            workflowID: workflow.id,
            trigger: .display(DisplayAutomationTrigger(
                event: .connected,
                displayIdentifier: "742311"
            ))
        )
        let localCalendarRule = AutomationRule(
            name: "Local Calendar",
            workflowID: workflow.id,
            trigger: .calendar(CalendarAutomationTrigger(
                phase: .starts,
                calendarIdentifier: "eventkit-calendar-id"
            ))
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: [provider.metadata.id: Data("provider-settings".utf8)],
            workflows: [workflow],
            automationRules: [portableRule, localRule, localCalendarRule]
        )

        _ = try host.importPreferences(backup)

        XCTAssertEqual(host.automationController.rules.map(\.id), [portableRule.id])
    }

    func testActionSurfaceBackupPersistsProviderDependencyIndex() throws {
        let provider = BackupActionProviderPlugin()
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let reference = try provider.references()[0]
        surface.references = [reference]

        let backup = host.makePreferencesBackup()

        XCTAssertEqual(
            backup.pluginPreferenceActionReferences[surface.metadata.id],
            [reference]
        )
    }

    func testSelectiveExportOmitsActionsThatDependOnUnselectedPluginPreferences() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let reference = try provider.references()[0]
        guard case .success = host.setActionShortcutBinding(
            ShortcutBinding(keyCode: 41, modifiers: [.command, .control]),
            to: reference
        ), case .success = host.createActionRunLink(for: reference) else {
            return XCTFail("Expected portable provider action to be assignable")
        }
        let workflow = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(workflowID: workflow.id, reference: reference)
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: true,
            includesAutomation: true,
            includesRunLinks: true,
            pluginPreferenceIDs: []
        )

        let backup = host.makePreferencesBackup(selection: selection)

        XCTAssertTrue(backup.actionShortcutAssignments.isEmpty)
        XCTAssertTrue(backup.actionInvocationPresets?.isEmpty ?? false)
        XCTAssertTrue(backup.workflows?.isEmpty ?? false)
        XCTAssertNil(backup.pluginPreferences[provider.metadata.id])
    }

    func testStandaloneWorkflowExportRejectsActionsThatDependOnPluginPreferences() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let workflow = try XCTUnwrap(host.automationController.createWorkflow())
        host.automationController.addStep(
            workflowID: workflow.id,
            reference: try provider.references()[0]
        )

        XCTAssertEqual(
            host.automationController.exportWorkflow(id: workflow.id),
            .failure(.unsafeForExport)
        )
    }

    func testSelectiveImportDropsWorkflowDependentsWhenAutomationIsNotSelected() throws {
        let provider = BackupActionProviderPlugin()
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let child = WorkflowDefinition(
            name: "Child",
            steps: [WorkflowStep(reference: try provider.references()[0])]
        )
        let parent = WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: parent.actionReference,
                binding: ShortcutBinding(keyCode: 42, modifiers: [.command, .control])
            )],
            pluginPreferences: [
                surface.metadata.id: try JSONEncoder().encode([parent.actionReference]),
                provider.metadata.id: Data("provider-settings".utf8),
            ],
            workflows: [child, parent]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: true,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: [surface.metadata.id]
        )

        let preview = try host.preferencesImportPreview(for: backup, selection: selection)
        XCTAssertEqual(preview.shortcutCount, 0)
        XCTAssertTrue(preview.unavailableActionReferences.contains(parent.actionReference))

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
        XCTAssertTrue(surface.references.isEmpty)
        XCTAssertTrue(host.automationController.workflows.isEmpty)
    }

    func testImportingEmptyShortcutCategoryClearsDestinationActionAssignments() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let reference = try provider.references()[0]
        guard case .success = host.setActionShortcutBinding(
            ShortcutBinding(keyCode: 42, modifiers: [.command, .control]),
            to: reference
        ) else {
            return XCTFail("Expected destination shortcut to be assignable")
        }
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            actionShortcutAssignments: []
        )

        _ = try host.importPreferences(backup)

        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
    }

    func testImportingLegacyBackupWithoutActionAssignmentsKeepsDestinationAssignments() throws {
        let provider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let reference = try provider.references()[0]
        guard case .success = host.setActionShortcutBinding(
            ShortcutBinding(keyCode: 42, modifiers: [.command, .control]),
            to: reference
        ) else {
            return XCTFail("Expected destination shortcut to be assignable")
        }
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        json["formatVersion"] = 1
        for key in [
            "actionShortcutAssignments",
            "pluginPreferences",
            "pluginPreferenceActionReferences",
            "actionInvocationPresets",
            "workflows",
            "automationRules",
            "selection",
        ] {
            json.removeValue(forKey: key)
        }
        let legacyBackup = try PreferencesBackup.decodeJSON(
            JSONSerialization.data(withJSONObject: json)
        )

        _ = try host.importPreferences(legacyBackup)

        XCTAssertEqual(host.shortcutAssignmentService.assignments.map(\.reference), [reference])
    }

    func testImportingLegacyBackupBridgesActionBackedPluginShortcutAfterMigration() throws {
        let defaults = makeDefaults()
        let plugin = BackupLegacyActionShortcutPlugin()
        let host = makeHost(plugins: [plugin], defaults: defaults)
        let replacement = ShortcutBinding(keyCode: 17, modifiers: [.command, .option])
        let imported = ShortcutBinding(keyCode: 16, modifiers: [.command, .shift])
        XCTAssertEqual(
            host.setActionShortcutBinding(replacement, to: plugin.reference),
            .success
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [plugin.metadata.id],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [
                BackupLegacyActionShortcutPlugin.shortcutItemID: .custom(imported),
            ]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        json["formatVersion"] = 2
        for key in [
            "actionShortcutAssignments",
            "pluginPreferenceActionReferences",
            "actionInvocationPresets",
            "workflows",
            "automationRules",
            "selection",
        ] {
            json.removeValue(forKey: key)
        }
        let legacyBackup = try PreferencesBackup.decodeJSON(
            JSONSerialization.data(withJSONObject: json)
        )

        _ = try host.importPreferences(legacyBackup)

        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: plugin.reference)?.binding,
            imported
        )
    }

    func testCurrentImportValidatesShortcutCustomizationsAndActionsAsOneDesiredState() throws {
        let ordinary = BackupTestPlugin(id: "ordinary", order: 1, shortcutID: "toggle")
        let actionProvider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [ordinary, actionProvider], defaults: makeDefaults())
        let binding = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        host.setShortcutBinding(binding, for: "ordinary.shortcut.toggle")
        let reference = try actionProvider.references()[0]
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: ["ordinary.shortcut.toggle": .cleared],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: reference,
                binding: binding
            )],
            pluginPreferences: [
                actionProvider.metadata.id: Data("provider-settings".utf8),
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(
            host.shortcutAssignmentService.assignment(for: reference)?.binding,
            binding
        )
        XCTAssertFalse(
            host.shortcutItems.first { $0.id == "ordinary.shortcut.toggle" }?.canClear ?? true
        )
    }

    func testCurrentImportRejectsNewShortcutConflictWithoutPartiallyApplyingState() throws {
        let ordinary = BackupTestPlugin(id: "ordinary", order: 1, shortcutID: "toggle")
        let actionProvider = BackupActionProviderPlugin()
        let host = makeHost(plugins: [ordinary, actionProvider], defaults: makeDefaults())
        let binding = ShortcutBinding(keyCode: 19, modifiers: [.command, .option])
        let reference = try actionProvider.references()[0]
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: ["ordinary.shortcut.toggle": .custom(binding)],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: reference,
                binding: binding
            )],
            pluginPreferences: [
                actionProvider.metadata.id: Data("provider-settings".utf8),
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertNotNil(result.shortcutErrors["action-shortcuts"])
        XCTAssertNil(host.shortcutAssignmentService.assignment(for: reference))
        XCTAssertFalse(
            host.shortcutItems.first { $0.id == "ordinary.shortcut.toggle" }?.canClear ?? true
        )
    }

    func testActionBackedShortcutCallbacksReceiveFinalGlobalAndImportedBindings() throws {
        let plugin = BackupLegacyActionShortcutPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let direct = ShortcutBinding(keyCode: 20, modifiers: [.command, .option])
        XCTAssertEqual(host.setActionShortcutBinding(direct, to: plugin.reference), .success)
        XCTAssertEqual(plugin.receivedBindings.compactMap { $0 }.last, direct)
        let imported = ShortcutBinding(keyCode: 21, modifiers: [.command, .shift])
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: [],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [
                BackupLegacyActionShortcutPlugin.shortcutItemID: .cleared,
            ],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: plugin.reference,
                binding: imported
            )]
        )

        let result = try host.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(plugin.receivedBindings.compactMap { $0 }.last, imported)
        XCTAssertTrue(plugin.receivedBindings.allSatisfy { $0 != nil })
    }

    func testPreviewAndImportShareSelectedPreferenceDefinedWorkflowContext() throws {
        let provider = BackupPreferenceDefinedActionPlugin()
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let child = WorkflowDefinition(
            name: "Child",
            steps: [WorkflowStep(reference: provider.reference)]
        )
        let parent = WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: parent.actionReference,
                binding: ShortcutBinding(keyCode: 47, modifiers: [.command, .control])
            )],
            pluginPreferences: [
                provider.metadata.id: Data("enabled".utf8),
                surface.metadata.id: try JSONEncoder().encode([parent.actionReference]),
            ],
            actionInvocationPresets: [ActionInvocationPreset(reference: provider.reference)],
            workflows: [child, parent]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: true,
            includesAutomation: true,
            includesRunLinks: true,
            pluginPreferenceIDs: [provider.metadata.id, surface.metadata.id]
        )

        let preview = try host.preferencesImportPreview(for: backup, selection: selection)
        XCTAssertEqual(preview.shortcutCount, 1)
        XCTAssertTrue(preview.unavailableActionReferences.isEmpty)

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertEqual(host.shortcutAssignmentService.assignments.first?.reference, parent.actionReference)
        XCTAssertEqual(Set(host.automationController.workflows.map(\.id)), [child.id, parent.id])
        XCTAssertEqual(surface.references, [parent.actionReference])
        XCTAssertEqual(host.makePreferencesBackup().actionInvocationPresets?.map(\.reference), [
            provider.reference,
        ])
    }

    func testPortablePayloadCannotAuthorizeDifferentCurrentPreferenceAction() throws {
        let provider = BackupPreferenceDefinedActionPlugin()
        provider.restorePortablePreferences(from: Data("item-a".utf8))
        let host = makeHost(plugins: [provider], defaults: makeDefaults())
        let currentReference = ActionReference(
            key: ActionKey(providerID: provider.metadata.id, actionID: "item-a")
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: currentReference,
                binding: ShortcutBinding(keyCode: 46, modifiers: [.command, .control])
            )],
            pluginPreferences: [provider.metadata.id: Data("item-b".utf8)]
        )

        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.shortcutCount, 0)
        XCTAssertTrue(preview.unavailableActionReferences.contains(currentReference))
        _ = try host.importPreferences(backup)
        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
    }

    func testFailedProviderRestoreDropsAllDependentImportedReferences() throws {
        let provider = BackupPreferenceDefinedActionPlugin()
        provider.shouldFailRestore = true
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let workflow = WorkflowDefinition(
            name: "Provider Dependent",
            steps: [WorkflowStep(reference: provider.reference)]
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: provider.reference,
                binding: ShortcutBinding(keyCode: 45, modifiers: [.command, .control])
            )],
            pluginPreferences: [
                provider.metadata.id: Data("enabled".utf8),
                surface.metadata.id: try JSONEncoder().encode([
                    provider.reference,
                    workflow.actionReference,
                ]),
            ],
            actionInvocationPresets: [
                ActionInvocationPreset(reference: provider.reference),
                ActionInvocationPreset(reference: workflow.actionReference),
            ],
            workflows: [workflow]
        )

        let result = try host.importPreferences(backup)

        XCTAssertEqual(
            Set(result.shortcutErrors.keys),
            [
                "plugin-preferences.\(provider.metadata.id)",
                "plugin-preferences.\(surface.metadata.id)",
            ]
        )
        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
        XCTAssertTrue(host.automationController.workflows.isEmpty)
        XCTAssertTrue(surface.references.isEmpty)
        XCTAssertTrue(host.makePreferencesBackup().actionInvocationPresets?.isEmpty ?? true)
    }

    func testFailedAutomationRestoreDropsNestedWorkflowConsumers() throws {
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [surface], defaults: makeDefaults())
        let workflows = (0 ... WorkflowStore.maximumWorkflowCount).map { index in
            WorkflowDefinition(name: "Workflow \(index)")
        }
        let nestedReference = workflows[0].actionReference
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: nestedReference,
                binding: ShortcutBinding(keyCode: 40, modifiers: [.command, .control])
            )],
            pluginPreferences: [
                surface.metadata.id: try JSONEncoder().encode([nestedReference]),
            ],
            actionInvocationPresets: [ActionInvocationPreset(reference: nestedReference)],
            workflows: workflows
        )

        let result = try host.importPreferences(backup)

        XCTAssertNotNil(result.shortcutErrors["automation"])
        XCTAssertTrue(host.automationController.workflows.isEmpty)
        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
        XCTAssertTrue(surface.references.isEmpty)
        XCTAssertTrue(host.makePreferencesBackup().actionInvocationPresets?.isEmpty ?? true)
    }

    func testSelectiveImportDropsTransitiveWorkflowWhenProviderSettingsAreNotSelected() throws {
        let provider = BackupActionProviderPlugin()
        let surface = BackupActionSurfacePlugin()
        let host = makeHost(plugins: [provider, surface], defaults: makeDefaults())
        let child = WorkflowDefinition(
            name: "Child",
            steps: [WorkflowStep(reference: try provider.references()[0])]
        )
        let parent = WorkflowDefinition(
            name: "Parent",
            steps: [WorkflowStep(reference: child.actionReference)]
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: parent.actionReference,
                binding: ShortcutBinding(keyCode: 43, modifiers: [.command, .control])
            )],
            pluginPreferences: [
                surface.metadata.id: try JSONEncoder().encode([parent.actionReference]),
                provider.metadata.id: Data("provider-settings".utf8),
            ],
            workflows: [child, parent]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: true,
            includesAutomation: true,
            includesRunLinks: false,
            pluginPreferenceIDs: [surface.metadata.id]
        )

        let preview = try host.preferencesImportPreview(for: backup, selection: selection)
        XCTAssertEqual(preview.shortcutCount, 0)
        XCTAssertTrue(preview.unavailableActionReferences.contains(parent.actionReference))
        XCTAssertTrue(
            preview.unavailableActionReferences.contains(try provider.references()[0])
        )

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
        XCTAssertTrue(surface.references.isEmpty)
        XCTAssertTrue(host.automationController.workflows.isEmpty)
    }

    func testImportMigratesOlderActionSchemaBeforePortabilityFiltering() throws {
        let plugin = BackupMigratingActionPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let legacyReference = try plugin.legacyReference()
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: legacyReference,
                binding: ShortcutBinding(keyCode: 44, modifiers: [.command, .control])
            )]
        )

        let preview = try host.preferencesImportPreview(for: backup)
        XCTAssertEqual(preview.shortcutCount, 1)
        XCTAssertTrue(preview.unavailableActionReferences.isEmpty)

        _ = try host.importPreferences(backup)

        XCTAssertEqual(host.shortcutAssignmentService.assignments.first?.reference.schemaVersion, 2)
        XCTAssertEqual(
            host.shortcutAssignmentService.assignments.first?.reference.parameters["value"],
            .string("legacy")
        )
    }

    func testPreviewDoesNotCountUnpublishedParameterizedShortcutAsAvailable() throws {
        let plugin = BackupMigratingActionPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let unpublished = try plugin.unpublishedReference()
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: unpublished,
                binding: ShortcutBinding(keyCode: 41, modifiers: [.command, .control])
            )]
        )

        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.shortcutCount, 0)
        XCTAssertTrue(preview.unavailableActionReferences.isEmpty)
        XCTAssertEqual(preview.retainedUnavailableActionReferences, [unpublished])
    }

    func testPreviewReportsUnavailableRunLinkAndWorkflowReferencesAsRetained() throws {
        let plugin = BackupMigratingActionPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let unpublished = try plugin.unpublishedReference()
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionInvocationPresets: [ActionInvocationPreset(reference: unpublished)],
            workflows: [WorkflowDefinition(
                name: "Unavailable action",
                steps: [WorkflowStep(reference: unpublished)]
            )]
        )
        let runLinksOnly = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: false,
            includesRunLinks: true,
            pluginPreferenceIDs: []
        )
        let automationOnly = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: true,
            includesRunLinks: false,
            pluginPreferenceIDs: []
        )

        let runLinkPreview = try host.preferencesImportPreview(
            for: backup,
            selection: runLinksOnly
        )
        let automationPreview = try host.preferencesImportPreview(
            for: backup,
            selection: automationOnly
        )

        XCTAssertTrue(runLinkPreview.unavailableActionReferences.isEmpty)
        XCTAssertEqual(runLinkPreview.retainedUnavailableActionReferences, [unpublished])
        XCTAssertTrue(automationPreview.unavailableActionReferences.isEmpty)
        XCTAssertEqual(automationPreview.retainedUnavailableActionReferences, [unpublished])
    }

    func testExportMigratesOlderRunLinkSchemaBeforePortabilityFiltering() throws {
        let plugin = BackupMigratingActionPlugin()
        let legacyReference = try plugin.legacyReference()
        let currentReference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)
        let legacyPreset = ActionInvocationPreset(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000471")!,
            reference: legacyReference,
            createdAt: Date(timeIntervalSince1970: 471)
        )
        let currentPreset = ActionInvocationPreset(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000472")!,
            reference: currentReference,
            createdAt: Date(timeIntervalSince1970: 472)
        )
        let sourceDefaults = makeDefaults()
        sourceDefaults.set(
            try JSONEncoder().encode(
                BackupActionPresetEnvelope(
                    formatVersion: ActionInvocationPreset.currentFormatVersion,
                    presets: [legacyPreset, currentPreset]
                )
            ),
            forKey: "actions.run-link-presets.v1"
        )
        let sourceHost = makeHost(plugins: [plugin], defaults: sourceDefaults)

        let encodedBackup = try sourceHost.makePreferencesBackup().encodedJSON()
        let decodedBackup = try PreferencesBackup.decodeJSON(encodedBackup)
        let exportedPresets = try XCTUnwrap(decodedBackup.actionInvocationPresets)
        XCTAssertEqual(exportedPresets.map(\.id), [legacyPreset.id, currentPreset.id])
        XCTAssertEqual(exportedPresets.map(\.createdAt), [legacyPreset.createdAt, currentPreset.createdAt])
        XCTAssertEqual(Set(exportedPresets.map(\.reference)), [currentReference])
        XCTAssertTrue(exportedPresets.allSatisfy { $0.reference.schemaVersion == 2 })
        XCTAssertTrue(exportedPresets.allSatisfy {
            $0.reference.parameters["value"] == .string("legacy")
        })

        let restoredHost = makeHost(
            plugins: [BackupMigratingActionPlugin()],
            defaults: makeDefaults()
        )
        _ = try restoredHost.importPreferences(decodedBackup)

        XCTAssertEqual(
            restoredHost.makePreferencesBackup().actionInvocationPresets,
            exportedPresets
        )
    }

    func testSelectiveImportDropsPreferenceDefinedActionWhenItsSettingsAreOmitted() throws {
        let plugin = BackupPreferenceDefinedActionPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: plugin.reference,
                binding: ShortcutBinding(keyCode: 45, modifiers: [.command, .control])
            )],
            pluginPreferences: [plugin.metadata.id: Data("enabled".utf8)]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: true,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: []
        )

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertTrue(host.shortcutAssignmentService.assignments.isEmpty)
    }

    func testSelectiveImportRestoresPreferenceDefinedActionAfterItsSettings() throws {
        let plugin = BackupPreferenceDefinedActionPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: plugin.reference,
                binding: ShortcutBinding(keyCode: 46, modifiers: [.command, .control])
            )],
            pluginPreferences: [plugin.metadata.id: Data("enabled".utf8)]
        )
        let selection = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: true,
            includesAutomation: false,
            includesRunLinks: false,
            pluginPreferenceIDs: [plugin.metadata.id]
        )

        _ = try host.importPreferences(backup, selection: selection)

        XCTAssertEqual(host.shortcutAssignmentService.assignments.first?.reference, plugin.reference)
    }

    func testImportRestoresPortablePreferencesBeforeDynamicShortcutCustomizations() throws {
        let binding = ShortcutBinding(keyCode: 12, modifiers: [.command, .shift])
        let plugin = DynamicBackupShortcutPlugin()
        let host = makeHost(plugins: [plugin], defaults: makeDefaults())
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: ["sidecar"], hiddenPluginIDs: []),
            shortcutCustomizations: [
                "sidecar.shortcut.device": .custom(binding)
            ],
            pluginPreferences: ["sidecar": Data("device-settings".utf8)]
        )

        let result = try host.importPreferences(backup)

        XCTAssertTrue(result.shortcutErrors.isEmpty)
        XCTAssertEqual(plugin.restoredPortablePreferences, Data("device-settings".utf8))
        XCTAssertEqual(plugin.receivedShortcutBinding, binding)
        XCTAssertEqual(
            host.makePreferencesBackup().shortcutCustomizations["sidecar.shortcut.device"],
            .custom(binding)
        )
    }

    func testPreviewReportsUnavailablePluginAndShortcutSettings() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [BackupTestPlugin(id: "available", order: 1, shortcutID: "toggle")],
            defaults: defaults
        )
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["available", "unavailable"],
                hiddenPluginIDs: ["unavailable"]
            ),
            shortcutCustomizations: [
                "available.shortcut.toggle": .cleared,
                "unavailable.shortcut.toggle": .cleared
            ]
        )

        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.pluginCount, 1)
        XCTAssertEqual(preview.unavailablePluginIDs, ["unavailable"])
        XCTAssertEqual(preview.shortcutCount, 1)
        XCTAssertEqual(preview.unavailableShortcutIDs, ["unavailable.shortcut.toggle"])
    }

    func testVersionFiveBackupDiscoversSurfaceDependenciesFromPortablePayload() throws {
        let surface = BackupActionSurfacePlugin()
        let reference = ActionReference(
            key: ActionKey(providerID: "legacy-surface-only", actionID: "run")
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: [
                surface.metadata.id: try JSONEncoder().encode([reference]),
            ]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        json["formatVersion"] = 5
        json.removeValue(forKey: "pluginPreferenceActionReferences")
        let legacyBackup = try PreferencesBackup.decodeJSON(
            JSONSerialization.data(withJSONObject: json)
        )
        let host = makeHost(plugins: [surface], defaults: makeDefaults())

        let preview = try host.preferencesImportPreview(for: legacyBackup)

        XCTAssertEqual(preview.unavailablePluginIDs, ["legacy-surface-only"])
    }

    func testPreviewIgnoresTamperedPortablePreferenceActionIndex() throws {
        let surface = BackupActionSurfacePlugin()
        let payloadReference = ActionReference(
            key: ActionKey(providerID: "payload-provider", actionID: "run")
        )
        let forgedReference = ActionReference(
            key: ActionKey(providerID: "forged-index-provider", actionID: "run")
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: [
                surface.metadata.id: try JSONEncoder().encode([payloadReference]),
            ],
            pluginPreferenceActionReferences: [surface.metadata.id: [forgedReference]]
        )
        let host = makeHost(plugins: [surface], defaults: makeDefaults())

        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.unavailablePluginIDs, ["payload-provider"])
    }

    func testPreviewAndInstallIncludeRunLinkAndWorkflowOnlyPluginDependencies() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupActionDependencyTests-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "PreferencesBackupActionDependencyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let pluginIDs = ["run-link-only", "surface-only", "workflow-only"]
        var packagesByID: [String: URL] = [:]
        for pluginID in pluginIDs {
            packagesByID[pluginID] = try makeDynamicPluginPackage(
                at: temporaryRoot,
                id: pluginID,
                version: "1.0.0"
            )
        }
        let packageStore = PluginPackageStore(
            rootDirectory: temporaryRoot.appending(path: "Installed", directoryHint: .isDirectory),
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let dynamicManager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: BackupDynamicPluginLoader()
        )
        let catalogManager = PluginCatalogManager(
            catalogProvider: BackupCatalogProvider(
                entries: pluginIDs.map { makeCatalogEntry(id: $0, version: "1.0.0") }
            ),
            packageResolver: BackupPackageResolver(packagesByID: packagesByID),
            dynamicPluginManager: dynamicManager,
            source: .production(URL(string: "https://example.com/catalog.json")!)
        )
        let surface = BackupActionSurfacePlugin()
        let host = PluginHost(
            plugins: [surface],
            dynamicPluginManager: dynamicManager,
            pluginCatalogManager: catalogManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
        let runLinkReference = ActionReference(
            key: ActionKey(providerID: "run-link-only", actionID: "run")
        )
        let workflowReference = ActionReference(
            key: ActionKey(providerID: "workflow-only", actionID: "run")
        )
        let surfaceReference = ActionReference(
            key: ActionKey(providerID: "surface-only", actionID: "run")
        )
        let surfacePayload = try JSONEncoder().encode([surfaceReference])
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: [surface.metadata.id: surfacePayload],
            pluginPreferenceActionReferences: [surface.metadata.id: [surfaceReference]],
            actionInvocationPresets: [
                ActionInvocationPreset(id: UUID(), reference: runLinkReference, createdAt: .now),
            ],
            workflows: [
                WorkflowDefinition(
                    name: "Plugin Workflow",
                    steps: [WorkflowStep(reference: workflowReference)]
                ),
            ]
        )

        await host.refreshPluginCatalog()
        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.installablePlugins.map(\.id).sorted(), pluginIDs)
        XCTAssertTrue(preview.unavailablePluginIDs.isEmpty)

        let withoutSurface = PreferencesBackupSelection(
            includesApplicationPreferences: false,
            includesPluginLayout: false,
            includesShortcuts: false,
            includesAutomation: true,
            includesRunLinks: true,
            pluginPreferenceIDs: []
        )
        let selectivePreview = try host.preferencesImportPreview(
            for: backup,
            selection: withoutSurface
        )
        XCTAssertEqual(
            selectivePreview.installablePlugins.map(\.id).sorted(),
            ["run-link-only", "workflow-only"]
        )

        let result = try await host.importPreferences(
            backup,
            installingMissingPluginIDs: Set(pluginIDs)
        )
        XCTAssertEqual(result.installedPluginIDs, pluginIDs)
        XCTAssertTrue(result.pluginInstallationFailures.isEmpty)
    }

    func testImportRestoresDisplayPreferencesAndShortcutCustomizations() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: "first.shortcut.toggle"
        )
        let openSettingsBinding = ShortcutBinding(
            keyCode: 13,
            modifiers: [.command, .option]
        )
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["second", "unavailable", "first"],
                hiddenPluginIDs: ["first", "unavailable"]
            ),
            shortcutCustomizations: [
                "second.shortcut.open": .cleared,
                "unavailable.shortcut.toggle": .cleared
            ],
            actionShortcutAssignments: [ActionShortcutAssignmentRecord(
                reference: ActionReference(
                    key: ActionKey(
                        providerID: "mactools",
                        actionID: AppShortcutAction.openSettings.rawValue
                    )
                ),
                binding: openSettingsBinding
            )]
        )

        _ = try host.importPreferences(backup)

        XCTAssertEqual(host.featureManagementItems.map(\.id), ["second", "first"])
        XCTAssertTrue(host.featureManagementItems.first(where: { $0.id == "first" })?.isVisible ?? false)
        XCTAssertFalse(host.shortcutItems.first(where: { $0.id == "second.shortcut.open" })?.canClear ?? true)
        XCTAssertTrue(host.shortcutItems.first(where: { $0.id == "first.shortcut.toggle" })?.usesDefaultValue ?? false)
        XCTAssertEqual(
            host.appShortcutItems.first { $0.action == .openSettings }?.bindingText,
            ShortcutFormatter.displayString(for: openSettingsBinding)
        )
    }

    func testExportAndImportPreserveSurfaceDisplayOrders() throws {
        let sourceDefaults = makeDefaults()
        let sourceHost = makeHost(
            plugins: [
                BackupCombinedPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupCombinedPlugin(id: "second", order: 2, shortcutID: "open"),
                BackupCombinedPlugin(id: "third", order: 3, shortcutID: "show")
            ],
            defaults: sourceDefaults
        )
        sourceHost.movePlugin(id: "third", toOffset: 0, on: .dashboard)
        sourceHost.movePlugin(id: "second", toOffset: 0, on: .featurePanel)
        sourceHost.setPluginVisible(false, id: "first", on: .dashboard)
        sourceHost.setPluginVisible(false, id: "third", on: .featurePanel)

        let backup = sourceHost.makePreferencesBackup()

        XCTAssertEqual(backup.pluginDisplay.dashboardOrderedPluginIDs, ["third", "first", "second"])
        XCTAssertEqual(backup.pluginDisplay.featurePanelOrderedPluginIDs, ["second", "first", "third"])
        XCTAssertEqual(backup.pluginDisplay.dashboardHiddenPluginIDs, ["first"])
        XCTAssertEqual(backup.pluginDisplay.featurePanelHiddenPluginIDs, ["third"])

        let targetDefaults = makeDefaults()
        let targetHost = makeHost(
            plugins: [
                BackupCombinedPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupCombinedPlugin(id: "second", order: 2, shortcutID: "open"),
                BackupCombinedPlugin(id: "third", order: 3, shortcutID: "show")
            ],
            defaults: targetDefaults
        )

        _ = try targetHost.importPreferences(backup)

        XCTAssertEqual(targetHost.dashboardLayoutItems.map(\.id), ["third", "second"])
        XCTAssertEqual(targetHost.dashboardHiddenLayoutItems.map(\.id), ["first"])
        XCTAssertEqual(targetHost.componentItems.map(\.id), ["third", "second"])
        XCTAssertEqual(targetHost.featurePanelLayoutItems.map(\.id), ["second", "first"])
        XCTAssertEqual(targetHost.featurePanelHiddenLayoutItems.map(\.id), ["third"])
        XCTAssertEqual(targetHost.panelItems.map(\.id), ["second", "first"])
    }

    func testImportLegacyDisplayBackupSeedsSurfaceOrdersFromGeneralOrder() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupCombinedPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupCombinedPlugin(id: "second", order: 2, shortcutID: "open"),
                BackupCombinedPlugin(id: "third", order: 3, shortcutID: "show")
            ],
            defaults: defaults
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["third", "second", "first"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:]
        )

        _ = try host.importPreferences(backup)

        XCTAssertEqual(host.dashboardLayoutItems.map(\.id), ["third", "second", "first"])
        XCTAssertEqual(host.featurePanelLayoutItems.map(\.id), ["third", "second", "first"])
    }

    func testInvalidShortcutImportLeavesAllShortcutCustomizationsUntouched() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        let firstBinding = ShortcutBinding(keyCode: 12, modifiers: [.command])
        let secondBinding = ShortcutBinding(keyCode: 13, modifiers: [.command])
        host.setShortcutBinding(firstBinding, for: "first.shortcut.toggle")
        host.setShortcutBinding(secondBinding, for: "second.shortcut.open")
        let existingCustomizations = host.makePreferencesBackup().shortcutCustomizations
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: ["first", "second"], hiddenPluginIDs: []),
            shortcutCustomizations: [
                "first.shortcut.toggle": .custom(firstBinding),
                "second.shortcut.open": .custom(firstBinding)
            ]
        )

        let result = try host.importPreferences(backup)

        XCTAssertEqual(
            Set(result.shortcutErrors.keys),
            Set(["first.shortcut.toggle", "second.shortcut.open"])
        )
        XCTAssertEqual(host.makePreferencesBackup().shortcutCustomizations, existingCustomizations)
    }

    func testImportMapsLegacyGlobalHiddenPreferenceToSurfaceVisibility() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupInstallTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PreferencesBackupInstallTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let packageURL = try makeDynamicPluginPackage(
            at: temporaryRoot,
            id: "installable",
            version: "1.0.0"
        )
        let packageStore = PluginPackageStore(
            rootDirectory: temporaryRoot.appending(path: "Installed", directoryHint: .isDirectory),
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
        let loader = BackupDynamicPluginLoader()
        let dynamicManager = DynamicPluginManager(
            packageStore: packageStore,
            pluginLoader: loader
        )
        let entry = makeCatalogEntry(id: "installable", version: "1.0.0")
        let catalogManager = PluginCatalogManager(
            catalogProvider: BackupCatalogProvider(entries: [entry]),
            packageResolver: BackupPackageResolver(packagesByID: ["installable": packageURL]),
            dynamicPluginManager: dynamicManager,
            source: .production(URL(string: "https://example.com/catalog.json")!)
        )
        let host = PluginHost(
            plugins: [BackupTestPlugin(id: "built-in", order: 1, shortcutID: "toggle")],
            dynamicPluginManager: dynamicManager,
            pluginCatalogManager: catalogManager,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(),
            loadDynamicPluginsOnInit: false
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["installable", "built-in"],
                hiddenPluginIDs: ["installable"]
            ),
            shortcutCustomizations: [:]
        )

        await host.refreshPluginCatalog()
        let result = try await host.importPreferences(
            backup,
            installingMissingPluginIDs: ["installable"]
        )

        XCTAssertEqual(result.installedPluginIDs, ["installable"])
        XCTAssertTrue(result.pluginInstallationFailures.isEmpty)
        XCTAssertEqual(host.featurePanelHiddenLayoutItems.map(\.id), ["installable"])
        XCTAssertFalse(host.panelItems.contains(where: { $0.id == "installable" }))
        XCTAssertEqual(dynamicManager.pluginManagementItems.first(where: { $0.id == "installable" })?.state, .installed)
        XCTAssertEqual(loader.receivedRecordIDBatches, [["installable"]])
    }

    func testDecodeRejectsUnsupportedFormatVersion() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        let unsupportedVersion = PreferencesBackup.currentFormatVersion + 1
        json["formatVersion"] = unsupportedVersion

        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))) { error in
            guard case PreferencesBackupError.unsupportedFormatVersion(unsupportedVersion) = error else {
                return XCTFail("Expected unsupported format version error, got \(error)")
            }
        }
    }

    func testDecodeRejectsVersionSixWithoutPluginActionDependencies() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        json.removeValue(forKey: "pluginPreferenceActionReferences")

        XCTAssertThrowsError(
            try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected missing dependency index to be rejected, got \(error)")
            }
        }
    }

    func testDecodeRejectsVersionSixWithoutActionShortcutAssignments() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        json.removeValue(forKey: "actionShortcutAssignments")

        XCTAssertThrowsError(
            try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected missing shortcut assignment array to be rejected, got \(error)")
            }
        }
    }

    func testDecodeRejectsInvalidApplicationPreferences() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        var application = try XCTUnwrap(json["application"] as? [String: Any])
        application["languagePreference"] = "unsupported-language"
        json["application"] = application

        let decodedBackup = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))
        let store = PreferencesBackupStore(userDefaults: makeDefaults())

        XCTAssertThrowsError(try decodedBackup.validateApplicationPreferences(using: store.validates)) { error in
            guard case PreferencesBackupError.invalidApplicationPreferences = error else {
                return XCTFail("Expected invalid application preferences error, got \(error)")
            }
        }
    }

    func testDecodeAcceptsVersionOneBackupWithoutPortablePluginPreferences() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: ["sidecar": Data("portable".utf8)]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        json["formatVersion"] = 1
        json.removeValue(forKey: "pluginPreferences")
        json.removeValue(forKey: "actionInvocationPresets")
        json.removeValue(forKey: "workflows")
        json.removeValue(forKey: "automationRules")
        json.removeValue(forKey: "selection")
        json.removeValue(forKey: "actionShortcutAssignments")

        let decoded = try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertTrue(decoded.pluginPreferences.isEmpty)
        XCTAssertNil(decoded.actionInvocationPresets)
        XCTAssertNil(decoded.workflows)
        XCTAssertNil(decoded.automationRules)
        XCTAssertFalse(decoded.actionShortcutAssignmentsWereEncoded)
        XCTAssertTrue(decoded.effectiveSelection.includesApplicationPreferences)
        XCTAssertTrue(decoded.effectiveSelection.includesPluginLayout)
        XCTAssertTrue(decoded.effectiveSelection.includesShortcuts)
        XCTAssertFalse(decoded.effectiveSelection.includesAutomation)
        XCTAssertFalse(decoded.effectiveSelection.includesRunLinks)
    }

    func testDecodeTreatsVersionFourBackupWithoutSelectionAsAFullBackup() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["sidecar"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:],
            pluginPreferences: ["sidecar": Data("portable".utf8)]
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any]
        )
        json["formatVersion"] = 4
        json.removeValue(forKey: "selection")

        let decoded = try PreferencesBackup.decodeJSON(
            JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertTrue(decoded.effectiveSelection.includesApplicationPreferences)
        XCTAssertTrue(decoded.effectiveSelection.includesPluginLayout)
        XCTAssertTrue(decoded.effectiveSelection.includesShortcuts)
        XCTAssertTrue(decoded.effectiveSelection.includesAutomation)
        XCTAssertTrue(decoded.effectiveSelection.includesRunLinks)
        XCTAssertEqual(decoded.effectiveSelection.pluginPreferenceIDs, ["sidecar"])
    }

    func testDecodeRejectsVersionFourBackupMissingAutomationFields() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        json.removeValue(forKey: "workflows")

        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected missing current-format fields to be rejected, got \(error)")
            }
        }
    }

    func testDecodeRejectsUnsupportedShortcutModifierBits() throws {
        let binding = ShortcutBinding(
            keyCode: 12,
            modifiers: ShortcutModifiers(rawValue: 1 << 4)
        )
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: ["plugin.shortcut.action": .custom(binding)]
        )

        XCTAssertFalse(binding.isValid)
        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(backup.encodedJSON())) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected invalid shortcut modifiers, got \(error)")
            }
        }
    }

    func testRegularKeyShortcutWithoutModifierIsStillRejected() {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [BackupTestPlugin(id: "plugin", order: 1, shortcutID: "action")],
            defaults: defaults
        )
        let binding = ShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [])

        let error = host.setShortcutBindingAndReturnError(binding, for: "plugin.shortcut.action")

        XCTAssertNotNil(error)
        XCTAssertNil(host.makePreferencesBackup().shortcutCustomizations["plugin.shortcut.action"])
    }

    func testDecodeFileRejectsContentAboveSizeLimit() async throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x20, count: PreferencesBackup.maximumFileSize + 1).write(to: url)

        do {
            _ = try await PreferencesBackup.decodeJSON(contentsOf: url)
            XCTFail("Expected oversized backup to be rejected")
        } catch {
            XCTAssertEqual(
                error as? PreferencesBackupError,
                .fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
            )
        }
    }

    func testEncodeRejectsContentAboveFileSizeLimit() {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: Dictionary(uniqueKeysWithValues: (0..<4).map { index in
                ("plugin-\(index)", Data(repeating: UInt8(index), count: 3_200_000))
            })
        )

        XCTAssertThrowsError(try backup.encodedJSON()) { error in
            XCTAssertEqual(
                error as? PreferencesBackupError,
                .fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
            )
        }
    }

    func testNearLimitExportRoundTripsThroughFileImporter() async throws {
        let payloads = Dictionary(uniqueKeysWithValues: (0..<4).map { index in
            ("plugin-\(index)", Data(repeating: UInt8(index), count: 3_000_000))
        })
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:],
            pluginPreferences: payloads
        )
        let data = try backup.encodedJSON()
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let decoded = try await PreferencesBackup.decodeJSON(contentsOf: url)

        XCTAssertEqual(decoded.pluginPreferences, payloads)
        XCTAssertLessThanOrEqual(data.count, PreferencesBackup.maximumFileSize)
    }

    private var validApplicationPreferences: PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.system.rawValue,
            languagePreference: AppLanguagePreference.system.rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
        )
    }

    private func makeDefaults(suiteName customSuiteName: String? = nil) -> UserDefaults {
        let resolvedSuiteName = customSuiteName ?? suiteName
        let defaults = UserDefaults(suiteName: resolvedSuiteName)!
        defaults.removePersistentDomain(forName: resolvedSuiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: resolvedSuiteName)
        }
        return defaults
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferencesBackupTests-\(UUID().uuidString).json")
    }

    private func makeHost(
        plugins: [any MacToolsPlugin],
        defaults: UserDefaults
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }

    private func makeDynamicPluginPackage(at root: URL, id: String, version: String) throws -> URL {
        let packageURL = root
            .appending(path: "Source/\(id)-\(UUID().uuidString).mactoolsplugin", directoryHint: .isDirectory)
        let bundleRelativePath = "Demo.bundle"
        try FileManager.default.createDirectory(
            at: packageURL.appending(path: bundleRelativePath, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Installable",
            version: version,
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleRelativePath,
            capabilities: .init(primaryPanel: true)
        )
        try JSONEncoder().encode(manifest).write(to: packageURL.appending(path: "plugin.json"))
        return packageURL
    }

    private func makeCatalogEntry(id: String, version: String) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Installable",
            summary: "Available from the verified catalog.",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
    }
}

@MainActor
private struct BackupCatalogProvider: PluginCatalogProviding {
    let entries: [PluginCatalogEntry]

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.backup-tests",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "0.1.0",
                plugins: entries
            ),
            sourceURL: URL(string: "https://example.com/catalog.json")!,
            sourceKind: .production,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private struct BackupPackageResolver: PluginPackageResolving {
    let packagesByID: [String: URL]

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        guard let packageURL = packagesByID[entry.id] else {
            throw PluginCatalogManagerError.catalogEntryNotFound(entry.id)
        }

        return packageURL
    }
}

@MainActor
private final class BackupDynamicPluginLoader: DynamicPluginLoading {
    private(set) var receivedRecordIDBatches: [[String]] = []

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDBatches.append(records.map(\.id))
        return records.map { record in
            DynamicPluginLoadResult(
                record: record,
                plugins: [BackupTestPlugin(id: record.id, order: 10, shortcutID: "toggle")],
                errorMessage: nil
            )
        }
    }
}

@MainActor
private final class BackupTestPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginPortablePreferencesProviding {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private let portablePreferences: Data?
    private(set) var restoredPortablePreferences: Data?

    init(id: String, order: Int, shortcutID: String, portablePreferences: Data? = nil) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: .blue,
            order: order,
            defaultDescription: id
        )
        primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: shortcutID,
                title: shortcutID,
                description: shortcutID,
                actionID: shortcutID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
        self.portablePreferences = portablePreferences
    }

    func makePortablePreferencesBackup() -> Data? {
        portablePreferences
    }

    func restorePortablePreferences(from data: Data) {
        restoredPortablePreferences = data
    }

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

@MainActor
private final class BackupActionProviderPlugin: MacToolsPlugin, PluginActionProviding,
    PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding
{
    let metadata = PluginMetadata(
        id: "backup-actions",
        title: "Backup Actions",
        iconName: "shippingbox",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Backup action portability tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionDefinitions: [ActionDefinition] {
        [
            definition(actionID: "portable"),
            definition(actionID: "local", portability: .localOnly),
            definition(actionID: "sensitive", privacy: .sensitive),
        ]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        (try? references())?.map {
            ActionCatalogEntry(reference: $0, title: $0.key.actionID)
        } ?? []
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }

    func makePortablePreferencesBackup() -> Data? { Data("provider-settings".utf8) }
    func restorePortablePreferences(from data: Data) {}
    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        data == Data("provider-settings".utf8)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        guard data == Data("provider-settings".utf8) else { return nil }
        return try? [references()[0]]
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        reference.key.actionID == "portable" ? .requiresPluginPreferences : .selfContained
    }

    func references() throws -> [ActionReference] {
        try ["portable", "local", "sensitive"].map { actionID in
            ActionReference(
                key: ActionKey(providerID: metadata.id, actionID: actionID),
                parameters: try ActionParameterSet(["value": .string(actionID)])
            )
        }
    }

    private func definition(
        actionID: String,
        privacy: ActionParameterPrivacy = .publicValue,
        portability: ActionParameterPortability = .portable
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: actionID),
            title: actionID,
            description: actionID,
            systemImage: "shippingbox",
            parameters: [
                ActionParameterDefinition(
                    id: "value",
                    title: "Value",
                    kind: .string,
                    privacy: privacy,
                    portability: portability
                ),
            ],
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
    }
}

private struct BackupActionPresetEnvelope: Encodable {
    let formatVersion: Int
    let presets: [ActionInvocationPreset]
}

@MainActor
private final class BackupMigratingActionPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "migrating-actions",
        title: "Migrating Actions",
        iconName: "arrow.triangle.2.circlepath",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Migration tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(
            key: actionKey,
            parameterSchemaVersion: 2,
            title: "Migrated",
            description: "Migrated",
            systemImage: "arrow.triangle.2.circlepath",
            parameters: [ActionParameterDefinition(id: "value", title: "Value", kind: .string)],
            capabilities: [.background, .foregroundInteractive]
        )]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        guard let reference = try? currentReference() else { return [] }
        return [ActionCatalogEntry(reference: reference, title: "Migrated")]
    }

    func legacyReference() throws -> ActionReference {
        ActionReference(
            key: actionKey,
            schemaVersion: 1,
            parameters: try ActionParameterSet(["legacyValue": .string("legacy")])
        )
    }

    func unpublishedReference() throws -> ActionReference {
        ActionReference(
            key: actionKey,
            schemaVersion: 2,
            parameters: try ActionParameterSet(["value": .string("unpublished")])
        )
    }

    func migrateActionReference(
        _ reference: ActionReference,
        toSchemaVersion schemaVersion: Int
    ) -> ActionReference? {
        guard reference.key == actionKey,
              reference.schemaVersion == 1,
              schemaVersion == 2,
              case let .string(value)? = reference.parameters["legacyValue"] else {
            return nil
        }
        return try? ActionReference(
            key: actionKey,
            schemaVersion: 2,
            parameters: ActionParameterSet(["value": .string(value)])
        )
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }

    private var actionKey: ActionKey {
        ActionKey(providerID: metadata.id, actionID: "migrated")
    }

    private func currentReference() throws -> ActionReference {
        ActionReference(
            key: actionKey,
            schemaVersion: 2,
            parameters: try ActionParameterSet(["value": .string("legacy")])
        )
    }
}

@MainActor
private final class BackupPreferenceDefinedActionPlugin: MacToolsPlugin, PluginActionProviding,
    PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding,
    PluginActionReferenceBackupProviding
{
    let metadata = PluginMetadata(
        id: "preference-defined-actions",
        title: "Preference Defined Actions",
        iconName: "gear",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Preference dependency tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var shouldFailRestore = false
    private var preferencesRestored = false

    var reference: ActionReference {
        ActionReference(key: ActionKey(providerID: metadata.id, actionID: storedActionID))
    }

    var actionDefinitions: [ActionDefinition] {
        guard preferencesRestored else { return [] }
        return [ActionDefinition(
            key: reference.key,
            title: "Restored Item",
            description: "Restored Item",
            systemImage: "gear",
            capabilities: [.background, .foregroundInteractive]
        )]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        preferencesRestored ? [ActionCatalogEntry(reference: reference, title: "Restored Item")] : []
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }

    func makePortablePreferencesBackup() -> Data? {
        preferencesRestored ? Data(storedActionID.utf8) : nil
    }

    func restorePortablePreferences(from data: Data) {
        restoredActionID = decodedActionID(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard !shouldFailRestore, let actionID = decodedActionID(from: data) else {
            return false
        }
        restoredActionID = actionID
        return true
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        guard let actionID = decodedActionID(from: data) else { return nil }
        return [ActionReference(
            key: ActionKey(providerID: metadata.id, actionID: actionID)
        )]
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        restoredActionID == reference.key.actionID
            ? .requiresPluginPreferences
            : .excluded
    }

    private var restoredActionID: String? {
        get { preferencesRestored ? storedActionID : nil }
        set {
            storedActionID = newValue ?? "restored-item"
            preferencesRestored = newValue != nil
        }
    }

    private var storedActionID = "restored-item"

    private func decodedActionID(from data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value == "enabled" ? "restored-item" : value
    }
}

@MainActor
private final class BackupActionSurfacePlugin: MacToolsPlugin, PluginPortablePreferencesProviding,
    PluginPortablePreferencesRestorationReporting,
    PluginPortablePreferencesActionReferencesProviding, ActionGridHostContextConsuming
{
    let metadata = PluginMetadata(
        id: "backup-action-surface",
        title: "Backup Action Surface",
        iconName: "square.grid.3x3",
        iconTint: .blue,
        order: 2,
        defaultDescription: "Action-surface backup tests"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var actionGridHostContext: ActionGridHostContext?
    var references: [ActionReference] = []

    func makePortablePreferencesBackup() -> Data? {
        try? JSONEncoder().encode(references.filter {
            actionGridHostContext?.canExport($0) ?? false
        })
    }

    func restorePortablePreferences(from data: Data) {
        references = ((try? JSONDecoder().decode([ActionReference].self, from: data)) ?? []).filter {
            actionGridHostContext?.canRestore($0) ?? false
        }
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode([ActionReference].self, from: data),
              decoded.allSatisfy({ actionGridHostContext?.canRestore($0) ?? false }) else {
            return false
        }
        references = decoded
        return true
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        try? JSONDecoder().decode([ActionReference].self, from: data)
    }
    func handleAction(_ action: PluginPanelAction) {}
}

@MainActor
private final class DynamicBackupShortcutPlugin: MacToolsPlugin, PluginPortablePreferencesProviding,
    PluginShortcutBindingChangeHandling {
    let metadata = PluginMetadata(
        id: "sidecar",
        title: "Sidecar",
        iconName: "display",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Sidecar"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var restoredPortablePreferences: Data?
    private(set) var receivedShortcutBinding: ShortcutBinding?

    var shortcutDefinitions: [PluginShortcutDefinition] {
        guard restoredPortablePreferences != nil else { return [] }

        return [
            PluginShortcutDefinition(
                id: "device",
                title: "Device",
                description: "Device",
                actionID: "device",
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }

    func makePortablePreferencesBackup() -> Data? {
        restoredPortablePreferences
    }

    func restorePortablePreferences(from data: Data) {
        restoredPortablePreferences = data
    }

    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        guard id == "device" else { return }
        receivedShortcutBinding = binding
    }

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

@MainActor
private final class BackupLegacyActionShortcutPlugin:
    MacToolsPlugin,
    PluginActionProviding,
    PluginLegacyActionShortcutProviding,
    PluginShortcutBindingChangeHandling
{
    static let shortcutItemID = "backup-legacy-action-shortcut.shortcut.toggle"

    let metadata = PluginMetadata(
        id: "backup-legacy-action-shortcut",
        title: "Legacy Action Shortcut",
        iconName: "command",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Legacy action shortcut import fixture"
    )
    let definition = ActionDefinition(
        key: ActionKey(providerID: "backup-legacy-action-shortcut", actionID: "toggle"),
        title: "Toggle",
        description: "Toggle the fixture",
        systemImage: "command",
        externalInvocationPolicy: .allowed,
        capabilities: [.foregroundInteractive]
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var receivedBindings: [ShortcutBinding?] = []

    var reference: ActionReference { ActionReference(key: definition.key) }
    var actionDefinitions: [ActionDefinition] { [definition] }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: "toggle",
                title: "Toggle",
                description: "Toggle the fixture",
                actionID: definition.key.actionID,
                scope: .global,
                defaultBinding: ShortcutBinding(
                    keyCode: 46,
                    modifiers: [.command, .option]
                ),
                isRequired: false
            ),
        ]
    }
    var legacyActionShortcutAssignments: [LegacyActionShortcutAssignment] {
        guard let binding = shortcutBindingResolver?("toggle") else { return [] }
        return [
            LegacyActionShortcutAssignment(
                reference: reference,
                binding: binding,
                legacyShortcutDefinitionID: "toggle"
            ),
        ]
    }

    func legacyActionShortcutsDidMigrate() {}

    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        guard id == "toggle" else { return }
        receivedBindings.append(binding)
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded() }
    }
}

private final class BackupCombinedPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginComponentPanel {
    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    let descriptor = PluginComponentDescriptor(span: .oneByOne)
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int, shortcutID: String) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: .blue,
            order: order,
            defaultDescription: id
        )
        primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .switch,
            menuActionBehavior: .keepPresented
        )
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: shortcutID,
                title: shortcutID,
                description: shortcutID,
                actionID: shortcutID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }

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

    func makeView(context: PluginComponentContext) -> AnyView {
        AnyView(Text(context.pluginID))
    }

    func handleAction(_ action: PluginPanelAction) {}
}
