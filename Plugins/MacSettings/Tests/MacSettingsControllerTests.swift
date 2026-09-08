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

    func testFinderExtensionsUndoRestoresAbsenceEvenWhenBooleanDidNotChange() async throws {
        let store = InMemoryFinderPreferencesStore()
        let record = makeTestRecord(
            id: "finder.show-all-extensions", title: "Extensions",
            adapter: FinderExtensionsSystemSettingAdapter(store: store)
        )
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let applied = await controller.applyAndWait(.boolean(false), to: record)
        XCTAssertTrue(applied)
        XCTAssertEqual(controller.history.count, 1, "An explicit false is different from an absent key")
        let undone = await controller.undoMostRecentChange()
        XCTAssertTrue(undone)
        XCTAssertNil(store.domains[UserDefaults.globalDomain]?["AppleShowAllExtensions"])
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

    func testDeactivationCancelsRollbackBeforeAnyFurtherRestoration() async {
        let firstAdapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let secondAdapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
        let first = makeTestRecord(id: "first", title: "First", adapter: firstAdapter)
        let second = makeTestRecord(id: "second", title: "Second", adapter: secondAdapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([first, second]), storage: MacSettingsTestStorage())
        controller.preparePlan(for: .init(name: "Rollback", entries: [
            .init(settingID: first.id, desiredValue: .boolean(true), category: .finder),
            .init(settingID: second.id, desiredValue: .boolean(true), category: .finder),
        ]))
        while controller.isPreparingPlan { await Task.yield() }
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        secondAdapter.suspendNextRead = true
        controller.rollbackLastApply()
        while !secondAdapter.firstReadStarted { await Task.yield() }
        controller.deactivate()
        secondAdapter.resumeFirstRead(with: .boolean(true))
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(controller.lastRollbackResults?.map(\.kind), [.cancelled, .cancelled])
        XCTAssertTrue(firstAdapter.rollbackValues.isEmpty)
        XCTAssertEqual(secondAdapter.value, .boolean(true))
    }

    func testProfilePreviewReadsLiveValuesInsteadOfInitialDefaults() async throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(true))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let profile = SystemSettingsProfile(name: "Fresh", entries: [
            .init(settingID: record.id, desiredValue: .boolean(false), category: .finder),
        ])

        controller.preparePlan(for: profile)
        XCTAssertTrue(controller.isPreparingPlan)
        XCTAssertNil(controller.activePlan)
        while controller.isPreparingPlan { await Task.yield() }

        let item = try XCTUnwrap(controller.activePlan?.items.first)
        XCTAssertEqual(item.currentValue, .boolean(true))
        XCTAssertEqual(item.status, .ready)
        XCTAssertTrue(item.isSelected)
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(adapter.value, .boolean(false))
        XCTAssertEqual(controller.lastApplyReport?.results.first?.kind, .appliedAndVerified)
    }

    func testDismissingProfileComparisonReturnsToTheProfileLibrary() async {
        let record = makeTestRecord(
            id: "toggle",
            title: "Toggle",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage()
        )
        controller.preparePlan(for: SystemSettingsProfile(name: "Work", entries: [
            .init(settingID: record.id, desiredValue: .boolean(true), category: .finder),
        ]))
        while controller.isPreparingPlan { await Task.yield() }

        XCTAssertNotNil(controller.activePlan)
        controller.dismissActivePlan()
        XCTAssertNil(controller.activePlan)
        XCTAssertNil(controller.lastApplyReport)
        XCTAssertNil(controller.lastRollbackResults)
    }

    func testNewPreviewSupersedesAnOlderSuspendedRead() async {
        let adapter = FirstReadSuspendingSystemSettingAdapter(value: .boolean(true))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let first = SystemSettingsProfile(name: "Old", entries: [
            .init(settingID: record.id, desiredValue: .boolean(false), category: .finder),
        ])
        let second = SystemSettingsProfile(name: "New", entries: [
            .init(settingID: record.id, desiredValue: .boolean(true), category: .finder),
        ])
        controller.preparePlan(for: first)
        while !adapter.firstReadStarted { await Task.yield() }
        controller.preparePlan(for: second)
        while controller.isPreparingPlan { await Task.yield() }
        adapter.resumeFirstRead(with: .boolean(false))
        await Task.yield()
        XCTAssertEqual(controller.activePlan?.profileID, second.id)
        XCTAssertEqual(controller.activePlan?.items.first?.status, .alreadyMatches)
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

    func testKeyboardNavigationMovesBetweenSearchAndVisibleRows() {
        let ids: [SystemSettingID] = ["first", "second", "third"]

        XCTAssertEqual(
            MacSettingsKeyboardNavigation.target(
                from: nil,
                movingForward: true,
                settingIDs: ids
            ),
            .setting("first")
        )
        XCTAssertEqual(
            MacSettingsKeyboardNavigation.target(
                from: "second",
                movingForward: true,
                settingIDs: ids
            ),
            .setting("third")
        )
        XCTAssertEqual(
            MacSettingsKeyboardNavigation.target(
                from: "second",
                movingForward: false,
                settingIDs: ids
            ),
            .setting("first")
        )
        XCTAssertEqual(
            MacSettingsKeyboardNavigation.target(
                from: "first",
                movingForward: false,
                settingIDs: ids
            ),
            .search
        )
        XCTAssertEqual(
            MacSettingsKeyboardNavigation.target(
                from: "third",
                movingForward: true,
                settingIDs: ids
            ),
            .setting("third")
        )
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

    func testVerificationUnavailableIsRecordedAsUnverified() async {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        adapter.verificationOverride = .unavailable
        let record = makeTestRecord(id: "unverified", title: "Unverified", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        let applied = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertTrue(applied)
        XCTAssertEqual(controller.rowStates[record.id]?.verification, .unverified)
        XCTAssertEqual(controller.history.first?.verification, .unverified)
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

    func testChoiceDisplayDescriptionUsesLocalizedOptionTitle() {
        let record = makeTestRecord(
            id: "choice",
            title: "Choice",
            schema: .choice(options: [
                .init(id: "internal-left", title: "左侧"),
                .init(id: "internal-right", title: "右侧"),
            ]),
            defaultValue: .choice(id: "internal-left"),
            adapter: DeterministicSystemSettingAdapter(value: .choice(id: "internal-left"))
        )

        XCTAssertEqual(
            record.definition.displayDescription(for: .choice(id: "internal-right")),
            "右侧"
        )
    }

    func testFavoritesPreserveOrderingAndRemainControllable() async {
        let first = makeTestRecord(
            id: "first",
            title: "First",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let second = makeTestRecord(
            id: "second",
            title: "Second",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([first, second]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        controller.toggleFavorite(second.id)
        controller.toggleFavorite(first.id)
        controller.destination = .favorites
        XCTAssertEqual(controller.visibleRecords.map(\.id), [second.id, first.id])

        controller.moveFavorites(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(controller.visibleRecords.map(\.id), [first.id, second.id])
        controller.moveFavorite(second.id, by: -1)
        XCTAssertEqual(controller.visibleRecords.map(\.id), [second.id, first.id])
        let applied = await controller.applyAndWait(.boolean(true), to: first)
        XCTAssertTrue(applied)
    }

    func testTogglingFavoritePublishesAReplacementCollection() {
        let record = makeTestRecord(
            id: "favorite-publication",
            title: "Favorite Publication",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        var publishedValues: [[SystemSettingID]] = []
        let cancellable = controller.$favoriteIDs
            .dropFirst()
            .sink { publishedValues.append($0) }

        controller.toggleFavorite(record.id)
        controller.toggleFavorite(record.id)

        XCTAssertEqual(publishedValues, [[record.id], []])
        withExtendedLifetime(cancellable) {}
    }

    func testNeedsAttentionContainsOnlyActionableStates() {
        let direct = makeTestRecord(
            id: "direct",
            title: "Direct",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let guided = makeTestRecord(
            id: "guided",
            title: "Guided",
            executionClass: .guidedManual,
            adapter: UnavailableSystemSettingAdapter(message: "Manual")
        )
        let provider = makeTestRecord(
            id: "provider",
            title: "Provider",
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: "missing"),
            adapter: UnavailableSystemSettingAdapter(message: "Missing")
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([direct, guided, provider]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        XCTAssertFalse(controller.needsAttention(direct.id))
        XCTAssertFalse(controller.needsAttention(guided.id))
        XCTAssertTrue(controller.needsAttention(provider.id))
        controller.destination = .attention
        XCTAssertEqual(controller.visibleRecords.map(\.id), [provider.id])
    }

    func testPaletteHomeShowsEverySettingGroupedByCategory() {
        let accessibility = makeTestRecord(
            id: "accessibility",
            title: "Accessibility",
            category: .accessibility,
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let finder = makeTestRecord(
            id: "finder",
            title: "Finder",
            category: .finder,
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let unavailable = makeTestRecord(
            id: "unavailable",
            title: "Unavailable",
            category: .finder,
            executionClass: .existingPluginProvider,
            requirements: .init(existingProviderID: "missing"),
            adapter: UnavailableSystemSettingAdapter(message: "Missing")
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([accessibility, finder, unavailable]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        controller.toggleFavorite(finder.id)

        XCTAssertEqual(
            controller.paletteSections.map(\.id),
            ["favorites", "category.accessibility", "category.finder"]
        )
        XCTAssertEqual(controller.paletteSections[0].records.map(\.id), [finder.id])
        XCTAssertEqual(controller.paletteSections[1].records.map(\.id), [accessibility.id])
        XCTAssertEqual(controller.paletteSections[2].records.map(\.id), [unavailable.id])

        controller.searchText = "Unavailable"
        controller.showFavorites()
        XCTAssertEqual(controller.searchText, "")
        XCTAssertEqual(controller.paletteSections.flatMap(\.records).map(\.id), [finder.id])

        controller.destination = .all
        controller.toggleFavorite(finder.id)
        XCTAssertEqual(controller.paletteSections.map(\.id), ["category.accessibility", "category.finder"])
        XCTAssertEqual(controller.paletteSections.flatMap(\.records).map(\.id), [accessibility.id, finder.id, unavailable.id])
    }

    func testPaletteSearchAlwaysSearchesTheFullCatalog() {
        let first = makeTestRecord(
            id: "first",
            title: "First",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let second = makeTestRecord(
            id: "second",
            title: "Second",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([first, second]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        controller.toggleFavorite(first.id)
        controller.destination = .favorites
        controller.searchText = "Second"

        XCTAssertEqual(controller.paletteSections.map(\.kind), [.searchResults])
        XCTAssertEqual(controller.paletteSections[0].records.map(\.id), [second.id])
    }

    func testReturningFromSecondaryToolsPreservesSearchUntilHomeIsRequested() {
        let record = makeTestRecord(
            id: "setting",
            title: "Setting",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )

        controller.searchText = "Setting"
        controller.destination = .profiles
        controller.showPalette()
        XCTAssertEqual(controller.destination, .all)
        XCTAssertEqual(controller.searchText, "Setting")

        controller.showPaletteHome()
        XCTAssertEqual(controller.destination, .all)
        XCTAssertTrue(controller.searchText.isEmpty)
    }

    func testHistoryStoreBoundsCountAndAge() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let recent = (0 ..< 250).map { offset in
            SystemSettingChange(
                settingID: SystemSettingID(rawValue: "setting.\(offset)"),
                settingTitle: "Setting",
                previousValue: .boolean(false),
                newValue: .boolean(true),
                date: now.addingTimeInterval(-Double(offset)),
                verification: .verified,
                canRollback: true
            )
        }
        let old = SystemSettingChange(
            settingID: "old",
            settingTitle: "Old",
            previousValue: .boolean(false),
            newValue: .boolean(true),
            date: now.addingTimeInterval(-(SystemSettingChangeHistoryStore.maximumAge + 1)),
            verification: .verified,
            canRollback: true
        )

        let bounded = SystemSettingChangeHistoryStore.bounded(recent + [old], referenceDate: now)
        XCTAssertEqual(bounded.count, SystemSettingChangeHistoryStore.maximumCount)
        XCTAssertFalse(bounded.contains { $0.id == old.id })
    }
}
