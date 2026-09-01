import AppKit
import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardSavedLibraryTests: XCTestCase {
    func testCachedHistoryPresentationTracksMetadataWithoutChangingOlderCopies() {
        let original = ClipboardSavedItem(title: "Original", savedKind: .snippet,
            payload: .plainText("first body"), templateText: "first body")
        let firstPresentation = original.historyPresentationItem()
        var edited = original
        let editedAt = original.updatedAt.addingTimeInterval(10)
        edited.updateMetadata(title: "Edited", tags: ["changed"], keyword: ";edited", templateText: "second body https://example.com", updatedAt: editedAt)
        edited.lastUsedAt = editedAt.addingTimeInterval(1)

        XCTAssertEqual(original.historyPresentationItem(), firstPresentation)
        XCTAssertEqual(edited.historyPresentationItem().text, "second body https://example.com")
        XCTAssertEqual(edited.historyPresentationItem().capturedAt, editedAt)
        XCTAssertEqual(edited.historyPresentationItem().lastUsedAt, edited.lastUsedAt)
        XCTAssertTrue(edited.historyPresentationItem().semanticTraits.contains(.link))
        XCTAssertTrue(ClipboardHistorySearch.matches(index: edited.searchIndex, query: "changed"))
        XCTAssertFalse(ClipboardHistorySearch.matches(index: original.searchIndex, query: "changed"))
    }

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
    func testClipboardVariableReadsBoundedSnapshotAsynchronously() async {
        let template = "Hello {{clipboard}}"
        let item = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText(template), templateText: template)
        let board = SavedLibraryTestPasteboard()
        board.text = "Ada"
        let controller = ClipboardSavedLibraryController(pasteboard: board,
            persistence: SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [item]))
        await startSavedLibrary(controller)
        let result = await controller.copy(id: item.id)
        XCTAssertEqual(result?.text, "Hello Ada")
        XCTAssertEqual(board.plainTextReadCount, 0)
        XCTAssertEqual(board.asynchronousPlainTextReadCount, 1)

        board.text = "oversized clipboard"
        controller.maximumExpandedTextByteCount = { 3 }
        let previousVersion = board.changeCount
        let rejected = await controller.copy(id: item.id)
        XCTAssertNil(rejected)
        XCTAssertEqual(board.changeCount, previousVersion)
        XCTAssertNotNil(controller.errorMessage)
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

    @MainActor
    func testStopDuringSnippetValidationCannotRecreateUninstalledStorage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardUninstallRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let keyStore = SavedLibraryTestKeyStore()
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: IncrementalEncryptedClipboardSavedLibraryStore(
                databaseURL: databaseURL, keyStore: keyStore
            )
        )
        await startSavedLibrary(controller)
        var validating = false
        controller.maximumExpandedTextByteCount = {
            validating = true
            return 5 * 1024 * 1024
        }
        let pending = Task { @MainActor in
            await controller.saveSnippet(ClipboardSnippetDraft(id: nil, title: "Pending",
                content: String(repeating: "private text ", count: 100_000),
                tags: [], keyword: nil))
        }
        while !validating { await Task.yield() }
        controller.stop(invalidatePersistence: true)
        try FileManager.default.removeItem(at: directory)
        try keyStore.deleteKey()
        let saved = await pending.value
        XCTAssertNil(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertNil(try keyStore.loadKey())
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testStopAndRestartRejectsQueuedMutationsFromPreviousLifecycle() async {
        let store = SlowSavedLibraryTestStore(saveDelay: 0)
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(), persistence: store)
        await startSavedLibrary(controller)
        var validating = false
        controller.maximumExpandedTextByteCount = {
            validating = true
            return 5 * 1024 * 1024
        }
        let draft = ClipboardSnippetDraft(id: nil, title: "Old lifecycle",
            content: String(repeating: "text ", count: 200_000),
            tags: [], keyword: nil)
        let first = Task { @MainActor in await controller.saveSnippet(draft) }
        while !validating { await Task.yield() }
        var queued = false
        let second = Task { @MainActor in
            queued = true
            return await controller.saveSnippet(draft)
        }
        while !queued { await Task.yield() }
        controller.stop()
        controller.start()
        let oldResults = await [first.value, second.value]
        XCTAssertTrue(oldResults.allSatisfy { $0 == nil })
        XCTAssertTrue(store.persistedItems.isEmpty)
        await waitForSavedLibraryLoad(controller)
        let fresh = await controller.saveSnippet(ClipboardSnippetDraft(id: nil,
            title: "New lifecycle", content: "fresh", tags: [], keyword: nil))
        XCTAssertNotNil(fresh)
        XCTAssertEqual(store.persistedItems.map(\.title), ["New lifecycle"])
        controller.stop()
    }

    func testInvalidatedSavedStoreCannotRecreateDatabaseOrKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardRetiredStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let keyStore = SavedLibraryTestKeyStore()
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let store = IncrementalEncryptedClipboardSavedLibraryStore(databaseURL: databaseURL, keyStore: keyStore)
        let item = ClipboardSavedItem(title: "Snippet", savedKind: .snippet, payload: .plainText("body"))
        try store.save(item, payloadChanged: true)
        let lazyItem = try XCTUnwrap(store.load().first)
        store.invalidate()
        try FileManager.default.removeItem(at: directory)
        try keyStore.deleteKey()

        try store.prepare()
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertThrowsError(try store.save(item, payloadChanged: true))
        XCTAssertThrowsError(try store.updateLastUsedAt(id: item.id, date: Date()))
        XCTAssertThrowsError(try lazyItem.loadPayload())
        try store.delete(id: item.id)
        try store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertNil(try keyStore.loadKey())
    }

    @MainActor
    func testSnippetPasteReceiptReturnsBeforeUsageMetadataAndKeepsWriteVersion() async throws {
        let item = ClipboardSavedItem(title: "Snippet", savedKind: .snippet,
                                      payload: .plainText("expanded text"), templateText: "expanded text")
        let secondItem = ClipboardSavedItem(title: "Second", savedKind: .snippet,
                                            payload: .plainText("second text"), templateText: "second text")
        let gate = SavedLibraryTestGate()
        defer { gate.open() }
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            initialItems: [item, secondItem],
            lastUsedGate: gate
        )
        let pasteboard = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(pasteboard: pasteboard, persistence: store)
        await startSavedLibrary(controller)
        let result = await controller.copyForPaste(id: item.id)
        let receipt = try XCTUnwrap(result)
        let writtenVersion = pasteboard.changeCount
        XCTAssertFalse(gate.hasEntered)
        XCTAssertEqual(receipt.pasteboardVersion, writtenVersion)
        XCTAssertEqual(receipt.expansion.text, "expanded text")

        controller.recordSuccessfulUse(id: item.id)
        while !gate.hasEntered { await Task.yield() }
        XCTAssertEqual(pasteboard.text, "expanded text")

        let nextCopy = Task { @MainActor in
            await controller.copyForPaste(id: secondItem.id)
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while pasteboard.text != "second text", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let nextCopyDidNotWaitForMetadata = pasteboard.text == "second text"
        if !nextCopyDidNotWaitForMetadata { gate.open() }
        let nextReceipt = await nextCopy.value
        XCTAssertTrue(nextCopyDidNotWaitForMetadata)
        XCTAssertEqual(nextReceipt?.expansion.text, "second text")

        _ = pasteboard.writePlainText("external copy")
        gate.open()
        for _ in 0..<200 where controller.items.first?.lastUsedAt == nil {
            await Task.yield()
        }

        XCTAssertNotNil(controller.items.first?.lastUsedAt)
        XCTAssertNotEqual(receipt.pasteboardVersion, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.text, "external copy")
        controller.stop()
    }

    @MainActor
    func testRapidUsageUpdatesCoalesceWhilePersistenceIsBusy() async throws {
        let item = ClipboardSavedItem(
            title: "Snippet",
            savedKind: .snippet,
            payload: .plainText("expanded text"),
            templateText: "expanded text"
        )
        let gate = SavedLibraryTestGate()
        defer { gate.open() }
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            initialItems: [item],
            lastUsedGate: gate
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )
        await startSavedLibrary(controller)
        let first = Date(timeIntervalSince1970: 10)
        let second = Date(timeIntervalSince1970: 20)
        let latest = Date(timeIntervalSince1970: 30)

        controller.recordSuccessfulUse(id: item.id, at: first)
        while !gate.hasEntered { await Task.yield() }
        controller.recordSuccessfulUse(id: item.id, at: second)
        controller.recordSuccessfulUse(id: item.id, at: latest)
        XCTAssertEqual(store.lastUsedUpdateCount, 1)
        gate.open()
        for _ in 0..<200 where controller.items.first?.lastUsedAt != latest {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(controller.items.first?.lastUsedAt, latest)
        XCTAssertEqual(store.persistedItems.first?.lastUsedAt, latest)
        XCTAssertEqual(store.lastUsedUpdateCount, 2)
        controller.stop()
    }

    @MainActor
    func testBatchSuccessfulUseDeduplicatesIDsAndReturnsBeforePersistence() async throws {
        let first = ClipboardSavedItem(
            title: "First",
            savedKind: .snippet,
            payload: .plainText("first"),
            templateText: "first"
        )
        let second = ClipboardSavedItem(
            title: "Second",
            savedKind: .snippet,
            payload: .plainText("second"),
            templateText: "second"
        )
        let gate = SavedLibraryTestGate()
        defer { gate.open() }
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            initialItems: [first, second],
            lastUsedGate: gate
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )
        await startSavedLibrary(controller)
        let usageDate = Date(timeIntervalSince1970: 2_000)

        controller.recordSuccessfulUse(
            ids: [first.id, first.id, UUID(), second.id],
            at: usageDate
        )
        while !gate.hasEntered { await Task.yield() }

        XCTAssertEqual(store.lastUsedUpdateCount, 1)
        XCTAssertNil(controller.items.first(where: { $0.id == first.id })?.lastUsedAt)
        XCTAssertNil(controller.items.first(where: { $0.id == second.id })?.lastUsedAt)

        gate.open()
        for _ in 0..<200 where controller.items.filter({ $0.lastUsedAt == usageDate }).count != 2 {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(store.lastUsedUpdateCount, 2)
        XCTAssertEqual(
            Set(store.persistedItems.compactMap { $0.lastUsedAt == usageDate ? $0.id : nil }),
            [first.id, second.id]
        )
        controller.stop()
    }

    @MainActor
    func testLargeSuccessfulUseBatchDoesNotBacklogFollowingSnippetSave() async throws {
        let snippets = (0..<500).map { index in
            ClipboardSavedItem(
                title: "Snippet \(index)",
                savedKind: .snippet,
                payload: .plainText("body \(index)"),
                templateText: "body \(index)"
            )
        }
        let gate = SavedLibraryTestGate()
        defer { gate.open() }
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            initialItems: snippets,
            lastUsedGate: gate
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )
        await startSavedLibrary(controller)
        let usageDate = Date(timeIntervalSince1970: 3_000)

        controller.recordSuccessfulUse(
            ids: snippets.map(\.id) + [snippets[0].id, UUID()],
            at: usageDate
        )
        while !gate.hasEntered { await Task.yield() }

        XCTAssertEqual(controller.usageUpdateTaskCountForTesting, 1)
        XCTAssertEqual(controller.pendingUsageUpdateCountForTesting, snippets.count)
        XCTAssertEqual(store.lastUsedUpdateCount, 1)

        var saveReachedWorker = false
        controller.persistenceSaveCheckpointForTesting = { saveReachedWorker = true }
        let editedID = snippets.last!.id
        let edit = Task { @MainActor in
            await controller.saveSnippet(ClipboardSnippetDraft(
                id: editedID,
                title: "Edited",
                content: "edited body",
                tags: [],
                keyword: nil
            ))
        }
        while !saveReachedWorker { await Task.yield() }
        gate.open()

        let editResult = await edit.value
        let edited = try XCTUnwrap(editResult)
        XCTAssertEqual(edited.title, "Edited")
        XCTAssertGreaterThanOrEqual(store.operationLog.count, 2)
        XCTAssertTrue(store.operationLog[0].hasPrefix("usage:"))
        XCTAssertEqual(store.operationLog[1], "save:\(editedID.uuidString)")
        XCTAssertEqual(controller.usageUpdateTaskCountForTesting, 1)
        controller.stop()
    }

    @MainActor
    func testConcurrentSnippetEditPreservesPersistedUsageDate() async throws {
        let item = ClipboardSavedItem(
            title: "Original",
            savedKind: .snippet,
            payload: .plainText("original body"),
            templateText: "original body"
        )
        let gate = SavedLibraryTestGate()
        defer { gate.open() }
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            initialItems: [item],
            lastUsedGate: gate
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )
        await startSavedLibrary(controller)
        let usageDate = Date(timeIntervalSince1970: 1_000)

        controller.recordSuccessfulUse(id: item.id, at: usageDate)
        while !gate.hasEntered { await Task.yield() }
        let edit = Task { @MainActor in
            await controller.saveSnippet(ClipboardSnippetDraft(
                id: item.id,
                title: "Edited",
                content: "edited body",
                tags: ["updated"],
                keyword: ";edited"
            ))
        }
        for _ in 0..<20 { await Task.yield() }
        gate.open()

        let editResult = await edit.value
        let edited = try XCTUnwrap(editResult)
        XCTAssertEqual(edited.title, "Edited")
        XCTAssertEqual(edited.lastUsedAt, usageDate, "edited result must preserve usage")
        let persisted = try XCTUnwrap(store.persistedItems.first)
        XCTAssertEqual(persisted.title, "Edited")
        XCTAssertEqual(persisted.tags, ["updated"])
        XCTAssertEqual(persisted.keyword, ";edited")
        XCTAssertEqual(persisted.lastUsedAt, usageDate, "persisted item must preserve usage")
        controller.stop()
    }

    func testSnippetVariableInsertionUsesAndReplacesTheCurrentSelection() {
        let inserted = ClipboardSnippetEditorInsertion.insert(
            "{{date}}",
            into: "Hello world",
            selectedRange: NSRange(location: 6, length: 5)
        )

        XCTAssertEqual(inserted.text, "Hello {{date}}")
        XCTAssertEqual(inserted.selectedRange, NSRange(location: 14, length: 0))
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

    func testKeywordMatcherExpandsImmediatelyUnlessKeywordIsAmbiguous() {
        let shortID = UUID()
        let longID = UUID()
        var matcher = ClipboardSnippetKeywordMatcher(
            snippetsByKeyword: [";b": shortID, ";bb": longID]
        )

        XCTAssertNil(matcher.consume(text: ";", keyCode: 41, modifiers: []))
        XCTAssertNil(matcher.consume(text: "b", keyCode: 11, modifiers: []))
        let match = matcher.consume(text: "b", keyCode: 11, modifiers: [])
        XCTAssertEqual(
            match,
            ClipboardSnippetKeywordMatch(itemID: longID, keyword: ";bb", delimiter: "")
        )
        XCTAssertEqual(match?.deliveredText, ";bb")
    }

    func testDelimiterMatchValidatesTheAlreadyDeliveredDelimiterAlongWithKeyword() {
        let itemID = UUID()
        let match = ClipboardSnippetKeywordMatch(
            itemID: itemID,
            keyword: ";bb",
            delimiter: " "
        )

        XCTAssertEqual(match.deliveredText, ";bb ")
        let context = ClipboardSnippetReplacementContext(selectionLocation: 4, selectionLength: 0,
            keywordLocation: 0, keywordLength: 4, keyword: match.deliveredText)
        XCTAssertTrue(context.isValid(selection: CFRange(location: 4, length: 0), keywordText: ";bb "))
        XCTAssertFalse(context.isValid(selection: CFRange(location: 3, length: 0), keywordText: ";bb"))
    }

    func testTextElementClassificationAcceptsOrdinaryTextAreasWithoutSubrole() {
        XCTAssertEqual(
            ClipboardSnippetTextElementClassification.classify(
                role: kAXTextAreaRole as String,
                subrole: nil
            ),
            .nonSecure
        )
        XCTAssertEqual(
            ClipboardSnippetTextElementClassification.classify(
                role: kAXTextFieldRole as String,
                subrole: "AXSecureTextField"
            ),
            .secure
        )
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

    func testKeywordInputStateRevalidatesFocusAndUsesPassiveTap() {
        var state = ClipboardSnippetKeywordInputState()
        let itemID = UUID()
        state.snippetsByKeyword = [";bb": itemID]
        var classificationCount = 0
        var match: ClipboardSnippetKeywordMatch?
        for character in ";bb" {
            match = state.consume(
                text: String(character),
                keyCode: 0,
                modifiers: [],
                processIdentifier: 42,
                classifyEditor: { _ in
                    classificationCount += 1
                    return .nonSecure
                }
            ) ?? match
        }
        XCTAssertEqual(match?.itemID, itemID)
        XCTAssertEqual(classificationCount, 3)
        XCTAssertEqual(
            ClipboardSnippetKeywordExpander.eventTapOptionsForTesting.rawValue,
            CGEventTapOptions.listenOnly.rawValue
        )
    }

    func testKeywordInputStateStopsBufferingWhenFocusMovesToSecureFieldInSameApp() {
        var state = ClipboardSnippetKeywordInputState()
        state.snippetsByKeyword = [";bb": UUID()]
        var classifications: [ClipboardSnippetSecureTextClassification] = [
            .nonSecure, .secure, .secure,
        ]

        for character in ";bb" {
            XCTAssertNil(state.consume(
                text: String(character),
                keyCode: 0,
                modifiers: [],
                processIdentifier: 42,
                classifyEditor: { _ in classifications.removeFirst() }
            ))
        }

        XCTAssertEqual(state.bufferedTextForTesting, "")
    }

    func testKeywordMatcherRemainsResponsiveWithTenThousandKeywords() {
        let itemID = UUID()
        var keywords = Dictionary(uniqueKeysWithValues: (0..<10_000).map {
            (";snippet\($0)", UUID())
        })
        keywords[";bb"] = itemID
        var matcher = ClipboardSnippetKeywordMatcher(snippetsByKeyword: keywords)

        measure(metrics: [XCTClockMetric()]) {
            matcher.reset()
            var match: ClipboardSnippetKeywordMatch?
            for character in ";bb" {
                match = matcher.consume(text: String(character), keyCode: 0, modifiers: []) ?? match
            }
            XCTAssertEqual(match?.itemID, itemID)
        }
    }

    func testKeywordMatcherHandlesBackspaceAndCommandBoundaries() {
        let itemID = UUID()
        var matcher = ClipboardSnippetKeywordMatcher(snippetsByKeyword: [
            ";date": itemID,
            ";date-extra": UUID(),
        ])
        for character in ";datex" {
            _ = matcher.consume(text: String(character), keyCode: 0, modifiers: [])
        }
        _ = matcher.consume(text: "", keyCode: 51, modifiers: [])
        XCTAssertEqual(
            matcher.consume(text: "\n", keyCode: 36, modifiers: []),
            ClipboardSnippetKeywordMatch(itemID: itemID, keyword: ";date", delimiter: "\n")
        )

        for character in ";date" {
            _ = matcher.consume(text: String(character), keyCode: 0, modifiers: [])
        }
        XCTAssertNil(matcher.consume(text: "v", keyCode: 9, modifiers: .command))
        XCTAssertNil(matcher.consume(text: " ", keyCode: 49, modifiers: []))
    }

    func testKeywordMatcherWaitsWhenPunctuationContinuesALongerKeyword() {
        let shortID = UUID()
        let longID = UUID()
        var matcher = ClipboardSnippetKeywordMatcher(snippetsByKeyword: [
            ";date": shortID,
            ";date-extra": longID,
        ])

        for character in ";date" {
            XCTAssertNil(matcher.consume(text: String(character), keyCode: 0, modifiers: []))
        }
        XCTAssertNil(matcher.consume(text: "-", keyCode: 27, modifiers: []))

        var match: ClipboardSnippetKeywordMatch?
        for character in "extra" {
            match = matcher.consume(text: String(character), keyCode: 0, modifiers: []) ?? match
        }
        XCTAssertEqual(
            match,
            ClipboardSnippetKeywordMatch(itemID: longID, keyword: ";date-extra", delimiter: "")
        )
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
            clipboardText: "copied",
            uuid: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )

        let expansion = try ClipboardSnippetTemplateEngine.expand(
            #"{{date format="yyyy-MM-dd"}} {{time format="HH:mm"}} {{clipboard}} {{uuid}} before{{cursor}}after \{{date}}"#,
            context: context
        )

        XCTAssertEqual(
            expansion.text,
            "2024-01-02 03:04 copied AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE beforeafter {{date}}"
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
            clipboardText: nil,
            uuid: { UUID() }
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

    func testTemplateExpansionRejectsMalformedMacroSyntax() {
        let context = ClipboardSnippetExpansionContext.current(clipboardText: nil)
        for template in [
            "{{date",
            "date}}",
            "{{}}",
            "{{date format='yyyy'}}",
        ] {
            XCTAssertThrowsError(try ClipboardSnippetTemplateEngine.expand(template, context: context)) {
                XCTAssertEqual($0 as? ClipboardSnippetTemplateError, .invalidMacroSyntax)
            }
        }
        XCTAssertNoThrow(try ClipboardSnippetTemplateEngine.expand(#"\{{date}}"#, context: context))
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

    func testSavedStoreDeletesMultipleItemsInOneBatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryBatchDeleteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: directory.appendingPathComponent("clipboard.sqlite3"),
            keyStore: SavedLibraryTestKeyStore()
        )
        let first = ClipboardSavedItem(title: "First", savedKind: .snippet, payload: .plainText("First"))
        let second = ClipboardSavedItem(title: "Second", savedKind: .snippet, payload: .plainText("Second"))
        let retained = ClipboardSavedItem(title: "Retained", savedKind: .snippet, payload: .plainText("Retained"))
        for item in [first, second, retained] { try store.save(item, payloadChanged: true) }

        try store.delete(ids: [first.id, second.id])

        XCTAssertEqual(try store.load().map(\.id), [retained.id])
    }

    @MainActor
    func testSavedLibraryBatchDeleteRejectsAStaleTargetBeforeWriting() async {
        let first = ClipboardSavedItem(title: "First", savedKind: .snippet, payload: .plainText("First"))
        let second = ClipboardSavedItem(title: "Second", savedKind: .snippet, payload: .plainText("Second"))
        let store = SlowSavedLibraryTestStore(saveDelay: 0, initialItems: [first, second])
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )
        await startSavedLibrary(controller)

        let staleDelete = await controller.delete(ids: [first.id, UUID()])
        XCTAssertFalse(staleDelete)
        XCTAssertEqual(Set(controller.items.map(\.id)), [first.id, second.id])
        XCTAssertEqual(Set(store.persistedItems.map(\.id)), [first.id, second.id])

        let deleted = await controller.delete(ids: [first.id, second.id])
        XCTAssertTrue(deleted)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertTrue(store.persistedItems.isEmpty)
        controller.stop()
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
    func testUnreadableSavedLibraryCanBeClearedAndReloadedWithoutHistoryReset() async {
        let storedItem = ClipboardSavedItem(
            title: "corrupt row",
            savedKind: .clip,
            payload: .plainText("saved")
        )
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            initialItems: [storedItem],
            failLoadWhileNonempty: true
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store,
            errorMessageProvider: { _ in "Unreadable Saved Library" }
        )

        controller.start()
        await waitForSavedLibraryLoad(controller)
        XCTAssertEqual(controller.items, [])
        XCTAssertEqual(controller.fatalErrorMessage, "Unreadable Saved Library")

        let didClear = await controller.clearAll()
        XCTAssertTrue(didClear)
        controller.retryLoading()
        await waitForSavedLibraryLoad(controller)
        XCTAssertEqual(controller.items, [])
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.fatalErrorMessage)
        XCTAssertEqual(store.persistedItems, [])
    }

    func testSavedStorePersistsBoundedLiteralClipSearchText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibrarySearchTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let keyStore = SavedLibraryTestKeyStore()
        let store = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        try store.save(
            ClipboardSavedItem(
                title: "First line",
                savedKind: .clip,
                payload: .plainText("First line\nunique needle {{name}}")
            ),
            payloadChanged: true
        )

        let reloadedStore = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let reloaded = try XCTUnwrap(try reloadedStore.load().first)
        XCTAssertTrue(reloaded.searchableText.contains("unique needle"))
        XCTAssertTrue(reloaded.searchableText.contains("{{name}}"))
        XCTAssertNil(reloaded.templateText)
    }

    func testSavedStorePreservesCompleteSnippetBeyondSearchIndexLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryLongSnippetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let keyStore = SavedLibraryTestKeyStore()
        let store = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let content = String(
            repeating: "a",
            count: ClipboardHistoryItem.maximumSearchableCharacterCount + 256
        ) + "{{cursor}}tail"
        try store.save(
            ClipboardSavedItem(
                title: "Long snippet",
                savedKind: .snippet,
                payload: .plainText(content),
                templateText: content
            ),
            payloadChanged: true
        )

        let reloaded = try XCTUnwrap(try store.load().first)
        XCTAssertNil(reloaded.templateText)
        XCTAssertEqual(
            reloaded.templateSearchText,
            String(content.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount))
        )
        XCTAssertTrue(reloaded.hasDynamicTemplateContent)
        XCTAssertFalse(reloaded.isPayloadCachedForTesting)
        XCTAssertEqual(try reloaded.loadPayload().plainText, content)
        XCTAssertFalse(reloaded.searchableText.contains("{{cursor}}tail"))
    }

    @MainActor
    func testKeywordTemplateCacheLoadsCompleteBodyFromLazyPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryKeywordCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("clipboard.sqlite3")
        let keyStore = SavedLibraryTestKeyStore()
        let store = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let content = String(
            repeating: "a",
            count: ClipboardHistoryItem.maximumSearchableCharacterCount + 256
        ) + "{{cursor}}tail"
        let item = ClipboardSavedItem(
            title: "Keyword snippet",
            keyword: ";long",
            savedKind: .snippet,
            payload: .plainText(content),
            templateText: content
        )
        try store.save(item, payloadChanged: true)
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )

        await startSavedLibrary(controller)
        for _ in 0..<200 where controller.templateForKeywordExpansion(id: item.id) == nil {
            await Task.yield()
        }

        XCTAssertNil(controller.items.first?.templateText)
        XCTAssertEqual(controller.templateForKeywordExpansion(id: item.id), content)
        XCTAssertFalse(try XCTUnwrap(controller.items.first).isPayloadCachedForTesting)
        controller.stop()
        XCTAssertNil(controller.templateForKeywordExpansion(id: item.id))
        controller.start()
        for _ in 0..<200 where controller.templateForKeywordExpansion(id: item.id) == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(controller.templateForKeywordExpansion(id: item.id), content,
                       "Reactivation must rebuild the cleared cache without editing the snippet")
        controller.stop()
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
    func testEscapedOnlySnippetCopyMatchesTemplatePreview() async throws {
        let pasteboard = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(
            pasteboard: pasteboard,
            persistence: SlowSavedLibraryTestStore(saveDelay: 0)
        )
        await startSavedLibrary(controller)
        let savedResult = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Literal",
            content: #"\{{date}}"#,
            tags: [],
            keyword: nil,
        ))
        let saved = try XCTUnwrap(savedResult)

        let expansion = await controller.copy(id: saved.id)
        XCTAssertEqual(expansion?.text, "{{date}}")
        XCTAssertEqual(pasteboard.text, "{{date}}")
    }

    func testSavedPayloadReferenceCoalescesConcurrentFirstLoad() async throws {
        let original = ClipboardSavedItem(
            title: "Lazy",
            savedKind: .clip,
            payload: .plainText("payload")
        )
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            payloadLoadDelay: 0.08,
            initialItems: [original]
        )
        let lazyItem = original.reloadingPayload(using: store)

        async let first = lazyItem.loadPayloadAsync()
        async let second = lazyItem.loadPayloadAsync()
        let firstPayload = try await first
        let secondPayload = try await second
        XCTAssertEqual(firstPayload, .plainText("payload"))
        XCTAssertEqual(secondPayload, .plainText("payload"))
        XCTAssertEqual(store.loadPayloadCount, 1)
    }

    func testCancellingOneSavedPayloadWaiterDoesNotCancelOrRepeatSharedLoad() async throws {
        let original = ClipboardSavedItem(
            title: "Lazy",
            savedKind: .clip,
            payload: .plainText("payload")
        )
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            payloadLoadDelay: 0.2,
            initialItems: [original]
        )
        let lazyItem = original.reloadingPayload(using: store)
        let first = Task { try await lazyItem.loadPayloadAsync() }
        for _ in 0..<1_000 where store.loadPayloadCount == 0 { await Task.yield() }
        let cancelledWaiter = Task { try await lazyItem.loadPayloadAsync() }
        for _ in 0..<1_000 where lazyItem.waitingPayloadLoaderCountForTesting < 2 {
            await Task.yield()
        }

        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("A cancelled Saved payload waiter must finish with cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let firstPayload = try await first.value
        XCTAssertEqual(firstPayload, .plainText("payload"))
        XCTAssertEqual(store.loadPayloadCount, 1)
    }

    func testConcurrentSavedPayloadWaitersShareTheSameFailure() async {
        let original = ClipboardSavedItem(
            title: "Lazy",
            savedKind: .clip,
            payload: .plainText("payload")
        )
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            payloadLoadDelay: 0.08,
            initialItems: [original],
            failPayloadLoads: true
        )
        let lazyItem = original.reloadingPayload(using: store)
        let first = Task { () -> Result<ClipboardHistoryPayload, Error> in
            do { return .success(try await lazyItem.loadPayloadAsync()) }
            catch { return .failure(error) }
        }
        let second = Task { () -> Result<ClipboardHistoryPayload, Error> in
            do { return .success(try await lazyItem.loadPayloadAsync()) }
            catch { return .failure(error) }
        }

        let results = [await first.value, await second.value]
        XCTAssertTrue(results.allSatisfy { if case .failure = $0 { true } else { false } })
        XCTAssertEqual(store.loadPayloadCount, 1)
    }

    @MainActor
    func testSavedImagePreviewPipelineSerializesPayloadLoadingAndDecoding() async throws {
        let pngData = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: pngData
                ),
            ]),
        ])
        let originalItems = ["First", "Second"].map {
            ClipboardSavedItem(title: $0, savedKind: .clip, payload: payload)
        }
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            payloadLoadDelay: 0.08,
            initialItems: originalItems
        )
        let items = originalItems.map { $0.reloadingPayload(using: store) }

        async let first = ClipboardBoundedImagePreviewWork.image(for: items[0])
        async let second = ClipboardBoundedImagePreviewWork.image(for: items[1])
        _ = await (first, second)

        XCTAssertEqual(store.loadPayloadCount, 2)
        XCTAssertEqual(store.maximumConcurrentPayloadLoadCount, 1)
        XCTAssertFalse(items[0].isPayloadCachedForTesting)
        XCTAssertFalse(items[1].isPayloadCachedForTesting)
    }

    func testSavedSearchIsBoundedAndUsesPrecomputedIndex() {
        let items = (0..<200).map { index in
            ClipboardSavedItem(
                title: "Saved \(index)",
                tags: index.isMultiple(of: 2) ? ["needle"] : [],
                savedKind: .clip,
                payload: .plainText("payload \(index)")
            )
        }
        let result = ClipboardSavedLibrarySearch.result(items: items, query: "needle", limit: 25)

        XCTAssertEqual(result.items.count, 25)
        XCTAssertTrue(result.hasMore)
    }

    @MainActor
    func testConcurrentSnippetSavesReserveCaseInsensitiveKeyword() async throws {
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: SlowSavedLibraryTestStore(saveDelay: 0.08)
        )
        await startSavedLibrary(controller)
        let firstTask = Task { @MainActor in
            await controller.saveSnippet(ClipboardSnippetDraft(
                id: nil,
                title: "First",
                content: "first",
                tags: [],
                keyword: ";Sig",
            ))
        }
        await Task.yield()
        let second = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Second",
            content: "second",
            tags: [],
            keyword: ";sig",
        ))
        let first = await firstTask.value

        XCTAssertEqual(Set([first, second].compactMap { $0?.id }).count, 1)
        XCTAssertEqual(controller.items.count, 1)
        XCTAssertEqual(controller.items.first?.keyword?.lowercased(), ";sig")
    }

    @MainActor
    func testRepeatedNewSnippetSubmissionUsesStableDraftIdentity() async throws {
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: SlowSavedLibraryTestStore(saveDelay: 0.08)
        )
        await startSavedLibrary(controller)
        let draft = ClipboardSnippetDraft(
            id: UUID(),
            title: "One submission",
            content: "body",
            tags: [],
            keyword: nil,
            isNew: true
        )

        async let first = controller.saveSnippet(draft)
        async let second = controller.saveSnippet(draft)
        let results = await [first, second]

        XCTAssertEqual(Set(results.compactMap { $0?.id }), Set([try XCTUnwrap(draft.id)]))
        XCTAssertEqual(controller.items.count, 1)
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
    func testOversizedExpansionLeavesClipboardUntouchedAndCanRetryWithLargerLimit() async throws {
        let pasteboard = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(pasteboard: pasteboard,
            persistence: SlowSavedLibraryTestStore(saveDelay: 0))
        await startSavedLibrary(controller)
        let result = await controller.saveSnippet(ClipboardSnippetDraft(id: nil, title: "Repeated clipboard",
            content: "{{clipboard}}{{clipboard}}", tags: [], keyword: nil))
        let saved = try XCTUnwrap(result)
        controller.maximumExpandedTextByteCount = { 1_024 * 1_024 }
        let copiedText = String(repeating: "x", count: 1_024 * 1_024)
        pasteboard.text = copiedText
        let before = pasteboard.changeCount
        let rejected = await controller.copy(id: saved.id)
        XCTAssertNil(rejected)
        XCTAssertEqual(pasteboard.changeCount, before)
        XCTAssertEqual(pasteboard.text, copiedText)
        XCTAssertNotNil(controller.errorMessage)
        controller.maximumExpandedTextByteCount = { 5 * 1_024 * 1_024 }
        let accepted = await controller.copy(id: saved.id)
        XCTAssertEqual(accepted?.text, copiedText + copiedText)
        controller.stop()
    }

    @MainActor
    func testPreviewClipboardRefusesSensitiveProducerContent() async {
        let pasteboard = SavedLibraryTestPasteboard()
        pasteboard.text = "name"
        let text = await ClipboardSnippetPreviewClipboard.readText(from: pasteboard)
        XCTAssertEqual(text, "name")
        for type in ClipboardCapturePolicy.ignoredProducerTypes {
            pasteboard.typeNames = [type]
            let sensitiveText = await ClipboardSnippetPreviewClipboard.readText(from: pasteboard)
            XCTAssertNil(sensitiveText)
        }
    }

    @MainActor
    func testLongSnippetCopyAndEditDraftPreserveContentBeyondSearchIndexLimit() async throws {
        let pasteboard = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(
            pasteboard: pasteboard,
            persistence: SlowSavedLibraryTestStore(saveDelay: 0)
        )
        await startSavedLibrary(controller)
        let content = String(
            repeating: "a",
            count: ClipboardHistoryItem.maximumSearchableCharacterCount + 256
        ) + "{{cursor}}tail"

        let savedResult = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Long snippet",
            content: content,
            tags: [],
            keyword: nil,
        ))
        let saved = try XCTUnwrap(savedResult)
        let expansion = await controller.copy(id: saved.id)

        let reloadedDraft = await controller.draft(for: saved.id)
        XCTAssertEqual(reloadedDraft?.content, content)
        XCTAssertEqual(expansion?.text, String(repeating: "a", count: ClipboardHistoryItem.maximumSearchableCharacterCount + 256) + "tail")
        XCTAssertEqual(pasteboard.text, expansion?.text)
    }

    @MainActor
    func testLegacyBinarySavedClipIsDiscardedWithoutMutatingPasteboard() async throws {
        let imagePayload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                ),
            ]),
        ])
        let savedItem = ClipboardSavedItem(
            title: "Image",
            savedKind: .clip,
            payload: imagePayload
        )
        let pasteboard = SavedLibraryTestPasteboard()
        let controller = ClipboardSavedLibraryController(
            pasteboard: pasteboard,
            persistence: SlowSavedLibraryTestStore(
                saveDelay: 0,
                initialItems: [savedItem]
            )
        )
        await startSavedLibrary(controller)

        let result = await controller.copy(id: savedItem.id, asPlainText: true)

        XCTAssertNil(result)
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertEqual(pasteboard.changeCount, 0)
        XCTAssertNil(pasteboard.payload)
        XCTAssertNil(controller.errorMessage)
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

    @MainActor
    func testSavedPayloadFailureIsScopedToTheAffectedItem() async throws {
        let item = ClipboardSavedItem(
            title: "Unreadable item",
            savedKind: .snippet,
            payload: .plainText("payload"),
            templateText: "payload"
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: SlowSavedLibraryTestStore(
                saveDelay: 0,
                initialItems: [item],
                failPayloadLoads: true
            ),
            errorMessageProvider: { _ in "Could not decrypt this item" }
        )
        await startSavedLibrary(controller)

        let previewPayload = await controller.previewPayload(id: item.id)
        XCTAssertNil(previewPayload)
        XCTAssertEqual(
            controller.itemLoadErrorMessages[item.id],
            "Could not decrypt this item"
        )
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.fatalErrorMessage)
    }

    @MainActor
    func testLegacySavedClipsAreDiscardedWhenSnippetLibraryLoads() async throws {
        let existing = ClipboardSavedItem(
            title: "Already saved",
            savedKind: .clip,
            payload: .plainText("Already saved")
        )
        let store = SlowSavedLibraryTestStore(
            saveDelay: 0,
            loadDelay: 0.08,
            initialItems: [existing]
        )
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: store
        )

        controller.start()
        XCTAssertFalse(controller.isLoaded)
        await waitForSavedLibraryLoad(controller)

        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
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

    func testConcurrentFirstPreparationUsesOneEncryptionKeyForHistoryAndSavedItems() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardSavedLibraryConcurrentKeyTests-\(UUID().uuidString)")
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
        let errors = SavedLibraryTestErrorBox()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                if index == 0 {
                    try historyStore.prepare()
                } else {
                    try savedStore.prepare()
                }
            } catch {
                errors.append(error)
            }
        }
        XCTAssertTrue(errors.values.isEmpty, "Concurrent preparation failed: \(errors.values)")

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
                title: "saved",
                savedKind: .clip,
                payload: .plainText("saved")
            ),
            payloadChanged: true
        )

        let reloadedHistoryStore = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        let reloadedSavedStore = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: databaseURL,
            keyStore: keyStore
        )
        XCTAssertEqual(try reloadedHistoryStore.load().map(\.text), ["history"])
        XCTAssertEqual(try reloadedSavedStore.load().map(\.title), ["saved"])
    }
}

private final class SavedLibraryTestKeyStore: ClipboardHistoryKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func loadKey() throws -> Data? { lock.withLock { key } }
    func saveKey(_ data: Data) throws { lock.withLock { key = data } }
    func deleteKey() throws { lock.withLock { key = nil } }
}

private final class SavedLibraryTestErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Error] = []

    var values: [Error] { lock.withLock { storedValues } }
    func append(_ error: Error) { lock.withLock { storedValues.append(error) } }
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
