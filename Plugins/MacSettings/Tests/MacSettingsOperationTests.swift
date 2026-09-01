import XCTest
import MacToolsPluginKit
@testable import MacSettingsPlugin

@MainActor
final class MacSettingsOperationTests: XCTestCase {
    func testDevelopmentHistoryStartsFreshWithoutTouchingLegacyData() throws {
        let storage = MacSettingsTestStorage()
        let old = SystemSettingChange(settingID: "input.tap-to-click", settingTitle: "Tap",
            previousValue: .boolean(false), newValue: .boolean(true), verification: .verified, canRollback: true)
        let legacy = try JSONEncoder().encode([old])
        storage.set(legacy, forKey: "change-history")
        storage.set(["input.tap-to-click"], forKey: "favorite-setting-ids")
        let store = SystemSettingChangeHistoryStore(storage: storage)
        XCTAssertTrue(store.load().isEmpty)
        _ = store.append(old)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(storage.data(forKey: "change-history"), legacy)
        XCTAssertEqual(storage.stringArray(forKey: "favorite-setting-ids"), ["input.tap-to-click"])
        XCTAssertNotNil(storage.data(forKey: "change-history-v2"))
    }

    func testTrackpadRecoverySkipsUnchangedReadOnlyDomain() async throws {
        let store = OperationPreferenceStore()
        let original = store.values
        store.blocked = ["built-in"]
        let adapter = composite(store)
        let record = makeTestRecord(id: "trackpad", title: "Trackpad", adapter: adapter)
        let controller = makeController([record])
        let result = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertFalse(result)
        XCTAssertEqual(store.values, original)
        XCTAssertTrue(controller.pendingRecoveries.isEmpty)
    }

    func testTrackpadRecoveryContinuesAfterFirstChangedDomainFails() async throws {
        let store = OperationPreferenceStore()
        let adapter = composite(store)
        let snapshot = try await adapter.snapshot()
        try await adapter.apply(.boolean(true))
        store.blocked = ["built-in"]
        do { _ = try await adapter.restore(snapshot); XCTFail("One device remains changed") }
        catch { }
        XCTAssertEqual(store.values["built-in"], .boolean(true))
        XCTAssertEqual(store.values["bluetooth"], .integer(0))
    }

    func testLiveSetterFailureStillRestoresPersistedDomains() async throws {
        let store = OperationPreferenceStore()
        var live = false
        var blockLiveRestore = false
        let adapter = LiveTrackpadBooleanSystemSettingAdapter(persistedAdapter: composite(store),
            readLiveValue: { live }, writeLiveValue: { value in
                if blockLiveRestore { throw SystemSettingAdapterError.writeFailed("Blocked live restore") }
                live = value
            })
        let original = try await adapter.snapshot()
        let originalValues = store.values
        try await adapter.apply(.boolean(true))
        blockLiveRestore = true
        do { _ = try await adapter.restore(original); XCTFail("Live state remains changed") }
        catch { }
        XCTAssertTrue(live)
        XCTAssertEqual(store.values, originalValues)
    }

