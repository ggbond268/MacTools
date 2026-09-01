import XCTest
import MacToolsPluginKit
@testable import MacSettingsPlugin

@MainActor
final class MacSettingsReviewRegressionTests: XCTestCase {
    func testTrackpadSnapshotRestoresDifferentDevicesAndMissingKeysAfterReload() async throws {
        for originalBuiltIn: SystemSettingStoredPreference in [.missing, .boolean(false), .integer(0)] {
            let store = InMemoryFinderPreferencesStore(domains: [
                "built-in": originalBuiltIn == .missing ? [:] : ["Clicking": originalBuiltIn],
                "bluetooth": ["Clicking": .integer(1)],
            ])
            let originalDomains = store.domains
            var live = false
            let composite = CompositeBooleanSystemSettingAdapter(adapters: [
                TrackpadBooleanPreferencesSettingAdapter(domain: "built-in", key: "Clicking", store: store),
                TrackpadBooleanPreferencesSettingAdapter(domain: "bluetooth", key: "Clicking", store: store),
            ])
            let adapter = LiveTrackpadBooleanSystemSettingAdapter(
                persistedAdapter: composite, readLiveValue: { live }, writeLiveValue: { live = $0 }
            )
            let record = makeTestRecord(id: "input.tap-to-click", title: "Tap", adapter: adapter)
            let storage = MacSettingsTestStorage()
            let catalog = makeTestCatalog([record])
            let controller = MacSettingsController(catalog: catalog, storage: storage)
            let applied = await controller.applyAndWait(.boolean(true), to: record)
            XCTAssertTrue(applied)
            XCTAssertTrue(live)
            let reloaded = MacSettingsController(catalog: catalog, storage: storage)
            let undone = await reloaded.undoMostRecentChange()
            XCTAssertTrue(undone)
            XCTAssertFalse(live)
            XCTAssertEqual(store.domains, originalDomains)
        }
    }

    func testTrackpadPartialWriteFailureRestoresEveryDomain() async throws {
        let store = InMemoryFinderPreferencesStore(domains: [
            "built-in": ["drag": .boolean(false)], "bluetooth": ["drag": .boolean(true)],
        ])
        let original = store.domains
        let composite = CompositeBooleanSystemSettingAdapter(adapters: [
            TrackpadBooleanPreferencesSettingAdapter(domain: "built-in", key: "drag", store: store),
            TrackpadBooleanPreferencesSettingAdapter(domain: "bluetooth", key: "drag", store: store),
        ])
        let snapshot = try await composite.snapshot()
        store.failNextWriteAfterFirstKey = true
        try await composite.apply(.boolean(true))
        let restored = try await composite.restore(snapshot)
        XCTAssertEqual(restored, .verified(.boolean(false)))
        XCTAssertEqual(store.domains, original)
        do {
            _ = try await composite.restore(.init(value: .boolean(false)))
            XCTFail("A legacy single-value snapshot must not overwrite independent devices")
        } catch { }
        XCTAssertEqual(store.domains, original)
    }

