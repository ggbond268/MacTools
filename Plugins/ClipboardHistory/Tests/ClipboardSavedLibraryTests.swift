import AppKit
import Combine
import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardSavedLibraryTests: XCTestCase {

    @MainActor
    func testLiteralAndDateSnippetsNeverReadClipboardWhenCopiedOrResolved() async {
        for template in ["literal template", "{{date format=\"yyyy\"}}", #"\{{clipboard}}"#] {
            let item = ClipboardSavedItem(title: "Template", savedKind: .snippet,
                payload: .plainText(template), templateText: template)
            let board = SavedLibraryTestPasteboard()
            let controller = ClipboardSavedLibraryController(pasteboard: board,
                persistence: SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [item]))
            await startSavedLibrary(controller)
            let resolved = await controller.resolvedPlainText(id: item.id)
            let copied = await controller.copy(id: item.id)
            XCTAssertNotNil(resolved, template)
            XCTAssertNotNil(copied, template)
            XCTAssertEqual(board.plainTextReadCount, 0, template)
            XCTAssertEqual(board.asynchronousPlainTextReadCount, 0, template)
            controller.stop()
        }
    }

    @MainActor
    func testQuickPasteSnapshotExpandsAgainstEachNewClipboardValue() async {
        let board = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(
            pasteboard: board, persistence: SlowSavedLibraryTestStore(saveDelay: 0)
        )
        await startSavedLibrary(controller)
        let snapshot = ClipboardSequentialPasteSnapshot(
            sourceItemID: UUID(), payload: .plainText("Hello {{clipboard}}"),
            expandsSnippetVariables: true
        )

        _ = board.writePlainText("Ada")
        let first = await controller.copyQueuedSnapshotForPaste(snapshot)
        XCTAssertEqual(first?.expansion.text, "Hello Ada")
        _ = board.writePlainText("Grace")
        let second = await controller.copyQueuedSnapshotForPaste(snapshot)
        XCTAssertEqual(second?.expansion.text, "Hello Grace")
        XCTAssertEqual(board.asynchronousPlainTextReadCount, 2)
        controller.stop()
    }

    @MainActor
    func testSensitiveClipboardIsUnavailableToCopyResolvedTextAndKeywordExpansion() async throws {
        let template = "Hello {{clipboard}}"
        let item = ClipboardSavedItem(
            title: "Sensitive template",
            keyword: ";sensitive",
            savedKind: .snippet,
            payload: .plainText(template),
            templateText: template
        )
        let board = SavedLibraryTestPasteboard()
        board.text = "secret"
        board.typeNames = ["org.nspasteboard.ConcealedType"]
        board.onAsynchronousPlainTextRead = { .changed }
        let controller = ClipboardSavedLibraryController(
            pasteboard: board,
            persistence: SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [item])
        )
        await startSavedLibrary(controller)

        let resolved = await controller.resolvedPlainText(id: item.id)
        let copied = await controller.copy(id: item.id)
        XCTAssertNil(resolved)
        XCTAssertNil(copied)
        XCTAssertNil(board.payload)
        do {
            _ = try await controller.expansionContext(for: template)
            XCTFail("Keyword expansion must not receive sensitive clipboard text")
        } catch is CancellationError {
            // Sensitive content is intentionally treated as unavailable.
        }
        XCTAssertEqual(board.asynchronousPlainTextReadCount, 3)
        controller.stop()
    }

    @MainActor
    func testClipboardVariableCannotWriteAfterVersionChangeOrCancellation() async throws {
        for cancel in [false, true] {
            let template = "{{clipboard}}"
            let item = ClipboardSavedItem(title: "Template", savedKind: .snippet,
                payload: .plainText(template), templateText: template)
            let board = SavedLibraryTestPasteboard()
            var pendingRead: CheckedContinuation<ClipboardPasteboardReadResult, Never>?
            board.onAsynchronousPlainTextRead = {
                await withCheckedContinuation { pendingRead = $0 }
            }
            let controller = ClipboardSavedLibraryController(pasteboard: board,
                persistence: SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [item]))
            await startSavedLibrary(controller)
            let task = Task { await controller.copy(id: item.id) }
            let deadline = ContinuousClock.now + .seconds(5)
            while pendingRead == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let pendingRead else {
                task.cancel()
                XCTFail("Expected asynchronous clipboard read")
                controller.stop()
                return
            }
            if cancel { task.cancel() } else { board.changeCount += 1 }
            let expectedVersion = board.changeCount
            pendingRead.resume(returning: .payload(.plainText("stale value")))
            let result = await task.value
            XCTAssertNil(result)
            XCTAssertEqual(board.changeCount, expectedVersion)
            XCTAssertNil(board.payload)
            controller.stop()
        }
    }

    func testKeywordMatcherUsesBoundariesAndLongestMatch() {
        let shortID = UUID()
        let longID = UUID()
        var matcher = ClipboardSnippetKeywordMatcher(
            snippetsByKeyword: [";sig": shortID, ";signature": longID]
        )
        var match: ClipboardSnippetKeywordMatch?
        for character in "hello ;signature" {
            match = matcher.consume(
                text: String(character),
                keyCode: 0,
                modifiers: []
            ) ?? match
        }

        XCTAssertEqual(
            match,
            ClipboardSnippetKeywordMatch(
                itemID: longID,
                keyword: ";signature",
                delimiter: ""
            )
        )

        for character in "prefix;sig" {
            _ = matcher.consume(text: String(character), keyCode: 0, modifiers: [])
        }
        XCTAssertNil(matcher.consume(text: " ", keyCode: 49, modifiers: []))
    }

    func testKeywordInputStateFailsClosedBeforeBufferingSecureOrUnknownText() {
        for classification in [
            ClipboardSnippetSecureTextClassification.secure,
            .unknown,
        ] {
            var state = ClipboardSnippetKeywordInputState()
            state.snippetsByKeyword = [";bb": UUID()]
            for character in ";bb" {
                XCTAssertNil(state.consume(
                    text: String(character),
                    keyCode: 0,
                    modifiers: [],
                    processIdentifier: 42,
                    classifyEditor: { _ in classification }
                ))
            }
            XCTAssertEqual(state.bufferedTextForTesting, "")
        }
    }

    func testKeywordInputStateFailsClosedWhileSecureEventInputIsEnabled() {
        var state = ClipboardSnippetKeywordInputState()
        state.snippetsByKeyword = [";bb": UUID()]
        var classificationCount = 0

        for character in ";bb" {
            XCTAssertNil(state.consume(
                text: String(character),
                keyCode: 0,
                modifiers: [],
                processIdentifier: 42,
                isSecureEventInputEnabled: { true },
                classifyEditor: { _ in
                    classificationCount += 1
                    return .nonSecure
                }
            ))
        }

        XCTAssertEqual(classificationCount, 0)
        XCTAssertEqual(state.bufferedTextForTesting, "")
    }

    func testKeywordReplacementContextRejectsInterveningCursorOrTextChanges() {
        let context = ClipboardSnippetReplacementContext(
            selectionLocation: 12,
            selectionLength: 0,
            keywordLocation: 7,
            keywordLength: 5,
            keyword: ";date"
        )

        XCTAssertTrue(context.isValid(
            selection: CFRange(location: 12, length: 0),
            keywordText: ";date"
        ))
        XCTAssertFalse(context.isValid(
            selection: CFRange(location: 13, length: 0),
            keywordText: ";date"
        ))
        XCTAssertFalse(context.isValid(
            selection: CFRange(location: 12, length: 1),
            keywordText: ";date"
        ))
        XCTAssertFalse(context.isValid(
            selection: CFRange(location: 12, length: 0),
            keywordText: ";changed"
        ))
    }

    func testTemplateExpansionSupportsDeterministicVariablesAndCursor() throws {
        let date = Date(timeIntervalSince1970: 1_704_164_645)
        let context = ClipboardSnippetExpansionContext(
            date: date,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            clipboardText: "copied"
        )

        let expansion = try ClipboardSnippetTemplateEngine.expand(
            #"{{date format="yyyy-MM-dd"}} {{time format="HH:mm"}} {{clipboard}} before{{cursor}}after \{{date}}"#,
            context: context
        )

        XCTAssertEqual(
            expansion.text,
            "2024-01-02 03:04 copied beforeafter {{date}}"
        )
        XCTAssertEqual(expansion.cursorOffsetFromEnd, "after {{date}}".count)

        let emojiExpansion = try ClipboardSnippetTemplateEngine.expand(
            "before{{cursor}}🙂",
            context: context
        )
        XCTAssertEqual(emojiExpansion.cursorOffsetFromEnd, 1)
        XCTAssertEqual(emojiExpansion.cursorUTF16OffsetFromEnd, 2)
    }

    func testTemplateExpansionRejectsUnknownAndMultipleCursorVariables() {
        let context = ClipboardSnippetExpansionContext(
            date: Date(timeIntervalSince1970: 0),
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            clipboardText: nil
        )

        XCTAssertThrowsError(try ClipboardSnippetTemplateEngine.expand("{{network}}", context: context)) {
            XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .unknownMacro("network"))
        }
        XCTAssertThrowsError(
            try ClipboardSnippetTemplateEngine.expand("{{cursor}}x{{cursor}}", context: context)
        ) {
            XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .multipleCursorMarkers)
        }
    }

    func testSavedStoreRoundTripsIndependentlyFromHistoryTable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let keyStore = SavedLibraryTestKeyStore()
        let historyStore = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let savedStore = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let historyItem = ClipboardHistoryItem(
            id: UUID(),
            text: "temporary",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let savedItem = ClipboardSavedItem(
            title: "Durable",
            tags: ["work", "Work"],
            keyword: ";durable",
            savedKind: .snippet,
            payload: .plainText("Hello {{date}}"),
            templateText: "Hello {{date}}"
        )

        try historyStore.save([historyItem])
        try savedStore.save(savedItem, payloadChanged: true)
        try historyStore.save([])

        XCTAssertTrue(try historyStore.load().isEmpty)
        let loaded = try savedStore.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Durable")
        XCTAssertEqual(loaded[0].tags, ["work"])
        XCTAssertEqual(loaded[0].keyword, ";durable")
        XCTAssertEqual(try loaded[0].loadPayload().plainText, "Hello {{date}}")
    }

    func testSavedStoreClearDoesNotDeleteHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryClearTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let keyStore = SavedLibraryTestKeyStore()
        let historyStore = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let savedStore = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        try historyStore.save([
            ClipboardHistoryItem(
                id: UUID(),
                text: "history",
                capturedAt: Date(),
                sourceApplication: nil,
                isPinned: false,
                lastUsedAt: nil
            ),
        ])
        try savedStore.save(
            ClipboardSavedItem(
                title: "Saved",
                savedKind: .snippet,
                payload: .plainText("saved"),
                templateText: "saved"
            ),
            payloadChanged: true
        )

        try savedStore.removeAll()

        XCTAssertEqual(try historyStore.load().map(\.text), ["history"])
        XCTAssertTrue(try savedStore.load().isEmpty)
    }

    @MainActor
    func testControllerRejectsDuplicateAndWhitespaceKeywords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryKeywordTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(
            pasteboard: pasteboard,
            persistence: IncrementalEncryptedClipboardSavedLibraryStore(
                databaseURL: directory.appendingPathComponent("clipboard.sqlite3"),
                keyStore: SavedLibraryTestKeyStore()
            )
        )
        await startSavedLibrary(controller)

        let first = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Signature",
            content: "Regards",
            tags: [],
            keyword: ";sig",
        ))
        XCTAssertNotNil(first)
        let duplicate = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Duplicate",
            content: "Hello",
            tags: [],
            keyword: ";SIG",
        ))
        XCTAssertNil(duplicate)
        XCTAssertTrue(controller.errorMessage?.contains("already assigned") == true)

        let invalid = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Invalid",
            content: "Hello",
            tags: [],
            keyword: "two words",
        ))
        XCTAssertNil(invalid)
        XCTAssertTrue(controller.errorMessage?.contains("spaces") == true)
    }

    @MainActor
    func testSnippetSizeLimitRejectsInsteadOfTruncating() async {
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: SlowSavedLibraryTestStore(saveDelay: 0)
        )
        await startSavedLibrary(controller)
        let oversized = String(
            repeating: "a",
            count: ClipboardSavedItem.maximumSnippetUTF8ByteCount + 1
        )

        let result = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Too large",
            content: oversized,
            tags: [],
            keyword: nil,
        ))

        XCTAssertNil(result)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertNotNil(controller.errorMessage)
    }

    @MainActor
    func testUsingSavedItemMovesItToTheTopAfterUsageIsPersisted() async throws {
        let older = ClipboardSavedItem(
            title: "Older",
            savedKind: .snippet,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            payload: .plainText("older"),
            templateText: "older"
        )
        let newer = ClipboardSavedItem(
            title: "Newer",
            savedKind: .snippet,
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2),
            payload: .plainText("newer"),
            templateText: "newer"
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: SlowSavedLibraryTestStore(
                saveDelay: 0,
                initialItems: [newer, older]
            )
        )
        await startSavedLibrary(controller)
        XCTAssertEqual(controller.items.first?.id, newer.id)

        _ = await controller.copy(id: older.id)

        for _ in 0..<200 where controller.items.first?.id != older.id {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(controller.items.first?.id, older.id)
    }

    @MainActor
    func testSnippetLoadFailureHasRetryableStateAndRecovers() async {
        let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText("body"), templateText: "body")
        let store = SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [snippet])
        store.failOperations(load: true)
        let controller = ClipboardSavedLibraryController(pasteboard: SavedLibraryTestPasteboard(),
            persistence: store, errorMessageProvider: { _ in "Storage unavailable" })
        await startSavedLibrary(controller)
        XCTAssertEqual(controller.fatalErrorMessage, "Storage unavailable")
        XCTAssertTrue(controller.items.isEmpty)

        store.failOperations(load: false)
        controller.retryLoading()
        XCTAssertFalse(controller.isLoaded)
        await waitForSavedLibraryLoad(controller)
        XCTAssertNil(controller.fatalErrorMessage)
        XCTAssertEqual(controller.items.map(\.id), [snippet.id])
        controller.stop()
    }

    @MainActor
    func testFailedSnippetDeleteKeepsItemAndRetryClearsError() async {
        let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText("body"), templateText: "body")
        let store = SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [snippet])
        let controller = ClipboardSavedLibraryController(pasteboard: SavedLibraryTestPasteboard(),
            persistence: store, errorMessageProvider: { _ in "Could not delete" })
        await startSavedLibrary(controller)
        store.failOperations(delete: true)
        let failed = await controller.delete(id: snippet.id)
        XCTAssertFalse(failed)
        XCTAssertEqual(controller.errorMessage, "Could not delete")
        XCTAssertEqual(controller.items.map(\.id), [snippet.id])
        XCTAssertEqual(store.persistedItems.map(\.id), [snippet.id])
        XCTAssertNil(controller.fatalErrorMessage)

        store.failOperations(delete: false)
        let deleted = await controller.delete(id: snippet.id)
        XCTAssertTrue(deleted)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.items.isEmpty)
        controller.stop()
    }

    func testLastUsedUpdateCannotReinsertADeletedSavedRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryLastUsedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: directory.appendingPathComponent("clipboard.sqlite3"),
            keyStore: SavedLibraryTestKeyStore()
        )
        let item = ClipboardSavedItem(
            title: "Delete me",
            savedKind: .clip,
            payload: .plainText("Delete me")
        )
        try store.save(item, payloadChanged: true)
        try store.delete(id: item.id)

        try store.updateLastUsedAt(id: item.id, date: Date())

        XCTAssertTrue(try store.load().isEmpty)
    }

}