    func testInlinePhasesPublishAndRecoverySurvivesReloadAndRetry() async throws {
        let adapter = OperationTestAdapter()
        adapter.failVerification = true
        adapter.failRestore = true
        let record = makeTestRecord(id: "flag", title: "Flag", adapter: adapter)
        let storage = MacSettingsTestStorage()
        let controller = makeController([record], storage: storage)
        var phases: [SystemSettingOperationPhase] = []
        controller.onStateChange = {
            if let phase = controller.rowStates[record.id]?.operationPhase { phases.append(phase) }
        }
        let result = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertFalse(result)
        XCTAssertTrue([.reading, .applying, .verifying, .restoring].allSatisfy(phases.contains))
        XCTAssertNil(controller.rowStates[record.id]?.operationPhase)
        XCTAssertFalse(controller.canEditSettings)
        let recovery = try XCTUnwrap(controller.pendingRecoveries[record.id])
        XCTAssertEqual(recovery.original.value, .boolean(false))
        XCTAssertEqual(recovery.current?.value, .boolean(true))
        XCTAssertFalse(recovery.differences.isEmpty)
        let reloaded = makeController([record], storage: storage)
        XCTAssertNil(reloaded.pendingRecoveries[record.id]?.current)
        await reloaded.refresh(record)
        XCTAssertEqual(reloaded.pendingRecoveries[record.id], recovery)
        XCTAssertFalse(reloaded.canEditSettings)
        adapter.failRestore = false
        reloaded.retryRecovery(record.id)
        while reloaded.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(adapter.value, .boolean(false))
        XCTAssertTrue(reloaded.pendingRecoveries.isEmpty)
        XCTAssertTrue(reloaded.canEditSettings)
        XCTAssertTrue(makeController([record], storage: storage).pendingRecoveries.isEmpty)
    }

    func testKeepingCurrentValuesDoesNotWriteTheSetting() async {
        let adapter = OperationTestAdapter()
        adapter.failVerification = true
        adapter.failRestore = true
        let record = makeTestRecord(id: "flag", title: "Flag", adapter: adapter)
        let controller = makeController([record])
        _ = await controller.applyAndWait(.boolean(true), to: record)
        let writes = adapter.writes
        controller.keepCurrentValues(record.id)
        XCTAssertEqual(adapter.writes, writes)
        XCTAssertEqual(adapter.value, .boolean(true))
        XCTAssertTrue(controller.pendingRecoveries.isEmpty)
        XCTAssertTrue(controller.canEditSettings)
        XCTAssertNil(controller.failedDesiredValues[record.id])
        controller.deactivate()
    }

    func testRecoveryReadFailurePublishesUnknownCurrentValue() async {
        let adapter = OperationTestAdapter()
        adapter.failVerification = true
        adapter.failRestore = true
        let record = makeTestRecord(id: "flag", title: "Flag", adapter: adapter)
        let controller = makeController([record])
        _ = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertNotNil(controller.pendingRecoveries[record.id]?.current)
        adapter.failRead = true
        await controller.refresh(record)
        XCTAssertNil(controller.pendingRecoveries[record.id]?.current)
        XCTAssertNil(controller.rowStates[record.id]?.value)
        XCTAssertFalse(controller.canEditSettings)
    }

    func testFailedRecoveryPersistenceKeepsSnapshotAndCanBeRetried() async {
        let adapter = OperationTestAdapter()
        adapter.failVerification = true
        adapter.failRestore = true
        let storage = MacSettingsTestStorage()
        let record = makeTestRecord(id: "flag", title: "Flag", adapter: adapter)
        let controller = makeController([record], storage: storage)
        storage.failingWriteKeys = ["pending-recovery-v1"]
        _ = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertNotNil(controller.recoveryPersistenceError)
        XCTAssertNotNil(controller.pendingRecoveries[record.id])
        storage.failingWriteKeys = []
        controller.retrySavingRecoveries()
        XCTAssertNil(controller.recoveryPersistenceError)
        XCTAssertNotNil(makeController([record], storage: storage).pendingRecoveries[record.id])
        storage.failingNextWriteKey = "pending-recovery-v1"
        controller.keepCurrentValues(record.id)
        XCTAssertNotNil(controller.recoveryPersistenceError)
        XCTAssertNotNil(controller.pendingRecoveries[record.id])
        XCTAssertFalse(controller.canEditSettings)
        controller.keepCurrentValues(record.id)
        XCTAssertNil(controller.recoveryPersistenceError)
        XCTAssertTrue(controller.pendingRecoveries.isEmpty)
        XCTAssertTrue(makeController([record], storage: storage).pendingRecoveries.isEmpty)
        controller.deactivate()
    }

