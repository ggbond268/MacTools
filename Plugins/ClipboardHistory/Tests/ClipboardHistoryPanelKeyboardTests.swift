import AppKit
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryPanelKeyboardTests: XCTestCase {
    func testSequentialPasteHUDReservesPreviewGeometryBeforeDecodeCompletes() {
        XCTAssertEqual(ClipboardSequentialPasteHUDPreviewLayout.dimension(hasData: true), 48)
        XCTAssertEqual(ClipboardSequentialPasteHUDPreviewLayout.dimension(hasData: false), 0)
    }

    func testSaveFeedbackAcknowledgesImmediatelyAndCoalescesRepeatedRequests() {
        let clip = item(text: "Clip", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [clip])

        XCTAssertFalse(model.effectiveSavedState(for: clip))
        XCTAssertTrue(model.beginSavedMutation(for: clip.id))
        XCTAssertTrue(model.effectiveSavedState(for: clip))
        XCTAssertEqual(model.pendingSavedItemIDs, [clip.id])
        XCTAssertFalse(model.beginSavedMutation(for: clip.id))

        model.finishSavedMutation(for: clip.id)
        XCTAssertFalse(model.effectiveSavedState(for: clip))
        XCTAssertTrue(model.pendingSavedItemIDs.isEmpty)
    }

    func testStructuralRemovalDisappearsBeforeBackgroundSearchCompletes() async {
        let clip = item(text: "Sensitive", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [clip])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [clip.id])

        model.updateItems([])

        XCTAssertTrue(model.visibleItems.isEmpty)
    }

    func testActionPaletteModelResetsAndCachesGroupedSearchResultsForEveryPresentation() {
        let model = ClipboardHistoryActionPaletteModel()
        let entries: [ClipboardHistoryExportMenuEntry] = [
            .init(title: "Paste", action: .paste, shortcut: "Return"),
            .init(title: "Share", action: .share, shortcut: "⇧⌘E"),
        ]

        model.present(entries: entries, contextTitle: "First")
        model.query = "share"
        XCTAssertEqual(model.filteredEntries.map(\.action), [.share])

        model.present(entries: entries, contextTitle: "Second")

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.contextTitle, "Second")
        XCTAssertEqual(model.filteredEntries.map(\.action), [.paste, .share])
        XCTAssertEqual(model.selectedAction, .paste)
        XCTAssertEqual(model.sections.flatMap(\.entries).count, 2)
    }

    func testVisibleRowHitAreaFocusesExceptForMultiSelectCheckbox() {
        XCTAssertTrue(ClipboardHistoryRowHitTesting.targetsFocus(
            atX: 0,
            isMultiSelectionEnabled: false
        ))
        XCTAssertFalse(ClipboardHistoryRowHitTesting.targetsFocus(
            atX: ClipboardHistoryRowHitTesting.multiSelectionLeadingControlWidth - 1,
            isMultiSelectionEnabled: true
        ))
        XCTAssertTrue(ClipboardHistoryRowHitTesting.targetsFocus(
            atX: ClipboardHistoryRowHitTesting.multiSelectionLeadingControlWidth,
            isMultiSelectionEnabled: true
        ))
    }

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

    func testActionContextTracksOrderedSelectionAndHighlightedTarget() async throws {
        let first = item(text: "First", pinned: false)
        let second = item(text: "Second", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        await model.waitForSearchForTesting()
        model.selectedItemID = first.id
        model.setMultiSelectionEnabled(true)
        let context = try XCTUnwrap(model.actionContext)
        model.selectedItemID = second.id
        XCTAssertFalse(model.canPerformAction(in: context), "Mark Item must retain the original highlighted target")
        model.toggleFocusedSelection()
        let both = try XCTUnwrap(model.actionContext)
        XCTAssertEqual(both.itemIDs, [first.id, second.id])
        model.toggleFocusedSelection()
        XCTAssertFalse(model.canPerformAction(in: both))
    }

    func testDeleteConfirmationCapturesTheOrderedMultiSelection() async throws {
        let first = item(text: "First", pinned: false)
        let second = item(text: "Second", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        await model.waitForSearchForTesting()
        model.selectedItemID = first.id
        model.setMultiSelectionEnabled(true)
        model.selectedItemID = second.id
        model.toggleFocusedSelection()

        model.requestDeleteConfirmation()

        XCTAssertEqual(model.deleteConfirmationRequestID, 1)
        let context = try XCTUnwrap(model.consumeDeleteConfirmationContext())
        XCTAssertEqual(context.itemIDs, [first.id, second.id])
        XCTAssertTrue(context.isMultiSelectionEnabled)
        XCTAssertNil(model.consumeDeleteConfirmationContext())
    }

    func testMixedSnippetActionContextCanStartAnOrderedQueue() {
        let clipID = UUID()
        let snippetID = UUID()
        let context = ClipboardHistoryPanelActionContext(
            itemIDs: [snippetID, clipID],
            snippetIDs: [snippetID],
            savedClipIDs: [],
            focusedItemID: snippetID,
            isMultiSelectionEnabled: true
        )

        XCTAssertTrue(context.canStartSequentialQueue)
        XCTAssertEqual(context.itemIDs, [snippetID, clipID])
    }

    func testActionContextSurvivesUnrelatedCaptureButRejectsDeletedSnippet() async throws {
        let history = item(text: "History", pinned: false)
        let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText("Hello"), templateText: "Hello")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [history], savedItems: [snippet])
        await model.waitForSearchForTesting()
        model.selectedItemID = snippet.id
        let context = try XCTUnwrap(model.actionContext)
        XCTAssertEqual(context.snippetIDs, [snippet.id])
        model.updateItems([history, item(text: "New capture", pinned: false)])
        XCTAssertTrue(model.canPerformAction(in: context))
        model.updateSavedItems([])
        XCTAssertFalse(model.canPerformAction(in: context))
    }

    func testActionContextRejectsChangedSaveStateInsteadOfReversingDisplayedAction() async throws {
        var history = item(text: "History", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [history])
        await model.waitForSearchForTesting()
        let context = try XCTUnwrap(model.actionContext)
        XCTAssertTrue(context.savedClipIDs.isEmpty)
        history.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Saved", savedAt: Date()))
        model.updateItems([history])
        XCTAssertFalse(model.canPerformAction(in: context), "An old Save action must not become Unsave")
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

    func testActionPaletteRoutesOnlyOfferedActionsUsingCurrentShortcutBindings() {
        let save = ClipboardHistoryPlugin.ShortcutID.panelSave
        let share = ClipboardHistoryPlugin.ShortcutID.panelShare
        let edit = ClipboardHistoryPlugin.ShortcutID.panelEditSnippet
        let entries: [ClipboardHistoryExportMenuEntry] = [
            .init(title: "Save", action: .saveToLibrary, shortcutDefinitionID: save),
            .init(title: "Share", action: .share, shortcutDefinitionID: share),
            .init(title: "Edit", action: .editSaved, shortcutDefinitionID: edit),
        ]
        let bindings = [
            save: ShortcutBinding(keyCode: 35, modifiers: .command),
            share: ShortcutBinding(keyCode: 14, modifiers: [.command, .shift]),
            edit: ShortcutBinding(keyCode: 14, modifiers: [.command, .option]),
        ]
        func action(_ key: UInt16, _ flags: NSEvent.ModifierFlags,
                    offered: [ClipboardHistoryExportMenuEntry]? = nil,
                    configured: [String: ShortcutBinding]? = nil) -> ClipboardHistoryExportMenuEntry.Action? {
            ClipboardHistoryActionPaletteShortcuts.action(keyCode: key, modifiers: flags,
                entries: offered ?? entries, bindings: configured ?? bindings,
                isEditingText: true, hasSelectedText: false, hasMarkedText: false,
                isRecordingShortcut: false)
        }
        XCTAssertEqual(action(35, .command), .saveToLibrary)
        XCTAssertEqual(action(14, [.command, .shift]), .share)
        XCTAssertEqual(action(14, [.command, .option]), .editSaved)
        XCTAssertNil(action(35, .command, offered: []))
        XCTAssertNil(action(35, .command, configured: [:]))
        XCTAssertEqual(action(1, [.command, .option], configured: [
            save: ShortcutBinding(keyCode: 1, modifiers: [.command, .option]),
        ]), .saveToLibrary)
    }

    func testActionPalettePreservesSearchEditingCompositionRecordingAndReturnSubmission() {
        let id = ClipboardHistoryPlugin.ShortcutID.panelSave
        let entries: [ClipboardHistoryExportMenuEntry] = [
            .init(title: "Paste", action: .paste, shortcut: "Return"),
            .init(title: "Plain Text", action: .pastePlainText, shortcut: "⇧Return"),
            .init(title: "Copy", action: .copy, shortcut: "⌘C"),
            .init(title: "Save", action: .saveToLibrary, shortcutDefinitionID: id),
        ]
        func action(_ key: UInt16, _ flags: NSEvent.ModifierFlags = [],
                    selection: Bool = false, marked: Bool = false,
                    recording: Bool = false, binding: ShortcutBinding? = nil) -> ClipboardHistoryExportMenuEntry.Action? {
            ClipboardHistoryActionPaletteShortcuts.action(keyCode: key, modifiers: flags,
                entries: entries, bindings: [id: binding ?? ShortcutBinding(keyCode: 35, modifiers: .command)],
                isEditingText: true, hasSelectedText: selection, hasMarkedText: marked,
                isRecordingShortcut: recording)
        }
        XCTAssertNil(action(36))
        XCTAssertNil(action(76))
        XCTAssertNil(action(53))
        XCTAssertEqual(action(36, .shift), .pastePlainText)
        XCTAssertEqual(action(8, .command), .copy)
        XCTAssertNil(action(8, .command, selection: true))
        XCTAssertNil(action(35, .command, marked: true))
        XCTAssertNil(action(35, .command, recording: true))
        for key: UInt16 in [0, 7, 9, 6] {
            XCTAssertNil(action(key, .command, binding: ShortcutBinding(keyCode: key, modifiers: .command)))
        }
        for key: UInt16 in [123, 124, 125, 126] {
            XCTAssertNil(action(key, .command, binding: ShortcutBinding(keyCode: key, modifiers: .command)))
            XCTAssertNil(action(key, .option, binding: ShortcutBinding(keyCode: key, modifiers: .option)))
        }
    }

    func testLargeSnippetLibraryOpeningAndMissSearchReuseMetadataWithoutLoadingPayloads() async {
        let loads = ClipboardPayloadLoadCounter()
        let template = String(repeating: "Reusable customer reply without a match. ", count: 80)
        let snippets = (0..<1_000).map { index in
            ClipboardSavedItem(
                id: UUID(), title: "Reply \(index)", tags: ["support"], keyword: ";reply\(index)", savedKind: .snippet, createdAt: .distantPast,
                updatedAt: .distantPast, lastUsedAt: nil, sourceApplication: nil,
                contentKind: .plainText, payloadByteCount: template.utf8.count,
                fileURLs: [], fileReferenceCount: 0, linkURLs: [],
                representationTypeIdentifiers: [ClipboardRepresentationType.plainText],
                payloadDigest: Data("snippet-\(index)".utf8), templateSearchText: template,
                hasDynamicTemplateContent: false, clipSearchText: nil, imageSearchText: nil,
                payloadLoader: {
                    loads.increment()
                    return .plainText(template)
                }
            )
        }
        let model = ClipboardHistoryPanelModel()
        // Construction represents the background database load, outside the UI budget.
        let openedAt = Date()
        model.prepareForPresentation(items: [], savedItems: snippets)
        XCTAssertLessThan(Date().timeIntervalSince(openedAt), 1.0)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
        let searchStartedAt = Date()
        model.query = "zzzz-unmatched-customer"
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.visibleItems.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(searchStartedAt), 2.0)
        XCTAssertEqual(loads.value, 0)
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

    func testSnippetMetadataSearchUsesTitleTagsAndKeywordInBothScopes() async {
        var snippet = ClipboardSavedItem(title: "Customer reply", tags: ["support"], keyword: ";reply",
            savedKind: .snippet, payload: .plainText("Thanks for contacting us"), templateText: "Thanks for contacting us")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [], savedItems: [snippet])
        for mode in [ClipboardPanelMode.all, .snippets] {
            model.mode = mode
            for query in ["Customer", "support", ";reply", "Thanks"] {
                model.query = query
                await model.waitForSearchForTesting()
                XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id], "\(mode) \(query)")
            }
        }
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

    func testSnippetExportRoutePreservesClickedTargetAndCombinedIntent() {
        let history = UUID(), snippet = UUID()
        XCTAssertEqual(ClipboardPanelExportRoute.historyItemID(ids: [history], snippetIDs: [snippet]), history)
        XCTAssertNil(ClipboardPanelExportRoute.historyItemID(ids: [snippet], snippetIDs: [snippet]))
        XCTAssertNil(ClipboardPanelExportRoute.historyItemID(ids: [history, snippet], snippetIDs: [snippet]))
        XCTAssertNil(ClipboardPanelExportRoute.historyItemID(ids: [history], snippetIDs: [], combining: true))
        XCTAssertEqual(ClipboardPanelExportRoute.snippetFormats, [.plainText, .markdown, .html, .pdf])
    }

    func testSnippetLoadingFailureDoesNotLookEmptyOrHideWorkingHistory() {
        let loading = ClipboardHistoryPanelPresentation.resolve(itemCount: 0, visibleItemCount: 0,
            hasStorageError: false, isLoaded: true, isSnippetScope: true, snippetsAreLoaded: false)
        XCTAssertTrue(loading.showsLoading)
        XCTAssertFalse(loading.showsEmptyState)
        let failed = ClipboardHistoryPanelPresentation.resolve(itemCount: 0, visibleItemCount: 0,
            hasStorageError: false, isLoaded: true, isSnippetScope: true, snippetsHaveStorageError: true)
        XCTAssertTrue(failed.showsErrorOnly)
        XCTAssertFalse(failed.showsEmptyState)
        let history = ClipboardHistoryPanelPresentation.resolve(itemCount: 3, visibleItemCount: 3,
            hasStorageError: false, isLoaded: true, snippetsHaveStorageError: true)
        XCTAssertTrue(history.showsHistory)
        XCTAssertFalse(history.showsErrorOnly)
        let recovered = ClipboardHistoryPanelPresentation.resolve(itemCount: 1, visibleItemCount: 1,
            hasStorageError: true, isLoaded: false, isSnippetScope: true)
        XCTAssertTrue(recovered.showsHistory)
        XCTAssertFalse(recovered.showsLoading)
    }
    func testActionKeyboardOrderMatchesRenderedGroupsAndSearchResults() {
        let entries: [ClipboardHistoryExportMenuEntry] = [
            .init(title: "Paste", action: .paste),
            .init(title: "Save Clip", action: .saveToLibrary, group: .selection),
            .init(title: "Delete", action: .delete, group: .selection),
            .init(title: "Share", action: .share, group: .exportAndShare),
            .init(title: "Export PDF", action: .format(.pdf), group: .exportAndShare),
            .init(title: "Pause", action: .toggleCollection, group: .history),
        ]
        let visible = ClipboardHistoryExportMenuEntry.visibleEntries(entries, query: "")
        XCTAssertEqual(visible.map(\.action), [.paste, .share, .format(.pdf), .saveToLibrary, .delete, .toggleCollection])
        for index in visible.indices {
            let next = ClipboardHistoryPanelModel.wrappedIndex(index + 1, count: visible.count)
            XCTAssertEqual(visible[next].id, visible[(index + 1) % visible.count].id)
        }
        XCTAssertEqual(ClipboardHistoryExportMenuEntry.visibleEntries(entries, query: " export ").map(\.action), [.format(.pdf)])
        XCTAssertTrue(ClipboardHistoryExportMenuEntry.visibleEntries(entries, query: "no-such-action").isEmpty)
        let snippetEntries: [ClipboardHistoryExportMenuEntry] = [
            .init(title: "Delete", action: .delete, group: .selection),
            .init(title: "Edit Snippet", action: .editSaved),
            .init(title: "Share", action: .share, group: .exportAndShare),
            .init(title: "Copy Combined", action: .copyCombined),
        ]
        XCTAssertEqual(ClipboardHistoryExportMenuEntry.visibleEntries(snippetEntries, query: "").map(\.action), [.editSaved, .copyCombined, .share, .delete])
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

    func testSnippetScopeRefreshKeepsSearchAndFiltersForBackgroundUpdates() async {
        let matching = ClipboardSavedItem(title: "Match", savedKind: .snippet,
            payload: .plainText("matching content"), templateText: "matching content")
        let other = ClipboardSavedItem(title: "Other", savedKind: .snippet,
            payload: .plainText("unrelated"), templateText: "unrelated")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [])
        model.showSnippetScope()
        model.query = "matching"
        model.contentFilter = .text
        model.updateSavedItems([matching, other])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.query, "matching")
        XCTAssertEqual(model.contentFilter, .text)
        XCTAssertEqual(model.visibleItems.map(\.id), [matching.id])
    }

    func testCreatedSnippetIsRevealedFromFilteredHistoryAndSelectionMode() async {
        let history = [item(text: "alpha", pinned: false), item(text: "beta", pinned: false)]
        let snippet = ClipboardSavedItem(title: "New template", savedKind: .snippet,
            payload: .plainText("new content"), templateText: "new content")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: history)
        await model.waitForSearchForTesting()
        model.setMultiSelectionEnabled(true)
        model.query = "old query"
        model.contentFilter = .image
        model.semanticFilter = .email

        model.revealCreatedSnippet(id: snippet.id, savedItems: [snippet])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.mode, .snippets)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.contentFilter, .all)
        XCTAssertEqual(model.semanticFilter, .any)
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id])
        XCTAssertEqual(model.selectedItemID, snippet.id)
        XCTAssertEqual(model.requestedScrollItemID, snippet.id)
        XCTAssertFalse(model.isMultiSelectionEnabled)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertTrue(model.availableScopeModes.contains(.all))
        XCTAssertTrue(model.availableScopeModes.contains(.history))
        XCTAssertTrue(model.availableScopeModes.contains(.snippets))
        XCTAssertEqual(model.selectedFilterFamily, .scope)
    }

    func testCreatedSnippetIsSelectedOnFirstPageOfLargeSnippetList() async {
        let oldDate = Date(timeIntervalSince1970: 100)
        let existing = (0..<100).map { index in
            ClipboardSavedItem(title: "Old \(index)", savedKind: .snippet,
                createdAt: oldDate, updatedAt: oldDate,
                payload: .plainText("old"), templateText: "old")
        }
        let snippet = ClipboardSavedItem(title: "Created", savedKind: .snippet,
            payload: .plainText("new"), templateText: "new")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [], savedItems: existing)
        model.showSnippetScope()
        await model.waitForSearchForTesting()
        model.loadMoreResults()
        await model.waitForSearchForTesting()
        model.revealCreatedSnippet(id: snippet.id, savedItems: existing + [snippet])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.first?.id, snippet.id)
        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
        XCTAssertTrue(model.hasMoreResults)
        XCTAssertEqual(model.selectedItemID, snippet.id)
        XCTAssertEqual(model.consumeRequestedScrollItemID(), snippet.id)
    }

    func testUncommittedSnippetDoesNotChangeScopeOrSearch() async {
        let history = item(text: "existing", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [history])
        model.query = "existing"
        await model.waitForSearchForTesting()
        model.revealCreatedSnippet(id: UUID(), savedItems: [])
        XCTAssertEqual(model.mode, .history)
        XCTAssertEqual(model.query, "existing")
        XCTAssertEqual(model.selectedItemID, history.id)
    }

    func testReopeningUnchangedHistoryUsesInitialPageWithoutSearching() async {
        let items = (0..<80).map { item(text: "item \($0)", pinned: false) }
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
        XCTAssertFalse(model.showsSearchProgress)
        await model.waitForSearchForTesting()
        let firstPage = model.visibleItems
        model.query = "item 79"
        await model.waitForSearchForTesting()
        model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.showsSearchProgress)
        XCTAssertEqual(model.visibleItems, firstPage)
        XCTAssertTrue(model.hasMoreResults)
    }

    func testInitialPageCacheInvalidatesForRemovedItemsAndChangedSnippets() async {
        let first = item(text: "first", pinned: false)
        let second = item(text: "second", pinned: false)
        let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText("body"), templateText: "body")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second], savedItems: [snippet])
        await model.waitForSearchForTesting()
        model.prepareForPresentation(items: [first], savedItems: [snippet])
        XCTAssertTrue(model.isSearching)
        XCTAssertFalse(model.visibleItems.contains { $0.id == second.id })
        await model.waitForSearchForTesting()
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), [first.id, snippet.id])
        model.prepareForPresentation(items: [first], savedItems: [])
        XCTAssertTrue(model.isSearching)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [first.id])
        XCTAssertTrue(model.visibleSavedPresentationItemIDs.isEmpty)
    }

    func testDelayedSearchProgressCancelsOnCompletionAndReopen() async throws {
        let items = [item(text: "alpha", pinned: false), item(text: "beta", pinned: false)]
        let model = ClipboardHistoryPanelModel(searchProgressDelayNanoseconds: 0)
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.query = "alpha"
        XCTAssertFalse(model.showsSearchProgress)
        for _ in 0..<20 where !model.showsSearchProgress { await Task.yield() }
        XCTAssertTrue(model.showsSearchProgress)
        XCTAssertEqual(model.visibleItems.count, 2, "Retain results while refreshing")
        await model.waitForSearchForTesting()
        XCTAssertFalse(model.showsSearchProgress)
        model.query = "beta"
        model.prepareForPresentation(items: items)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.showsSearchProgress)
        XCTAssertEqual(model.visibleItems.count, 2)
    }

    func testSelectionEntryRequiresMultipleItemsButSurvivesFilteringAndDeletion() async {
        let first = item(text: "alpha", pinned: false)
        let second = item(text: "beta", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first])
        await model.waitForSearchForTesting()
        XCTAssertFalse(model.showsMultiSelectionControl)
        model.setMultiSelectionEnabled(true)
        model.selectAllVisibleItems()
        model.extendSelection(by: 1)
        XCTAssertFalse(model.isMultiSelectionEnabled)
        model.updateItems([first, second])
        model.query = "alpha"
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.count, 1)
        XCTAssertTrue(model.showsMultiSelectionControl)
        model.setMultiSelectionEnabled(true)
        model.updateItems([first])
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.showsMultiSelectionControl, "Done remains reachable")
        model.setMultiSelectionEnabled(false)
        XCTAssertFalse(model.showsMultiSelectionControl)
    }

    func testManageSnippetsExposesEmptySnippetScopeForCreation() async {
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [])
        model.showSnippetScope()
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.mode, .snippets)
        XCTAssertTrue(model.availableScopeModes.contains(.snippets))
        XCTAssertTrue(model.availableFilterFamilies.contains(.scope))
    }

    func testProgressiveFilterBarKeepsOneAvailableFamilySelected() {
        let families = ClipboardHistoryFilterFamily.available(
            totalItemCount: 3,
            scopeCounts: [3, 1, 0],
            typeCounts: [2, 1],
            contentCounts: [1]
        )

        XCTAssertEqual(families, [.scope, .type, .content])
        XCTAssertEqual(
            ClipboardHistoryFilterFamily.resolvedSelection(
                current: .content,
                available: [.scope, .type]
            ),
            .scope
        )
        XCTAssertEqual(
            ClipboardHistoryFilterFamily.resolvedSelection(
                current: .scope,
                available: [.scope, .content]
            ),
            .scope
        )
    }

    func testEmptySingleAndUniformCollectionsDoNotReserveFilterSpace() {
        var savedLink = item(text: "https://example.com", pinned: false)
        savedLink.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Link", savedAt: Date()))
        for items in [[], [item(text: "plain", pinned: false)], [savedLink], [
            item(text: "first", pinned: false), item(text: "second", pinned: false),
        ], [
            item(text: "https://example.com", pinned: false),
            item(text: "https://example.org", pinned: false),
        ]] {
            let model = ClipboardHistoryPanelModel()
            model.prepareForPresentation(items: items)
            XCTAssertTrue(model.availableFilterFamilies.isEmpty)
            XCTAssertEqual(model.filterOptionCount, 0)
            XCTAssertFalse(model.selectFilterOption(at: 0))
            model.cycleFilterFamily()
            XCTAssertTrue(model.availableFilterFamilies.isEmpty)
        }
    }

    func testOverlappingScopesAndTypesMustActuallyNarrowResults() {
        let model = ClipboardHistoryPanelModel()
        let items = ["first", "second"].map { text in
            var value = item(text: text, pinned: false)
            value.setSavedMetadata(ClipboardHistorySavedMetadata(title: text, savedAt: Date()))
            return value
        }
        model.prepareForPresentation(items: items)
        XCTAssertEqual(model.availableScopeModes, [.all, .history, .saved])
        XCTAssertTrue(model.availableFilterFamilies.isEmpty)
        XCTAssertEqual(ClipboardHistoryFilterFamily.available(
            totalItemCount: 2, scopeCounts: [2, 2], typeCounts: [2, 2], contentCounts: [2]
        ), [])
    }

    func testSingleSnippetDoesNotExposeRedundantFilters() {
        let snippet = ClipboardSavedItem(
            title: "Link", savedKind: .snippet,
            payload: .plainText("https://example.com"), templateText: "https://example.com"
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [], savedItems: [snippet])
        XCTAssertEqual(model.mode, .snippets)
        XCTAssertTrue(model.availableFilterFamilies.isEmpty)
        XCTAssertEqual(model.filterOptionCount, 0)
    }

    func testOCRDoesNotAddAFilterGroupDuringAnOpenPresentation() {
        let plain = item(text: "plain", pinned: false)
        var image = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain, image])
        XCTAssertEqual(model.availableFilterFamilies, [.type])
        image.setImageSearchText("person@example.com")
        model.updateItems([plain, image])
        XCTAssertEqual(model.availableFilterFamilies, [.type])
        model.prepareForPresentation(items: [plain, image])
        XCTAssertEqual(model.availableFilterFamilies, [.type, .content])
        XCTAssertEqual(model.availableSemanticFilters, [.email, .recognizedText])
    }

    func testFilterLayoutAndOptionOrderRemainLockedUntilNextOpening() async {
        let plain = item(text: "plain", pinned: false)
        let email = item(text: "person@example.com", pinned: false)
        let pdf = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.pdf.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain])
        model.updateItems([plain, email, pdf])
        await model.waitForSearchForTesting()
        XCTAssertTrue(model.availableFilterFamilies.isEmpty)

        model.prepareForPresentation(items: [plain, email, pdf])
        let types = model.availableContentFilters
        let content = model.availableSemanticFilters
        XCTAssertEqual(model.availableFilterFamilies, [.type, .content])
        XCTAssertEqual(types, [.text, .pdf])
        model.query = "no matches"
        model.updateItems([])
        model.updateSavedItems([ClipboardSavedItem(
            title: "Snippet", savedKind: .snippet, payload: .plainText("snippet"), templateText: "snippet"
        )])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.availableFilterFamilies, [.type, .content])
        XCTAssertEqual(model.availableContentFilters, types)
        XCTAssertEqual(model.availableSemanticFilters, content)

        model.prepareForPresentation(items: [])
        XCTAssertTrue(model.availableFilterFamilies.isEmpty)
        XCTAssertEqual(model.filterOptionCount, 0)
    }

    func testVisibleFilterRowAppendsNewOptionsWithoutReorderingExistingOptions() {
        let email = item(text: "person@example.com", pinned: false)
        let ordinary = item(text: "ordinary", pinned: false)
        let link = item(text: "https://example.com", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [email, ordinary])

        XCTAssertEqual(model.availableFilterFamilies, [.content])
        XCTAssertEqual(model.availableSemanticFilters, [.email])

        model.updateItems([link, email, ordinary])

        XCTAssertEqual(model.availableFilterFamilies, [.content])
        XCTAssertEqual(model.availableSemanticFilters, [.email, .link])
    }

    func testHiddenFilterFamilyDoesNotAddANewRowUntilReopen() {
        let plain = item(text: "plain", pinned: false)
        let image = item(
            payload: payload(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue),
            pinned: false
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain])

        model.updateItems([image, plain])
        XCTAssertTrue(model.availableFilterFamilies.isEmpty)

        model.prepareForPresentation(items: [image, plain])
        XCTAssertEqual(model.availableFilterFamilies, [.type])
        XCTAssertEqual(model.availableContentFilters, [.text, .image])
    }

    func testFilterOptionNumbersFollowTheVisibleStripWithoutGaps() async {
        let plain = item(text: "plain", pinned: false)
        let email = item(text: "person@example.com", pinned: false)
        let pdf = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.pdf.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain, email, pdf])
        XCTAssertEqual(model.selectedFilterFamily, .type)
        XCTAssertEqual(model.filterOptionCount, 3)
        XCTAssertTrue(model.selectFilterOption(at: 2))
        XCTAssertEqual(model.contentFilter, .pdf)
        XCTAssertFalse(model.selectFilterOption(at: 3))
        XCTAssertFalse(model.selectFilterOption(at: -1))
        XCTAssertEqual(model.contentFilter, .pdf)

        model.selectFilterOption(at: 0)
        model.cycleFilterFamily()
        XCTAssertEqual(model.selectedFilterFamily, .content)
        XCTAssertEqual(model.filterOptionCount, 2)
        XCTAssertEqual(model.semanticFilter, .any)
        XCTAssertTrue(model.selectFilterOption(at: 1))
        XCTAssertEqual(model.semanticFilter, .email)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [email.id])
        model.selectFilterOption(at: 0)
        XCTAssertEqual(model.semanticFilter, .any)
    }

    func testReturningFromAnotherAppRefreshesTypesWithoutResettingInteraction() async {
        let plain = item(text: "plain", pinned: false)
        let image = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain])
        model.query = "plain"
        model.selectedItemID = plain.id
        model.updateItems([image, plain])
        model.setMultiSelectionEnabled(true)
        XCTAssertTrue(model.availableFilterFamilies.isEmpty)

        model.refreshFiltersForReactivation(items: [image, plain])
        await model.waitForFilterRefreshForTesting()
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.availableFilterFamilies, [.type])
        XCTAssertEqual(model.availableContentFilters, [.text, .image])
        XCTAssertEqual(model.selectedFilterFamily, .type)
        XCTAssertEqual(model.query, "plain")
        XCTAssertEqual(model.selectedItemID, plain.id)
        XCTAssertEqual(model.selectedItemIDs, [plain.id])
        XCTAssertTrue(model.isMultiSelectionEnabled)
        XCTAssertEqual(model.visibleItems.map(\.id), [plain.id])
    }

    func testReturningRefreshesOCRFiltersButKeepsTheChosenFamilyAndType() async {
        let plain = item(text: "plain", pinned: false)
        var image = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain, image])
        model.contentFilter = .image
        image.setImageSearchText("help@example.com")
        model.updateItems([plain, image])
        XCTAssertEqual(model.availableFilterFamilies, [.type])
        model.refreshFiltersForReactivation(items: [plain, image])
        await model.waitForFilterRefreshForTesting()
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.availableFilterFamilies, [.type, .content])
        XCTAssertEqual(model.selectedFilterFamily, .type)
        XCTAssertEqual(model.contentFilter, .image)
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])
    }

    func testReturningKeepsAnEmptyActiveFilterVisibleAndClearable() async {
        let plain = item(text: "plain", pinned: false)
        let image = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [plain, image])
        model.contentFilter = .image
        model.refreshFiltersForReactivation(items: [plain])
        await model.waitForFilterRefreshForTesting()
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.contentFilter, .image)
        XCTAssertEqual(model.availableFilterFamilies, [.type])
        XCTAssertTrue(model.availableContentFilters.contains(.image))
        XCTAssertTrue(model.visibleItems.isEmpty)
        XCTAssertTrue(model.selectFilterOption(at: 0))
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [plain.id])
    }

    func testFamilyCyclingWrapsWithoutChangingFiltersOrSelection() async {
        var savedText = item(text: "person@example.com", pinned: false)
        savedText.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Email", savedAt: Date()))
        let pdf = item(payload: payload(typeIdentifier: NSPasteboard.PasteboardType.pdf.rawValue), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [savedText, pdf])
        await model.waitForSearchForTesting()
        let selectedID = model.selectedItemID
        XCTAssertEqual(model.availableFilterFamilies, [.scope, .type, .content])
        model.selectFilterFamily(.scope)
        model.cycleFilterFamily(offset: -1)
        XCTAssertEqual(model.selectedFilterFamily, .content)
        model.cycleFilterFamily()
        XCTAssertEqual(model.selectedFilterFamily, .scope)
        model.cycleFilterFamily()
        XCTAssertEqual(model.selectedFilterFamily, .type)
        XCTAssertEqual(model.mode, .all)
        XCTAssertEqual(model.contentFilter, .all)
        XCTAssertEqual(model.semanticFilter, .any)
        XCTAssertEqual(model.selectedItemID, selectedID)
    }

    func testSingleAvailableFamilySupportsOptionsButIgnoresCycling() {
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [
            item(text: "plain", pinned: false), item(text: "https://example.com", pinned: false),
        ])
        XCTAssertEqual(model.availableFilterFamilies, [.content])
        model.selectFilterFamily(.scope)
        model.cycleFilterFamily()
        model.cycleFilterFamily(offset: -1)
        XCTAssertEqual(model.selectedFilterFamily, .content)
        XCTAssertEqual(model.filterOptionCount, 2)
        XCTAssertTrue(model.selectFilterOption(at: 1))
        XCTAssertEqual(model.semanticFilter, .link)
    }

    func testGlobalShortcutDismissesOnlyTheVisibleKeyHistoryPanel() {
        XCTAssertTrue(ClipboardHistoryPanelController.shouldDismissForGlobalShortcut(
            isVisible: true,
            isKeyWindow: true
        ))
        XCTAssertFalse(ClipboardHistoryPanelController.shouldDismissForGlobalShortcut(
            isVisible: true,
            isKeyWindow: false
        ))
        XCTAssertFalse(ClipboardHistoryPanelController.shouldDismissForGlobalShortcut(
            isVisible: false,
            isKeyWindow: false
        ))
    }

    func testMultipleSelectionSupportsConstantTimeLookupAndVisibleSelectAll() async {
        let items = (0..<500).map { index in
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

    func testMultipleSelectionStopsAtQueueLimitAndReportsRejectedAppend() async {
        let items = (0..<(ClipboardHistoryPanelModel.maximumMultiSelectionItemCount + 1)).map {
            item(text: "item-\($0)", pinned: false)
        }
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.setMultiSelectionEnabled(true)

        for item in items where !model.selectedItemIDs.contains(item.id) {
            model.toggleMultiSelection(for: item.id)
        }

        XCTAssertEqual(
            model.selectedItemIDs.count,
            ClipboardHistoryPanelModel.maximumMultiSelectionItemCount
        )
        XCTAssertEqual(model.selectionLimitReachedRevision, 1)
        XCTAssertEqual(Set(items.map(\.id)).subtracting(model.selectedItemIDs).count, 1)
    }

    func testOpeningDefaultsToScopeWhenAvailableAndFallsBackToType() {
        let model = ClipboardHistoryPanelModel()
        let history = item(text: "history", pinned: false)
        let snippet = ClipboardSavedItem(title: "Snippet", savedKind: .snippet,
            payload: .plainText("template"), templateText: "template")
        model.prepareForPresentation(items: [history], savedItems: [snippet])
        XCTAssertEqual(model.selectedFilterFamily, .scope)
        XCTAssertEqual(model.mode, .all)
        XCTAssertEqual(ClipboardHistoryFilterFamily.resolvedSelection(current: .scope,
            available: [.type, .content]), .type)
    }

    func testCheckboxMarkingDoesNotMoveFocusAndEmptySelectionHasNoActionTarget() async {
        let model = ClipboardHistoryPanelModel()
        let items = [item(text: "first", pinned: false), item(text: "second", pinned: false)]
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()
        model.selectedItemID = items[0].id
        model.setMultiSelectionEnabled(true)
        model.toggleMultiSelection(for: items[1].id)
        XCTAssertEqual(model.selectedItemID, items[0].id)
        XCTAssertEqual(model.actionItemIDs, items.map(\.id))
        model.clearMultiSelection()
        XCTAssertTrue(model.actionItemIDs.isEmpty)
        XCTAssertEqual(model.selectedItemID, items[0].id)
        model.setMultiSelectionEnabled(false)
        XCTAssertEqual(model.actionItemIDs, [items[0].id])
    }

    func testSelectAllAppendsInVisibleOrderWithoutReorderingExistingSelection() async {
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: (0..<4).map { item(text: "\($0)", pinned: false) })
        await model.waitForSearchForTesting()
        let ids = model.visibleItems.map(\.id)
        model.selectedItemID = ids[2]
        model.setMultiSelectionEnabled(true)
        model.toggleMultiSelection(for: ids[0])
        model.selectAllVisibleItems()
        XCTAssertEqual(model.actionItemIDs, [ids[2], ids[0], ids[1], ids[3]])
        XCTAssertTrue(model.areAllVisibleItemsSelected)
        model.toggleMultiSelection(for: ids[0])
        model.toggleMultiSelection(for: ids[0])
        XCTAssertEqual(model.actionItemIDs, [ids[2], ids[1], ids[3], ids[0]])
        XCTAssertEqual(model.selectionNumber(for: ids[0]), 4)
        model.clearMultiSelection()
        XCTAssertFalse(model.areAllVisibleItemsSelected)
    }

    func testMultiSelectionNumbersNeverFallBackToQuickPasteBadges() {
        let model = ClipboardHistoryPanelModel()
        let first = item(text: "first", pinned: false)
        let second = item(text: "second", pinned: false)
        model.prepareForPresentation(items: [first, second])
        model.selectedItemID = first.id
        XCTAssertEqual(model.rowNumber(for: second.id, quickPasteNumber: 2), 2)
        model.setMultiSelectionEnabled(true)
        XCTAssertEqual(model.rowNumber(for: first.id, quickPasteNumber: 1), 1)
        XCTAssertNil(model.rowNumber(for: second.id, quickPasteNumber: 2))
    }

    func testStandardPasteAndCopyUseCombinedSelectionInMultiSelectMode() {
        XCTAssertEqual(command(keyCode: 36, isMultiSelectionEnabled: true), .pasteCombinedSelection)
        XCTAssertEqual(command(keyCode: 36, modifiers: .shift, isMultiSelectionEnabled: true), .pasteCombinedSelection)
        XCTAssertEqual(command(keyCode: 8, modifiers: .command, isMultiSelectionEnabled: true), .copyCombinedSelection)
        XCTAssertEqual(command(keyCode: 8, modifiers: .command, isEditingText: true,
                               isMultiSelectionEnabled: true), .copyCombinedSelection)
        XCTAssertNil(command(keyCode: 8, modifiers: .command, isEditingText: true,
                             hasSelectedText: true, isMultiSelectionEnabled: true))
        XCTAssertEqual(command(keyCode: 36), .pasteSelection(asPlainText: false))
    }

    func testSavedSnippetCanParticipateInMixedMultiSelection() async {
        let captured = item(text: "history", pinned: false)
        let savedItem = ClipboardSavedItem(
            title: "Saved only",
            savedKind: .snippet,
            payload: .plainText("saved only"),
            templateText: "saved only"
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [captured], savedItems: [savedItem])
        await model.waitForSearchForTesting()

        model.selectedItemID = savedItem.id
        model.setMultiSelectionEnabled(true)
        XCTAssertTrue(model.canStartSequentialQueue)
        model.toggleMultiSelection(for: captured.id)

        XCTAssertTrue(model.isMultiSelectionEnabled)
        XCTAssertEqual(model.selectedItemIDs, [savedItem.id, captured.id])
        XCTAssertTrue(model.canStartSequentialQueue)

        model.clearMultiSelection()
        XCTAssertFalse(model.canStartSequentialQueue)
        model.selectedItemID = captured.id
        model.toggleFocusedSelection()
        XCTAssertEqual(model.selectedItemIDs, [captured.id])
        XCTAssertTrue(model.canStartSequentialQueue)
    }

    func testHistoryPanelUsesNativeResizableTitlelessWindowMask() {
        let styleMask = ClipboardHistoryPanelController.panelStyleMask

        XCTAssertTrue(styleMask.contains(.titled))
        XCTAssertTrue(styleMask.contains(.resizable))
        XCTAssertTrue(styleMask.contains(.fullSizeContentView))
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

    func testAllScopeKeepsMatchingSavedCapturedItemAndSnippetDistinct() async {
        let payload = ClipboardHistoryPayload.plainText("shared text")
        var historyItem = item(payload: payload, pinned: false)
        historyItem.setSavedMetadata(ClipboardHistorySavedMetadata(
            title: "Saved clip",
            savedAt: Date()
        ))
        let matchingSnippet = ClipboardSavedItem(
            title: "Matching snippet",
            savedKind: .snippet,
            payload: payload,
            templateText: "shared text"
        )
        let model = ClipboardHistoryPanelModel()

        model.prepareForPresentation(
            items: [historyItem],
            savedItems: [matchingSnippet]
        )
        await model.waitForSearchForTesting()

        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([historyItem.id, matchingSnippet.id]))
        XCTAssertEqual(
            ClipboardHistoryPanelModel.logicalItemCount(
                historyItems: [historyItem],
                savedItems: [matchingSnippet]
            ),
            2
        )
        XCTAssertEqual(
            ClipboardHistoryPanelModel.logicalItemCount(
                historyItems: [],
                savedItems: [matchingSnippet]
            ),
            1
        )
    }

    func testScopeOptionSelectionExcludesSavedOnlyItems() async {
        let historyItem = item(text: "history", pinned: false)
        let savedItem = ClipboardSavedItem(
            title: "saved",
            savedKind: .snippet,
            payload: .plainText("saved"),
            templateText: "saved"
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [historyItem], savedItems: [savedItem])
        await model.waitForSearchForTesting()

        model.selectFilterFamily(.scope)
        model.selectFilterOption(at: 1)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.mode, .history)
        XCTAssertEqual(model.visibleItems.map(\.id), [historyItem.id])

        model.selectFilterOption(at: 2)
        XCTAssertEqual(model.mode, .snippets)
        model.selectFilterOption(at: 0)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.mode, .all)
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([historyItem.id, savedItem.id]))

        model.selectFilterOption(at: 2)
        XCTAssertEqual(model.mode, .snippets)
    }

    func testConfiguredPanelShortcutCanReplaceAndClearTheDefaultBinding() {
        let customActions = ShortcutBinding(keyCode: 3, modifiers: [.command, .option])
        XCTAssertEqual(
            command(
                keyCode: 3,
                modifiers: [.command, .option],
                panelShortcutBindings: [
                    ClipboardHistoryPlugin.ShortcutID.panelActions: customActions,
                ]
            ),
            .toggleActionMenu
        )
        XCTAssertNil(command(
            keyCode: 40,
            modifiers: .command,
            panelShortcutBindings: [:]
        ))

        let customScope = ShortcutBinding(keyCode: 38, modifiers: [.command])
        XCTAssertEqual(
            command(
                keyCode: 38,
                modifiers: .command,
                panelShortcutBindings: [
                    ClipboardHistoryPlugin.ShortcutID.panelCycleScope: customScope,
                ]
            ),
            .cycleFilterFamily(offset: 1)
        )
        XCTAssertEqual(
            command(
                keyCode: 38,
                modifiers: [.command, .shift],
                panelShortcutBindings: [
                    ClipboardHistoryPlugin.ShortcutID.panelCycleScope: customScope,
                ]
            ),
            .cycleFilterFamily(offset: -1)
        )

        XCTAssertEqual(
            command(
                keyCode: 14,
                modifiers: [.command, .shift],
                panelShortcutBindings: [
                    ClipboardHistoryPlugin.ShortcutID.panelCycleScope: ShortcutBinding(
                        keyCode: 14,
                        modifiers: .command
                    ),
                    ClipboardHistoryPlugin.ShortcutID.panelShare: ShortcutBinding(
                        keyCode: 14,
                        modifiers: [.command, .shift]
                    ),
                ]
            ),
            .shareSelection
        )
    }

    func testEditSnippetHasDistinctCustomizableShortcutAndRespectsFocus() {
        XCTAssertEqual(command(keyCode: 14, modifiers: [.command, .option]), .editSnippet)
        XCTAssertEqual(command(keyCode: 14, modifiers: .command), .showExportMenu)
        XCTAssertEqual(command(keyCode: 14, modifiers: [.command, .shift]), .shareSelection)
        XCTAssertNil(command(keyCode: 14, modifiers: [.command, .option], hasAttachedSheet: true))
        XCTAssertNil(command(keyCode: 14, modifiers: [.command, .option], isPanelKeyWindow: false))
        XCTAssertNil(command(keyCode: 14, modifiers: [.command, .option], hasMarkedText: true))
        XCTAssertNil(command(keyCode: 14, modifiers: [.command, .option], panelShortcutBindings: [:]))
        let bindings = [ClipboardHistoryPlugin.ShortcutID.panelEditSnippet:
            ShortcutBinding(keyCode: 3, modifiers: [.command, .option])]
        XCTAssertEqual(command(keyCode: 3, modifiers: [.command, .option], panelShortcutBindings: bindings), .editSnippet)
        XCTAssertNil(command(keyCode: 14, modifiers: [.command, .option], panelShortcutBindings: bindings))
        XCTAssertEqual(ClipboardHistoryPlugin.defaultPanelShortcutBinding(
            ClipboardHistoryPlugin.ShortcutID.panelEditSnippet
        ), ShortcutBinding(keyCode: 14, modifiers: [.command, .option]))
    }

    func testEditRequestOnlyOpensOneSelectedSnippet() async {
        let model = ClipboardHistoryPanelModel()
        let clip = item(text: "Captured text", pinned: false)
        let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText("Hello"), templateText: "Hello")
        model.prepareForPresentation(items: [clip], savedItems: [snippet])
        await model.waitForSearchForTesting()
        model.selectedItemID = clip.id
        model.requestSavedItemEdit()
        XCTAssertEqual(model.savedEditRequestID, 0)
        model.selectedItemID = snippet.id
        model.requestSavedItemEdit()
        XCTAssertEqual(model.savedEditRequestID, 1)
        model.setMultiSelectionEnabled(true)
        model.toggleMultiSelection(for: clip.id)
        model.toggleMultiSelection(for: snippet.id)
        model.requestSavedItemEdit()
        XCTAssertEqual(model.savedEditRequestID, 1)
        model.selectedItemID = nil
        model.requestSavedItemEdit()
        XCTAssertEqual(model.savedEditRequestID, 1)
    }

    func testPanelActionStateRejectsDuplicateAndStaleOperations() throws {
        var state = ClipboardHistoryPanelActionState()
        state.beginPresentation()
        let first = try XCTUnwrap(state.beginAction())

        XCTAssertNil(state.beginAction())
        XCTAssertTrue(state.isCurrent(first, panelIsVisible: true))
        XCTAssertFalse(state.isCurrent(first, panelIsVisible: false))

        state.invalidatePresentation()
        XCTAssertFalse(state.isCurrent(first, panelIsVisible: true))
        let second = try XCTUnwrap(state.beginAction())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.commit(first))
        XCTAssertTrue(state.commit(second))
        XCTAssertFalse(state.isCurrent(second, panelIsVisible: true))
    }

    func testHistoryPanelCentersOnlyBeforeItsFirstPresentation() {
        XCTAssertTrue(ClipboardHistoryPanelController.shouldCenterPanel(hasExistingPanel: false))
        XCTAssertFalse(ClipboardHistoryPanelController.shouldCenterPanel(hasExistingPanel: true))
    }

    func testActionPalettePrefersTheRightSideAndStaysInsideTheDisplay() {
        let display = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: 430, height: 520)
        XCTAssertEqual(
            ClipboardHistoryActionPalettePlacement.origin(
                parentFrame: NSRect(x: 100, y: 120, width: 700, height: 620),
                paletteSize: size,
                visibleFrame: display
            ),
            NSPoint(x: 810, y: 220)
        )
        XCTAssertEqual(
            ClipboardHistoryActionPalettePlacement.origin(
                parentFrame: NSRect(x: 620, y: 120, width: 800, height: 620),
                paletteSize: size,
                visibleFrame: display
            ),
            NSPoint(x: 1_010, y: 220)
        )
    }

    func testWindowLayoutTargetRequiresVisibleKeyPanel() {
        XCTAssertTrue(ClipboardHistoryPanelController.isEligibleWindowLayoutTarget(
            isVisible: true,
            isKeyWindow: true
        ))
        XCTAssertFalse(ClipboardHistoryPanelController.isEligibleWindowLayoutTarget(
            isVisible: true,
            isKeyWindow: false
        ))
        XCTAssertFalse(ClipboardHistoryPanelController.isEligibleWindowLayoutTarget(
            isVisible: false,
            isKeyWindow: true
        ))
        XCTAssertTrue(ClipboardHistoryPanelController.isEligibleWindowLayoutTarget(
            isVisible: true,
            isKeyWindow: false,
            isActionPaletteKeyWindow: true
        ))
    }

    func testSequentialPasteHUDRestoredFrameIsClampedToVisibleDisplay() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let restored = NSRect(x: 1_500, y: -300, width: 410, height: 142)

        XCTAssertEqual(
            ClipboardSequentialPasteHUDController.clampedFrame(restored, to: visibleFrame),
            NSRect(x: 590, y: 0, width: 410, height: 142)
        )
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

    func testRetryLoadingDoesNotPresentEmptyHistory() {
        let presentation = ClipboardHistoryPanelPresentation.resolve(
            itemCount: 0,
            visibleItemCount: 0,
            hasStorageError: false,
            isLoaded: false
        )

        XCTAssertTrue(presentation.showsLoading)
        XCTAssertFalse(presentation.showsEmptyState)
        XCTAssertFalse(presentation.showsErrorOnly)
        XCTAssertFalse(presentation.showsHistory)
    }

    func testFocusRestorationTargetIsReplacedAndConsumedForEveryPresentation() {
        var state = ClipboardHistoryPreviousApplicationState<String>()
        state.beginPresentation(frontmostApplication: "Browser", isExternal: { _ in true })
        XCTAssertEqual(state.application, "Browser")

        state.beginPresentation(frontmostApplication: "MacTools", isExternal: { _ in false })
        XCTAssertNil(state.application)
        XCTAssertNil(state.consume())

        state.beginPresentation(frontmostApplication: "Editor", isExternal: { _ in true })
        XCTAssertEqual(state.consume(), "Editor")
        XCTAssertNil(state.application)
    }

    func testCommandsRequireTheActivePanelWithoutAnAttachedSheet() {
        XCTAssertNil(command(keyCode: 36, isPanelEvent: false))
        XCTAssertNil(command(keyCode: 36, isPanelKeyWindow: false))
        XCTAssertNil(command(keyCode: 36, hasAttachedSheet: true))
    }

    func testMarkedTextPassesReturnAndEscapeToTheInputMethod() {
        XCTAssertNil(command(keyCode: 36, hasMarkedText: true))
        XCTAssertNil(command(keyCode: 53, hasMarkedText: true))
    }

    func testPanelCommandsResolveWhenTextIsNotBeingComposed() {
        XCTAssertEqual(command(keyCode: 36), .pasteSelection(asPlainText: false))
        XCTAssertEqual(
            command(keyCode: 36, modifiers: .shift),
            .pasteSelection(asPlainText: true)
        )
        XCTAssertEqual(command(keyCode: 53), .close)
        XCTAssertEqual(command(keyCode: 35, modifiers: .command), .saveSelection)
        XCTAssertEqual(command(keyCode: 8, modifiers: .command), .copySelection)
        XCTAssertEqual(command(keyCode: 8, modifiers: .command, isEditingText: true), .copySelection)
        XCTAssertNil(command(keyCode: 8, modifiers: .command,
                             isEditingText: true, hasSelectedText: true))
        XCTAssertEqual(command(keyCode: 14, modifiers: .command), .showExportMenu)
        XCTAssertEqual(command(keyCode: 14, modifiers: [.command, .shift]), .shareSelection)
        XCTAssertEqual(command(keyCode: 48, modifiers: .control), .cycleFilterFamily(offset: 1))
        XCTAssertEqual(
            command(keyCode: 48, modifiers: [.control, .shift]),
            .cycleFilterFamily(offset: -1)
        )
        XCTAssertNil(command(keyCode: 47, modifiers: .command))
    }

    func testSharedPaletteSearchFieldUsesShiftReturnForPlainTextPaste() {
        XCTAssertEqual(
            PluginPaletteSearchField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false,
                modifierFlags: .shift,
                alternateSubmitModifier: .shift
            ),
            .alternateSubmit
        )
        XCTAssertEqual(
            PluginPaletteSearchField.command(
                for: #selector(NSResponder.insertNewline(_:)),
                hasMarkedText: false,
                alternateSubmitModifier: .shift
            ),
            .submit
        )
        XCTAssertFalse(
            PluginPaletteSearchField.isAlternateSubmitKeyEquivalent(
                keyCode: 36,
                modifierFlags: .command,
                alternateSubmitModifier: .shift
            )
        )
    }

    func testArrowKeysMoveHistorySelectionWhileSearchIsFocused() {
        XCTAssertEqual(command(keyCode: 125, isEditingText: true), .moveSelection(offset: 1))
        XCTAssertEqual(command(keyCode: 126, isEditingText: true), .moveSelection(offset: -1))
        XCTAssertEqual(
            command(keyCode: 125, modifiers: [.numericPad, .function], isEditingText: true),
            .moveSelection(offset: 1)
        )
        XCTAssertEqual(
            command(keyCode: 126, modifiers: [.numericPad, .function], isEditingText: true),
            .moveSelection(offset: -1)
        )
        XCTAssertNil(command(keyCode: 125, modifiers: .command, isEditingText: true))
    }

    func testControlPNMoveSelectionWhileSearchIsFocused() {
        XCTAssertEqual(
            command(keyCode: 35, modifiers: .control, isEditingText: true),
            .moveSelection(offset: -1)
        )
        XCTAssertEqual(
            command(keyCode: 45, modifiers: .control, isEditingText: true),
            .moveSelection(offset: 1)
        )
        XCTAssertEqual(command(keyCode: 35, modifiers: .command), .saveSelection)
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

    func testControlNumberSelectsAnOptionInTheActiveFamily() {
        let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

        for (index, keyCode) in keyCodes.enumerated() {
            XCTAssertEqual(
                command(keyCode: keyCode, modifiers: .control, isEditingText: true),
                .selectFilterOption(index: index)
            )
        }

        XCTAssertNil(command(keyCode: 29, modifiers: .control, isEditingText: true))
    }

    func testOptionNumbersAreNoLongerInterceptedForFiltering() {
        for keyCode: UInt16 in [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] {
            XCTAssertNil(command(keyCode: keyCode, modifiers: .option, isEditingText: true))
        }
    }

    func testVisibleOrderUsesCaptureDateRatherThanLegacyPinState() async {
        let recent = item(
            text: "recent",
            pinned: false,
            capturedAt: Date(),
            lastUsedAt: nil
        )
        let legacyPin = item(
            text: "legacy pin",
            pinned: true,
            capturedAt: Date().addingTimeInterval(-60),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()

        model.updateItems([legacyPin, recent])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.visibleItems.map(\.id), [recent.id, legacyPin.id])
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

    func testTenThousandItemPresentationSchedulesWithinInteractiveBudget() async {
        let now = Date()
        let items = (0..<ClipboardHistorySettings.maximumSupportedItemCount).map { index in
            item(
                text: "result \(index)",
                pinned: false,
                capturedAt: now.addingTimeInterval(TimeInterval(-index)),
                lastUsedAt: nil
            )
        }
        let model = ClipboardHistoryPanelModel()
        let startedAt = Date()

        model.prepareForPresentation(items: items)

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
        XCTAssertTrue(model.hasMoreResults)
    }

    func testExtremeSearchKeepsOnlyTheVisiblePageWithinInteractiveBudget() async {
        let now = Date()
        let items = (0..<50_000).map { index in
            item(
                text: "shared extreme result \(index)",
                pinned: false,
                capturedAt: now.addingTimeInterval(TimeInterval(-index)),
                lastUsedAt: nil
            )
        }
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: items)
        await model.waitForSearchForTesting()

        for query in ["shared result", "ar"] {
            let startedAt = ContinuousClock.now
            model.query = query
            await model.waitForSearchForTesting()
            let elapsed = ContinuousClock.now - startedAt

            XCTAssertEqual(model.visibleItems.count, ClipboardHistoryPanelModel.resultPageSize)
            XCTAssertTrue(model.hasMoreResults)
            XCTAssertLessThan(elapsed, .seconds(2), query)
        }
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

    func testFinderFilesMatchBothFilesAndTheirSemanticTypeFilters() async {
        let pdf = item(payload: filePayload(named: "Guide.PDF"), pinned: false)
        let image = item(payload: filePayload(named: "Screenshot.png"), pinned: false)
        let audio = item(payload: filePayload(named: "Recording.m4a"), pinned: false)
        let video = item(payload: filePayload(named: "Demo.mov"), pinned: false)
        let ordinaryFile = item(payload: filePayload(named: "Notes.txt"), pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.updateItems([pdf, image, audio, video, ordinaryFile])

        XCTAssertEqual(pdf.kind, .files)
        XCTAssertEqual(audio.kind, .files)

        model.contentFilter = .files
        await model.waitForSearchForTesting()
        XCTAssertEqual(
            Set(model.visibleItems.map(\.id)),
            Set([pdf.id, image.id, audio.id, video.id, ordinaryFile.id])
        )

        model.contentFilter = .pdf
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [pdf.id])

        model.contentFilter = .image
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])

        model.contentFilter = .media
        await model.waitForSearchForTesting()
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([audio.id, video.id]))
    }

    func testPayloadWithMultipleRepresentationsMatchesEveryRelevantFilter() {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.pdf,
                    data: Data([0x01])
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.tiff,
                    data: Data([0x02])
                ),
            ]),
        ])

        XCTAssertTrue(ClipboardHistoryContentFilter.pdf.matches(payload))
        XCTAssertTrue(ClipboardHistoryContentFilter.image.matches(payload))
        XCTAssertFalse(ClipboardHistoryContentFilter.files.matches(payload))
    }

    func testPanelPresentationResetsTheTypeFilter() async {
        let text = item(text: "plain", pinned: false)
        let image = item(
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            pinned: false
        )
        let model = ClipboardHistoryPanelModel()
        model.updateItems([text, image])
        model.contentFilter = .image

        model.prepareForPresentation(items: [text, image])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.contentFilter, .all)
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), Set([text.id, image.id]))
    }

    func testPanelPresentationOrdersAllItemsByCaptureDate() async {
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
        let model = ClipboardHistoryPanelModel()

        model.prepareForPresentation(items: [recentlyCaptured, recentlyUsed, pinned])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.visibleItems.map(\.id), [recentlyCaptured.id, recentlyUsed.id, pinned.id])
        XCTAssertEqual(model.selectedItemID, recentlyCaptured.id)
        XCTAssertEqual(model.consumeRequestedScrollItemID(), recentlyCaptured.id)
    }

    func testUsageUpdateNeverReordersHistory() async {
        let now = Date()
        let first = item(text: "first", pinned: false, capturedAt: now, lastUsedAt: nil)
        let second = item(
            text: "second",
            pinned: false,
            capturedAt: now.addingTimeInterval(-60),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        await model.waitForSearchForTesting()

        var usedSecond = second
        usedSecond.lastUsedAt = now.addingTimeInterval(30)
        model.updateItems([first, usedSecond])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.visibleItems.map(\.id), [first.id, second.id])
        model.prepareForPresentation(items: [first, usedSecond])
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [first.id, second.id])
    }

    func testAllScopeUsesCaptureAndUpdateDatesInsteadOfLastUseDates() async {
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
        XCTAssertEqual(model.visibleItems.map(\.id), [historyItem.id, snippet.id])
    }

    func testDeletingSelectedMiddleItemKeepsSelectionAtItsPosition() async {
        let now = Date()
        let first = item(text: "first", pinned: false, capturedAt: now, lastUsedAt: nil)
        let middle = item(
            text: "middle",
            pinned: false,
            capturedAt: now.addingTimeInterval(-1),
            lastUsedAt: nil
        )
        let last = item(
            text: "last",
            pinned: false,
            capturedAt: now.addingTimeInterval(-2),
            lastUsedAt: nil
        )
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, middle, last])
        await model.waitForSearchForTesting()
        model.selectedItemID = middle.id

        model.selectNeighborBeforeRemoving(itemID: middle.id)
        model.updateItems([first, last])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.selectedItemID, last.id)
    }

    func testDeletingLastSelectedItemSelectsPreviousAndNonselectedDeletePreservesSelection() async {
        let first = item(text: "first", pinned: false)
        let middle = item(text: "middle", pinned: false)
        let last = item(text: "last", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, middle, last])
        await model.waitForSearchForTesting()
        model.selectedItemID = last.id

        model.selectNeighborBeforeRemoving(itemID: last.id)
        XCTAssertEqual(model.selectedItemID, middle.id)

        model.selectNeighborBeforeRemoving(itemID: first.id)
        XCTAssertEqual(model.selectedItemID, middle.id)
    }

    func testImageTextAvailabilityDistinguishesPendingAvailableAndUnavailable() {
        var image = ClipboardHistoryItem(
            id: UUID(),
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        XCTAssertEqual(ClipboardImageTextAvailability(item: image), .pending)

        image.hasCompletedImageTextIndexing = true
        image.setImageSearchText("Recognized")
        XCTAssertEqual(ClipboardImageTextAvailability(item: image), .available)

        image.setImageSearchText("  ")
        XCTAssertEqual(ClipboardImageTextAvailability(item: image), .unavailable)
    }

    func testImagePreviewLayoutAspectFitsWideAndTallImagesWithPadding() {
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: CGSize(width: 400, height: 200),
                containerSize: CGSize(width: 300, height: 300),
                padding: 10
            ),
            CGSize(width: 280, height: 140)
        )
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: CGSize(width: 200, height: 400),
                containerSize: CGSize(width: 300, height: 300),
                padding: 10
            ),
            CGSize(width: 140, height: 280)
        )
    }

    func testImagePreviewLayoutRejectsInvalidOrUnusableGeometry() {
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: .zero,
                containerSize: CGSize(width: 300, height: 300)
            ),
            .zero
        )
        XCTAssertEqual(
            ClipboardImagePreviewLayout.aspectFitSize(
                contentSize: CGSize(width: 100, height: 100),
                containerSize: CGSize(width: 20, height: 20),
                padding: 20
            ),
            .zero
        )
    }

    func testRelativeTimestampUsesOneMeaningfulLocalizedUnit() {
        let locale = Locale(identifier: "en_US")
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let fifteenHoursAgo = referenceDate.addingTimeInterval(-15 * 60 * 60)
        let fiveMinutesAgo = referenceDate.addingTimeInterval(-5 * 60)
        let oneMinuteAgo = referenceDate.addingTimeInterval(-60)

        let hours = ClipboardHistoryTimestampFormatting.relativeString(
            for: fifteenHoursAgo,
            relativeTo: referenceDate,
            locale: locale
        )
        let minutes = ClipboardHistoryTimestampFormatting.relativeString(
            for: fiveMinutesAgo,
            relativeTo: referenceDate,
            locale: locale
        )
        let oneMinute = ClipboardHistoryTimestampFormatting.relativeString(
            for: oneMinuteAgo,
            relativeTo: referenceDate,
            locale: locale
        )

        XCTAssertEqual(hours, "15 hours ago")
        XCTAssertEqual(minutes, "5 minutes ago")
        XCTAssertEqual(oneMinute, "1 minute ago")
    }

    func testShiftCommandDeleteRemovesASelectedItemWithoutClaimingEditingShortcuts() {
        XCTAssertNil(command(keyCode: 51, isEditingText: true))
        XCTAssertNil(command(keyCode: 51))
        XCTAssertNil(command(keyCode: 51, modifiers: .command, isEditingText: true))
        XCTAssertNil(command(keyCode: 51, modifiers: .command))
        XCTAssertNil(command(keyCode: 51, modifiers: .option, isEditingText: true))
        XCTAssertEqual(
            command(keyCode: 51, modifiers: [.command, .shift], isEditingText: true),
            .deleteSelection
        )
        XCTAssertEqual(
            command(keyCode: 51, modifiers: [.command, .shift]),
            .deleteSelection
        )
    }

    func testRichTextPreviewAndPlainTextConversionPreserveUsefulContent() throws {
        let richItem = item(
            payload: ClipboardHistoryPayload(pasteboardItems: [
                ClipboardStoredPasteboardItem(representations: [
                    ClipboardStoredRepresentation(
                        typeIdentifier: ClipboardRepresentationType.rtf,
                        data: Data("{\\rtf1\\b Formatted\\b0  note}".utf8)
                    ),
                ]),
            ]),
            pinned: false
        )
        let richPayload = try XCTUnwrap(richItem.payload)
        let attributedString = try XCTUnwrap(ClipboardRichText.attributedString(for: richPayload))

        XCTAssertEqual(attributedString.string, "Formatted note")
        XCTAssertEqual(ClipboardPlainTextConversion.text(for: richItem), "Formatted note")
        guard case let .formatted(preview) = ClipboardRichTextPreviewPolicy.makePreview(
            payload: richPayload,
            fallbackText: richItem.text
        ) else {
            return XCTFail("Expected a formatted rich-text preview")
        }
        XCTAssertEqual(String(preview.characters), "Formatted note")

        let imageItem = ClipboardHistoryItem(
            id: UUID(),
            payload: payload(typeIdentifier: ClipboardRepresentationType.png),
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: "Recognized screenshot text",
            hasCompletedImageTextIndexing: true
        )
        XCTAssertEqual(
            ClipboardPlainTextConversion.text(for: imageItem),
            "Recognized screenshot text"
        )
    }

    func testRichPlainTextConversionUsesVisibleTextAndPreservesVisibleQuotes() {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("\"CSV wrapped\"".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.html,
                    data: Data("<meta charset='utf-8'><span>Visible “quotation marks” remain</span>".utf8)
                ),
            ]),
        ])
        let item = item(payload: payload, pinned: false)

        XCTAssertEqual(
            ClipboardPlainTextConversion.text(for: item),
            "Visible “quotation marks” remain"
        )
    }

    func testOversizedRichPlainTextConversionFallsBackToCompleteNativeText() {
        let nativeText = "\"Keep producer text\""
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data(nativeText.utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data(
                        repeating: 0x20,
                        count: ClipboardRichTextPreviewPolicy.maximumFormattedByteCount + 1
                    )
                ),
            ]),
        ])
        let item = item(payload: payload, pinned: false)

        XCTAssertEqual(ClipboardPlainTextConversion.text(for: item), nativeText)
    }

    func testImagePlainTextConversionUsesCompletedOCRWithoutLoadingPayload() {
        let loadCounter = ClipboardPayloadLoadCounter()
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: "",
            capturedAt: Date(),
            sourceApplication: nil,
            kind: .image,
            payloadByteCount: 1,
            filterContentKinds: [.image],
            fileURLs: [],
            representationTypeIdentifiers: [ClipboardRepresentationType.png],
            payloadDigest: Data("ocr-only".utf8),
            allowsRichTextImport: false,
            textCharacterCount: 0,
            textLineCount: 0,
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: "Recognized without payload",
            hasCompletedImageTextIndexing: true,
            payloadLoader: {
                loadCounter.increment()
                return ClipboardHistoryPayload(pasteboardItems: [])
            }
        )

        XCTAssertEqual(
            ClipboardPlainTextConversion.text(for: item),
            "Recognized without payload"
        )
        XCTAssertEqual(loadCounter.value, 0)
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

    func testOversizedRichTextUsesBoundedPlainTextWithoutImportingFormatting() {
        let fallbackText = String(repeating: "a", count: 20_000)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data(
                        repeating: 0x20,
                        count: ClipboardRichTextPreviewPolicy.maximumFormattedByteCount + 1
                    )
                ),
            ]),
        ])

        guard case let .plainText(preview, isSimplified) =
            ClipboardRichTextPreviewPolicy.makePreview(
                payload: payload,
                fallbackText: fallbackText
            ) else {
            return XCTFail("Expected a simplified preview")
        }

        XCTAssertTrue(isSimplified)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(preview.dropLast().count, ClipboardRichTextPreviewPolicy.maximumFormattedCharacterCount)
        let item = item(payload: payload, pinned: false)
        XCTAssertFalse(ClipboardPlainTextConversion.isAvailable(for: item))
    }

    func testLargePlainTextBoundsSearchPreviewButPreservesFullPlainTextPaste() {
        let fullText = String(repeating: "large clipboard line\n", count: 2_000)
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: fullText,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )

        XCTAssertEqual(item.text.count, ClipboardHistoryItem.maximumSearchableCharacterCount)
        XCTAssertTrue(item.isSearchTextTruncated)
        XCTAssertEqual(item.textCharacterCount, fullText.count)
        XCTAssertEqual(item.textLineCount, 2_001)
        XCTAssertEqual(ClipboardPlainTextConversion.text(for: item), fullText)
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

    func testNormalNavigationWrapsWhileRangeExtensionClamps() async {
        let first = item(text: "First", pinned: false, capturedAt: Date(timeIntervalSince1970: 1), lastUsedAt: nil)
        let second = item(text: "Second", pinned: false, capturedAt: Date(timeIntervalSince1970: 2), lastUsedAt: nil)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        await model.waitForSearchForTesting()

        XCTAssertEqual(model.selectedItemID, second.id)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedItemID, first.id)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedItemID, second.id)

        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItemID, first.id)
        model.setMultiSelectionEnabled(true)
        model.extendSelection(by: 1)
        model.extendSelection(by: 1)
        XCTAssertEqual(model.selectedItemID, first.id)
    }

    func testSavedNavigationAndActionIndexWrappingUseTheSamePolicy() {
        let model = ClipboardHistoryPanelModel()
        let firstID = UUID()
        let secondID = UUID()
        model.updateVisibleSavedItemIDs([firstID, secondID])

        XCTAssertEqual(model.selectedSavedItemID, firstID)
        model.moveSavedSelection(by: -1)
        XCTAssertEqual(model.selectedSavedItemID, secondID)
        XCTAssertEqual(ClipboardHistoryPanelModel.wrappedIndex(2, count: 2), 0)
        XCTAssertEqual(ClipboardHistoryPanelModel.wrappedIndex(-1, count: 2), 1)
    }

    func testKeyboardProvidesShareActionsMenuAndMultiSelectionCommands() {
        XCTAssertEqual(command(keyCode: 14, modifiers: [.command, .shift]), .shareSelection)
        XCTAssertEqual(command(keyCode: 40, modifiers: .command), .toggleActionMenu)
        XCTAssertEqual(command(keyCode: 37, modifiers: [.command]), .toggleMultiSelection)
        XCTAssertNil(command(keyCode: 49, isMultiSelectionEnabled: true))
        XCTAssertEqual(command(keyCode: 8, modifiers: [.command, .shift]), .copyCombinedSelection)
        XCTAssertEqual(command(keyCode: 36, modifiers: [.command, .shift]), .pasteCombinedSelection)
    }

    func testSpaceRemainsAvailableForSearchInMultiSelectMode() {
        XCTAssertNil(command(keyCode: 49))
        XCTAssertNil(command(keyCode: 49, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 49, isEditingText: true, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 49, modifiers: .shift, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 49, hasMarkedText: true, isMultiSelectionEnabled: true))
    }

    func testSelectAllUsesAConfigurableNonEditingShortcut() {
        XCTAssertNil(command(keyCode: 0, modifiers: .command,
                             isEditingText: true, isMultiSelectionEnabled: true))
        XCTAssertEqual(command(keyCode: 0, modifiers: [.command, .option],
                               isEditingText: true, isMultiSelectionEnabled: true), .selectAllVisible)
        XCTAssertEqual(command(keyCode: 0, modifiers: [.command, .option],
                               isMultiSelectionEnabled: true), .selectAllVisible)
        XCTAssertNil(command(keyCode: 0, modifiers: .command,
                             isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 0, modifiers: .command))
        XCTAssertNil(command(keyCode: 0, modifiers: [.command, .shift],
                             isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 0, modifiers: .command,
                             hasMarkedText: true, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 0, modifiers: .command,
                             hasAttachedSheet: true, isMultiSelectionEnabled: true))
    }

    func testCommandReturnTogglesHighlightedItemWhileSearchingOnlyInMultiSelectMode() {
        for isEditing in [false, true] {
            XCTAssertEqual(command(keyCode: 36, modifiers: .command,
                                   isEditingText: isEditing, isMultiSelectionEnabled: true), .toggleFocusedSelection)
            XCTAssertNil(command(keyCode: 36, modifiers: .command, isEditingText: isEditing))
        }
        XCTAssertNil(command(keyCode: 36, modifiers: .command,
                             hasMarkedText: true, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 36, modifiers: .command,
                             hasAttachedSheet: true, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 36, modifiers: .command,
                             isPanelEvent: false, isMultiSelectionEnabled: true))
        XCTAssertNil(command(keyCode: 36, modifiers: .command,
                             isPanelKeyWindow: false, isMultiSelectionEnabled: true))
        XCTAssertEqual(command(keyCode: 36, isEditingText: true,
                               isMultiSelectionEnabled: true), .pasteCombinedSelection)
        XCTAssertEqual(command(keyCode: 36, modifiers: [.command, .shift],
                               isEditingText: true, isMultiSelectionEnabled: true), .pasteCombinedSelection)
    }

    func testSelectionToggleHonorsCustomizationAndUnassignedBinding() {
        let bindings = [ClipboardHistoryPlugin.ShortcutID.panelToggleSelection:
            ShortcutBinding(keyCode: 1, modifiers: [.command, .option])]
        XCTAssertEqual(command(keyCode: 1, modifiers: [.command, .option],
                               isEditingText: true, isMultiSelectionEnabled: true,
                               panelShortcutBindings: bindings), .toggleFocusedSelection)
        XCTAssertNil(command(keyCode: 36, modifiers: .command, isMultiSelectionEnabled: true,
                             panelShortcutBindings: bindings))
        XCTAssertNil(command(keyCode: 36, modifiers: .command, isMultiSelectionEnabled: true,
                             panelShortcutBindings: [:]))
    }

    func testActionsShortcutTogglesFromEitherSearchFieldWithoutLeakingOtherCommands() {
        for isPresented in [false, true] {
            XCTAssertEqual(command(keyCode: 40, modifiers: .command,
                                   isEditingText: true, isActionPalettePresented: isPresented), .toggleActionMenu)
        }
        for keyCode: UInt16 in [36, 49, 53, 125, 126] {
            XCTAssertNil(command(keyCode: keyCode, isEditingText: true,
                                 isMultiSelectionEnabled: true, isActionPalettePresented: true))
        }
        for keyCode: UInt16 in [36, 37, 14, 18] {
            XCTAssertNil(command(keyCode: keyCode, modifiers: .command, isEditingText: true,
                                 isMultiSelectionEnabled: true, isActionPalettePresented: true))
        }
        XCTAssertNil(command(keyCode: 40, modifiers: .command,
                             hasMarkedText: true, isActionPalettePresented: true))
        XCTAssertNil(command(keyCode: 40, modifiers: .command,
                             hasAttachedSheet: true, isActionPalettePresented: true))
        XCTAssertNil(command(keyCode: 40, modifiers: .command,
                             isPanelEvent: false, isActionPalettePresented: true))
        XCTAssertNil(command(keyCode: 40, modifiers: .command,
                             isPanelKeyWindow: false, isActionPalettePresented: true))
    }

    func testActionsToggleUsesCustomizedBindingInCompanion() {
        let bindings = [ClipboardHistoryPlugin.ShortcutID.panelActions:
            ShortcutBinding(keyCode: 2, modifiers: [.command, .option])]
        XCTAssertEqual(command(keyCode: 2, modifiers: [.command, .option],
                               isEditingText: true, isActionPalettePresented: true,
                               panelShortcutBindings: bindings), .toggleActionMenu)
        XCTAssertNil(command(keyCode: 40, modifiers: .command,
                             isActionPalettePresented: true, panelShortcutBindings: bindings))
        XCTAssertNil(command(keyCode: 40, modifiers: .command,
                             isActionPalettePresented: true, panelShortcutBindings: [:]))
    }

    func testFocusedSelectionToggleAndActionsDismissalPreserveSearchAndSelectionOrder() async {
        let first = item(text: "Test First", pinned: false)
        let second = item(text: "Test Second", pinned: false)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [first, second])
        model.query = "Test"
        await model.waitForSearchForTesting()
        model.selectedItemID = first.id
        model.toggleFocusedSelection()
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        model.setMultiSelectionEnabled(true)
        model.selectedItemID = second.id
        model.toggleFocusedSelection()
        XCTAssertEqual(model.actionItemIDs, [first.id, second.id])
        model.toggleFocusedSelection()
        XCTAssertEqual(model.actionItemIDs, [first.id])
        model.toggleFocusedSelection()
        model.requestActionMenu()
        model.dismissActionMenu()
        XCTAssertFalse(model.isActionPalettePresented)
        XCTAssertEqual(model.query, "Test")
        XCTAssertEqual(model.selectedItemID, second.id)
        XCTAssertEqual(model.actionItemIDs, [first.id, second.id])
        XCTAssertTrue(model.isMultiSelectionEnabled)
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

    private func filePayload(named name: String) -> ClipboardHistoryPayload {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(url.absoluteString.utf8)
                ),
            ]),
        ])
    }
}

private final class ClipboardPayloadLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
