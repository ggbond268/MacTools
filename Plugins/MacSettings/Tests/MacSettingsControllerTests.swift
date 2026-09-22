import Combine
import XCTest
@testable import MacSettingsPlugin

@MainActor
final class MacSettingsControllerTests: XCTestCase {
    private final class RejectingProfileStore: SystemSettingsProfileStoring {
        func load() -> [SystemSettingsProfile] { [] }
        func save(_ profile: SystemSettingsProfile) -> Bool { false }
        func remove(id: UUID) -> Bool { false }
        func replaceAll(_ profiles: [SystemSettingsProfile]) -> Bool { false }
    }

    func testImportPreviewsWithoutPreparingAnApplyPlan() throws {
        let record = makeTestRecord(
            id: "preview-only",
            title: "Preview Only",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        let controller = MacSettingsController(
            catalog: catalog,
            storage: MacSettingsTestStorage(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let profile = SystemSettingsProfile(
            name: "Imported",
            entries: [SystemSettingsProfileEntry(
                settingID: record.id,
                desiredValue: .boolean(true),
                category: record.definition.category
            )]
        )

        controller.importProfile(data: try SystemSettingsProfileCodec.encode(profile, catalog: catalog))

        XCTAssertEqual(controller.importedPreview?.profile.id, profile.id)
        XCTAssertEqual(controller.importedPreview?.profile.entries, profile.entries)
        XCTAssertNil(controller.activePlan)
        XCTAssertFalse(controller.isPreparingPlan)
        XCTAssertEqual(controller.operationState, .idle)
    }

    func testAcceptImportedProfileReportsSaveFailure() throws {
        let record = makeTestRecord(
            id: "save-failure",
            title: "Save Failure",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        let controller = MacSettingsController(
            catalog: catalog,
            storage: MacSettingsTestStorage(),
            profileStore: RejectingProfileStore()
        )
        let profile = SystemSettingsProfile(
            name: "Imported",
            entries: [SystemSettingsProfileEntry(
                settingID: record.id,
                desiredValue: .boolean(true),
                category: record.definition.category
            )]
        )
        controller.importProfile(data: try SystemSettingsProfileCodec.encode(profile, catalog: catalog))

        XCTAssertFalse(controller.acceptImportedProfile())
        XCTAssertNotNil(controller.profileErrorMessage)
        XCTAssertTrue(controller.profiles.isEmpty)
    }

    func testAcceptImportedProfileConfirmsPersistedProfile() throws {
        let record = makeTestRecord(
            id: "save-success",
            title: "Save Success",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let catalog = makeTestCatalog([record])
        let store = InMemorySystemSettingsProfileStore()
        let controller = MacSettingsController(
            catalog: catalog,
            storage: MacSettingsTestStorage(),
            profileStore: store
        )
        let profile = SystemSettingsProfile(
            name: "Imported",
            entries: [SystemSettingsProfileEntry(
                settingID: record.id,
                desiredValue: .boolean(true),
                category: record.definition.category
            )]
        )
        controller.importProfile(data: try SystemSettingsProfileCodec.encode(profile, catalog: catalog))

        XCTAssertTrue(controller.acceptImportedProfile())
        XCTAssertEqual(controller.profiles.map(\.id), [profile.id])
        XCTAssertEqual(controller.profiles.first?.entries, profile.entries)
        XCTAssertNil(controller.profileErrorMessage)
    }

    func testPortableRestoreRollsBackProfilesAndFavoritesWhenDensityWriteFails() throws {
        let record = makeTestRecord(
            id: "flag", title: "Flag", adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let storage = MacSettingsTestStorage()
        let store = SystemSettingsProfileStore(storage: storage)
        let original = SystemSettingsProfile(
            name: "Original", createdAt: Date(timeIntervalSince1970: 1_000),
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: record.definition.category)]
        )
        XCTAssertTrue(store.save(original))
        let catalog = makeTestCatalog([record])
        let controller = MacSettingsController(catalog: catalog, storage: storage, profileStore: store)
        controller.toggleFavorite(record.id)
        controller.setDensity(.comfortable)
        var replacement = original
        replacement.name = "Replacement"
        storage.failingNextWriteKey = "workspace-density"

        XCTAssertFalse(controller.restorePortablePreferences(
            favorites: [], density: .compact, profiles: [replacement]
        ))

        let reloaded = MacSettingsController(catalog: catalog, storage: storage)
        for state in [controller, reloaded] {
            XCTAssertEqual(state.profiles, [original])
            XCTAssertEqual(state.favoriteIDs, [record.id])
            XCTAssertEqual(state.density, .comfortable)
        }
    }

    func testFinderDestinationUndoAfterReloadRestoresExactCustomPath() async throws {
        let url = URL(filePath: "/private/tmp/Original Projects", directoryHint: .isDirectory)
        let original: [String: SystemSettingStoredPreference] = [
            "NewWindowTarget": .string("PfLo"), "NewWindowTargetPath": .string(url.absoluteString),
        ]
        let store = InMemoryFinderPreferencesStore(domains: ["com.apple.finder": original])
        let adapter = FinderWindowDestinationSystemSettingAdapter(store: store, validateDirectory: { _ in })
        let record = makeTestRecord(
            id: "finder.new-window-target", title: "Destination",
            schema: .directoryChoice(options: FinderWindowDestination.options),
            defaultValue: .choice(id: "PfAF"), adapter: adapter
        )
        let storage = MacSettingsTestStorage()
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: storage)
        await controller.refresh(record)
        XCTAssertNil(controller.rowStates[record.id]?.errorMessage)
        XCTAssertEqual(controller.rowStates[record.id]?.value, .url(url))
        XCTAssertEqual(controller.makeDraft().items.first?.desiredValue, .choice(id: "PfAF"))
        let applied = await controller.applyAndWait(.choice(id: "PfDe"), to: record)
        XCTAssertTrue(applied)
        let reloaded = MacSettingsController(catalog: makeTestCatalog([record]), storage: storage)
        XCTAssertEqual(reloaded.history.first?.previousSnapshot?.restoration, original)
        let undone = await reloaded.undoMostRecentChange()
        XCTAssertTrue(undone)
        XCTAssertEqual(store.domains["com.apple.finder"], original)
        XCTAssertEqual(reloaded.rowStates[record.id]?.value, .url(url))
    }

    func testFinderPartialWriteAndVerificationFailureRestoreCompleteOriginalState() async throws {
        for failsWrite in [true, false] {
            let original: [String: SystemSettingStoredPreference] = [
                "NewWindowTarget": .string("PfLo"), "NewWindowTargetPath": .string("file:///tmp/original%20path/"),
            ]
            let store = InMemoryFinderPreferencesStore(domains: ["com.apple.finder": original])
            store.failNextWriteAfterFirstKey = failsWrite
            store.ignoreNextPathWrite = !failsWrite
            let record = makeTestRecord(
                id: "finder.new-window-target", title: "Destination",
                schema: .directoryChoice(options: FinderWindowDestination.options),
                defaultValue: .choice(id: "PfAF"),
                adapter: FinderWindowDestinationSystemSettingAdapter(store: store, validateDirectory: { _ in })
            )
            let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
            let applied = await controller.applyAndWait(.choice(id: "PfDe"), to: record)
            XCTAssertFalse(applied)
            XCTAssertEqual(store.domains["com.apple.finder"], original)
            XCTAssertTrue(controller.history.isEmpty)
        }
    }

    func testCancellingCallerStopsInlineWriteBeforeMutation() async {
        let adapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let operation = Task { await controller.applyAndWait(.boolean(true), to: record) }
        while !adapter.firstReadStarted { await Task.yield() }
        operation.cancel()
        adapter.resumeFirstRead(with: .boolean(false))
        let result = await operation.value
        XCTAssertFalse(result)
        XCTAssertEqual(adapter.value, .boolean(false))
        XCTAssertTrue(controller.history.isEmpty)
    }

    func testRollbackFailureRemainsVisibleAndRetryOnlyRestoresUnresolvedSettings() async throws {
        let successful = RollbackFailingSystemSettingAdapter()
        successful.failsRollback = false
        let failing = RollbackFailingSystemSettingAdapter()
        let first = makeTestRecord(id: "first", title: "First", adapter: successful)
        let second = makeTestRecord(id: "second", title: "Second", adapter: failing)
        let controller = MacSettingsController(catalog: makeTestCatalog([first, second]), storage: MacSettingsTestStorage())
        controller.preparePlan(for: .init(name: "Rollback", entries: [
            .init(settingID: first.id, desiredValue: .boolean(true), category: .finder),
            .init(settingID: second.id, desiredValue: .boolean(true), category: .finder),
        ]))
        while controller.isPreparingPlan { await Task.yield() }
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        controller.rollbackLastApply()
        while controller.isApplyingProfile { await Task.yield() }

        XCTAssertEqual(controller.lastRollbackResults?.map(\.kind), [.appliedAndVerified, .failedWithoutRollback])
        XCTAssertEqual(failing.value, .boolean(true))
        await controller.refresh(second)
        XCTAssertEqual(controller.rowStates[second.id]?.errorMessage, "Injected rollback failure")
        XCTAssertTrue(controller.needsAttention(second.id))

        failing.failsRollback = false
        controller.rollbackLastApply()
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(successful.rollbackAttempts, 1)
        XCTAssertEqual(failing.rollbackAttempts, 2)
        XCTAssertEqual(failing.value, .boolean(false))
        XCTAssertEqual(controller.lastRollbackResults?.map(\.kind), [.appliedAndVerified, .appliedAndVerified])
        XCTAssertNil(controller.rowStates[second.id]?.errorMessage)
        XCTAssertFalse(controller.needsAttention(second.id))
        XCTAssertEqual(controller.history.count, 4)
    }

    func testVerifiedApplyUpdatesOnlyOneRowAndRecordsBoundedHistory() async {
        let firstAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let secondAdapter = DeterministicSystemSettingAdapter(value: .boolean(true))
        let first = makeTestRecord(id: "first", title: "First", adapter: firstAdapter)
        let second = makeTestRecord(id: "second", title: "Second", adapter: secondAdapter)
        let historyStore = InMemorySystemSettingChangeHistoryStore()
        let controller = MacSettingsController(
            catalog: makeTestCatalog([first, second]),
            storage: MacSettingsTestStorage(),
            historyStore: historyStore,
            profileStore: InMemorySystemSettingsProfileStore()
        )

        await controller.refresh(first)
        await controller.refresh(second)
        let applied = await controller.applyAndWait(.boolean(true), to: first)
        XCTAssertTrue(applied)

        XCTAssertEqual(controller.rowStates[first.id]?.value, .boolean(true))
        XCTAssertEqual(controller.rowStates[first.id]?.verification, .verified)
        XCTAssertEqual(controller.rowStates[second.id]?.value, .boolean(true))
        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history.first?.previousValue, .boolean(false))
        XCTAssertEqual(controller.history.first?.newValue, .boolean(true))
    }

    func testVerificationMismatchIsVisibleAndNotRecordedAsSuccess() async {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        adapter.queuedVerificationOverrides = [.mismatch(actual: .boolean(false))]
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        let applied = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertFalse(applied)
        XCTAssertEqual(controller.rowStates[record.id]?.verification, .failed)
        XCTAssertEqual(controller.rowStates[record.id]?.value, .boolean(false))
        XCTAssertEqual(adapter.rollbackValues, [.boolean(false)])
        XCTAssertNotNil(controller.rowStates[record.id]?.errorMessage)
        XCTAssertTrue(controller.needsAttention(record.id))
        XCTAssertTrue(controller.history.isEmpty)
    }

    func testSlowRefreshCannotOverwriteACompletedApply() async {
        let adapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "race", title: "Race", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        controller.refresh()
        while !adapter.firstReadStarted { await Task.yield() }
        let applied = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertTrue(applied)
        adapter.resumeFirstRead(with: .boolean(false))
        while controller.isRefreshing { await Task.yield() }

        XCTAssertEqual(controller.rowStates[record.id]?.value, .boolean(true))
        XCTAssertEqual(adapter.value, .boolean(true))
    }

}