    func testRecoveryTargetIsSavedBeforeReadingPostFailureState() async {
        let adapter = OperationTestAdapter()
        adapter.failVerification = true
        adapter.failRestore = true
        let storage = MacSettingsTestStorage()
        var reads = 0
        adapter.onRead = {
            reads += 1
            if reads > 1 { XCTAssertNotNil(storage.data(forKey: "pending-recovery-v1")) }
        }
        let record = makeTestRecord(id: "flag", title: "Flag", adapter: adapter)
        let controller = makeController([record], storage: storage)
        _ = await controller.applyAndWait(.boolean(true), to: record)
        XCTAssertGreaterThan(reads, 1)
    }

    func testRestorationPublishesEachValueBeforeBatchCompletes() async {
        let first = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
        let second = OperationTestAdapter()
        let records = [makeTestRecord(id: "first", title: "First", adapter: first),
                       makeTestRecord(id: "second", title: "Second", adapter: second)]
        let controller = makeController(records)
        controller.preparePlan(for: profile(records))
        while controller.isPreparingPlan { await Task.yield() }
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        first.suspendNextRead = true
        controller.rollbackLastApply()
        while !first.firstReadStarted { await Task.yield() }
        XCTAssertEqual(controller.operationState, .restoring)
        XCTAssertEqual(controller.operationProgress?.completed, 1)
        XCTAssertEqual(controller.rowStates[records[1].id]?.value, .boolean(false))
        first.resumeFirstRead(with: .boolean(true))
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(controller.rowStates[records[0].id]?.value, .boolean(false))
    }

    func testProgressArrivesBeforeBatchCompletesAndCancellationStopsNextWrite() async {
        let firstAdapter = OperationTestAdapter()
        let delayed = FirstReadSuspendingSystemSettingAdapter(value: .boolean(false), suspendsFirstRead: false)
        let lastAdapter = OperationTestAdapter()
        let records = [
            makeTestRecord(id: "first", title: "First", adapter: firstAdapter),
            makeTestRecord(id: "delayed", title: "Delayed", adapter: delayed),
            makeTestRecord(id: "last", title: "Last", adapter: lastAdapter),
        ]
        let controller = makeController(records)
        controller.preparePlan(for: profile(records))
        while controller.isPreparingPlan { await Task.yield() }
        delayed.suspendNextRead = true
        controller.applyActivePlan()
        while !delayed.firstReadStarted { await Task.yield() }
        XCTAssertEqual(controller.operationProgress?.completed, 1)
        XCTAssertEqual(controller.operationProgress?.total, 3)
        XCTAssertEqual(controller.operationProgress?.results.first?.kind, .appliedAndVerified)
        XCTAssertNil(controller.lastApplyReport)
        XCTAssertEqual(controller.rowStates[records[0].id]?.value, .boolean(true))
        controller.cancelOperation()
        delayed.resumeFirstRead(with: .boolean(false))
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(controller.operationState, .idle)
        XCTAssertEqual(controller.operationProgress?.completed, 3)
        XCTAssertEqual(controller.lastApplyReport?.results.map(\.kind), [.appliedAndVerified, .cancelled, .cancelled])
        XCTAssertEqual(lastAdapter.writes, 0)
    }

    func testPartialRecoveryStopsLaterSettingsAndRequiresResolution() async {
        let broken = OperationTestAdapter()
        broken.failVerification = true
        broken.failRestore = true
        let untouched = OperationTestAdapter()
        let records = [makeTestRecord(id: "broken", title: "Broken", adapter: broken),
                       makeTestRecord(id: "later", title: "Later", adapter: untouched)]
        let controller = makeController(records)
        controller.preparePlan(for: profile(records))
        while controller.isPreparingPlan { await Task.yield() }
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(controller.lastApplyReport?.results.map(\.kind), [.failedWithoutRollback, .cancelled])
        XCTAssertEqual(untouched.writes, 0)
        XCTAssertFalse(controller.canRetryFailedChanges)
        XCTAssertNotNil(controller.pendingRecoveries[records[0].id])
    }