private final class SavedLibraryTestKeyStore: ClipboardHistoryKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func loadKey() throws -> Data? { lock.withLock { key } }
    func saveKey(_ data: Data) throws { lock.withLock { key = data } }
    func deleteKey() throws { lock.withLock { key = nil } }
}

private final class SlowSavedLibraryTestStore: ClipboardSavedLibraryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let saveDelay: TimeInterval
    private let loadDelay: TimeInterval
    private let lastUsedDelay: TimeInterval
    private let payloadLoadDelay: TimeInterval
    private let failLoadWhileNonempty: Bool
    private let failPayloadLoads: Bool
    private let lastUsedGate: SavedLibraryTestGate?
    private var items: [ClipboardSavedItem]
    private var payloads: [UUID: ClipboardHistoryPayload]
    private var failsLoad = false
    private var failsDelete = false

    func failOperations(load: Bool? = nil, delete: Bool? = nil) {
        lock.withLock {
            if let load { failsLoad = load }
            if let delete { failsDelete = delete }
        }
    }

    var persistedItems: [ClipboardSavedItem] { lock.withLock { items } }
    var loadPayloadCount: Int { lock.withLock { storedLoadPayloadCount } }
    var maximumConcurrentPayloadLoadCount: Int {
        lock.withLock { storedMaximumConcurrentPayloadLoadCount }
    }
    var lastUsedUpdateCount: Int { lock.withLock { storedLastUsedUpdateCount } }
    var operationLog: [String] { lock.withLock { storedOperationLog } }
    private var storedLoadPayloadCount = 0
    private var activePayloadLoadCount = 0
    private var storedMaximumConcurrentPayloadLoadCount = 0
    private var storedLastUsedUpdateCount = 0
    private var storedOperationLog: [String] = []

    init(
        saveDelay: TimeInterval,
        loadDelay: TimeInterval = 0,
        lastUsedDelay: TimeInterval = 0,
        payloadLoadDelay: TimeInterval = 0,
        initialItems: [ClipboardSavedItem] = [],
        failLoadWhileNonempty: Bool = false,
        failPayloadLoads: Bool = false,
        lastUsedGate: SavedLibraryTestGate? = nil
    ) {
        self.saveDelay = saveDelay
        self.loadDelay = loadDelay
        self.lastUsedDelay = lastUsedDelay
        self.payloadLoadDelay = payloadLoadDelay
        self.failLoadWhileNonempty = failLoadWhileNonempty
        self.failPayloadLoads = failPayloadLoads
        self.lastUsedGate = lastUsedGate
        items = initialItems
        payloads = Dictionary(uniqueKeysWithValues: initialItems.compactMap { item in
            try? (item.id, item.loadPayload())
        })
    }

    func prepare() throws {}
    func load() throws -> [ClipboardSavedItem] {
        Thread.sleep(forTimeInterval: loadDelay)
        return try lock.withLock {
            if failsLoad || (failLoadWhileNonempty && !items.isEmpty) {
                throw ClipboardHistoryStoreError.invalidEnvelope
            }
            return items.map { $0.reloadingPayload(using: self) }
        }
    }

    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {
        lock.withLock { storedOperationLog.append("save:\(item.id.uuidString)") }
        Thread.sleep(forTimeInterval: saveDelay)
        let payload = payloadChanged || lock.withLock({ payloads[item.id] == nil })
            ? try item.loadPayload()
            : nil
        lock.withLock {
            if let payload { payloads[item.id] = payload }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        }
    }

    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload {
        let payload = lock.withLock { () -> ClipboardHistoryPayload? in
            storedLoadPayloadCount += 1
            activePayloadLoadCount += 1
            storedMaximumConcurrentPayloadLoadCount = max(
                storedMaximumConcurrentPayloadLoadCount,
                activePayloadLoadCount
            )
            return payloads[id]
        }
        defer { lock.withLock { activePayloadLoadCount -= 1 } }
        Thread.sleep(forTimeInterval: payloadLoadDelay)
        if failPayloadLoads {
            throw ClipboardHistoryPayloadAccessError.unavailable
        }
        guard let payload else {
            throw ClipboardHistoryPayloadAccessError.unavailable
        }
        return payload
    }

    func updateLastUsedAt(id: UUID, date: Date) throws {
        lock.withLock {
            storedLastUsedUpdateCount += 1
            storedOperationLog.append("usage:\(id.uuidString)")
        }
        lastUsedGate?.wait()
        Thread.sleep(forTimeInterval: lastUsedDelay)
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].lastUsedAt = date
        }
    }

    func delete(id: UUID) throws {
        try lock.withLock {
            if failsDelete { throw ClipboardHistoryStoreError.unavailableStorage }
            items.removeAll { $0.id == id }
            payloads.removeValue(forKey: id)
        }
    }
    func removeAll() throws {
        lock.withLock {
            items.removeAll()
            payloads.removeAll()
        }
    }
}

