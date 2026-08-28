import AppKit
import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardSavedLibraryTests: XCTestCase {
    func testSnippetVariableInsertionUsesAndReplacesTheCurrentSelection() {
        let inserted = ClipboardSnippetEditorInsertion.insert(
            "{{date}}",
            into: "Hello world",
            selectedRange: NSRange(location: 6, length: 5)
        )

        XCTAssertEqual(inserted.text, "Hello {{date}}")
        XCTAssertEqual(inserted.selectedRange, NSRange(location: 14, length: 0))
    }

    func testSavedPreviewIsVisibleOnlyForItsOwningItem() {
        let ownerID = UUID()
        let otherID = UUID()
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let imageState = ClipboardSavedPreviewState(itemID: ownerID, image: image, text: nil)
        let textState = ClipboardSavedPreviewState(itemID: ownerID, image: nil, text: "body")

        XCTAssertTrue(imageState.image(for: ownerID) === image)
        XCTAssertNil(imageState.image(for: otherID))
        XCTAssertEqual(textState.text(for: ownerID), "body")
        XCTAssertNil(textState.text(for: otherID))
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
            isFavorite: true,
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
        XCTAssertTrue(loaded[0].isFavorite)
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
            isFavorite: false
        ))
        XCTAssertNotNil(first)
        let duplicate = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Duplicate",
            content: "Hello",
            tags: [],
            keyword: ";SIG",
            isFavorite: false
        ))
        XCTAssertNil(duplicate)
        XCTAssertTrue(controller.errorMessage?.contains("already assigned") == true)

        let invalid = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Invalid",
            content: "Hello",
            tags: [],
            keyword: "two words",
            isFavorite: false
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
            isFavorite: false
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
                isFavorite: false
            ))
        }
        await Task.yield()
        let second = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Second",
            content: "second",
            tags: [],
            keyword: ";sig",
            isFavorite: false
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
            isFavorite: false,
            isNew: true
        )

        async let first = controller.saveSnippet(draft)
        async let second = controller.saveSnippet(draft)
        let results = await [first, second]

        XCTAssertEqual(Set(results.compactMap { $0?.id }), Set([try XCTUnwrap(draft.id)]))
        XCTAssertEqual(controller.items.count, 1)
    }

    @MainActor
    func testSavedMutationsForOneItemAreSerialized() async throws {
        let controller = ClipboardSavedLibraryController(
            pasteboard: SavedLibraryTestPasteboard(),
            persistence: SlowSavedLibraryTestStore(saveDelay: 0.08)
        )
        await startSavedLibrary(controller)
        let savedResult = await controller.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Favorite",
            content: "body",
            tags: [],
            keyword: nil,
            isFavorite: false
        ))
        let saved = try XCTUnwrap(savedResult)

        async let first = controller.toggleFavorite(id: saved.id)
        async let second = controller.toggleFavorite(id: saved.id)
        let results = await [first, second]

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(controller.items.first?.isFavorite, false)
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
            isFavorite: false
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
            content: "{{clipboard}}{{clipboard}}", tags: [], keyword: nil, isFavorite: false))
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
    func testPreviewClipboardRefusesSensitiveProducerContent() {
        let pasteboard = SavedLibraryTestPasteboard()
        pasteboard.text = "name"
        XCTAssertEqual(ClipboardSnippetPreviewClipboard.readText(from: pasteboard), "name")
        for type in ClipboardCapturePolicy.ignoredProducerTypes {
            pasteboard.typeNames = [type]
            XCTAssertNil(ClipboardSnippetPreviewClipboard.readText(from: pasteboard))
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
            isFavorite: false
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

        XCTAssertEqual(controller.items.first?.id, older.id)
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
    private var items: [ClipboardSavedItem]
    private var payloads: [UUID: ClipboardHistoryPayload]

    var persistedItems: [ClipboardSavedItem] { lock.withLock { items } }
    var loadPayloadCount: Int { lock.withLock { storedLoadPayloadCount } }
    var maximumConcurrentPayloadLoadCount: Int {
        lock.withLock { storedMaximumConcurrentPayloadLoadCount }
    }
    private var storedLoadPayloadCount = 0
    private var activePayloadLoadCount = 0
    private var storedMaximumConcurrentPayloadLoadCount = 0

    init(
        saveDelay: TimeInterval,
        loadDelay: TimeInterval = 0,
        lastUsedDelay: TimeInterval = 0,
        payloadLoadDelay: TimeInterval = 0,
        initialItems: [ClipboardSavedItem] = [],
        failLoadWhileNonempty: Bool = false,
        failPayloadLoads: Bool = false
    ) {
        self.saveDelay = saveDelay
        self.loadDelay = loadDelay
        self.lastUsedDelay = lastUsedDelay
        self.payloadLoadDelay = payloadLoadDelay
        self.failLoadWhileNonempty = failLoadWhileNonempty
        self.failPayloadLoads = failPayloadLoads
        items = initialItems
        payloads = Dictionary(uniqueKeysWithValues: initialItems.compactMap { item in
            try? (item.id, item.loadPayload())
        })
    }

    func prepare() throws {}
    func load() throws -> [ClipboardSavedItem] {
        Thread.sleep(forTimeInterval: loadDelay)
        return try lock.withLock {
            if failLoadWhileNonempty, !items.isEmpty {
                throw ClipboardHistoryStoreError.invalidEnvelope
            }
            return items.map { $0.reloadingPayload(using: self) }
        }
    }

    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {
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
        Thread.sleep(forTimeInterval: lastUsedDelay)
        lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].lastUsedAt = date
        }
    }

    func delete(id: UUID) throws {
        lock.withLock {
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

    func readPlainText() -> String? { text }

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