    func testChangingOnlySecondaryTrackpadStillCreatesUndoHistory() async throws {
        let first = DeterministicSystemSettingAdapter(value: .boolean(false))
        let second = DeterministicSystemSettingAdapter(value: .boolean(true))
        let adapter = CompositeBooleanSystemSettingAdapter(adapters: [first, second])
        let record = makeTestRecord(id: "trackpad", title: "Trackpad", adapter: adapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let applied = await controller.applyAndWait(.boolean(false), to: record)
        XCTAssertTrue(applied)
        XCTAssertEqual(controller.history.count, 1)
        let undone = await controller.undoMostRecentChange()
        XCTAssertTrue(undone)
        XCTAssertEqual(first.value, .boolean(false))
        XCTAssertEqual(second.value, .boolean(true))
    }

    func testFailedLiveTrackpadWriteAutomaticallyRestoresOriginalDevicePreferences() async {
        let store = InMemoryFinderPreferencesStore(domains: [
            "built-in": [:], "bluetooth": ["drag": .integer(1)],
        ])
        let original = store.domains
        var live = false
        let adapter = LiveTrackpadBooleanSystemSettingAdapter(
            persistedAdapter: CompositeBooleanSystemSettingAdapter(adapters: [
                TrackpadBooleanPreferencesSettingAdapter(domain: "built-in", key: "drag", store: store),
                TrackpadBooleanPreferencesSettingAdapter(domain: "bluetooth", key: "drag", store: store),
            ]),
            readLiveValue: { live },
            writeLiveValue: { enabled in
                live = enabled
                try store.write(["drag": .boolean(enabled)], domain: "built-in")
                if enabled { throw SystemSettingAdapterError.writeFailed("Partial runtime failure") }
            }
        )
        let record = makeTestRecord(id: "trackpad", title: "Trackpad", adapter: adapter)
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        let applied = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertFalse(applied)
        XCTAssertFalse(live)
        XCTAssertEqual(store.domains, original)
        XCTAssertTrue(controller.history.isEmpty)
    }

    func testPortableRestoreCapacityFailureDoesNotOverwriteEarlierProfilesOrFavorites() throws {
        let record = booleanRecord()
        let storage = MacSettingsTestStorage()
        let store = SystemSettingsProfileStore(storage: storage)
        let original = profile(record, name: "Original")
        XCTAssertTrue(store.save(original))
        for index in 1..<100 { XCTAssertTrue(store.save(profile(record, name: "Local \(index)"))) }
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: storage, profileStore: store)
        controller.toggleFavorite(record.id)
        let before = try XCTUnwrap(MacSettingsPlugin(controller: controller).makePortablePreferencesBackup())
        let storedProfilesBefore = storage.data(forKey: "settings-profiles-v1")
        var replacement = original
        replacement.name = "Replaced"
        let restored = controller.restorePortablePreferences(
            favorites: [], density: .compact, profiles: [replacement, profile(record, name: "New")]
        )
        XCTAssertFalse(restored)
        let after = try XCTUnwrap(MacSettingsPlugin(controller: controller).makePortablePreferencesBackup())
        // JSON object ordering is not stable across independent encoders.
        XCTAssertEqual(try JSONSerialization.jsonObject(with: after) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: before) as? NSDictionary)
        XCTAssertEqual(storage.data(forKey: "settings-profiles-v1"), storedProfilesBefore)
        XCTAssertEqual(store.load().first { $0.id == original.id }, original)
    }

    func testPortableRestoreRollsBackProfileAndMetadataWriteFailures() throws {
        for failedKey in ["settings-profiles-v1", "favorite-setting-ids", "workspace-density"] {
            let record = booleanRecord()
            let storage = MacSettingsTestStorage()
            let store = SystemSettingsProfileStore(storage: storage)
            let original = profile(record, name: "Original")
            XCTAssertTrue(store.save(original))
            let catalog = makeTestCatalog([record])
            let controller = MacSettingsController(catalog: catalog, storage: storage, profileStore: store)
            controller.toggleFavorite(record.id)
            controller.setDensity(.comfortable)
            storage.failingNextWriteKey = failedKey
            var replacement = original
            replacement.name = "Replaced"
            XCTAssertFalse(controller.restorePortablePreferences(favorites: [], density: .compact, profiles: [replacement]))
            let reloaded = MacSettingsController(catalog: catalog, storage: storage)
            XCTAssertEqual(reloaded.favoriteIDs, [record.id], failedKey)
            XCTAssertEqual(reloaded.density, .comfortable, failedKey)
            XCTAssertEqual(reloaded.profiles, [original], failedKey)
            XCTAssertEqual(controller.profiles, [original], failedKey)
        }
    }

    func testSuccessfulPortableRestorePreservesIncomingFavoriteOrder() {
        let first = booleanRecord()
        let second = makeTestRecord(id: "second", title: "Second", adapter: DeterministicSystemSettingAdapter(value: .boolean(false)))
        let controller = MacSettingsController(catalog: makeTestCatalog([first, second]), storage: MacSettingsTestStorage())
        controller.toggleFavorite(first.id)
        controller.toggleFavorite(second.id)
        XCTAssertTrue(controller.restorePortablePreferences(favorites: [second.id, first.id], density: .compact, profiles: []))
        XCTAssertEqual(controller.favoriteIDs, [second.id, first.id])
    }

    func testUndoSkipsDeferredHistoryAndAvailabilityUsesSameCandidate() async throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(true))
        let record = makeTestRecord(id: "supported", title: "Supported", adapter: adapter)
        let now = Date()
        let entries = [(SystemSettingID(rawValue: "keyboard.function-keys"), now), (record.id, now.addingTimeInterval(-1))].map { id, date in
            SystemSettingChange(settingID: id, settingTitle: id.rawValue, previousValue: .boolean(false), newValue: .boolean(true), date: date, verification: .verified, canRollback: true)
        }
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage(), historyStore: InMemorySystemSettingChangeHistoryStore(changes: entries))
        let plugin = MacSettingsPlugin(controller: controller)
        let undo = ActionReference(key: .init(providerID: "mac-settings", actionID: "undo-most-recent-change"))
        XCTAssertTrue(plugin.actionAvailability(for: undo).isAvailable)
        let result = await controller.undoMostRecentChange()
        XCTAssertTrue(result)
        XCTAssertEqual(adapter.value, .boolean(false))
        let onlyDeferred = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage(), historyStore: InMemorySystemSettingChangeHistoryStore(changes: [entries[0]]))
        XCTAssertFalse(MacSettingsPlugin(controller: onlyDeferred).actionAvailability(for: undo).isAvailable)
    }

    func testPreparingProfileDisablesAndRejectsInlineCommits() async {
        let delayed = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "delayed", title: "Delayed", adapter: delayed)
        let other = booleanRecord()
        let controller = MacSettingsController(catalog: makeTestCatalog([record, other]), storage: MacSettingsTestStorage())
        controller.preparePlan(for: profile(record, name: "Plan"))
        XCTAssertTrue(controller.isPreparingPlan)
        controller.showPalette()
        XCTAssertFalse(controller.canEditSettings)
        XCTAssertFalse(controller.apply(.boolean(true), to: other.id))
        for _ in 0..<100 where !delayed.firstReadStarted { await Task.yield() }
        delayed.resumeFirstRead(with: .boolean(false))
        for _ in 0..<100 where controller.isPreparingPlan { await Task.yield() }
        XCTAssertTrue(controller.canEditSettings)
        controller.deactivate()
    }

    func testUnavailableProviderRoutesToPluginAndRetainsReasonChanges() {
        let record = makeTestRecord(id: "provider-setting", title: "Provider", requirements: .init(existingProviderID: "appearance"), adapter: DeterministicSystemSettingAdapter(value: .boolean(false)))
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: MacSettingsTestStorage())
        var destinations: [String] = []
        controller.onOpenProviderSettings = { destinations.append($0) }
        controller.onOpenSystemSettings = { _ in XCTFail("Must not open Apple System Settings") }
        controller.updateProviderAvailability(["appearance": .unavailable("Permission missing")])
        XCTAssertEqual(controller.rowStates[record.id]?.availability, .providerUnavailable("Permission missing"))
        controller.openProviderSettings(for: record.id)
        XCTAssertEqual(destinations, ["appearance"])
        controller.updateProviderAvailability(["appearance": .unavailable("Hardware unavailable")])
        XCTAssertEqual(controller.rowStates[record.id]?.availability, .providerUnavailable("Hardware unavailable"))
        controller.deactivate()
    }

    func testApplyingProfileDisablesAndRejectsInlineCommits() async {
        let delayed = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
        let record = makeTestRecord(id: "delayed", title: "Delayed", adapter: delayed)
        let other = booleanRecord()
        let controller = MacSettingsController(catalog: makeTestCatalog([record, other]), storage: MacSettingsTestStorage())
        controller.preparePlan(for: profile(record, name: "Plan"))
        while controller.isPreparingPlan { await Task.yield() }
        delayed.suspendNextRead = true
        controller.applyActivePlan()
        while !delayed.firstReadStarted { await Task.yield() }
        controller.showPalette()
        XCTAssertTrue(controller.isApplyingProfile)
        XCTAssertFalse(controller.canEditSettings)
        XCTAssertFalse(controller.apply(.boolean(true), to: other.id))
        delayed.resumeFirstRead(with: .boolean(false))
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertTrue(controller.canEditSettings)
        let otherValue = try? await other.adapter.read()
        XCTAssertEqual(otherValue, .boolean(false))
        controller.deactivate()
    }

    func testProfileEditorDistinguishesValidationAndPersistenceFailures() {
        let record = booleanRecord()
        let storage = MacSettingsTestStorage()
        let controller = MacSettingsController(catalog: makeTestCatalog([record]), storage: storage)
        var draft = controller.makeDraft()
        draft.items[0].isIncluded = true
        draft.name = String(repeating: "a", count: 121)
        XCTAssertNotNil(controller.draftValidationMessage(draft))
        XCTAssertFalse(controller.saveDraft(draft))
        let validationError = controller.profileErrorMessage
        draft.name = "Valid"
        XCTAssertNil(controller.draftValidationMessage(draft))
        storage.failingNextWriteKey = "settings-profiles-v1"
        XCTAssertFalse(controller.saveDraft(draft))
        XCTAssertNotNil(controller.profileErrorMessage)
        XCTAssertNotEqual(controller.profileErrorMessage, validationError)
        XCTAssertTrue(controller.saveDraft(draft))
        XCTAssertNil(controller.profileErrorMessage)
    }

    private func booleanRecord() -> SystemSettingRecord {
        makeTestRecord(id: "test.flag", title: "Flag", adapter: DeterministicSystemSettingAdapter(value: .boolean(false)))
    }

    private func profile(_ record: SystemSettingRecord, name: String) -> SystemSettingsProfile {
        SystemSettingsProfile(
            name: name, createdAt: Date(timeIntervalSince1970: 1_000),
            modifiedAt: Date(timeIntervalSince1970: 1_000),
            entries: [.init(settingID: record.id, desiredValue: .boolean(true), category: record.definition.category)]
        )
    }
}
