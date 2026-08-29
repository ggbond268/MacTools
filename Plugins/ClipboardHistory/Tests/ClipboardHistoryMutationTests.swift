import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryMutationTests: XCTestCase {
    func testIndependentSavedOCRAndUsageChangesMergeInEitherOrder() throws {
        let original = imageItem()
        var saved = original
        saved.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Saved image", savedAt: Date()))
        var indexed = original
        indexed.setImageSearchText("recognized words")
        indexed.hasCompletedImageTextIndexing = true
        var used = original
        used.lastUsedAt = Date().addingTimeInterval(1)
        let mutations = [saved, indexed, used].map { ClipboardHistoryMutation.between([original], [$0]) }

        for order in [[0, 1, 2], [2, 1, 0], [1, 0, 2], [0, 2, 1]] {
            let result = order.reduce([original]) { mutations[$1].applying(to: $0) }
            let merged = try XCTUnwrap(result.first)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(merged.savedMetadata, saved.savedMetadata)
            XCTAssertEqual(merged.imageSearchText, indexed.imageSearchText)
            XCTAssertTrue(merged.hasCompletedImageTextIndexing)
            XCTAssertEqual(merged.lastUsedAt, used.lastUsedAt)
        }
    }

    func testRecaptureKeepsConcurrentSavedMetadataOCRAndUsage() throws {
        let original = imageItem()
        var concurrent = original
        concurrent.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Saved image", savedAt: Date()))
        concurrent.setImageSearchText("recognized words")
        concurrent.hasCompletedImageTextIndexing = true
        concurrent.lastUsedAt = Date().addingTimeInterval(2)
        let recaptured = imageItem(id: original.id, capturedAt: original.capturedAt.addingTimeInterval(1))

        let mutation = ClipboardHistoryMutation.between([original], [recaptured])
        let merged = try XCTUnwrap(mutation.applying(to: [concurrent]).first)
        XCTAssertEqual(merged.capturedAt, recaptured.capturedAt)
        XCTAssertEqual(merged.savedMetadata, concurrent.savedMetadata)
        XCTAssertEqual(merged.imageSearchText, concurrent.imageSearchText)
        XCTAssertEqual(merged.lastUsedAt, concurrent.lastUsedAt)
        XCTAssertTrue(merged.hasCompletedImageTextIndexing)
    }

    func testLateUpdatesNeverResurrectADeletedItem() {
        let original = imageItem()
        var indexed = original
        indexed.setImageSearchText("late recognition")
        indexed.hasCompletedImageTextIndexing = true
        var used = original
        used.lastUsedAt = Date()
        var saved = original
        saved.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Too late", savedAt: Date()))
        for update in [indexed, used, saved] {
            XCTAssertTrue(ClipboardHistoryMutation.between([original], [update]).applying(to: []).isEmpty)
        }
    }

    func testLateOCRDoesNotApplyToChangedPayload() throws {
        let original = imageItem()
        var indexed = original
        indexed.setImageSearchText("old image words")
        indexed.hasCompletedImageTextIndexing = true
        let replacement = imageItem(id: original.id, digest: Data([2]))
        let merged = try XCTUnwrap(ClipboardHistoryMutation.between([original], [indexed])
            .applying(to: [replacement]).first)
        XCTAssertEqual(merged.payloadDigest, replacement.payloadDigest)
        XCTAssertNil(merged.imageSearchText)
        XCTAssertFalse(merged.hasCompletedImageTextIndexing)
    }

    func testGenuineRecopyRecreatesDeletedHistoryWithoutInheritedSavedMetadata() throws {
        var original = textItem("copy again")
        original.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Old bookmark", savedAt: Date()))
        let freshCopy = textItem("copy again", capturedAt: original.capturedAt.addingTimeInterval(1))
        let recaptured = try XCTUnwrap(original.recaptured(from: freshCopy))
        XCTAssertEqual(recaptured.savedMetadata, original.savedMetadata,
            "Capture sees the old bookmark before the pending deletion completes")

        let mutation = ClipboardHistoryMutation.between([original], [recaptured])
        let recreated = try XCTUnwrap(mutation.applying(to: []).first)
        XCTAssertEqual(recreated.id, original.id)
        XCTAssertEqual(recreated.text, "copy again")
        XCTAssertEqual(recreated.capturedAt, freshCopy.capturedAt)
        XCTAssertTrue(recreated.isInHistory)
        XCTAssertFalse(recreated.isSaved, "New history must not restore the bookmark that was deleted")
    }

    func testGenuineRecopyDuringBlockedDeleteSurvivesAsUnsavedHistory() async throws {
        try await assertRecopySurvivesBlockedDelete(hasNewerItem: true)
    }

    func testRecopyOfNewestItemDuringBlockedDeleteIsNotSuppressedAsDuplicate() async throws {
        try await assertRecopySurvivesBlockedDelete(hasNewerItem: false)
    }

    func testDeleteAcknowledgmentPreservesUnflushedOCRFromGenuineImageRecopy() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [ClipboardStoredPasteboardItem(representations: [
            ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.png, data: Data([1]))
        ])])
        let original = ClipboardHistoryItem(
            id: UUID(), payload: payload, capturedAt: Date().addingTimeInterval(-60),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil,
            imageSearchText: "old recognized words", hasCompletedImageTextIndexing: true,
            savedMetadata: ClipboardHistorySavedMetadata(title: "Old bookmark", savedAt: Date())
        )
        XCTAssertEqual(original.kind, .image)
        let recognizer = MutationTestOCR()
        let fixture = makeFixture(items: [original], recognizer: recognizer)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        let deleting = Task { await fixture.controller.deletePermanently(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }

        XCTAssertTrue(fixture.board.writePayload(payload))
        fixture.controller.processPasteboardChange()
        try await waitUntil { await recognizer.callCount == 1 }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.controller.items.first).capturedAt, original.capturedAt)
        await recognizer.release()
        try await waitUntil { fixture.controller.items.first?.imageSearchText == "recognized words" }
        XCTAssertTrue(fixture.store.snapshots.isEmpty,
            "Keep OCR locally debounced while the delete and recapture writes are still blocked")

        fixture.store.releaseSave()
        let succeeded = await deleting.value
        XCTAssertTrue(succeeded)
        let visible = try XCTUnwrap(fixture.controller.items.first)
        XCTAssertEqual(visible.id, original.id)
        XCTAssertFalse(visible.isSaved)
        XCTAssertEqual(visible.imageSearchText, "recognized words",
            "Publishing the delete and recopy must not overwrite newer OCR that has not been submitted yet")
        XCTAssertTrue(visible.hasCompletedImageTextIndexing)
        fixture.controller.stop()
        let durable = try XCTUnwrap(fixture.store.items.first)
        XCTAssertEqual(durable.id, original.id)
        XCTAssertEqual(durable.imageSearchText, "recognized words")
        XCTAssertTrue(durable.hasCompletedImageTextIndexing)
        XCTAssertFalse(durable.isSaved)
    }

    private func assertRecopySurvivesBlockedDelete(hasNewerItem: Bool) async throws {
        var original = textItem("copy again", capturedAt: Date().addingTimeInterval(-60))
        original.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Old bookmark", savedAt: Date()))
        let initialItems = hasNewerItem ? [textItem("newer item"), original] : [original]
        let fixture = makeFixture(items: initialItems)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        let deleting = Task { await fixture.controller.deletePermanently(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }
        XCTAssertTrue(fixture.controller.isCollectionOperational)
        fixture.board.copy("copy again")
        fixture.controller.processPasteboardChange()
        try await waitUntil {
            fixture.controller.items.first { $0.id == original.id }?.capturedAt != original.capturedAt
        }
        fixture.store.releaseSave()
        let succeeded = await deleting.value
        XCTAssertTrue(succeeded)
        try await waitUntil {
            fixture.store.items.first { $0.id == original.id }?.isSaved == false
                && fixture.controller.items.first { $0.id == original.id }?.isSaved == false
        }
        fixture.controller.stop()
        let recreated = try XCTUnwrap(fixture.store.items.first { $0.id == original.id })
        XCTAssertTrue(recreated.isInHistory)
        XCTAssertFalse(recreated.isSaved)
        XCTAssertGreaterThan(recreated.capturedAt, original.capturedAt)
        XCTAssertEqual(fixture.store.items.count, initialItems.count)
        XCTAssertEqual(fixture.store.items, fixture.controller.items)
    }

    func testCaptureOCRAndUsageContinueDuringBlockedSavedMutation() async throws {
        let original = imageItem()
        let recognizer = MutationTestOCR()
        let fixture = makeFixture(items: [original], recognizer: recognizer)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        try await waitUntil { await recognizer.callCount == 1 }
        let saving = Task { await fixture.controller.toggleSaved(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }
        XCTAssertTrue(fixture.controller.isCollectionOperational)
        XCTAssertFalse(fixture.controller.isClearingHistory)

        await recognizer.release()
        try await waitUntil { fixture.controller.items.first?.hasCompletedImageTextIndexing == true }
        fixture.board.copy("copied while saving")
        fixture.controller.processPasteboardChange()
        try await waitUntil { fixture.controller.items.count == 2 }
        fixture.controller.recordCombinedItemUsage(ids: [original.id])
        fixture.store.releaseSave()
        let succeeded = await saving.value
        XCTAssertTrue(succeeded)
        fixture.controller.stop()

        let saved = try XCTUnwrap(fixture.controller.items.first { $0.id == original.id })
        XCTAssertTrue(saved.isSaved)
        XCTAssertEqual(saved.imageSearchText, "recognized words")
        XCTAssertTrue(saved.hasCompletedImageTextIndexing)
        XCTAssertNotNil(saved.lastUsedAt)
        XCTAssertEqual(fixture.board.payloadReadCount, 1)
        XCTAssertEqual(Set(fixture.store.items.map(\.id)), Set(fixture.controller.items.map(\.id)))
        XCTAssertEqual(fixture.store.items.first { $0.id == original.id }, saved)
        XCTAssertTrue(fixture.store.items.contains { $0.text == "copied while saving" })
    }

    func testRapidSavedTogglesKeepEveryIntentWithoutBlockingCollection() async throws {
        let original = textItem("toggle target")
        let fixture = makeFixture(items: [original])
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        let first = Task { await fixture.controller.toggleSaved(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }
        let remaining = (0..<3).map { _ in Task { await fixture.controller.toggleSaved(id: original.id) } }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(fixture.controller.isCollectionOperational)
        XCTAssertFalse(fixture.controller.isClearingHistory)
        fixture.store.releaseSave()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        for task in remaining {
            let result = await task.value
            XCTAssertTrue(result)
        }
        fixture.controller.stop()
        XCTAssertEqual(fixture.store.snapshots.map { $0.first?.isSaved }, [true, false, true, false])
        XCTAssertFalse(try XCTUnwrap(fixture.controller.items.first).isSaved)
        XCTAssertEqual(fixture.store.items, fixture.controller.items)
    }

    func testEveryAcceptedQueuedMutationProtectsItsTargetFromRetention() async throws {
        let now = Date()
        let firstTarget = textItem("first target", capturedAt: now)
        let filler = textItem("unprotected filler", capturedAt: now.addingTimeInterval(-30))
        let secondTarget = textItem("second target", capturedAt: now.addingTimeInterval(-60))
        let fixture = makeFixture(items: [firstTarget, filler, secondTarget])
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }

        let first = Task { await fixture.controller.toggleSaved(id: firstTarget.id) }
        try await waitUntil { fixture.store.saveStarted }
        let second = Task { await fixture.controller.toggleSaved(id: secondTarget.id) }
        try await waitUntil {
            fixture.controller.pendingDurableItemIDsForTesting == [firstTarget.id, secondTarget.id]
        }

        fixture.controller.settings.maximumItemCount = 2
        fixture.controller.settingsDidChange()
        XCTAssertEqual(
            Set(fixture.controller.items.map(\.id)),
            [firstTarget.id, secondTarget.id],
            "Retention must not evict a mutation target that was already accepted behind another write"
        )

        fixture.store.releaseSave()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertTrue(fixture.controller.items.allSatisfy(\.isSaved))
    }

    func testFailedSavedMutationPreservesLaterCaptureAndDoesNotSaveMetadata() async throws {
        let original = textItem("original")
        let fixture = makeFixture(items: [original], failsBlockedSave: true)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        let saving = Task { await fixture.controller.toggleSaved(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }
        fixture.board.copy("capture after the failed save request")
        fixture.controller.processPasteboardChange()
        try await waitUntil { fixture.controller.items.count == 2 }
        fixture.store.releaseSave()
        let succeeded = await saving.value
        XCTAssertFalse(succeeded)
        try await waitUntil { fixture.store.items.count == 2 }
        fixture.controller.stop()
        XCTAssertFalse(try XCTUnwrap(fixture.controller.items.first { $0.id == original.id }).isSaved)
        XCTAssertTrue(fixture.controller.items.contains { $0.text == "capture after the failed save request" })
        XCTAssertEqual(fixture.store.items, fixture.controller.items)
    }

    func testFailedCaptureInsertCannotBecomeAPhantomSuccessfulBookmark() async throws {
        let fixture = makeFixture(items: [], failsBlockedSave: true)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        fixture.board.copy("capture whose insert fails")
        fixture.controller.processPasteboardChange()
        try await waitUntil { fixture.store.saveStarted }
        let capturedID = try XCTUnwrap(fixture.controller.items.first?.id)
        let saving = Task { await fixture.controller.toggleSaved(id: capturedID) }
        for _ in 0..<10 { await Task.yield() }

        fixture.store.releaseSave()
        let succeeded = await saving.value
        XCTAssertFalse(succeeded,
            "An update of a failed insertion must not claim that the missing item was saved")
        fixture.controller.stop()
        XCTAssertTrue(fixture.store.items.isEmpty)
        XCTAssertTrue(fixture.store.snapshots.isEmpty)
        XCTAssertTrue(fixture.controller.items.isEmpty,
            "A later acknowledgment must not hide the insert failure and leave a phantom item")
        XCTAssertNotNil(fixture.controller.errorMessage)
    }

    func testClearCancelsPendingOCRWithoutResurrectingDeletedHistory() async throws {
        let recognizer = MutationTestOCR()
        let fixture = makeFixture(items: [imageItem()], recognizer: recognizer)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        try await waitUntil { await recognizer.callCount == 1 }
        let clearing = Task { await fixture.controller.clearAllHistory() }
        try await waitUntil { fixture.store.saveStarted }
        XCTAssertTrue(fixture.controller.isClearingHistory)
        await recognizer.release()
        fixture.store.releaseSave()
        let succeeded = await clearing.value
        XCTAssertTrue(succeeded)
        for _ in 0..<10 { await Task.yield() }
        fixture.controller.stop()
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertTrue(fixture.store.items.isEmpty)
        XCTAssertFalse(fixture.controller.isClearingHistory)
    }

    func testStoppedControllerRejectsNewSavedMutations() async throws {
        let original = textItem("stopped target")
        let fixture = makeFixture(items: [original])
        fixture.store.releaseSave()
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        fixture.controller.stop()
        let succeeded = await fixture.controller.toggleSaved(id: original.id)
        XCTAssertFalse(succeeded)
        XCTAssertTrue(fixture.store.snapshots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(fixture.store.items.first).isSaved)
    }

    func testPendingSavedTargetSurvivesOCRPruningThenReceivesUpdatedRetention() async throws {
        let original = imageItem(capturedAt: Date().addingTimeInterval(-2 * 24 * 60 * 60))
        let recognizer = MutationTestOCR()
        let fixture = makeFixture(items: [original], recognizer: recognizer)
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        try await waitUntil { await recognizer.callCount == 1 }
        let saving = Task { await fixture.controller.toggleSaved(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }
        fixture.controller.settings.expiration = .oneDay
        fixture.controller.settingsDidChange()
        XCTAssertEqual(fixture.controller.items.map(\.id), [original.id])
        await recognizer.release()
        try await waitUntil { fixture.controller.items.first?.hasCompletedImageTextIndexing == true }
        XCTAssertEqual(fixture.controller.items.map(\.id), [original.id],
            "OCR retention must respect the same pending-save protection as normal capture")
        fixture.store.releaseSave()
        let succeeded = await saving.value
        XCTAssertTrue(succeeded)
        try await waitUntil { fixture.controller.items.first?.isInHistory == false }
        fixture.controller.stop()
        let savedOnly = try XCTUnwrap(fixture.controller.items.first)
        XCTAssertTrue(savedOnly.isSaved)
        XCTAssertFalse(savedOnly.isInHistory)
        XCTAssertEqual(savedOnly.imageSearchText, "recognized words")
        XCTAssertEqual(fixture.store.items, fixture.controller.items)
    }

    func testReleasingPendingSavedProtectionReopensTheRemainingCaptureSlot() async throws {
        let now = Date()
        let original = textItem("save target", capturedAt: now)
        let queueItems = (1...99).map { textItem("queue \($0)", capturedAt: now.addingTimeInterval(-Double($0))) }
        let fixture = makeFixture(items: [original] + queueItems)
        fixture.controller.settings.maximumItemCount = 100
        defer { fixture.store.releaseSave(); fixture.controller.stop() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.isLoaded }
        fixture.controller.updateSequentialPasteProtectedItemIDs(Set(queueItems.map(\.id)))
        XCTAssertFalse(fixture.controller.isCaptureBlockedByProtectedItems)
        let saving = Task { await fixture.controller.toggleSaved(id: original.id) }
        try await waitUntil { fixture.store.saveStarted }
        fixture.store.releaseSave()
        let succeeded = await saving.value
        XCTAssertTrue(succeeded)
        XCTAssertFalse(fixture.controller.isCaptureBlockedByProtectedItems,
            "Removing temporary save protection must restore the one free History slot")
        fixture.board.copy("new capture after save")
        fixture.controller.processPasteboardChange()
        try await waitUntil { fixture.controller.items.contains { $0.text == "new capture after save" } }
        fixture.controller.stop()
        XCTAssertTrue(fixture.store.items.contains { $0.text == "new capture after save" })
    }

    private func makeFixture(
        items: [ClipboardHistoryItem],
        recognizer: MutationTestOCR = MutationTestOCR(),
        failsBlockedSave: Bool = false
    ) -> MutationTestFixture {
        let settings = ClipboardHistorySettingsStore(storage: MutationTestStorage())
        settings.setPaused(false)
        settings.excludedApplications = []
        let board = MutationTestPasteboard()
        let store = MutationTestStore(items: items, failsBlockedSave: failsBlockedSave)
        let controller = ClipboardHistoryController(
            settings: settings, pasteboard: board, sourceContext: MutationTestSource(),
            persistence: store, monitoringInterval: 3_600, imageIndexBatchPauseNanoseconds: 0,
            imageTextRecognizer: recognizer
        )
        return MutationTestFixture(controller: controller, board: board, store: store)
    }

    private func textItem(_ text: String, capturedAt: Date = Date()) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: UUID(), text: text, capturedAt: capturedAt,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }

    private func imageItem(id: UUID = UUID(), capturedAt: Date = Date(), digest: Data = Data([1])) -> ClipboardHistoryItem {
        let payload = ClipboardHistoryPayload(pasteboardItems: [ClipboardStoredPasteboardItem(representations: [
            ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.png, data: digest)
        ])])
        return ClipboardHistoryItem(
            id: id, text: "", capturedAt: capturedAt, sourceApplication: nil,
            kind: .image, payloadByteCount: digest.count, filterContentKinds: [.image], fileURLs: [],
            representationTypeIdentifiers: [ClipboardRepresentationType.png], payloadDigest: digest,
            allowsRichTextImport: false, textCharacterCount: 0, textLineCount: 0,
            isSearchTextTruncated: false, isPinned: false, lastUsedAt: nil, imageSearchText: nil,
            hasCompletedImageTextIndexing: false, payloadLoader: { payload }
        )
    }

    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for isolated mutation work", file: file, line: line)
        throw MutationTestError.timeout
    }
}