private final class SavedLibraryTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    var hasEntered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        entered = true
        let deadline = Date().addingTimeInterval(5)
        while !isOpen {
            if !condition.wait(until: deadline) { break }
        }
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private func startSavedLibrary(_ controller: ClipboardSavedLibraryController) async {
    controller.start()
    await waitForSavedLibraryLoad(controller)
}

@MainActor
private func waitForSavedLibraryLoad(_ controller: ClipboardSavedLibraryController) async {
    while !controller.isLoaded {
        await Task.yield()
    }
}

@MainActor
private final class SavedLibraryTestPasteboard: ClipboardPasteboardAccess {
    var changeCount = 0
    var typeNames: Set<String> = []
    var text: String?
    var payload: ClipboardHistoryPayload?
    private(set) var plainTextReadCount = 0
    private(set) var asynchronousPlainTextReadCount = 0
    var onAsynchronousPlainTextRead: (@MainActor () async -> ClipboardPasteboardReadResult)?

    func readPlainText() -> String? {
        plainTextReadCount += 1
        return text
    }

    func readPlainTextAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        asynchronousPlainTextReadCount += 1
        if let onAsynchronousPlainTextRead { return await onAsynchronousPlainTextRead() }
        guard changeCount == expectedChangeCount else { return .changed }
        guard let text else { return .empty }
        guard text.utf8.count <= maximumByteCount else { return .oversized }
        return .payload(.plainText(text))
    }

    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult {
        guard let payload else { return .empty }
        return payload.byteCount <= maximumByteCount ? .payload(payload) : .oversized
    }

    func writePlainText(_ text: String) -> Bool {
        writePayload(.plainText(text))
    }

    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool {
        self.payload = payload
        text = payload.plainText
        typeNames = Set(payload.representations.map(\.typeIdentifier))
        changeCount += 1
        return true
    }
}
