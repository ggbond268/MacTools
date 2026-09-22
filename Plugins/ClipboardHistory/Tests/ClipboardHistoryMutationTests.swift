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