@MainActor
private struct MutationTestFixture {
    let controller: ClipboardHistoryController
    let board: MutationTestPasteboard
    let store: MutationTestStore
}

private enum MutationTestError: Error {
    case saveFailed
    case timeout
}

private final class MutationTestStore: ClipboardHistoryPersisting, @unchecked Sendable {
    private let condition = NSCondition()
    private var storedItems: [ClipboardHistoryItem]
    private var recordedSnapshots: [[ClipboardHistoryItem]] = []
    private var didStartSave = false
    private var wasReleased = false
    private let failsBlockedSave: Bool

    init(items: [ClipboardHistoryItem], failsBlockedSave: Bool) {
        storedItems = items
        self.failsBlockedSave = failsBlockedSave
    }

    var items: [ClipboardHistoryItem] { condition.withLock { storedItems } }
    var snapshots: [[ClipboardHistoryItem]] { condition.withLock { recordedSnapshots } }
    var saveStarted: Bool { condition.withLock { didStartSave } }
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { items }
    func save(_ items: [ClipboardHistoryItem]) throws {
        condition.lock()
        defer { condition.unlock() }
        let isFirstSave = !didStartSave
        didStartSave = true
        while !wasReleased { condition.wait() }
        if isFirstSave && failsBlockedSave { throw MutationTestError.saveFailed }
        storedItems = items
        recordedSnapshots.append(items)
    }
    func releaseSave() {
        condition.withLock {
            wasReleased = true
            condition.broadcast()
        }
    }
    func reset() throws { condition.withLock { storedItems = [] } }
    func removeAll() throws { try reset() }
}

private actor MutationTestOCR: ClipboardImageTextRecognizing {
    private(set) var callCount = 0
    private var wasReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        callCount += 1
        if !wasReleased { await withCheckedContinuation { continuation = $0 } }
        return "recognized words"
    }
    func release() {
        wasReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MutationTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

@MainActor
private final class MutationTestPasteboard: ClipboardPasteboardAccess {
    private(set) var changeCount = 0
    private var payload: ClipboardHistoryPayload?
    private(set) var payloadReadCount = 0
    var typeNames: Set<String> { Set(payload?.representations.map(\.typeIdentifier) ?? []) }
    func copy(_ text: String) { _ = writePlainText(text) }
    func readPlainText() -> String? { payload?.plainText }
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult {
        payloadReadCount += 1
        guard let payload else { return .empty }
        return .payload(payload)
    }
    func writePlainText(_ text: String) -> Bool { writePayload(.plainText(text)) }
    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool {
        self.payload = payload
        changeCount += 1
        return true
    }
}

@MainActor
private final class MutationTestSource: ClipboardSourceContextProviding {
    func frontmostApplication() -> ClipboardSourceApplication? { nil }
}
