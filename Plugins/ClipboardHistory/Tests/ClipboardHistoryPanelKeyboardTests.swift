import AppKit
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryPanelKeyboardTests: XCTestCase {

    func testActionContextRejectsRemovedTargetBeforeAndAfterSearchRetargetsSelection() async throws {
        let first = item(text: "First", pinned: false)
        let second = item(text: "Second", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        await model.waitForSearchForTesting()
        model.selectedItemID = first.id
        let context = try XCTUnwrap(model.actionContext)
        XCTAssertTrue(model.canPerformAction(in: context))
        model.requestActionMenu()
        model.updateItems([second])
        XCTAssertFalse(model.canPerformAction(in: context))
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.selectedItemID, second.id)
        XCTAssertFalse(model.canPerformAction(in: context))
        XCTAssertEqual(context.itemIDs, [first.id])
    }

    func testCombinedClipboardWriteChecksCancellationAndVisibilityBeforeWriting() {
        for (cancelled, current) in [(true, true), (false, false), (true, false)] {
            var events: [String] = []
            XCTAssertFalse(ClipboardHistoryPanelClipboardWrite.perform(
                isCancelled: cancelled, isCurrent: current,
                write: { events.append("write"); return true },
                didWrite: { events.append("manual") }
            ))
            XCTAssertTrue(events.isEmpty)
        }
        var events: [String] = []
        XCTAssertFalse(ClipboardHistoryPanelClipboardWrite.perform(
            isCancelled: false, isCurrent: true,
            write: { events.append("failed"); return false },
            didWrite: { events.append("manual") }
        ))
        XCTAssertEqual(events, ["failed"])
        events = []
        XCTAssertTrue(ClipboardHistoryPanelClipboardWrite.perform(
            isCancelled: false, isCurrent: true,
            write: { events.append("write"); return true },
            didWrite: { events.append("manual") }
        ))
        XCTAssertEqual(events, ["write", "manual"])
    }

    func testCombinedClipboardWriteRejectsTargetsDeletedDuringResolution() {
        let history = UUID(), snippet = UUID(), unrelated = UUID()
        XCTAssertTrue(ClipboardHistoryPanelClipboardWrite.targetsAreAvailable(
            [history, snippet], availableIDs: [history, snippet, unrelated]
        ))
        for available: Set<UUID> in [[history, unrelated], [snippet, unrelated], []] {
            XCTAssertFalse(ClipboardHistoryPanelClipboardWrite.targetsAreAvailable(
                [history, snippet], availableIDs: available
            ))
        }
        XCTAssertFalse(ClipboardHistoryPanelClipboardWrite.targetsAreAvailable([], availableIDs: [history]))
    }

    func testTwoCharacterSubstringSearchFindsHistoryAndSnippetMetadata() async {
        let history = item(text: "MT88 tripod", pinned: false)
        let unrelated = item(text: "MT99 tripod", pinned: false)
        let snippet = ClipboardSavedItem(title: "MT88 setup", tags: [], keyword: nil,
            savedKind: .snippet, payload: .plainText("Setup instructions"), templateText: "Setup instructions")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [history, unrelated], savedItems: [snippet])
        model.query = "88"
        for mode in [ClipboardPanelMode.all, .history, .snippets] {
            model.mode = mode
            await model.waitForSearchForTesting()
            let expected: Set<UUID> = switch mode {
            case .all: [history.id, snippet.id]
            case .history: [history.id]
            default: [snippet.id]
            }
            XCTAssertEqual(Set(model.visibleItems.map(\.id)), expected, "\(mode)")
        }
    }

    func testSnippetKeywordSearchRefreshesAfterMetadataChanges() async {
        var snippet = ClipboardSavedItem(title: "Customer reply", tags: ["support"], keyword: ";reply",
            savedKind: .snippet, payload: .plainText("Thanks for contacting us"), templateText: "Thanks for contacting us")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [], savedItems: [snippet])
        model.mode = .snippets
        model.query = ";reply"
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id])
        snippet.updateMetadata(title: "Updated title", tags: ["sales"], keyword: ";sales",
                               templateText: "Thanks for contacting us", updatedAt: Date())
        model.updateSavedItems([snippet])
        model.query = ";reply"
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)
        model.query = ";sales"
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id])
    }

    func testSnippetScopeRefreshesAfterCreateEditAndDeleteWithoutReopening() async {
        var snippet = ClipboardSavedItem(title: "New template", savedKind: .snippet,
            payload: .plainText("original"), templateText: "original")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [])
        model.showSnippetScope()
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)

        model.updateSavedItems([snippet])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id])
        XCTAssertTrue(model.isSavedPresentation(snippet.id))
        XCTAssertEqual(model.selectedItemID, snippet.id)

        snippet.updateMetadata(title: "Edited template", tags: [], keyword: nil, templateText: "original", updatedAt: Date())
        model.updateSavedItems([snippet])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.savedItem(forPresentationID: snippet.id)?.title, "Edited template")
        XCTAssertEqual(model.visibleItems.first?.searchIndex, snippet.historyPresentationItem().searchIndex)

        model.updateSavedItems([])
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)
        XCTAssertTrue(model.visibleSavedPresentationItemIDs.isEmpty)
        XCTAssertNil(model.selectedItemID)
    }

    func testSelectAllIncludesOnlyTheVisiblePage() async {
        let items = (0..<(ClipboardHistoryPanelModel.resultPageSize + 1)).map { index in
            item(text: "Item \(index)", pinned: false)
        }
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()

        model.selectAllVisibleItems()

        XCTAssertTrue(model.isMultiSelectionEnabled)
        XCTAssertEqual(model.selectedItemIDs.count, ClipboardHistoryPanelModel.resultPageSize)
        XCTAssertEqual(model.selectionNumber(for: model.selectedItemIDs[25]), 26)
    }

    func testOpeningMixedHistoryAndSnippetsDefaultsToAll() {
        let model = ClipboardHistoryPanelModel()
        let history = item(text: "history", pinned: false)
        let snippet = ClipboardSavedItem(title: "Snippet", savedKind: .snippet,
            payload: .plainText("template"), templateText: "template")
        model.prepareForPresentation(items: [history], savedItems: [snippet])
        XCTAssertEqual(model.mode, .all)
    }

    func testAllScopeShowsSavedCapturedItemOnceWithItsOriginalIdentity() async throws {
        var savedCapturedItem = item(
            payload: ClipboardHistoryPayload.plainText("shared text"),
            pinned: false
        )
        savedCapturedItem.setSavedMetadata(ClipboardHistorySavedMetadata(
            title: "Saved shared text",
            savedAt: Date()
        ))
        let historyOnly = item(text: "history only", pinned: false)
        let savedOnly = ClipboardSavedItem(
            title: "Saved only",
            savedKind: .snippet,
            payload: .plainText("saved only"),
            templateText: "saved only"
        )
        let model = ClipboardHistoryPanelModel()

        model.prepareForPresentation(
            items: [savedCapturedItem, historyOnly],
            savedItems: [savedOnly]
        )
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.mode, .all)
        XCTAssertEqual(model.visibleItems.count, 3)
        XCTAssertTrue(model.visibleItems.contains { $0.id == historyOnly.id })
        XCTAssertTrue(model.visibleItems.contains { $0.id == savedOnly.id })
        XCTAssertEqual(model.visibleItems.filter { $0.id == savedCapturedItem.id }.count, 1)
        XCTAssertNil(model.savedItem(forPresentationID: savedCapturedItem.id))
    }

    func testFailedClearKeepsPreservedHistoryVisibleWithInlineError() {
        let presentation = ClipboardHistoryPanelPresentation.resolve(
            itemCount: 2,
            visibleItemCount: 2,
            hasStorageError: true,
            isLoaded: true
        )

        XCTAssertFalse(presentation.showsLoading)
        XCTAssertFalse(presentation.showsErrorOnly)
        XCTAssertTrue(presentation.showsHistory)
        XCTAssertTrue(presentation.showsInlineStorageError)
    }

    func testLoadFailureWithoutUsableHistoryUsesErrorOnlyState() {
        let presentation = ClipboardHistoryPanelPresentation.resolve(
            itemCount: 0,
            visibleItemCount: 0,
            hasStorageError: true,
            isLoaded: true
        )

        XCTAssertFalse(presentation.showsLoading)
        XCTAssertTrue(presentation.showsErrorOnly)
        XCTAssertFalse(presentation.showsHistory)
        XCTAssertFalse(presentation.showsInlineStorageError)
    }

    func testMarkedTextPassesReturnAndEscapeToTheInputMethod() {
        XCTAssertNil(command(keyCode: 36, hasMarkedText: true))
        XCTAssertNil(command(keyCode: 53, hasMarkedText: true))
    }

    func testCommandNumberPastesTheCorrespondingVisibleItem() {
        let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

        for (index, keyCode) in numberRowKeyCodes.enumerated() {
            XCTAssertEqual(
                command(keyCode: keyCode, modifiers: .command),
                .pasteVisibleItem(index: index)
            )
        }
    }

    func testLargeResultSetStartsAtOnePageAndLoadsTheNextPage() async {
        let items = (0..<250).map { index in
            item(text: "result \(index)", pinned: false)
        }
        let model = ClipboardHistoryPanelModel()

        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
        XCTAssertTrue(model.hasMoreResults)

        model.loadMoreResults()
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize * 2)
        XCTAssertTrue(model.hasMoreResults)
    }

    func testLatestDebouncedQueryWins() async {
        let foo = item(text: "foo", pinned: false)
        let bar = item(text: "bar", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [foo, bar])
        await model.waitForSearchForTesting()

        model.query = "foo"
        model.query = "bar"
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.visibleItems.map(\.id), [bar.id])
    }

    func testContentFilterShowsOnlyMatchingTypesAndGroupsRichTextWithText() async {
        let plainText = item(text: "plain", pinned: false)
        let colorText = item(text: "#fff000", pinned: false)
        let richText = item(
            payload: payload(typeIdentifier: ClipboardRepresentationType.rtf),
            pinned: false
        )
        let image = item(
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            pinned: false
        )
        let model = ClipboardHistoryPanelModel()
        model.updateItems([plainText, colorText, richText, image])

        model.contentFilter = .text
        await model.waitForSearchForTesting()
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([plainText.id, colorText.id, richText.id]))

        model.contentFilter = .image
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])

        model.contentFilter = .color
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [colorText.id])
    }

    func testPanelPresentationOrdersByMostRecentCaptureOrUse() async {
        let now = Date()
        let recentlyCaptured = item(
            text: "new capture",
            pinned: false,
            capturedAt: now,
            lastUsedAt: nil
        )
        let recentlyUsed = item(
            text: "old but used",
            pinned: false,
            capturedAt: now.addingTimeInterval(-300),
            lastUsedAt: now.addingTimeInterval(10)
        )
        let pinned = item(
            text: "pin",
            pinned: true,
            capturedAt: now.addingTimeInterval(-600),
            lastUsedAt: nil
        )
        for asynchronous in [false, true] {
            let model = ClipboardHistoryPanelModel()
            let items = [recentlyCaptured, recentlyUsed, pinned]
            if asynchronous {
                model.prepareForPresentationAsynchronously(items: items)
                await model.waitForPresentationPreparationForTesting()
            } else {
                model.prepareForPresentation(items: items)
            }
            await model.waitForSearchForTesting()

            XCTAssertEqual(model.visibleItems.map(\.id), [recentlyUsed.id, recentlyCaptured.id, pinned.id])
            XCTAssertEqual(model.selectedItemID, recentlyUsed.id)
            XCTAssertEqual(model.consumeRequestedScrollItemID(), recentlyUsed.id)
        }
    }

    func testUsageMovesHistoryToFrontAndWarmReopenFocusesIt() async {
        let now = Date()
        let first = item(text: "first", pinned: false, capturedAt: now, lastUsedAt: nil)
        let second = item(
            text: "second",
            pinned: false,
            capturedAt: now.addingTimeInterval(-60),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second], historyRevision: 1, savedRevision: 1)
        await model.waitForSearchForTesting()
        model.setMultiSelectionEnabled(true)
        model.toggleMultiSelection(for: second.id)
        let selection = model.selectedItemIDs
        let context = model.actionContext

        var usedSecond = second
        usedSecond.lastUsedAt = now.addingTimeInterval(30)
        model.updateItems([first, usedSecond], revision: 2, changedIDs: [second.id])

        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleItems.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.selectedItemID, first.id)
        XCTAssertEqual(model.selectedItemIDs, selection)
        XCTAssertEqual(model.actionContext, context)
        model.prepareForPresentation(items: [first, usedSecond], historyRevision: 2, savedRevision: 1)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleItems.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.selectedItemID, second.id)
        XCTAssertEqual(model.consumeRequestedScrollItemID(), second.id)
    }

    func testAllScopeIncludesSnippetUsageInRecencyOrder() async {
        let now = Date()
        let historyItem = item(
            text: "new capture",
            pinned: false,
            capturedAt: now,
            lastUsedAt: nil
        )
        let snippet = ClipboardSavedItem(
            title: "old snippet",
            savedKind: .snippet,
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-300),
            lastUsedAt: now.addingTimeInterval(60),
            payload: .plainText("old snippet"),
            templateText: "old snippet"
        )
        let model = ClipboardHistoryPanelModel()

        model.prepareForPresentation(items: [historyItem], savedItems: [snippet])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.mode, .all)
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id, historyItem.id])
        XCTAssertEqual(model.selectedItemID, snippet.id)

        var reusedHistory = historyItem
        reusedHistory.lastUsedAt = now.addingTimeInterval(120)
        model.updateItems([reusedHistory], changedIDs: [historyItem.id])
        XCTAssertEqual(model.visibleItems.map(\.id), [historyItem.id, snippet.id])

        var reusedSnippet = snippet
        reusedSnippet.lastUsedAt = now.addingTimeInterval(180)
        model.updateSavedItems([reusedSnippet])
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id, historyItem.id])
        XCTAssertEqual(model.selectedItemID, snippet.id)
    }

    func testHTMLRichTextImporterRejectsSubsidiaryResourceRequests() throws {
        let delegate = ClipboardHTMLResourceLoadDenyDelegate()
        let selector = NSSelectorFromString(
            "webView:resource:willSendRequest:redirectResponse:fromDataSource:"
        )
        XCTAssertTrue(delegate.responds(to: selector))
        XCTAssertNil(delegate.denyResourceLoad(
            NSObject(),
            resource: NSObject(),
            willSendRequest: NSURLRequest(url: URL(string: "https://tracker.invalid/pixel.png")!),
            redirectResponse: nil,
            fromDataSource: NSObject()
        ))

        let html = "<html><body><b>Local preview</b><img src='https://tracker.invalid/pixel.png'></body></html>"
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.html,
                    data: Data(html.utf8)
                ),
            ]),
        ])
        let imported = try XCTUnwrap(ClipboardRichText.attributedString(for: payload))
        XCTAssertTrue(imported.string.contains("Local preview"))
    }

    private func command(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isPanelEvent: Bool = true,
        isPanelKeyWindow: Bool = true,
        hasAttachedSheet: Bool = false,
        isEditingText: Bool = false,
        hasSelectedText: Bool = false,
        hasMarkedText: Bool = false,
        isMultiSelectionEnabled: Bool = false,
        isActionPalettePresented: Bool = false,
        panelShortcutBindings: [String: ShortcutBinding]? = nil
    ) -> ClipboardHistoryPanelController.KeyboardCommand? {
        let resolvedBindings = panelShortcutBindings ?? [
            ClipboardHistoryPlugin.ShortcutID.panelCycleScope: ShortcutBinding(
                keyCode: 48,
                modifiers: .control
            ),
            ClipboardHistoryPlugin.ShortcutID.panelActions: ShortcutBinding(
                keyCode: 40,
                modifiers: .command
            ),
            ClipboardHistoryPlugin.ShortcutID.panelExport: ShortcutBinding(
                keyCode: 14,
                modifiers: .command
            ),
            ClipboardHistoryPlugin.ShortcutID.panelEditSnippet: ShortcutBinding(
                keyCode: 14,
                modifiers: [.command, .option]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelShare: ShortcutBinding(
                keyCode: 14,
                modifiers: [.command, .shift]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelSave: ShortcutBinding(
                keyCode: 35,
                modifiers: .command
            ),
            ClipboardHistoryPlugin.ShortcutID.panelDelete: ShortcutBinding(
                keyCode: 51,
                modifiers: [.command, .shift]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelMultiSelect: ShortcutBinding(
                keyCode: 37,
                modifiers: [.command]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelToggleSelection: ShortcutBinding(
                keyCode: 36,
                modifiers: [.command]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelSelectAll: ShortcutBinding(
                keyCode: 0,
                modifiers: [.command, .option]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelCopyCombined: ShortcutBinding(
                keyCode: 8,
                modifiers: [.command, .shift]
            ),
            ClipboardHistoryPlugin.ShortcutID.panelPasteCombined: ShortcutBinding(
                keyCode: 36,
                modifiers: [.command, .shift]
            ),
        ]
        return ClipboardHistoryPanelController.keyboardCommand(
            keyCode: keyCode,
            modifiers: modifiers,
            isPanelEvent: isPanelEvent,
            isPanelKeyWindow: isPanelKeyWindow,
            hasAttachedSheet: hasAttachedSheet,
            isEditingText: isEditingText,
            hasSelectedText: hasSelectedText,
            hasMarkedText: hasMarkedText,
            isMultiSelectionEnabled: isMultiSelectionEnabled,
            isActionPalettePresented: isActionPalettePresented,
            panelShortcutBindings: resolvedBindings
        )
    }

    func testMultiSelectionPreservesUserSelectionOrderAndClearsOnExit() {
        let first = item(text: "First", pinned: false)
        let second = item(text: "Second", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        let focusedID = try! XCTUnwrap(model.selectedItemID)
        let otherID = focusedID == first.id ? second.id : first.id
        model.setMultiSelectionEnabled(true)

        XCTAssertEqual(model.actionItemIDs, [focusedID])
        model.toggleMultiSelection(for: otherID)
        XCTAssertEqual(model.actionItemIDs, [focusedID, otherID])

        model.toggleMultiSelection(for: focusedID)
        XCTAssertEqual(model.actionItemIDs, [otherID])
        model.setMultiSelectionEnabled(false)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    private func item(text: String, pinned: Bool) -> ClipboardHistoryItem {
        item(text: text, pinned: pinned, capturedAt: Date(), lastUsedAt: nil)
    }

    private func item(
        text: String,
        pinned: Bool,
        capturedAt: Date,
        lastUsedAt: Date?
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: capturedAt,
            sourceApplication: nil,
            isPinned: pinned,
            lastUsedAt: lastUsedAt
        )
    }

    private func item(payload: ClipboardHistoryPayload, pinned: Bool) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: pinned,
            lastUsedAt: nil
        )
    }

    private func payload(typeIdentifier: String) -> ClipboardHistoryPayload {
        ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: typeIdentifier,
                    data: Data([0x01])
                ),
            ]),
        ])
    }

}