    func testRetryUsesFreshPreviewAndPreservesUndoForEarlierSuccesses() async {
        let first = OperationTestAdapter()
        let second = OperationTestAdapter()
        second.failVerification = true
        let records = [makeTestRecord(id: "first", title: "First", adapter: first),
                       makeTestRecord(id: "second", title: "Second", adapter: second)]
        let controller = makeController(records)
        controller.preparePlan(for: profile(records))
        while controller.isPreparingPlan { await Task.yield() }
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertTrue(controller.canRetryFailedChanges)
        XCTAssertEqual(controller.lastApplyReport?.rollbackPoint.entries.count, 1)
        second.failVerification = false
        controller.retryFailedChanges()
        while controller.isPreparingPlan { await Task.yield() }
        XCTAssertEqual(controller.activePlan?.items.map(\.settingID), [records[1].id])
        XCTAssertEqual(second.writes, 1, "Retry must only preview before explicit Apply")
        controller.applyActivePlan()
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(first.writes, 1)
        XCTAssertEqual(controller.lastApplyReport?.results.map(\.kind), [.appliedAndVerified, .appliedAndVerified])
        XCTAssertEqual(controller.lastApplyReport?.rollbackPoint.entries.count, 2)
        controller.rollbackLastApply()
        while controller.isApplyingProfile { await Task.yield() }
        XCTAssertEqual(first.value, .boolean(false))
        XCTAssertEqual(second.value, .boolean(false))
    }

    private func composite(_ store: OperationPreferenceStore) -> CompositeBooleanSystemSettingAdapter {
        CompositeBooleanSystemSettingAdapter(adapters: [
            TrackpadBooleanPreferencesSettingAdapter(domain: "built-in", key: "drag", store: store),
            TrackpadBooleanPreferencesSettingAdapter(domain: "bluetooth", key: "drag", store: store),
        ])
    }

    private func makeController(_ records: [SystemSettingRecord], storage: MacSettingsTestStorage? = nil) -> MacSettingsController {
        MacSettingsController(catalog: makeTestCatalog(records), storage: storage ?? .init())
    }

    private func profile(_ records: [SystemSettingRecord]) -> SystemSettingsProfile {
        .init(name: "Progress", entries: records.map { .init(settingID: $0.id, desiredValue: .boolean(true), category: .finder) })
    }
}

@MainActor
private final class OperationPreferenceStore: FinderPreferencesStoring {
    var values: [String: SystemSettingStoredPreference] = ["built-in": .boolean(false), "bluetooth": .integer(0)]
    var blocked: Set<String> = []
    func read(keys: [String], domain: String) throws -> [String: SystemSettingStoredPreference] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, values[domain] ?? .missing) })
    }
    func write(_ values: [String: SystemSettingStoredPreference], domain: String) throws {
        if blocked.contains(domain) { throw SystemSettingAdapterError.writeFailed("Blocked domain") }
        self.values[domain] = values["drag"]
    }
}

@MainActor
private final class OperationTestAdapter: SystemSettingAdapter {
    var value: SystemSettingValue = .boolean(false)
    var failVerification = false
    var failRestore = false
    var failRead = false
    var onRead: (() -> Void)?
    var writes = 0
    func read() async throws -> SystemSettingValue {
        onRead?()
        if failRead { throw SystemSettingAdapterError.unreadable }
        return value
    }
    func apply(_ value: SystemSettingValue) async throws { writes += 1; self.value = value }
    func verify(_ expected: SystemSettingValue) async throws -> SystemSettingVerification {
        failVerification ? .mismatch(actual: value) : .verified(value)
    }
    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        if failRestore { throw SystemSettingAdapterError.writeFailed("Injected recovery failure") }
        value = snapshot.value
        return .verified(value)
    }
}
