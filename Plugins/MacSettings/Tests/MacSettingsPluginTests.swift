import XCTest
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class MacSettingsPluginTests: XCTestCase {
    func testDeferredSettingsCannotReappearThroughFavoritesOrActions() async throws {
        let catalog = try MacSettingsCatalogFactory.make { nil }
        let storage = MacSettingsTestStorage()
        let retainedID: SystemSettingID = "finder.show-all-extensions"
        storage.set(
            [retainedID.rawValue] + catalog.deferredDefinitions.keys.map(\.rawValue),
            forKey: "favorite-setting-ids"
        )
        let controller = MacSettingsController(catalog: catalog, storage: storage)
        // Inspect the production catalog without running live system reads or writes.
        controller.deactivate()
        let plugin = MacSettingsPlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))

        XCTAssertEqual(controller.visibleRecords.count, 44)
        XCTAssertEqual(controller.favoriteIDs, [retainedID])
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.count, 2)
        let draftIDs = Set(controller.makeDraft().items.map(\.settingID))
        XCTAssertTrue(draftIDs.isDisjoint(with: catalog.deferredDefinitions.keys))
        let settingActions = plugin.actionCatalogEntries.filter {
            $0.reference.key.actionID == "open-setting"
        }
        XCTAssertEqual(settingActions.count, 44)

        for id in catalog.deferredDefinitions.keys {
            for actionID in ["open-setting", "set-boolean"] {
                let reference = ActionReference(
                    key: ActionKey(providerID: "mac-settings", actionID: actionID),
                    parameters: try ActionParameterSet([
                        "setting-id": .string(id.rawValue), "enabled": .boolean(true),
                    ])
                )
                XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
                let handle = try plugin.beginAction(.init(
                    reference: reference, source: .test, mode: .background
                ))
                guard case .failed = await handle.result() else {
                    return XCTFail("Deferred setting must not execute \(actionID): \(id)")
                }
            }
        }
    }

    func testFeaturePanelPreservesAllChoicesAndSelectionBeyondThirdOption() throws {
        let options = (1 ... 4).map { SystemSettingChoice(id: "\($0)", title: "Option \($0)") }
        let record = makeTestRecord(
            id: "choice", title: "Choice", schema: .choice(options: options),
            defaultValue: .choice(id: "4"),
            adapter: DeterministicSystemSettingAdapter(value: .choice(id: "4"))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage()
        )
        controller.toggleFavorite(record.id)
        let plugin = MacSettingsPlugin(controller: controller)
        plugin.handleAction(.setDisclosureExpanded(true))
        let control = try XCTUnwrap(plugin.primaryPanelState.detail?.controls.first)
        XCTAssertEqual(control.kind, .selectList)
        XCTAssertEqual(control.options.map(\.id), options.map(\.id))
        XCTAssertEqual(control.selectedOptionID, "4")
    }

    func testFullDiskAccessPermissionDerivesAffectedSettingsAndRoutesActions() throws {
        let protectedFirst = makeTestRecord(
            id: "protected.first",
            title: "First Protected Setting",
            requirements: .init(requiredPermissionID: MacSettingsPermission.fullDiskAccess),
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let ordinary = makeTestRecord(
            id: "ordinary",
            title: "Ordinary Setting",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let protectedSecond = makeTestRecord(
            id: "protected.second",
            title: "Second Protected Setting",
            requirements: .init(requiredPermissionID: MacSettingsPermission.fullDiskAccess),
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([protectedFirst, ordinary, protectedSecond]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore(),
            environment: SystemSettingEnvironment(
                systemVersion: .init(14),
                availableHardware: [],
                grantedPermissionIDs: [],
                availableProviderIDs: []
            )
        )
        var openedURLs: [URL] = []
        let plugin = MacSettingsPlugin(
            controller: controller,
            openSystemSettings: { openedURLs.append($0) }
        )

        let requirement = try XCTUnwrap(plugin.permissionRequirements.first)
        XCTAssertEqual(requirement.id, MacSettingsPermission.fullDiskAccess)
        XCTAssertTrue(requirement.description.contains(protectedFirst.definition.title))
        XCTAssertTrue(requirement.description.contains(protectedSecond.definition.title))
        XCTAssertFalse(requirement.description.contains(ordinary.definition.title))
        let state = plugin.permissionState(for: requirement.id)
        XCTAssertFalse(state.isGranted)
        XCTAssertNotNil(state.footnote)

        plugin.handlePermissionAction(id: requirement.id)
        controller.openSystemSettings(for: protectedFirst.id)
        controller.openSystemSettings(for: ordinary.id)
        XCTAssertEqual(openedURLs.count, 3)
        XCTAssertTrue(openedURLs.prefix(2).allSatisfy {
            $0.absoluteString.contains("Privacy_AllFiles")
        })
        XCTAssertEqual(openedURLs[2].absoluteString, "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    func testPluginDefaultsToAllSettingsAndPublishesFeaturePanelFavorites() throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "favorite", title: "Favorite", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)

        XCTAssertEqual(controller.destination, .all)
        XCTAssertEqual(plugin.metadata.id, "mac-settings")
        XCTAssertEqual(plugin.settingsPage?.body.layout, .workspace)
        controller.toggleFavorite(record.id)
        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.count, 2)
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.first?.actionTitle, "Favorite · Off")
    }

    func testSearchActionKeepsResultsInControllableWorkspace() async throws {
        let record = makeTestRecord(
            id: "finder.extension",
            title: "Show Extensions",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        var presentationCount = 0
        plugin.requestSettingsPresentation = { presentationCount += 1 }
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "search"),
            parameters: try ActionParameterSet(["query": .string("extensions")])
        )

        let result = try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .foreground
        ))
        let executionResult = await result.result()
        XCTAssertEqual(executionResult, .succeeded())
        XCTAssertEqual(controller.destination, .all)
        XCTAssertEqual(controller.searchText, "extensions")
        XCTAssertEqual(controller.visibleRecords.map(\.id), [record.id])
        XCTAssertEqual(presentationCount, 1)
    }

    func testSettingDeepLinkOpensTheExactControllableRow() async throws {
        let record = makeTestRecord(
            id: "finder.extension",
            title: "Show Extensions",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        var presentationCount = 0
        plugin.requestSettingsPresentation = { presentationCount += 1 }
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "open-setting"),
            parameters: try ActionParameterSet(["setting-id": .string(record.id.rawValue)])
        )

        let handle = try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .foreground
        ))

        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.destination, .all)
        XCTAssertTrue(controller.searchText.isEmpty)
        XCTAssertEqual(controller.settingFocusRequest?.settingID, record.id)
        XCTAssertEqual(presentationCount, 1)

        let firstRequest = controller.settingFocusRequest
        _ = await (try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .foreground
        ))).result()
        XCTAssertNotEqual(controller.settingFocusRequest, firstRequest)
        XCTAssertEqual(controller.settingFocusRequest?.settingID, record.id)
    }

    func testCategoryDeepLinkUsesVisibleSearchInsteadOfAHiddenScope() async throws {
        let record = makeTestRecord(
            id: "finder.extension",
            title: "Show Extensions",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "open-category"),
            parameters: try ActionParameterSet(["category": .string(SystemSettingCategory.finder.rawValue)])
        )

        let result = await (try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .foreground
        ))).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.destination, .all)
        XCTAssertEqual(controller.searchText, SystemSettingCategory.finder.title)
        XCTAssertEqual(controller.paletteSections.map(\.kind), [.searchResults])
        XCTAssertEqual(controller.paletteSections.flatMap(\.records).map(\.id), [record.id])
    }

    func testParameterizedBooleanActionUsesSameVerifiedAdapterPath() async throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "set-boolean"),
            parameters: try ActionParameterSet([
                "setting-id": .string(record.id.rawValue),
                "enabled": .boolean(true),
            ])
        )
        XCTAssertEqual(plugin.actionAvailability(for: reference), .available)

        let result = try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .background
        ))
        let executionResult = await result.result()
        XCTAssertEqual(executionResult, .succeeded())
        XCTAssertEqual(adapter.value, .boolean(true))
        XCTAssertEqual(controller.rowStates[record.id]?.verification, .verified)
    }

    func testRuntimeReadFailureDisablesActionsAndFeaturePanelControls() async throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        adapter.readError = SystemSettingAdapterError.unsupported("Device unavailable")
        let record = makeTestRecord(
            id: "failed",
            title: "Failed",
            executionClass: .hardwareDependent,
            adapter: adapter
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        controller.toggleFavorite(record.id)
        await controller.refresh(record)
        plugin.handleAction(.setDisclosureExpanded(true))

        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "set-boolean"),
            parameters: try ActionParameterSet([
                "setting-id": .string(record.id.rawValue),
                "enabled": .boolean(true),
            ])
        )
        XCTAssertEqual(
            plugin.actionAvailability(for: reference),
            .unavailable("This setting is currently unavailable.")
        )
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.first?.isEnabled, false)
        guard case .hardwareUnavailable? = controller.rowStates[record.id]?.availability else {
            return XCTFail("Expected a shared hardware-unavailable state")
        }
    }

    func testPortableRestorePreservesUnknownProfileEntries() throws {
        let record = makeTestRecord(
            id: "future.setting",
            title: "Future",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let sourceController = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        var draft = sourceController.makeDraft()
        draft.name = "Forward Compatible"
        draft.setDesiredValue(.boolean(true), for: record.id)
        XCTAssertTrue(sourceController.saveDraft(draft))
        let sourcePlugin = MacSettingsPlugin(controller: sourceController)
        let sourceBackup = try XCTUnwrap(sourcePlugin.makePortablePreferencesBackup())

        let targetController = MacSettingsController(
            catalog: makeTestCatalog([]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let targetPlugin = MacSettingsPlugin(controller: targetController)
        XCTAssertTrue(targetPlugin.restorePortablePreferencesReportingResult(from: sourceBackup))
        let roundTripBackup = try XCTUnwrap(targetPlugin.makePortablePreferencesBackup())

        XCTAssertTrue(String(decoding: roundTripBackup, as: UTF8.self).contains("future.setting"))
    }

    func testDeactivationCancelsRefreshAndExternalObservers() {
        let controller = MacSettingsController(
            catalog: makeTestCatalog([]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        plugin.activate(context: .init(pluginID: "mac-settings"))
        plugin.deactivate(reason: .disabled)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testDeactivationCancelsProfileBeforeTheNextWriteAndAllowsReactivation() async {
        let firstAdapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
        let secondAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let first = makeTestRecord(id: "first", title: "First", adapter: firstAdapter)
        let second = makeTestRecord(id: "second", title: "Second", adapter: secondAdapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([first, second]), storage: MacSettingsTestStorage())
        let plugin = MacSettingsPlugin(controller: controller)
        controller.preparePlan(for: .init(name: "Cancel", entries: [
            .init(settingID: first.id, desiredValue: .boolean(true), category: .finder),
            .init(settingID: second.id, desiredValue: .boolean(true), category: .finder),
        ]))
        while controller.isPreparingPlan { await Task.yield() }
        firstAdapter.suspendNextRead = true
        controller.applyActivePlan()
        while !firstAdapter.firstReadStarted { await Task.yield() }
        plugin.deactivate(reason: .disabled)
        firstAdapter.resumeFirstRead(with: .boolean(false))
        while controller.isApplyingProfile { await Task.yield() }

        XCTAssertEqual(firstAdapter.value, .boolean(false))
        XCTAssertTrue(secondAdapter.appliedValues.isEmpty)
        XCTAssertEqual(controller.lastApplyReport?.results.map(\.kind), [.cancelled, .cancelled])
        XCTAssertTrue(controller.history.isEmpty)
        let disabledWrite = await controller.applyAndWait(.boolean(true), to: second)
        XCTAssertFalse(disabledWrite)
        controller.activate()
        let reactivatedWrite = await controller.applyAndWait(.boolean(true), to: second)
        XCTAssertTrue(reactivatedWrite)
    }

    func testDeactivationCancelsAnInlineWriteSuspendedBeforeMutation() async {
        let adapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let plugin = MacSettingsPlugin(controller: controller)
        let operation = Task { await controller.applyAndWait(.boolean(true), to: record) }
        while !adapter.firstReadStarted { await Task.yield() }
        plugin.deactivate(reason: .disabled)
        adapter.resumeFirstRead(with: .boolean(false))
        let result = await operation.value
        XCTAssertFalse(result)
        XCTAssertEqual(adapter.value, .boolean(false))
        XCTAssertFalse(controller.rowStates[record.id]?.isApplying ?? true)
    }

    func testCancelledProfileRetainsCompletedChangesAndTheirRollbackPoint() async {
        let completed = DeterministicSystemSettingAdapter(value: .boolean(false))
        let pending = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
        let first = makeTestRecord(id: "first", title: "First", adapter: completed)
        let second = makeTestRecord(id: "second", title: "Second", adapter: pending)
        let controller = MacSettingsController(catalog: makeTestCatalog([first, second]), storage: MacSettingsTestStorage())
        let plugin = MacSettingsPlugin(controller: controller)
        controller.preparePlan(for: .init(name: "Partial", entries: [
            .init(settingID: first.id, desiredValue: .boolean(true), category: .finder),
            .init(settingID: second.id, desiredValue: .boolean(true), category: .finder),
        ]))
        while controller.isPreparingPlan { await Task.yield() }
        pending.suspendNextRead = true
        controller.applyActivePlan()
        while !pending.firstReadStarted { await Task.yield() }
        plugin.deactivate(reason: .disabled)
        pending.resumeFirstRead(with: .boolean(false))
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(controller.lastApplyReport?.results.map(\.kind), [.appliedAndVerified, .cancelled])
        XCTAssertEqual(controller.lastApplyReport?.rollbackPoint.entries.map(\.settingID), [first.id])
        XCTAssertEqual(controller.history.map(\.settingID), [first.id])
        XCTAssertEqual(controller.rowStates[first.id]?.value, .boolean(true))
        XCTAssertEqual(pending.value, .boolean(false))
    }

    func testProfileActionBackupRequiresItsPortableProfilePayload() throws {
        let record = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        var draft = controller.makeDraft()
        draft.name = "Portable"
        draft.setDesiredValue(.boolean(true), for: record.id)
        XCTAssertTrue(controller.saveDraft(draft))
        let plugin = MacSettingsPlugin(controller: controller)
        let payload = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let references = try XCTUnwrap(plugin.actionReferences(inPortablePreferences: payload))
        let reference = try XCTUnwrap(references.first)

        XCTAssertEqual(reference.key.actionID, "apply-profile")
        XCTAssertEqual(plugin.backupDisposition(for: reference), .requiresPluginPreferences)
        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(
                key: ActionKey(providerID: "mac-settings", actionID: "undo-most-recent-change")
            )),
            .excluded
        )
    }

    func testProfileActionProvidesRequiredConfirmationCopy() throws {
        let controller = MacSettingsController(
            catalog: makeTestCatalog([]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        let definition = try XCTUnwrap(
            plugin.actionDefinitions.first { $0.key.actionID == "apply-profile" }
        )

        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertNotNil(definition.confirmation)
        XCTAssertTrue(definition.capabilities.contains(.foregroundInteractive))
    }
}
