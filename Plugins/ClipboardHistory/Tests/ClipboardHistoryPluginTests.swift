import AppKit
import Foundation
import MacToolsPluginKit
import Security
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin
@testable import MacTools

@MainActor
final class ClipboardHistoryPluginTests: XCTestCase {
    func testCaptureClipboardAppearanceForReview() async throws {
        let capture = try PaletteCaptureSupport(name: "clipboard-history")
        defer { try? capture.finish() }
        var items = (0..<80).map { index in
            ClipboardHistoryItem(id: UUID(),
                text: "Synthetic note \(index + 1)\nReview the glass surface with readable text, controls, and previews.\nNo personal clipboard data is used.",
                capturedAt: Date().addingTimeInterval(-Double(index * 60)),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        }
        let preview = NSImage(size: NSSize(width: 480, height: 300), flipped: false) { rect in
            let colors: [NSColor] = [.systemBlue, .systemYellow, .systemPink, .systemGreen]
            for (index, color) in colors.enumerated() {
                color.setFill()
                NSRect(x: CGFloat(index) * 120, y: 0, width: 120, height: rect.height).fill()
            }
            return true
        }
        let previewData = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(preview.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        items.insert(ClipboardHistoryItem(id: UUID(), payload: ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.png, data: previewData)
            ])
        ]), capturedAt: .now, sourceApplication: nil, isPinned: false, lastUsedAt: nil), at: 0)
        let persistence = BlockingClipboardHistoryPersistence(items: items)
        persistence.allowSaveToFinish()
        let plugin = makePlugin(pasteboard: PluginTestClipboardPasteboard(), persistence: persistence,
            savedPersistence: InMemoryClipboardSavedLibraryPersistence(),
            imageTextRecognizer: FakePluginClipboardImageTextRecognizer(text: nil),
            accessibilityTrusted: { false }, accessibilityRequester: { _ in false })
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        _ = await waitUntil { plugin.savedLibraryController.isLoaded }
        let previous = Set(NSApp.windows.map(\.windowNumber))
        plugin.handleAction(.invokeAction(controlID: "execute"))
        let panel = try XCTUnwrap(NSApp.windows.first {
            !previous.contains($0.windowNumber) && $0 is NSPanel && $0.isVisible
        })
        try await capture.exercise(panel) { plugin.handleAction(.invokeAction(controlID: "execute")) }
    }

    func testHistoryAndSnippetClipboardReadsUseIndependentProcesses() {
        let plugin = makePlugin()
        defer { plugin.deactivate(reason: .hostShutdown) }

        let historyReader = try? XCTUnwrap(plugin.historyPasteboardReaderForTesting)
        XCTAssertNotNil(historyReader)
        if let historyReader {
            XCTAssertFalse(historyReader === plugin.snippetPasteboardReaderForTesting)
        }
    }

    func testDeactivationStopsSnippetPasteboardReaderWithoutRelaunching() async {
        let reader = ClipboardPasteboardReaderProcess(
            helperURL: { URL(fileURLWithPath: "/bin/sleep") },
            helperArguments: ["60"],
            requestTimeout: .seconds(5)
        )
        let plugin = makePlugin(snippetPasteboardReader: reader)
        let request = ClipboardPasteboardReaderRequest(
            kind: .plainText,
            pasteboardName: NSPasteboard.Name.general.rawValue,
            maximumByteCount: 1_024,
            expectedChangeCount: NSPasteboard.general.changeCount
        )
        let readTask = Task { try? await reader.read(request) }
        var launched = false
        for _ in 0..<200 {
            if await reader.hasLiveSessionForTesting {
                launched = true
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(launched)

        plugin.deactivate(reason: .hostShutdown)
        _ = await readTask.value
        let hasLiveSession = await reader.hasLiveSessionForTesting
        let launchCount = await reader.launchCountForTesting
        XCTAssertFalse(hasLiveSession)
        XCTAssertEqual(launchCount, 1)
    }

    func testExplicitQueueRejectsOnlyUnavailableItemsAtPluginBoundary() async {
        let historyItem = ClipboardHistoryItem(
            id: UUID(),
            text: "History",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [historyItem])
        persistence.allowSaveToFinish()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(persistence: persistence, privacyHUDPresenter: hud)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        plugin.controller.stop()

        let rejectedUnavailable = await plugin.startSequentialQueueForTesting(
            itemIDs: [historyItem.id, UUID()]
        )
        XCTAssertFalse(rejectedUnavailable)
        XCTAssertEqual(hud.failures.count, 1)
        let startedHistoryQueue = await plugin.startSequentialQueueForTesting(itemIDs: [historyItem.id])
        XCTAssertTrue(startedHistoryQueue)
    }

    func testExplicitQueuePastesHistoryAndSnippetInSelectionOrder() async throws {
        let historyItem = ClipboardHistoryItem(
            id: UUID(),
            text: "History value",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let snippet = ClipboardSavedItem(
            title: "Template",
            savedKind: .snippet,
            payload: .plainText("Snippet {{clipboard}}"),
            templateText: "Snippet {{clipboard}}"
        )
        let historyPersistence = BlockingClipboardHistoryPersistence(items: [historyItem])
        historyPersistence.allowSaveToFinish()
        let savedPersistence = InMemoryClipboardSavedLibraryPersistence()
        try savedPersistence.save(snippet, payloadChanged: true)
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            persistence: historyPersistence,
            savedPersistence: savedPersistence,
            pasteCommandSender: sender,
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLibraryLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryLoaded)

        let startedMixedQueue = await plugin.startSequentialQueueForTesting(
            itemIDs: [historyItem.id, snippet.id]
        )
        XCTAssertTrue(startedMixedQueue)
        plugin.handleShortcutAction(id: "paste-sequentially")
        let pastedHistory = await waitUntil {
            sender.sendCount == 1 && !plugin.hasPendingSequentialPasteForTesting
        }
        XCTAssertTrue(pastedHistory)
        XCTAssertEqual(pasteboard.text, "History value")

        // The explicit queue owns a frozen template snapshot. Removing the source item after
        // queue creation must not change the queued content or its paste-time variables.
        let deletedSourceSnippet = await plugin.savedLibraryController.delete(id: snippet.id)
        XCTAssertTrue(deletedSourceSnippet)

        plugin.handleShortcutAction(id: "paste-sequentially")
        let pastedSnippet = await waitUntil {
            sender.sendCount == 2 && !plugin.hasPendingSequentialPasteForTesting
        }
        XCTAssertTrue(pastedSnippet)
        XCTAssertEqual(pasteboard.text, "Snippet History value")
    }

    func testItemShortcutsPasteTwoItemsIndependentlyAndReexpandSnippet() async throws {
        let historyItem = ClipboardHistoryItem(
            id: UUID(), text: "History value", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let snippet = ClipboardSavedItem(
            title: "Template", savedKind: .snippet,
            payload: .plainText("Hello {{clipboard}}"), templateText: "Hello {{clipboard}}"
        )
        let historyPersistence = BlockingClipboardHistoryPersistence(items: [historyItem])
        historyPersistence.allowSaveToFinish()
        let savedPersistence = InMemoryClipboardSavedLibraryPersistence()
        try savedPersistence.save(snippet, payloadChanged: true)
        let board = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: board, persistence: historyPersistence, savedPersistence: savedPersistence,
            pasteCommandSender: sender, frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)

        let assignedHistory = await plugin.assignItemShortcut(
            itemID: historyItem.id, lifetime: .fiveMinutes,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assignedHistory, .accepted)
        board.simulateCopy("first external copy")
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: historyItem.id))
        let firstPaste = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(firstPaste)
        XCTAssertEqual(board.text, "History value")
        board.simulateCopy("second external copy")
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: historyItem.id))
        let secondPaste = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(secondPaste)
        XCTAssertEqual(board.text, "History value")

        let assignedSnippet = await plugin.assignItemShortcut(
            itemID: snippet.id, lifetime: .untilRemoved,
            binding: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )
        XCTAssertEqual(assignedSnippet, .accepted)
        let duplicateSnippetFormat = await plugin.assignItemShortcut(
            itemID: snippet.id, pasteFormat: .plainText, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 3, modifiers: [.command, .option])
        )
        guard case .rejected = duplicateSnippetFormat else {
            return XCTFail("Snippets already paste text and need one shortcut action")
        }
        XCTAssertEqual(plugin.itemShortcutStore.assignments.count, 2)
        board.simulateCopy("Ada")
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: snippet.id))
        let thirdPaste = await waitUntil { sender.sendCount == 3 }
        XCTAssertTrue(thirdPaste)
        XCTAssertEqual(board.text, "Hello Ada")
        board.simulateCopy("Grace")
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: snippet.id))
        let fourthPaste = await waitUntil { sender.sendCount == 4 }
        XCTAssertTrue(fourthPaste)
        XCTAssertEqual(board.text, "Hello Grace")

        let edited = await plugin.savedLibraryController.saveSnippet(ClipboardSnippetDraft(
            id: snippet.id, title: "Template", content: "Updated {{clipboard}}",
            tags: [], keyword: nil
        ))
        XCTAssertNotNil(edited)
        board.simulateCopy("Lin")
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: snippet.id))
        let editedPaste = await waitUntil { sender.sendCount == 5 }
        XCTAssertTrue(editedPaste)
        XCTAssertEqual(board.text, "Updated Lin")

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: historyItem.id))
        let independentPaste = await waitUntil { sender.sendCount == 6 }
        XCTAssertTrue(independentPaste)
        XCTAssertEqual(board.text, "History value")

        plugin.removeItemShortcut(itemID: snippet.id)
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: snippet.id))
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: snippet.id))
        XCTAssertNotNil(plugin.itemShortcutStore.assignment(for: historyItem.id))
        XCTAssertEqual(sender.sendCount, 6)
    }

    func testOneRichItemCanPasteOriginalAndPlainTextWithSeparateShortcuts() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("Fallback text".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data("{\\rtf1 Formatted note}".utf8)
                ),
            ]),
        ])
        let item = ClipboardHistoryItem(
            id: UUID(), payload: payload, capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let board = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: board, persistence: persistence,
            pasteCommandSender: sender, frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)

        let assignedOriginal = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assignedOriginal, .accepted)
        let assignedPlain = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneDay,
            binding: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )
        XCTAssertEqual(assignedPlain, .accepted)
        XCTAssertEqual(plugin.itemShortcutStore.assignments.count, 2)

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        let pastedOriginal = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(pastedOriginal)
        XCTAssertEqual(board.payload, payload)

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(
            for: item.id, pasteFormat: .plainText
        ))
        let pastedPlain = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(pastedPlain)
        XCTAssertEqual(board.payload, .plainText("Formatted note"))

        plugin.removeItemShortcut(itemID: item.id, pasteFormat: .original)
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertNotNil(plugin.itemShortcutStore.assignment(for: item.id, pasteFormat: .plainText))
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        XCTAssertEqual(sender.sendCount, 2)
    }

    func testConcurrentPasteFormatsBothKeepLastingAssignments() async throws {
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                .init(representations: [
                    .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Text".utf8)),
                    .init(typeIdentifier: ClipboardRepresentationType.rtf, data: Data("{\\rtf1 Text}".utf8)),
                ]),
            ]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        let plugin = makePlugin(persistence: persistence)
        defer {
            persistence.allowSaveToFinish()
            plugin.deactivate(reason: .hostShutdown)
        }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)

        let original = Task { @MainActor in
            await plugin.assignItemShortcut(
                itemID: item.id, lifetime: .untilRemoved,
                binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
            )
        }
        let saveStarted = await waitUntil { persistence.saveStarted }
        XCTAssertTrue(saveStarted)
        var secondStarted = false
        let plain = Task { @MainActor in
            secondStarted = true
            return await plugin.assignItemShortcut(
                itemID: item.id, pasteFormat: .plainText, lifetime: .untilRemoved,
                binding: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
            )
        }
        let bothStarted = await waitUntil { secondStarted }
        XCTAssertTrue(bothStarted)
        persistence.allowSaveToFinish()

        let originalResult = await original.value
        let plainResult = await plain.value
        XCTAssertEqual(originalResult, .accepted)
        XCTAssertEqual(plainResult, .accepted)
        XCTAssertTrue(plugin.controller.items.first { $0.id == item.id }?.isSaved == true)
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: item.id)?.source, .saved)
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: item.id, pasteFormat: .plainText)?.source, .saved)
    }

    func testDeactivationStopsInFlightItemPasteWhenAnotherPasteIsQueued() async throws {
        let item = ClipboardHistoryItem(
            id: UUID(), text: "Waiting paste", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let sender = PreDispatchClipboardPasteCommandSender()
        let plugin = makePlugin(
            persistence: persistence, pasteCommandSender: sender,
            frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)
        let assigned = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assigned, .accepted)

        let actionID = ClipboardItemShortcutStore.definitionID(for: item.id)
        plugin.handleShortcutAction(id: actionID)
        let firstWaiting = await waitUntil { sender.isWaiting }
        XCTAssertTrue(firstWaiting)
        plugin.handleShortcutAction(id: actionID)
        plugin.deactivate(reason: .disabled)
        sender.resume()
        let firstFinished = await waitUntil { sender.finishedCount == 1 }
        XCTAssertTrue(firstFinished)
        XCTAssertEqual(sender.sentCount, 0)
    }

    func testBackupSuspensionStopsInFlightItemPasteAfterResume() async {
        let item = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let sender = PreDispatchClipboardPasteCommandSender()
        let plugin = makePlugin(
            persistence: persistence, pasteCommandSender: sender,
            frontmostProcessIdentifier: { 42 }
        )
        defer {
            sender.resume()
            plugin.deactivate(reason: .hostShutdown)
        }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)
        let assigned = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assigned, .accepted)

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        let waiting = await waitUntil { sender.isWaiting }
        XCTAssertTrue(waiting)
        plugin.suspendForClipboardBackup()
        plugin.resumeAfterClipboardBackup(restored: true)
        sender.resume()
        let finished = await waitUntil { sender.finishedCount == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(sender.sentCount, 0)
    }

    func testBackupSuspensionRejectsPendingItemShortcutAssignmentAfterResume() async {
        let item = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence)
        let gate = PluginTestPayloadGate()
        defer {
            gate.release.signal()
            plugin.deactivate(reason: .hostShutdown)
        }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)
        item.configurePayloadLoader({ gate.load() }, discardCachedPayload: true)

        let assignment = Task { @MainActor in
            await plugin.assignItemShortcut(
                itemID: item.id, lifetime: .oneHour,
                binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
            )
        }
        let started = await waitUntil { gate.started }
        XCTAssertTrue(started)
        plugin.suspendForClipboardBackup()
        plugin.resumeAfterClipboardBackup(restored: true)
        gate.release.signal()

        let result = await assignment.value
        guard case .rejected = result else {
            XCTFail("Assignment started before backup suspension should be rejected")
            return
        }
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
    }

    func testBackupSuspensionRollsBackRejectedLastingShortcutSaveAfterResume() async {
        let item = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)

        let originalOnChange = plugin.controller.onChange
        var suspendedAfterSave = false
        var provisionalAtSuspension: ClipboardHistorySavedMetadata?
        plugin.controller.onChange = { [weak plugin] in
            originalOnChange?()
            guard let plugin, !suspendedAfterSave,
                  plugin.controller.items.first(where: { $0.id == item.id })?.isSaved == true else { return }
            provisionalAtSuspension = plugin.provisionalSavedMetadataForBackup()[item.id]
            suspendedAfterSave = true
            plugin.suspendForClipboardBackup()
        }
        let result = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .untilRemoved,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertTrue(suspendedAfterSave)
        guard case .rejected = result else {
            XCTFail("Assignment should be rejected when backup starts during its save")
            return
        }
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        let savedMetadata = plugin.controller.items.first(where: { $0.id == item.id })?.savedMetadata
        XCTAssertNotNil(savedMetadata)
        XCTAssertEqual(provisionalAtSuspension, savedMetadata)
        XCTAssertEqual(plugin.provisionalSavedMetadataForBackup()[item.id], savedMetadata)

        plugin.resumeAfterClipboardBackup(restored: true)
        let rolledBack = await waitUntil(timeout: .seconds(3)) {
            plugin.controller.isLoaded
                && plugin.controller.items.first(where: { $0.id == item.id })?.isSaved == false
        }
        XCTAssertTrue(rolledBack)
        XCTAssertFalse(persistence.savedItems.first(where: { $0.id == item.id })?.isSaved ?? true)
        XCTAssertNil(plugin.provisionalSavedMetadataForBackup()[item.id])
    }

    func testMissingFileCanStillPasteItsPathAsPlainText() async throws {
        let missingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-clipboard-file-\(UUID().uuidString)")
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                .init(representations: [
                    .init(typeIdentifier: ClipboardRepresentationType.fileURL,
                          data: Data(missingURL.absoluteString.utf8)),
                ]),
            ]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let board = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: board, persistence: persistence,
            pasteCommandSender: sender, frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)

        let assigned = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assigned, .accepted)
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(
            for: item.id, pasteFormat: .plainText
        ))
        let pasted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(pasted)
        XCTAssertEqual(board.payload, .plainText(missingURL.path))
    }

    func testMultiplePlainTextPasteboardItemsKeepTwoShortcutModes() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: ["First", "Second"].map { text in
            .init(representations: [
                .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data(text.utf8)),
            ])
        })
        let item = ClipboardHistoryItem(
            id: UUID(), payload: payload, capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let board = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: board, persistence: persistence,
            pasteCommandSender: sender, frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)

        let original = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        let plain = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )
        XCTAssertEqual(original, .accepted)
        XCTAssertEqual(plain, .accepted)

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        let originalPasted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(originalPasted)
        XCTAssertEqual(board.payload, payload)

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(
            for: item.id, pasteFormat: .plainText
        ))
        let plainPasted = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(plainPasted)
        XCTAssertEqual(board.payload, .plainText("First"))
    }

    func testTextOnlyItemUsesOneShortcutButKeepsAnExistingSecondAssignment() async throws {
        let item = ClipboardHistoryItem(
            id: UUID(), text: "Plain content", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLoaded)

        let original = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(original, .accepted)
        let redundant = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneDay,
            binding: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )
        guard case .rejected = redundant else { return XCTFail("A text-only item needs one paste action") }
        XCTAssertEqual(plugin.itemShortcutStore.assignments.count, 1)

        _ = plugin.itemShortcutStore.assign(
            itemID: item.id, source: .history, pasteFormat: .plainText, lifetime: .oneDay
        )
        let editedExisting = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 3, modifiers: [.command, .option])
        )
        XCTAssertEqual(editedExisting, .accepted)
        XCTAssertEqual(plugin.itemShortcutStore.assignments.count, 2)
        let originalDefinition = plugin.shortcutDefinitions.first {
            $0.id == ClipboardItemShortcutStore.definitionID(for: item.id)
        }
        XCTAssertTrue(originalDefinition?.title.contains("Paste Text") == true)
        let plainDefinition = plugin.shortcutDefinitions.first {
            $0.id == ClipboardItemShortcutStore.definitionID(for: item.id, pasteFormat: .plainText)
        }
        XCTAssertTrue(plainDefinition?.description.contains("same text") == true)

        plugin.removeItemShortcut(itemID: item.id, pasteFormat: .original)
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertNotNil(plugin.itemShortcutStore.assignment(for: item.id, pasteFormat: .plainText))
        let remainingDefinition = plugin.shortcutDefinitions.first {
            $0.id == ClipboardItemShortcutStore.definitionID(for: item.id, pasteFormat: .plainText)
        }
        XCTAssertTrue(remainingDefinition?.title.contains("Paste Text") == true)
    }

    func testItemShortcutRegistersWithHostAndUnregistersWhenRemoved() async throws {
        let suite = "ClipboardItemShortcutHostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults
        )
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                ClipboardStoredPasteboardItem(representations: [
                    ClipboardStoredRepresentation(
                        typeIdentifier: ClipboardRepresentationType.plainText,
                        data: Data("Template".utf8)
                    ),
                    ClipboardStoredRepresentation(
                        typeIdentifier: ClipboardRepresentationType.rtf,
                        data: Data("{\\rtf1 Template}".utf8)
                    ),
                ]),
            ]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let secondItem = ClipboardHistoryItem(
            id: UUID(), text: "Other template", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item, secondItem])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence, storage: storage)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let registrar = FakeCarbonHotKeyRegistrar()
        let host = PluginHost(
            plugins: [plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager(registrar: registrar)
        )
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        _ = await waitUntil { plugin.savedLibraryController.isLoaded }

        let binding = ShortcutBinding(keyCode: 1, modifiers: [.command, .option, .control])
        let lastingHistory = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .untilRemoved, binding: binding
        )
        XCTAssertEqual(lastingHistory, .accepted)
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: item.id)?.source, .saved)
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id)?.expiresAt)
        XCTAssertTrue(plugin.controller.items.first { $0.id == item.id }?.isSaved == true)

        let result = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour, binding: binding
        )
        XCTAssertEqual(result, .accepted)
        await host.waitForScheduledPluginStateRebuildForTests()
        let shortcutID = "clipboard.shortcut.\(ClipboardItemShortcutStore.definitionID(for: item.id))"
        XCTAssertTrue(host.shortcutItems.contains { $0.id == shortcutID })
        XCTAssertTrue(registrar.registeredBindings.contains(binding))

        let duplicateFormat = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneDay, binding: binding
        )
        guard case .rejected = duplicateFormat else {
            return XCTFail("One key must not invoke both paste formats")
        }
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id, pasteFormat: .plainText))
        XCTAssertNotNil(plugin.itemShortcutStore.assignment(for: item.id))

        let plainBinding = ShortcutBinding(keyCode: 2, modifiers: [.command, .option, .control])
        let plainResult = await plugin.assignItemShortcut(
            itemID: item.id, pasteFormat: .plainText, lifetime: .oneDay, binding: plainBinding
        )
        XCTAssertEqual(plainResult, .accepted)
        await host.waitForScheduledPluginStateRebuildForTests()
        let plainDefinitionID = ClipboardItemShortcutStore.definitionID(for: item.id, pasteFormat: .plainText)
        let plainShortcutID = "clipboard.shortcut.\(plainDefinitionID)"
        XCTAssertTrue(host.shortcutItems.contains { $0.id == plainShortcutID })
        XCTAssertTrue(registrar.registeredBindings.contains(plainBinding))

        let conflict = await plugin.assignItemShortcut(
            itemID: secondItem.id, lifetime: .oneDay, binding: binding
        )
        guard case .rejected = conflict else { return XCTFail("Duplicate binding must be rejected") }
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: secondItem.id))

        plugin.removeItemShortcut(itemID: item.id, pasteFormat: .original)
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertFalse(host.shortcutItems.contains { $0.id == shortcutID })
        XCTAssertTrue(host.shortcutItems.contains { $0.id == plainShortcutID })
        XCTAssertGreaterThan(registrar.unregisteredCount, 0)
        XCTAssertNil(defaults.data(forKey: "shortcut.customization.\(shortcutID)"))
        plugin.removeItemShortcut(itemID: item.id, pasteFormat: .plainText)
        await host.waitForScheduledPluginStateRebuildForTests()
        XCTAssertFalse(host.shortcutItems.contains { $0.id == plainShortcutID })
        XCTAssertTrue(plugin.controller.items.first { $0.id == item.id }?.isSaved == true)
    }

    func testTimedHistoryShortcutSurvivesRetentionAndRestartUntilRemoved() async throws {
        let suite = "ClipboardItemShortcutRetentionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults
        )
        let now = Date()
        let shortcutItem = ClipboardHistoryItem(
            id: UUID(), text: "older shortcut", capturedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let recent = ClipboardHistoryItem(
            id: UUID(), text: "recent", capturedAt: now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [recent, shortcutItem])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence, storage: storage)
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        _ = await waitUntil { plugin.savedLibraryController.isLoaded }

        let assignmentResult = await plugin.assignItemShortcut(
            itemID: shortcutItem.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assignmentResult, .accepted)
        plugin.controller.settings.maximumItemCount = 1
        plugin.controller.settings.expiration = .oneDay
        XCTAssertEqual(Set(plugin.controller.items.map(\.id)), [recent.id, shortcutItem.id])
        XCTAssertFalse(plugin.controller.items.first { $0.id == shortcutItem.id }?.isSaved ?? true)
        plugin.deactivate(reason: .hostShutdown)

        let reloaded = makePlugin(persistence: persistence, storage: storage)
        defer { reloaded.deactivate(reason: .hostShutdown) }
        reloaded.controller.start()
        reloaded.savedLibraryController.start()
        await waitUntilLoaded(reloaded.controller)
        XCTAssertEqual(Set(reloaded.controller.items.map(\.id)), [recent.id, shortcutItem.id])
        XCTAssertNotNil(reloaded.itemShortcutStore.assignment(for: shortcutItem.id))

        reloaded.removeItemShortcut(itemID: shortcutItem.id)
        XCTAssertEqual(reloaded.controller.items.map(\.id), [recent.id])
    }

    func testSavedClipSupportsLastingShortcutAndRemovesItWhenUnSaved() async throws {
        let item = ClipboardHistoryItem(
            id: UUID(), text: "Saved content", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil,
            isInHistory: false,
            savedMetadata: ClipboardHistorySavedMetadata(title: "Template A")
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let board = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: board, persistence: persistence,
            pasteCommandSender: sender, frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLibraryLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryLoaded)

        let result = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .untilRemoved,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(result, .accepted)
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id)?.expiresAt)
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: item.id)?.source.rawValue, "saved")
        XCTAssertEqual(plugin.shortcutDefinitions.first {
            $0.id == ClipboardItemShortcutStore.definitionID(for: item.id)
        }?.title, "Template A — Paste Text")

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        let pasted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(pasted)
        XCTAssertEqual(board.text, "Saved content")
        let deleted = await plugin.controller.deleteSavedItem(id: item.id)
        XCTAssertTrue(deleted)
        let removed = await waitUntil { plugin.itemShortcutStore.assignment(for: item.id) == nil }
        XCTAssertTrue(removed)
    }

    func testTemporaryItemLoadFailureAndCancellationKeepShortcut() async throws {
        let item = ClipboardHistoryItem(
            id: UUID(), text: "Template", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            persistence: persistence, privacyHUDPresenter: hud,
            frontmostProcessIdentifier: { 42 }
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLibraryLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryLoaded)
        let assigned = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(assigned, .accepted)

        item.configurePayloadLoader({ throw ClipboardHistoryPayloadAccessError.unavailable }, discardCachedPayload: true)
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        await plugin.waitForItemShortcutPasteForTesting()
        XCTAssertNotNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertEqual(hud.failures.count, 1)

        item.configurePayloadLoader({ throw CancellationError() }, discardCachedPayload: true)
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: item.id))
        await plugin.waitForItemShortcutPasteForTesting()
        XCTAssertNotNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertEqual(hud.failures.count, 1)
    }

    func testItemShortcutRejectsAnotherPluginsActionBinding() async throws {
        let suite = "ClipboardItemShortcutActionConflictTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let item = ClipboardHistoryItem(
            id: UUID(), text: "Template", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(
            persistence: persistence,
            storage: UserDefaultsPluginStorage(pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults)
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        let actionPlugin = ClipboardShortcutConflictActionPlugin()
        let manager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let host = PluginHost(
            plugins: [actionPlugin, plugin],
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: manager
        )
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLibraryLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryLoaded)
        let binding = ShortcutBinding(keyCode: 1, modifiers: [.command, .option, .control])
        let reference = actionPlugin.actionCatalogEntries[0].reference
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(binding, for: reference))

        let result = await plugin.assignItemShortcut(itemID: item.id, lifetime: .oneDay, binding: binding)
        guard case let .rejected(message) = result else { return XCTFail("Expected duplicate binding rejection") }
        XCTAssertTrue(message.contains("Other Plugin"))
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        let lastingResult = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .untilRemoved, binding: binding
        )
        guard case .rejected = lastingResult else { return XCTFail("Expected lasting shortcut conflict") }
        XCTAssertFalse(plugin.controller.items.first { $0.id == item.id }?.isSaved ?? true)
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertTrue(manager.debugRegistrationsForTests.contains {
            $0.binding == binding && $0.shortcutID.hasPrefix("action-shortcut.")
        })
    }

    func testRejectedLastingUpdateKeepsTimedShortcutAndRetentionProtectedItem() async throws {
        let oldItem = ClipboardHistoryItem(
            id: UUID(), text: "Retained by shortcut",
            capturedAt: Date().addingTimeInterval(-2 * 24 * 60 * 60),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let recentItem = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [recentItem, oldItem])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let actionPlugin = ClipboardShortcutConflictActionPlugin()
        let manager = GlobalShortcutManager(registrar: FakeCarbonHotKeyRegistrar())
        let hostDefaults = UserDefaults(suiteName: UUID().uuidString)!
        let host = PluginHost(
            plugins: [actionPlugin, plugin],
            shortcutStore: ShortcutStore(userDefaults: hostDefaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: hostDefaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: hostDefaults),
            globalShortcutManager: manager
        )
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)

        let originalBinding = ShortcutBinding(keyCode: 1, modifiers: [.command, .option, .control])
        let originalResult = await plugin.assignItemShortcut(
            itemID: oldItem.id, lifetime: .oneHour, binding: originalBinding
        )
        XCTAssertEqual(originalResult, .accepted)
        let originalAssignment = try XCTUnwrap(plugin.itemShortcutStore.assignment(for: oldItem.id))
        plugin.controller.settings.maximumItemCount = 1
        plugin.controller.settings.expiration = .oneDay
        XCTAssertTrue(plugin.controller.items.contains { $0.id == oldItem.id })

        let conflictingBinding = ShortcutBinding(keyCode: 2, modifiers: [.command, .option, .control])
        let reference = actionPlugin.actionCatalogEntries[0].reference
        XCTAssertNil(host.setActionShortcutBindingAndReturnError(conflictingBinding, for: reference))
        let result = await plugin.assignItemShortcut(
            itemID: oldItem.id, lifetime: .untilRemoved, binding: conflictingBinding
        )

        guard case .rejected = result else { return XCTFail("Expected conflicting update to be rejected") }
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: oldItem.id), originalAssignment)
        XCTAssertTrue(plugin.controller.items.contains { $0.id == oldItem.id })
        XCTAssertFalse(plugin.controller.items.first { $0.id == oldItem.id }?.isSaved ?? true)
        XCTAssertTrue(manager.debugRegistrationsForTests.contains {
            $0.binding == originalBinding
                && $0.shortcutID == "clipboard.shortcut.\(originalAssignment.definitionID)"
        })
    }

    func testTemporaryInitialLoadFailureDoesNotRemovePersistedItemShortcut() async throws {
        let suite = "ClipboardItemShortcutLoadRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults
        )
        let item = historyItem()
        let seededStore = ClipboardItemShortcutStore(storage: storage)
        let assignment = seededStore.assign(
            itemID: item.id, source: .history, lifetime: .oneHour
        )
        let plugin = makePlugin(
            persistence: RetryableKeychainClipboardHistoryPersistence(items: [item]),
            storage: storage
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.savedLibraryController.start()
        let savedLibraryLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryLoaded)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        XCTAssertNotNil(plugin.controller.errorMessage)
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: item.id), assignment)

        plugin.controller.retryStorageAccess()
        let retryLoaded = await waitUntil {
            plugin.controller.isLoaded && plugin.controller.errorMessage == nil
        }
        XCTAssertTrue(retryLoaded)
        XCTAssertEqual(plugin.controller.items.map(\.id), [item.id])
        XCTAssertEqual(plugin.itemShortcutStore.assignment(for: item.id), assignment)
    }

    func testRapidItemShortcutsKeepClipboardStableUntilEachPasteIsConsumed() async throws {
        let first = ClipboardHistoryItem(
            id: UUID(), text: "First shortcut", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let second = ClipboardHistoryItem(
            id: UUID(), text: "Second shortcut", capturedAt: Date().addingTimeInterval(-1),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let persistence = BlockingClipboardHistoryPersistence(items: [first, second])
        persistence.allowSaveToFinish()
        let board = PluginTestClipboardPasteboard()
        let sender = DelayedReadClipboardPasteCommandSender(
            delay: .milliseconds(20), currentPasteboardText: { board.text }
        )
        let plugin = makePlugin(
            pasteboard: board, persistence: persistence, pasteCommandSender: sender,
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .milliseconds(80)
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)
        let firstResult = await plugin.assignItemShortcut(
            itemID: first.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        XCTAssertEqual(firstResult, .accepted)
        let secondResult = await plugin.assignItemShortcut(
            itemID: second.id, lifetime: .oneHour,
            binding: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )
        XCTAssertEqual(secondResult, .accepted)

        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: first.id))
        plugin.handleShortcutAction(id: ClipboardItemShortcutStore.definitionID(for: second.id))

        let bothPasted = await waitUntil { sender.pastedTexts.count == 2 }
        XCTAssertTrue(bothPasted)
        XCTAssertEqual(sender.pastedTexts, ["First shortcut", "Second shortcut"])
    }

    func testShortcutDefinitionGetterStaysBoundedWithLargeHistory() async throws {
        let suite = "ClipboardItemShortcutDefinitionPerformanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults
        )
        let items = (0..<10_000).map { index in
            ClipboardHistoryItem(
                id: UUID(), text: "History item \(index)",
                capturedAt: Date().addingTimeInterval(-Double(index)),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil
            )
        }
        let seededStore = ClipboardItemShortcutStore(storage: storage)
        for item in items.prefix(100) {
            _ = seededStore.assign(itemID: item.id, source: .history, lifetime: .oneDay)
        }
        let persistence = BlockingClipboardHistoryPersistence(items: items)
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence, storage: storage)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)

        let measurementOptions = XCTMeasureOptions()
        measurementOptions.iterationCount = 5
        var measuredDefinitionCounts: [Int] = []
        measure(metrics: [XCTClockMetric()], options: measurementOptions) {
            measuredDefinitionCounts.append(plugin.shortcutDefinitions.lazy.filter {
                ClipboardItemShortcutStore.itemID(for: $0.id) != nil
            }.count)
        }
        XCTAssertGreaterThanOrEqual(measuredDefinitionCounts.count, 5)
        XCTAssertTrue(measuredDefinitionCounts.allSatisfy { $0 == 100 })

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10 {
            let dynamicDefinitionCount = plugin.shortcutDefinitions.lazy.filter {
                ClipboardItemShortcutStore.itemID(for: $0.id) != nil
            }.count
            XCTAssertEqual(dynamicDefinitionCount, 100)
        }
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(25))
    }

    func testAssignedSavedTitleRefreshesAndUnsavingPrunesItsShortcut() async throws {
        let item = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(persistence: persistence)
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)
        let result = await plugin.assignItemShortcut(itemID: item.id, lifetime: .untilRemoved,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option, .control]))
        XCTAssertEqual(result, .accepted)
        let definitionID = ClipboardItemShortcutStore.definitionID(for: item.id)
        XCTAssertNotNil(plugin.shortcutDefinitions.first { $0.id == definitionID })

        let updated = await plugin.controller.updateSavedMetadata(.init(id: item.id, title: "Renamed target", tags: []))
        XCTAssertNotNil(updated)
        XCTAssertTrue(plugin.shortcutDefinitions.first { $0.id == definitionID }?.title.contains("Renamed target") == true)
        let deleted = await plugin.controller.deleteSavedItem(id: item.id)
        XCTAssertTrue(deleted)
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertFalse(plugin.shortcutDefinitions.contains { $0.id == definitionID })
    }

    func testRemovingMultipleDefinitionsUsesOneHostResetRequest() {
        let plugin = makePlugin()
        defer { plugin.deactivate(reason: .hostShutdown) }
        var requests: [[String]] = []
        plugin.resetShortcutCustomizations = { requests.append($0) }
        let assignments = (0..<10).map { _ in
            plugin.itemShortcutStore.assign(itemID: UUID(), source: .history, lifetime: .oneDay)
        }
        plugin.itemShortcutStore.removeAll()
        XCTAssertEqual(requests, [assignments.map(\.definitionID)])
        XCTAssertTrue(plugin.itemShortcutStore.assignments.isEmpty)
        XCTAssertFalse(plugin.shortcutDefinitions.contains { ClipboardItemShortcutStore.itemID(for: $0.id) != nil })
    }

    func testLastingHistoryShortcutRequiresDurableSave() async throws {
        let item = ClipboardHistoryItem(
            id: UUID(), text: "Keep me", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        let plugin = makePlugin(persistence: FailingClipboardHistoryPersistence(items: [item]))
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.inlineShortcutSettingsContextProvider = {
            PluginSettingsContext(pluginID: ClipboardHistoryPlugin.pluginID)
        }
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        _ = await waitUntil { plugin.savedLibraryController.isLoaded }

        let result = await plugin.assignItemShortcut(
            itemID: item.id, lifetime: .untilRemoved,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        )
        guard case .rejected = result else { return XCTFail("The item must be saved durably") }
        XCTAssertNil(plugin.itemShortcutStore.assignment(for: item.id))
        XCTAssertFalse(plugin.controller.items.first { $0.id == item.id }?.isSaved ?? true)
    }

    func testSnippetClipboardWriteResetsImplicitQueueBeforeBlockedUsageSaveAndPreservesExplicitQueue() async throws {
        for usesExplicitQueue in [false, true] {
            let first = ClipboardHistoryItem(id: UUID(), text: "First", capturedAt: Date(),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
            let second = ClipboardHistoryItem(id: UUID(), text: "Second", capturedAt: Date().addingTimeInterval(-10),
                sourceApplication: nil, isPinned: false, lastUsedAt: nil)
            let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
                payload: .plainText("Snippet written"), templateText: "Snippet written")
            let savedPersistence = try BlockingUsageClipboardSavedPersistence(item: snippet)
            defer { savedPersistence.finishUsageUpdate() }
            let persistence = BlockingClipboardHistoryPersistence(items: [first, second])
            persistence.allowSaveToFinish()
            let pasteboard = PluginTestClipboardPasteboard()
            let sender = FakeClipboardPasteCommandSender()
            let initialSession = usesExplicitQueue
                ? try ClipboardSequentialPasteSession(explicitSnapshots: [
                    ClipboardSequentialPasteSnapshot(
                        sourceItemID: first.id,
                        payload: .plainText("First"),
                        expandsSnippetVariables: false
                    ),
                    ClipboardSequentialPasteSnapshot(
                        sourceItemID: second.id,
                        payload: .plainText("Second"),
                        expandsSnippetVariables: false
                    ),
                ])
                : nil
            let plugin = makePlugin(pasteboard: pasteboard, persistence: persistence,
                savedPersistence: savedPersistence, pasteCommandSender: sender,
                frontmostProcessIdentifier: { 42 }, sequentialPasteStabilizationDelay: .zero,
                initialExplicitSession: initialSession)
            defer { plugin.deactivate(reason: .hostShutdown) }
            plugin.controller.start()
            await waitUntilLoaded(plugin.controller)
            plugin.controller.stop()
            plugin.savedLibraryController.start()
            let loaded = await waitUntil { plugin.savedLibraryController.isLoaded }
            XCTAssertTrue(loaded)
            plugin.handleShortcutAction(id: "paste-sequentially")
            let pastedFirst = await waitUntil {
                sender.sendCount == 1 && !plugin.hasPendingSequentialPasteForTesting
            }
            XCTAssertTrue(pastedFirst)
            XCTAssertEqual(pasteboard.text, "First")

            let copiedSnippet = await plugin.savedLibraryController.copy(id: snippet.id)
            XCTAssertNotNil(copiedSnippet)
            let usageUpdateStarted = await waitUntil { savedPersistence.usageUpdateStarted }
            XCTAssertTrue(usageUpdateStarted)
            XCTAssertEqual(pasteboard.text, "Snippet written")
            // The copy returns before usage bookkeeping, while the successful-write callback has
            // already reset only the implicit queue.
            plugin.handleShortcutAction(id: "paste-sequentially")
            let pastedAfterSnippet = await waitUntil {
                sender.sendCount == 2 && !plugin.hasPendingSequentialPasteForTesting
            }
            XCTAssertTrue(pastedAfterSnippet)
            XCTAssertEqual(pasteboard.text, usesExplicitQueue ? "Second" : "First")
            savedPersistence.finishUsageUpdate()
            let surfacedUsageError = await waitUntil {
                plugin.savedLibraryController.errorMessage != nil
            }
            XCTAssertTrue(surfacedUsageError, "Usage persistence fails after the clipboard write")
        }
    }

    func testSequentialSnippetPasteDoesNotWaitForUsageMetadata() async throws {
        let snippet = ClipboardSavedItem(
            title: "Template",
            savedKind: .snippet,
            payload: .plainText("Snippet value"),
            templateText: "Snippet value"
        )
        let savedPersistence = try BlockingUsageClipboardSavedPersistence(item: snippet)
        defer { savedPersistence.finishUsageUpdate() }
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            savedPersistence: savedPersistence,
            pasteCommandSender: sender,
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)
        let startedSnippetQueue = await plugin.startSequentialQueueForTesting(itemIDs: [snippet.id])
        XCTAssertTrue(startedSnippetQueue)

        plugin.handleShortcutAction(id: "paste-sequentially")
        let pasted = await waitUntil {
            sender.sendCount == 1 && !plugin.hasPendingSequentialPasteForTesting
        }

        XCTAssertTrue(pasted)
        XCTAssertEqual(pasteboard.text, "Snippet value")
        let usageUpdateStarted = await waitUntil { savedPersistence.usageUpdateStarted }
        XCTAssertTrue(usageUpdateStarted)
        savedPersistence.finishUsageUpdate()
    }

    func testExternalCopyDuringPlainTextPasteWaitCancelsDispatch() async {
        let pasteboard = PluginTestClipboardPasteboard()
        pasteboard.simulateCopy("original")
        let sender = PreDispatchClipboardPasteCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(pasteboard: pasteboard, pasteCommandSender: sender,
                                privacyHUDPresenter: hud, accessibilityTrusted: { true })
        plugin.handleShortcutAction(id: "paste-clipboard-as-plain-text")
        let waiting = await waitUntil { sender.isWaiting }
        XCTAssertTrue(waiting)
        pasteboard.simulateCopy("new external copy")
        sender.resume()
        let finished = await waitUntil { !hud.failures.isEmpty }
        XCTAssertTrue(finished)
        XCTAssertEqual(sender.sentCount, 0)
        XCTAssertEqual(pasteboard.text, "new external copy")
        plugin.deactivate(reason: .hostShutdown)
    }

    func testPasteOwnershipIsRecheckedAtDispatchAndAllowsUnchangedClipboard() async {
        for externalCopy in [false, true] {
            let pasteboard = PluginTestClipboardPasteboard()
            pasteboard.simulateCopy("prepared")
            let version = pasteboard.changeCount
            let sender = PreDispatchClipboardPasteCommandSender()
            let task = Task { @MainActor in
                await sender.sendPasteCommand(to: 42, expectedPasteboardVersion: version,
                                             currentPasteboardVersion: { pasteboard.changeCount })
            }
            let waiting = await waitUntil { sender.isWaiting }
            XCTAssertTrue(waiting)
            if externalCopy { pasteboard.simulateCopy("replacement") }
            sender.resume()
            let sent = await task.value
            XCTAssertEqual(sent, !externalCopy)
            XCTAssertEqual(sender.sentCount, externalCopy ? 0 : 1)
        }
    }

    func testExternalCopyDuringPreDispatchWaitCancelsImplicitPaste() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = PreDispatchClipboardPasteCommandSender()
        let persistence = BlockingClipboardHistoryPersistence(items: [historyItem()])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(pasteboard: pasteboard,
            persistence: persistence,
            pasteCommandSender: sender, accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 }, sequentialPasteStabilizationDelay: .zero)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        plugin.controller.stop()
        plugin.handleShortcutAction(id: "paste-sequentially")
        let started = await waitUntil { sender.isWaiting }
        XCTAssertTrue(started)
        pasteboard.simulateCopy("new external copy")
        sender.resume()
        let finished = await waitUntil { !plugin.hasPendingSequentialPasteForTesting }
        XCTAssertTrue(finished)
        XCTAssertEqual(sender.sentCount, 0)
        XCTAssertEqual(pasteboard.text, "new external copy")
        plugin.deactivate(reason: .hostShutdown)
    }
    func testScopeShortcutReservesShiftForBackwardCycling() {
        let plugin = makePlugin()

        XCTAssertNil(plugin.shortcutValidationMessage(
            definitionID: ClipboardHistoryPlugin.ShortcutID.panelCycleScope,
            binding: ShortcutBinding(keyCode: 48, modifiers: [.control])
        ))
        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: ClipboardHistoryPlugin.ShortcutID.panelCycleScope,
            binding: ShortcutBinding(keyCode: 48, modifiers: [.control, .shift])
        ))
        XCTAssertNil(plugin.shortcutValidationMessage(
            definitionID: ClipboardHistoryPlugin.ShortcutID.panelShare,
            binding: ShortcutBinding(keyCode: 14, modifiers: [.command, .shift])
        ))
    }

    func testPublishesCanonicalPayloadFreeActions() {
        let plugin = makePlugin()
        let definitions = plugin.actionDefinitions

        XCTAssertEqual(Set(definitions.map(\.key.actionID)), ClipboardHistoryPlugin.ActionID.all)
        XCTAssertEqual(definitions.count, ClipboardHistoryPlugin.ActionID.all.count)
        XCTAssertTrue(definitions.allSatisfy(\.parameters.isEmpty))
        XCTAssertTrue(definitions.allSatisfy { $0.externalInvocationPolicy == .unavailable })
        XCTAssertEqual(
            definitions.first {
                $0.key.actionID == ClipboardHistoryPlugin.ActionID.clearAllHistory
            }?.risk,
            .confirmationRequired
        )
    }

    func testPauseResumeAndToggleActionsAreStateAware() async throws {
        let plugin = makePlugin()
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        let pause = reference(plugin, actionID: ClipboardHistoryPlugin.ActionID.pauseCollection)
        let resume = reference(plugin, actionID: ClipboardHistoryPlugin.ActionID.resumeCollection)
        let toggle = reference(plugin, actionID: ClipboardHistoryPlugin.ActionID.toggleCollection)

        XCTAssertTrue(plugin.actionAvailability(for: pause).isAvailable)
        XCTAssertTrue(plugin.actionAvailability(for: resume).isAvailable)

        let resumeNoOpResult = try await plugin.beginAction(
            ActionInvocation(reference: resume, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(resumeNoOpResult, .succeeded())

        let pauseResult = try await plugin.beginAction(
            ActionInvocation(reference: pause, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(pauseResult, .succeeded())
        XCTAssertTrue(plugin.actionAvailability(for: pause).isAvailable)
        XCTAssertTrue(plugin.actionAvailability(for: resume).isAvailable)

        let pauseNoOpResult = try await plugin.beginAction(
            ActionInvocation(reference: pause, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(pauseNoOpResult, .succeeded())

        let toggleResult = try await plugin.beginAction(
            ActionInvocation(reference: toggle, source: .test, mode: .background)
        ).result()
        XCTAssertEqual(toggleResult, .succeeded())
        XCTAssertTrue(plugin.actionAvailability(for: pause).isAvailable)
        plugin.controller.stop()
    }

    func testInactiveQueueNavigationActionsAreSuccessfulNoOps() async throws {
        let plugin = makePlugin()
        defer { plugin.deactivate(reason: .hostShutdown) }

        for actionID in [
            ClipboardHistoryPlugin.ActionID.previousSequentialQueueItem,
            ClipboardHistoryPlugin.ActionID.skipSequentialQueueItem,
            ClipboardHistoryPlugin.ActionID.restartSequentialQueue,
        ] {
            let action = reference(plugin, actionID: actionID)
            let result = try await plugin.beginAction(
                ActionInvocation(reference: action, source: .test, mode: .background)
            ).result()
            XCTAssertEqual(result, .succeeded())
        }
    }

    func testSettingsFormPublishesGroupedActionAndPluginShortcutSections() throws {
        let plugin = makePlugin()
        let page = try XCTUnwrap(plugin.settingsPage)
        XCTAssertEqual(page.body.layout, .form)
        XCTAssertEqual(page.body.integratedShortcutGroupIDs, [
            "primary-shortcuts", "sequential-paste-shortcuts", "clipboard-window-shortcuts",
            "privacy-copy-shortcuts", "collection-shortcuts",
        ])
        guard case let .form(sections) = page.body else {
            return XCTFail("Expected form settings")
        }
        XCTAssertEqual(sections.map(\.id), [
            "clipboard-essential-settings",
            "clipboard-snippet-settings",
            "clipboard-queue-settings",
            "clipboard-additional-shortcuts",
            "clipboard-data-settings",
        ])
        XCTAssertTrue(sections.allSatisfy { $0.title?.isEmpty == false }, "Each feature needs a native section header")
        XCTAssertTrue(sections.allSatisfy { $0.headerAccessory == nil }, "Do not duplicate native section headers")
        XCTAssertEqual(plugin.shortcutSettingsGroups.map(\.id), [
            "primary-shortcuts",
            "sequential-paste-shortcuts",
            "clipboard-window-shortcuts",
            "privacy-copy-shortcuts",
            "collection-shortcuts",
        ])
        XCTAssertNil(plugin.shortcutSettingsGroups[0].description)
        XCTAssertNotNil(plugin.shortcutSettingsGroups[1].description)
        XCTAssertNotNil(plugin.shortcutSettingsGroups[2].description)
        XCTAssertNil(plugin.shortcutSettingsGroups[3].description)
        XCTAssertNotNil(plugin.shortcutSettingsGroups[4].description)
        XCTAssertEqual(plugin.shortcutSettingsGroups[0].actionIDs, [
            ClipboardHistoryPlugin.ActionID.openHistory,
        ])
        XCTAssertEqual(
            plugin.shortcutSettingsGroups[0].shortcutDefinitionIDs,
            ["paste-clipboard-as-plain-text"]
        )
        XCTAssertEqual(
            Set(plugin.shortcutSettingsGroups.flatMap(\.actionIDs)),
            ClipboardHistoryPlugin.ActionID.all
        )
        XCTAssertEqual(plugin.shortcutSettingsGroups[1].actionIDs, [
            ClipboardHistoryPlugin.ActionID.previousSequentialQueueItem,
            ClipboardHistoryPlugin.ActionID.skipSequentialQueueItem,
            ClipboardHistoryPlugin.ActionID.restartSequentialQueue,
            ClipboardHistoryPlugin.ActionID.cancelSequentialQueue,
        ])
        XCTAssertEqual(
            plugin.shortcutSettingsGroups[1].shortcutDefinitionIDs,
            ["paste-sequentially"]
        )
        XCTAssertEqual(
            plugin.shortcutDefinitionFirstSettingsGroupIDs,
            ["sequential-paste-shortcuts"]
        )
        XCTAssertEqual(
            plugin.collapsibleActionSettingsGroupIDs,
            ["sequential-paste-shortcuts"]
        )
        XCTAssertEqual(
            plugin.collapsibleShortcutSettingsGroupIDs,
            ["clipboard-window-shortcuts", "privacy-copy-shortcuts", "collection-shortcuts"]
        )
        XCTAssertEqual(plugin.shortcutSettingsGroups[4].actionIDs, [
            ClipboardHistoryPlugin.ActionID.toggleCollection,
            ClipboardHistoryPlugin.ActionID.pauseCollection,
            ClipboardHistoryPlugin.ActionID.resumeCollection,
            ClipboardHistoryPlugin.ActionID.clearAllHistory,
        ])
        XCTAssertEqual(
            plugin.shortcutSettingsGroups.map(\.placementAfterSectionID),
            [
                "clipboard-essential-settings",
                "clipboard-queue-settings",
                "clipboard-additional-shortcuts",
                "clipboard-additional-shortcuts",
                "clipboard-essential-settings",
            ]
        )
        XCTAssertNotNil(plugin.primaryPanel)
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
    }

    func testEmbeddedShortcutSearchRevealsActualCustomSettingsSections() async throws {
        let plugin = makePlugin(pasteboard: PluginTestClipboardPasteboard())
        let host = makePluginHostForTests(plugins: [plugin], loadDynamicPluginsOnInit: false)
        defer { plugin.deactivate(reason: .hostShutdown) }
        let page = try XCTUnwrap(host.pluginSettingsItems.first {
            $0.pluginID == ClipboardHistoryPlugin.pluginID
        })
        let index = MacToolsSearchIndexBuilder.build(pluginHost: host)

        for groupID in page.integratedShortcutGroupIDs.sorted() {
            XCTAssertFalse(page.standaloneShortcutSettingsGroups.contains { $0.id == groupID })
            let section = try XCTUnwrap(page.sections.first {
                if case let .custom(content) = $0.content {
                    return content.embeddedShortcutGroupIDs.contains(groupID)
                }
                return false
            })
            let target = PluginSettingsSearchTarget(pluginID: plugin.metadata.id, entryID: groupID)
            // Action-only collection controls have no plugin-shortcut search result today.
            if groupID != ClipboardHistoryPlugin.ShortcutID.collectionGroup {
                let result = try XCTUnwrap(index.items.first {
                    $0.id == "shortcut-group.\(plugin.metadata.id).\(groupID)"
                })
                XCTAssertEqual(result.action, .navigate(
                    destination: .plugins(.configuration(plugin.metadata.id)), target: .plugin(target)))
                XCTAssertTrue(host.hasPluginSettingsSearchTarget(target))
            }
            let content = host.pluginSettingsContentViewItem(
                for: plugin.metadata.id, sectionID: section.id
            ).content
            func root(_ target: PluginSettingsSearchTarget?) -> some View {
                content
                    .environment(\.pluginSettingsSearchTarget, target)
                    .frame(width: 900)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let view = NSHostingView(rootView: root(nil))
            view.layoutSubtreeIfNeeded()
            let collapsedHeight = view.fittingSize.height

            if groupID == ClipboardHistoryPlugin.ShortcutID.primaryGroup {
                view.rootView = root(target)
                await Task.yield()
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.fittingSize.height, collapsedHeight, accuracy: 1,
                    "Primary history shortcuts are already visible and must not expand advanced controls")
                continue
            }

            view.rootView = root(target)
            let didExpand = await waitUntil {
                view.layoutSubtreeIfNeeded()
                return view.fittingSize.height > collapsedHeight + 100
            }
            XCTAssertTrue(didExpand, "Search must expand the actual embedded \(groupID) controls")
            let expandedHeight = view.fittingSize.height

            // Clearing the temporary highlight must preserve the user's expanded section.
            view.rootView = root(nil)
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            XCTAssertEqual(view.fittingSize.height, expandedHeight, accuracy: 1)

            // A search can also be present before the custom section first appears.
            let initialView = NSHostingView(rootView: root(target))
            let initiallyExpanded = await waitUntil {
                initialView.layoutSubtreeIfNeeded()
                return initialView.fittingSize.height > collapsedHeight + 100
            }
            XCTAssertTrue(initiallyExpanded, "Initial search must reveal \(groupID)")

            for unrelated in [
                PluginSettingsSearchTarget(pluginID: "another-plugin", entryID: groupID),
                PluginSettingsSearchTarget(pluginID: plugin.metadata.id, entryID: "unknown-group"),
            ] {
                let unrelatedView = NSHostingView(rootView: root(unrelated))
                unrelatedView.layoutSubtreeIfNeeded()
                await Task.yield()
                XCTAssertEqual(unrelatedView.fittingSize.height, collapsedHeight, accuracy: 1)
            }
        }
    }

    func testPublishesFocusedClipboardOperationsAsPluginShortcutsInsteadOfCanonicalActions() {
        let plugin = makePlugin()
        let shortcuts = plugin.shortcutDefinitions

        XCTAssertEqual(
            Set(shortcuts.map(\.actionID)),
            [
                "private-copy",
                "ignore-next-copy",
                "paste-clipboard-as-plain-text",
                "paste-sequentially",
                "panel-cycle-scope",
                "panel-actions",
                "panel-export",
                "panel-edit-snippet",
                "panel-share",
                "panel-save",
                "panel-delete",
                "panel-multi-select",
                "panel-toggle-selection",
                "panel-select-all",
                "panel-copy-combined",
                "panel-paste-combined",
            ]
        )
        XCTAssertEqual(shortcuts.filter { $0.scope == .whilePluginActive }.count, 12)
        let selectionShortcut = shortcuts.first { $0.id == ClipboardHistoryPlugin.ShortcutID.panelToggleSelection }
        XCTAssertEqual(selectionShortcut?.defaultBinding, ShortcutBinding(keyCode: 36, modifiers: [.command]))
        XCTAssertEqual(selectionShortcut?.defaultBinding,
                       ClipboardHistoryPlugin.defaultPanelShortcutBinding(ClipboardHistoryPlugin.ShortcutID.panelToggleSelection))
        XCTAssertEqual(
            ClipboardHistoryPlugin.defaultPanelShortcutBinding(ClipboardHistoryPlugin.ShortcutID.panelSelectAll),
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        )
        XCTAssertTrue(shortcuts.filter { $0.scope == .whilePluginActive }.allSatisfy {
            $0.settingsGroupID == "clipboard-window-shortcuts"
        })
        XCTAssertEqual(
            Set(shortcuts.compactMap(\.settingsGroupTitle)),
            [
                "敏感内容复制快捷键",
                "纯文本粘贴快捷键",
                "Sequential Paste",
                "Clipboard Window Shortcuts",
            ]
        )
        XCTAssertFalse(plugin.actionDefinitions.contains { $0.key.actionID == "private-copy" })
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
    }

    func testClipboardWindowShortcutValidationProtectsFixedCommandFamilies() {
        let plugin = makePlugin()
        let configurableID = ClipboardHistoryPlugin.ShortcutID.panelSave

        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: configurableID,
            binding: ShortcutBinding(keyCode: 18, modifiers: [.command])
        ))
        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: configurableID,
            binding: ClipboardHistoryFixedShortcut.pastePlainText
        ))
        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: configurableID,
            binding: ClipboardHistoryFixedShortcut.paste
        ))
        XCTAssertNil(plugin.shortcutValidationMessage(
            definitionID: configurableID,
            binding: ShortcutBinding(keyCode: 1, modifiers: [.command, .option])
        ))
        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: ClipboardItemShortcutStore.definitionID(for: UUID()),
            binding: ClipboardHistoryFixedShortcut.paste
        ))
    }

    func testClipboardWindowShortcutValidationProtectsDerivedReverseCycleBinding() {
        let plugin = makePlugin()
        let cycleBinding = ShortcutBinding(keyCode: 48, modifiers: [.control])
        let reverseBinding = ShortcutBinding(keyCode: 48, modifiers: [.control, .shift])
        var bindings = [ClipboardHistoryPlugin.ShortcutID.panelCycleScope: cycleBinding]
        plugin.shortcutBindingResolver = { bindings[$0] }

        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: ClipboardHistoryPlugin.ShortcutID.panelSave,
            binding: reverseBinding
        ))

        bindings[ClipboardHistoryPlugin.ShortcutID.panelSave] = reverseBinding
        XCTAssertNotNil(plugin.shortcutValidationMessage(
            definitionID: ClipboardHistoryPlugin.ShortcutID.panelCycleScope,
            binding: cycleBinding
        ))
    }

    func testInitialSetupPresentationAndCompletionPersistIndependently() {
        let suiteName = "ClipboardHistoryInitialSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )

        let firstStore = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertTrue(firstStore.isPaused)
        XCTAssertFalse(firstStore.hasCompletedInitialSetup)
        XCTAssertFalse(firstStore.hasPresentedInitialSetup)
        XCTAssertTrue(firstStore.shouldAutomaticallyPresentInitialSetup())
        XCTAssertFalse(firstStore.shouldAutomaticallyPresentInitialSetup())

        let restoredStore = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertFalse(restoredStore.hasCompletedInitialSetup)
        XCTAssertTrue(restoredStore.hasPresentedInitialSetup)
        XCTAssertFalse(restoredStore.shouldAutomaticallyPresentInitialSetup())

        restoredStore.completeInitialSetup()
        XCTAssertTrue(restoredStore.hasCompletedInitialSetup)

        let reopenedStore = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertFalse(reopenedStore.isPaused)
        XCTAssertTrue(reopenedStore.hasCompletedInitialSetup)
        XCTAssertTrue(reopenedStore.hasPresentedInitialSetup)
        XCTAssertFalse(reopenedStore.shouldAutomaticallyPresentInitialSetup())
    }

    func testFreshSettingsPauseCollectionButPreserveAnExplicitStoredChoice() {
        let suiteName = "ClipboardHistoryFreshPauseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )

        XCTAssertTrue(ClipboardHistorySettingsStore(storage: storage).isPaused)
        storage.set(false, forKey: "collection-paused")
        XCTAssertFalse(ClipboardHistorySettingsStore(storage: storage).isPaused)
    }

    func testSetupProgressRequiresCollectionBeforeRevealingShortcutSteps() {
        let storagePending = ClipboardHistorySetupProgress(
            storageReady: false,
            collectionEnabled: false,
            primaryShortcutAssigned: false,
            privacyShortcutAssigned: false,
            hasRevealedShortcutSections: false
        )
        XCTAssertTrue(storagePending.canReveal(.storage))
        XCTAssertFalse(storagePending.canReveal(.collection))
        XCTAssertEqual(storagePending.completedRequiredStepCount, 0)

        let collectionPaused = ClipboardHistorySetupProgress(
            storageReady: true,
            collectionEnabled: false,
            primaryShortcutAssigned: false,
            privacyShortcutAssigned: false,
            hasRevealedShortcutSections: false
        )
        XCTAssertTrue(collectionPaused.canReveal(.collection))
        XCTAssertFalse(collectionPaused.canReveal(.primaryShortcuts))
        XCTAssertFalse(collectionPaused.canReveal(.sensitiveCopy))
        XCTAssertEqual(collectionPaused.completedRequiredStepCount, 1)
        XCTAssertFalse(collectionPaused.canFinish)
    }

    func testSetupProgressTreatsShortcutSectionsAsOptional() {
        let ready = ClipboardHistorySetupProgress(
            storageReady: true,
            collectionEnabled: true,
            primaryShortcutAssigned: false,
            privacyShortcutAssigned: false,
            hasRevealedShortcutSections: true
        )
        XCTAssertTrue(ready.canFinish)
        XCTAssertEqual(ready.completedRequiredStepCount, 2)
        XCTAssertTrue(ready.canReveal(.primaryShortcuts))
        XCTAssertTrue(ready.canReveal(.sensitiveCopy))
        XCTAssertFalse(ready.isConfigured(.primaryShortcuts))
        XCTAssertFalse(ready.isConfigured(.sensitiveCopy))
    }

    func testSetupProgressKeepsPreviouslyRevealedShortcutsVisibleWhenCollectionIsDisabled() {
        let progress = ClipboardHistorySetupProgress(
            storageReady: true,
            collectionEnabled: false,
            primaryShortcutAssigned: true,
            privacyShortcutAssigned: true,
            hasRevealedShortcutSections: true
        )

        XCTAssertEqual(progress.completedRequiredStepCount, 1)
        XCTAssertFalse(progress.canFinish)
        XCTAssertTrue(progress.canReveal(.primaryShortcuts))
        XCTAssertTrue(progress.canReveal(.sensitiveCopy))
        XCTAssertTrue(progress.isConfigured(.primaryShortcuts))
        XCTAssertTrue(progress.isConfigured(.sensitiveCopy))
    }

    func testSetupDisclosureAccessibilityReportsExpandedState() {
        let localization = PluginLocalization(bundle: .main)

        XCTAssertEqual(
            ClipboardHistorySetupAccessibility.disclosureValue(
                isExpanded: true,
                localization: localization
            ),
            "已展开"
        )
        XCTAssertEqual(
            ClipboardHistorySetupAccessibility.disclosureValue(
                isExpanded: false,
                localization: localization
            ),
            "已折叠"
        )
    }

    func testSettingsContextCanMutateActionBackedShortcutFromSetup() {
        let item = PluginSettingsActionShortcutItem(
            actionID: ClipboardHistoryPlugin.ActionID.openHistory,
            title: "Open Clipboard History",
            description: "Open or close the panel.",
            bindingText: "⌥ + ⌘ + V",
            canAssign: true,
            canClear: true
        )
        var recordedActionID: String?
        var clearedActionID: String?
        let context = PluginSettingsContext(
            pluginID: ClipboardHistoryPlugin.pluginID,
            actionShortcutItems: [item],
            recordActionShortcut: { actionID, _ in
                recordedActionID = actionID
                return nil
            },
            clearActionShortcut: { actionID in
                clearedActionID = actionID
            }
        )

        XCTAssertEqual(
            context.actionShortcutItem(actionID: ClipboardHistoryPlugin.ActionID.openHistory)?.bindingText,
            "⌥ + ⌘ + V"
        )
        XCTAssertEqual(
            context.recordActionShortcut(
                ShortcutBinding(keyCode: 9, modifiers: [.command, .option]),
                for: ClipboardHistoryPlugin.ActionID.openHistory
            ),
            .accepted
        )
        context.clearActionShortcut(for: ClipboardHistoryPlugin.ActionID.openHistory)
        XCTAssertEqual(recordedActionID, ClipboardHistoryPlugin.ActionID.openHistory)
        XCTAssertEqual(clearedActionID, ClipboardHistoryPlugin.ActionID.openHistory)
    }

    func testRemovedUnlimitedItemCountFallsBackToDefaultLimit() {
        let suiteName = "ClipboardHistoryItemLimitMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )
        storage.set(-1, forKey: "maximum-item-count")

        let settings = ClipboardHistorySettingsStore(storage: storage)

        XCTAssertEqual(
            settings.maximumItemCount,
            ClipboardHistorySettings.defaultMaximumItemCount
        )
        XCTAssertFalse(ClipboardHistorySettingsStore.allowedItemCounts.contains(-1))
    }

    func testStorageLimitPersistsFiveGigabytePreset() {
        let suiteName = "ClipboardHistoryStorageLimitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )
        let settings = ClipboardHistorySettingsStore(storage: storage)

        settings.maximumTotalPayloadByteCount = ClipboardHistorySettings.maximumSupportedTotalPayloadByteCount
        let restored = ClipboardHistorySettingsStore(storage: storage)

        XCTAssertEqual(
            restored.maximumTotalPayloadByteCount,
            ClipboardHistorySettings.maximumSupportedTotalPayloadByteCount
        )
        XCTAssertEqual(ClipboardHistorySettingsStore.allowedTotalPayloadByteCounts.last, 5 * 1_024 * 1_024 * 1_024)
    }

    func testSequentialHUDSettingsDefaultAndPersist() {
        let suiteName = "ClipboardHistorySequentialHUDSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )
        let settings = ClipboardHistorySettingsStore(storage: storage)

        XCTAssertEqual(settings.sequentialHUDDismissal, .tenSeconds)
        XCTAssertFalse(settings.hidesSequentialHUDPreview)
        settings.sequentialHUDDismissal = .never
        settings.hidesSequentialHUDPreview = true

        let restored = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertEqual(restored.sequentialHUDDismissal, .never)
        XCTAssertTrue(restored.hidesSequentialHUDPreview)
    }

    func testSequentialHUDThumbnailRejectsMalformedDataAndProducesBoundedPNG() throws {
        XCTAssertNil(ClipboardHistoryPlugin.makeHUDThumbnailData(from: Data("invalid".utf8)))

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 320,
            pixelsHigh: 180,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let source = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let thumbnail = try XCTUnwrap(ClipboardHistoryPlugin.makeHUDThumbnailData(from: source))
        let result = try XCTUnwrap(NSBitmapImageRep(data: thumbnail))

        XCTAssertLessThanOrEqual(result.pixelsWide, 160)
        XCTAssertLessThanOrEqual(result.pixelsHigh, 160)
    }

    func testKeywordExpansionRetriesAfterAccessibilityBecomesTrusted() {
        var isTrusted = false
        let plugin = makePlugin(accessibilityTrusted: { isTrusted })

        plugin.setKeywordExpansionEnabledForTesting(true)
        XCTAssertEqual(plugin.keywordExpansionStartAttemptCountForTesting, 0)

        isTrusted = true
        plugin.refreshAccessibilityPermission()
        XCTAssertEqual(plugin.keywordExpansionStartAttemptCountForTesting, 0)
        XCTAssertFalse(plugin.hasConfiguredKeywordExpansionForTesting)
        XCTAssertFalse(plugin.isKeywordExpansionRunningForTesting)
        plugin.deactivate(reason: .hostShutdown)
    }

    func testAddingFirstSnippetKeywordRestartsEnabledExpansion() async throws {
        let plugin = makePlugin(
            savedPersistence: InMemoryClipboardSavedLibraryPersistence(),
            accessibilityTrusted: { true }
        )
        plugin.savedLibraryController.start()
        let didLoadSavedLibrary = await waitUntil {
            plugin.savedLibraryController.isLoaded
        }
        XCTAssertTrue(didLoadSavedLibrary)

        plugin.setKeywordExpansionEnabledForTesting(true)
        let attemptsBeforeKeyword = plugin.keywordExpansionStartAttemptCountForTesting
        XCTAssertFalse(plugin.hasConfiguredKeywordExpansionForTesting)

        let saved = await plugin.savedLibraryController.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Build",
            content: "Build the app",
            tags: [],
            keyword: ";bb",
        ))

        XCTAssertNotNil(saved)
        XCTAssertTrue(plugin.hasConfiguredKeywordExpansionForTesting)
        XCTAssertGreaterThan(
            plugin.keywordExpansionStartAttemptCountForTesting,
            attemptsBeforeKeyword
        )
        plugin.deactivate(reason: .hostShutdown)
    }

    func testPrivateCopyShortcutSuppressesSynthesizedCopyBeforePayloadRead() async throws {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardCopyCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            copyCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { true }
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        sender.onSend = {
            pasteboard.simulateCopy("browser secret")
        }

        plugin.handleShortcutAction(id: "private-copy")
        let didSendCopy = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(didSendCopy)
        plugin.controller.processPasteboardChange()

        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(sender.targetProcessIdentifiers, [1234])
        XCTAssertTrue(sender.didArmBeforeSending)
        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        XCTAssertTrue(plugin.controller.items.isEmpty)
        XCTAssertEqual(hud.events, [
            .armed(mode: .privateCopy, timeout: 15),
            .consumed(mode: .privateCopy),
        ])

        plugin.controller.cancelNextCaptureSuppression()
        pasteboard.simulateCopy("ordinary copy")
        plugin.controller.processPasteboardChange()
        XCTAssertEqual(plugin.controller.items.map(\.text), ["ordinary copy"])
        plugin.controller.stop()
    }

    func testPrivateCopyRequestsAccessibilityWithoutArmingWhenPermissionIsDenied() async {
        let sender = FakeClipboardCopyCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        var permissionWasRequested = false
        var guidancePermissionID: String?
        let plugin = makePlugin(
            copyCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { false },
            accessibilityRequester: { _ in
                permissionWasRequested = true
                return false
            }
        )
        plugin.requestPermissionGuidance = { guidancePermissionID = $0 }
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        plugin.handleShortcutAction(id: "private-copy")
        let didRequestPermission = await waitUntil { permissionWasRequested }

        XCTAssertTrue(didRequestPermission)
        XCTAssertEqual(guidancePermissionID, "accessibility")
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertFalse(plugin.controller.isIgnoringNextCopy)
        XCTAssertEqual(hud.failures, ["私密复制需要辅助功能权限"])
        plugin.controller.stop()
    }

    func testPrivateCopyRetainsInvocationTargetAndDoesNotArmAfterFocusChanges() async {
        let sender = FakeClipboardCopyCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        var frontmostProcessIdentifier: pid_t? = 1234
        sender.shouldSend = { processIdentifier in
            processIdentifier == frontmostProcessIdentifier
        }
        let plugin = makePlugin(
            copyCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { frontmostProcessIdentifier }
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        plugin.handleShortcutAction(id: "private-copy")
        frontmostProcessIdentifier = 5678
        let didFailClosed = await waitUntil { !hud.failures.isEmpty }

        XCTAssertTrue(didFailClosed)
        XCTAssertEqual(sender.targetProcessIdentifiers, [1234])
        XCTAssertFalse(sender.didArmBeforeSending)
        XCTAssertFalse(plugin.controller.isIgnoringNextCopy)
        XCTAssertEqual(hud.failures, ["私密复制失败"])
        plugin.controller.stop()
    }

    func testPrivateCopyKeepsSuppressionArmedUntilDelayedPasteboardChangeIsConsumed() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardCopyCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            copyCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { true }
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        plugin.handleShortcutAction(id: "private-copy")
        let didArmSuppression = await waitUntil {
            sender.sendCount == 1 && plugin.controller.isIgnoringNextCopy
        }

        XCTAssertTrue(didArmSuppression)
        XCTAssertTrue(hud.failures.isEmpty)

        // Model a slow application publishing the sensitive selection after command dispatch.
        pasteboard.simulateCopy("delayed sensitive copy")
        plugin.controller.processPasteboardChange()
        let didConsumeSuppression = await waitUntil {
            !plugin.controller.isIgnoringNextCopy
        }

        XCTAssertTrue(didConsumeSuppression)
        XCTAssertTrue(plugin.controller.items.isEmpty)
        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        plugin.controller.stop()
    }

    func testDeactivationCancelsInFlightPrivateCopyWithoutPresentingFailure() async {
        let sender = FakeClipboardCopyCommandSender()
        sender.waitUntilCancelled = true
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            copyCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { true }
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        plugin.handleShortcutAction(id: "private-copy")
        let didArmSuppression = await waitUntil {
            sender.sendCount == 1 && plugin.controller.isIgnoringNextCopy
        }
        XCTAssertTrue(didArmSuppression)

        plugin.deactivate(reason: .disabled)
        let didFinish = await waitUntil { sender.didFinish }
        XCTAssertTrue(didFinish)
        XCTAssertFalse(plugin.controller.isIgnoringNextCopy)
        XCTAssertTrue(hud.failures.isEmpty)
    }

    func testPrivateCopyLeaseSuppressesDelayedChangeAfterDeactivationAndReactivation() async {
        let suiteName = "ClipboardHistoryPluginTests.PrivateCopyLease.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )
        let context = PluginRuntimeContext(
            pluginID: ClipboardHistoryPlugin.pluginID,
            storage: storage
        )
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardCopyCommandSender()
        sender.waitUntilCancelled = true
        let firstPlugin = makePlugin(
            pasteboard: pasteboard,
            copyCommandSender: sender,
            accessibilityTrusted: { true },
            storage: storage
        )
        firstPlugin.activate(context: context)
        await waitUntilLoaded(firstPlugin.controller)

        firstPlugin.handleShortcutAction(id: "private-copy")
        let didArm = await waitUntil {
            sender.sendCount == 1 && firstPlugin.controller.isIgnoringNextCopy
        }
        XCTAssertTrue(didArm)
        firstPlugin.deactivate(reason: .disabled)
        let didFinish = await waitUntil { sender.didFinish }
        XCTAssertTrue(didFinish)

        // Model the target publishing its delayed sensitive selection while collection is off.
        pasteboard.simulateCopy("delayed private selection")
        let secondPlugin = makePlugin(
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            storage: storage
        )
        secondPlugin.activate(context: context)
        await waitUntilLoaded(secondPlugin.controller)
        secondPlugin.controller.processPasteboardChange()

        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        XCTAssertTrue(secondPlugin.controller.items.isEmpty)
        secondPlugin.deactivate(reason: .disabled)
    }

    func testPrivateCopyLeaseSurvivesBackupSuspensionAndResume() async throws {
        for restored in [false, true] {
            let pasteboard = PluginTestClipboardPasteboard()
            let persistence = RestartableClipboardHistoryPersistence()
            let sender = FakeClipboardCopyCommandSender()
            let plugin = makePlugin(
                pasteboard: pasteboard,
                persistence: persistence,
                savedPersistence: InMemoryClipboardSavedLibraryPersistence(),
                copyCommandSender: sender,
                accessibilityTrusted: { true }
            )
            defer { plugin.deactivate(reason: .hostShutdown) }
            plugin.controller.start()
            let loaded = await waitUntil { plugin.controller.isLoaded }
            XCTAssertTrue(loaded)
            plugin.handleShortcutAction(id: "private-copy")
            let armed = await waitUntil { sender.sendCount == 1 && plugin.controller.isIgnoringNextCopy }
            XCTAssertTrue(armed)

            plugin.suspendForClipboardBackup()
            XCTAssertFalse(plugin.controller.isIgnoringNextCopy)
            plugin.resumeAfterClipboardBackup(restored: restored)
            let resumed = await waitUntil { plugin.controller.isLoaded }
            XCTAssertTrue(resumed)
            XCTAssertTrue(plugin.controller.isIgnoringNextCopy)

            // The target publishes its private selection after the backup sheet has closed.
            pasteboard.simulateCopy("delayed private selection")
            plugin.controller.processPasteboardChange()
            plugin.controller.stop()
            XCTAssertEqual(pasteboard.plainTextReadCount, 0)
            XCTAssertTrue(plugin.controller.items.isEmpty)
            XCTAssertTrue(try persistence.load().isEmpty)
        }
    }

    func testBackupSuspensionDismissesHUDAndPreservesQueueUntilResume() async throws {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let item = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            persistence: persistence,
            savedPersistence: InMemoryClipboardSavedLibraryPersistence(),
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        defer { plugin.deactivate(reason: .hostShutdown) }
        plugin.controller.settings.sequentialHUDDismissal = .never
        plugin.controller.start()
        plugin.savedLibraryController.start()
        let loaded = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(loaded)
        let created = await plugin.startSequentialQueueForTesting(itemIDs: [item.id])
        XCTAssertTrue(created)
        let original = try XCTUnwrap(plugin.sequentialPasteSessionForTesting)
        let hud = plugin.sequentialPasteHUDForTesting
        XCTAssertTrue(hud.isVisible)

        // A callback queued just before suspension must recheck before changing the queue.
        hud.onSkip?()
        plugin.suspendForClipboardBackup()
        XCTAssertFalse(hud.isVisible)
        plugin.refresh()
        hud.onPasteNext?()
        hud.onPrevious?()
        hud.onSkip?()
        hud.onRestart?()
        hud.onCancel?()
        let rejectedCreation = await plugin.startSequentialQueueForTesting(itemIDs: [item.id])
        XCTAssertFalse(rejectedCreation)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(plugin.controller.isLoaded)
        XCTAssertFalse(plugin.savedLibraryController.isLoaded)
        XCTAssertFalse(plugin.hasPendingSequentialPasteForTesting)
        XCTAssertFalse(hud.isVisible)
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(plugin.sequentialPasteSessionForTesting, original)

        plugin.resumeAfterClipboardBackup(restored: false)
        let resumed = await waitUntil { plugin.controller.isLoaded && plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(resumed)
        hud.onPasteNext?()
        let pasted = await waitUntil { sender.sendCount == 1 && !plugin.hasPendingSequentialPasteForTesting }
        XCTAssertTrue(pasted)
        XCTAssertEqual(plugin.sequentialPasteSessionForTesting?.statuses, [.pasted])
        XCTAssertEqual(pasteboard.text, item.text)
    }

    func testRapidPrivateCopyRequestsDoNotOverlap() async {
        let sender = FakeClipboardCopyCommandSender()
        let plugin = makePlugin(
            copyCommandSender: sender,
            accessibilityTrusted: { true }
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        plugin.handleShortcutAction(id: "private-copy")
        let firstDispatchFinished = await waitUntil {
            sender.sendCount == 1
                && !plugin.hasPrivateCopyOperationForTesting
                && plugin.controller.isIgnoringNextCopy
        }
        XCTAssertTrue(firstDispatchFinished)

        plugin.handleShortcutAction(id: "private-copy")
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(sender.sendCount, 1)
        plugin.controller.stop()
    }

    func testPastePlainTextShortcutRewritesCurrentClipboardAndPastesWithoutOpeningHistory() async {
        let pasteboard = PluginTestClipboardPasteboard()
        pasteboard.simulateCopy("Styled website text")
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            accessibilityTrusted: { true }
        )

        plugin.handleShortcutAction(id: "paste-clipboard-as-plain-text")
        let didSendPaste = await waitUntil { sender.sendCount == 1 }

        XCTAssertTrue(didSendPaste)
        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(sender.targetProcessIdentifiers, [1234])
        XCTAssertEqual(pasteboard.plainTextWriteCount, 1)
        XCTAssertEqual(pasteboard.text, "Styled website text")
        XCTAssertTrue(plugin.controller.items.isEmpty)
    }

    func testPastePlainTextCapturesTargetBeforeAsynchronousWorkAndFailsClosedAfterFocusChanges() async {
        let pasteboard = PluginTestClipboardPasteboard()
        pasteboard.simulateCopy("Sensitive website text")
        let sender = FakeClipboardPasteCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        var frontmostProcessIdentifier: pid_t? = 1234
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { frontmostProcessIdentifier }
        )

        plugin.handleShortcutAction(id: "paste-clipboard-as-plain-text")
        frontmostProcessIdentifier = 5678
        let didFailClosed = await waitUntil { !hud.failures.isEmpty }

        XCTAssertTrue(didFailClosed)
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(pasteboard.plainTextWriteCount, 0)
        XCTAssertEqual(hud.failures, ["无法粘贴纯文本"])
    }

    func testPastePlainTextShortcutUsesRecognizedTextFromTheStillCurrentImage() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            imageTextRecognizer: FakePluginClipboardImageTextRecognizer(
                text: "Recognized screenshot text"
            ),
            accessibilityTrusted: { true }
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        pasteboard.simulateCopy(imagePayload())
        plugin.controller.processPasteboardChange()
        let didFinishIndexing = await waitUntil {
            plugin.controller.items.first?.hasCompletedImageTextIndexing == true
        }
        XCTAssertTrue(didFinishIndexing, "Expected image text indexing to finish")
        guard didFinishIndexing else {
            plugin.controller.stop()
            return
        }

        plugin.handleShortcutAction(id: "paste-clipboard-as-plain-text")
        let didSendPaste = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(didSendPaste, "Expected the plain-text paste command to be sent")

        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(pasteboard.plainTextWriteCount, 1)
        XCTAssertEqual(pasteboard.text, "Recognized screenshot text")
        plugin.controller.stop()
    }

    func testPastePlainTextShortcutFailsWithoutTextAndDoesNotSendPaste() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            privacyHUDPresenter: hud,
            accessibilityTrusted: { true }
        )

        plugin.handleShortcutAction(id: "paste-clipboard-as-plain-text")
        let didShowFailure = await waitUntil { !hud.failures.isEmpty }

        XCTAssertTrue(didShowFailure)
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(pasteboard.plainTextWriteCount, 0)
        XCTAssertEqual(hud.failures, ["剪贴板中没有可粘贴的文本"])
    }

    func testSequentialPasteShortcutUsesRecentHistoryNewestFirst() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        plugin.controller.settings.sequentialHUDDismissal = .never
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        pasteboard.simulateCopy("Older")
        plugin.controller.processPasteboardChange()
        let capturedOlder = await waitUntil { plugin.controller.items.count == 1 }
        XCTAssertTrue(capturedOlder)
        pasteboard.simulateCopy("Newer")
        plugin.controller.processPasteboardChange()
        let capturedNewer = await waitUntil { plugin.controller.items.count == 2 }
        XCTAssertTrue(capturedNewer)

        plugin.handleShortcutAction(id: "paste-sequentially")
        let pastedNewer = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(pastedNewer)
        XCTAssertEqual(pasteboard.text, "Newer")

        plugin.handleShortcutAction(id: "paste-sequentially")
        let pastedOlder = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(pastedOlder)
        XCTAssertEqual(pasteboard.text, "Older")
        plugin.deactivate(reason: .hostShutdown)
    }

    func testSequentialPasteFailureDoesNotAdvanceTheImplicitQueue() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        sender.shouldSucceed = false
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        pasteboard.simulateCopy("Still next")
        plugin.controller.processPasteboardChange()
        let captured = await waitUntil { plugin.controller.items.count == 1 }
        XCTAssertTrue(captured)

        plugin.handleShortcutAction(id: "paste-sequentially")
        let failedPaste = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(failedPaste)
        sender.shouldSucceed = true
        plugin.handleShortcutAction(id: "paste-sequentially")
        let successfulRetry = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(successfulRetry)

        XCTAssertEqual(pasteboard.text, "Still next")
        plugin.deactivate(reason: .hostShutdown)
    }

    func testRapidSequentialPasteRequestsAreSerializedWithoutDuplicatesOrSkips() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = BlockingClipboardPasteCommandSender {
            pasteboard.text
        }
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        plugin.controller.settings.sequentialHUDDismissal = .never
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        for (index, text) in ["Oldest", "Middle", "Newest"].enumerated() {
            pasteboard.simulateCopy(text)
            plugin.controller.processPasteboardChange()
            let expectedCount = index + 1
            let captured = await waitUntil { plugin.controller.items.count == expectedCount }
            XCTAssertTrue(captured)
        }

        plugin.handleShortcutAction(id: "paste-sequentially")
        plugin.handleShortcutAction(id: "paste-sequentially")
        plugin.handleShortcutAction(id: "paste-sequentially")

        let firstStarted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(firstStarted)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sender.sendCount, 1, "Only one paste may be in flight")
        XCTAssertEqual(sender.pastedTexts, ["Newest"])

        sender.completeNextPaste()
        let secondStarted = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newest", "Middle"])

        sender.completeNextPaste()
        let thirdStarted = await waitUntil { sender.sendCount == 3 }
        XCTAssertTrue(thirdStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newest", "Middle", "Oldest"])

        sender.completeNextPaste()
        plugin.deactivate(reason: .hostShutdown)
    }

    func testSuccessfulPasteFinishingDuringDeactivationDoesNotAdvanceImplicitQueue() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = BlockingClipboardPasteCommandSender { pasteboard.text }
        let plugin = makePlugin(
            pasteboard: pasteboard,
            persistence: RestartableClipboardHistoryPersistence(),
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        for (index, text) in ["Older", "Newer"].enumerated() {
            pasteboard.simulateCopy(text)
            plugin.controller.processPasteboardChange()
            let captured = await waitUntil { plugin.controller.items.count == index + 1 }
            XCTAssertTrue(captured)
        }

        plugin.handleShortcutAction(id: "paste-sequentially")
        let firstStarted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newer"])
        plugin.deactivate(reason: .hostShutdown)
        sender.completeNextPaste()
        for _ in 0..<50 { await Task.yield() }

        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        plugin.handleShortcutAction(id: "paste-sequentially")
        let secondStarted = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newer", "Newer"])
        sender.completeNextPaste()
        plugin.deactivate(reason: .hostShutdown)
    }

    func testSuccessfulExplicitPasteFinishingDuringDeactivationStillAdvancesQueue() async throws {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = BlockingClipboardPasteCommandSender { pasteboard.text }
        let newerID = UUID()
        let olderID = UUID()
        let initialSession = try ClipboardSequentialPasteSession(explicitSnapshots: [
            ClipboardSequentialPasteSnapshot(
                sourceItemID: newerID,
                payload: .plainText("Newer"),
                expandsSnippetVariables: false
            ),
            ClipboardSequentialPasteSnapshot(
                sourceItemID: olderID,
                payload: .plainText("Older"),
                expandsSnippetVariables: false
            ),
        ])
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero,
            initialExplicitSession: initialSession
        )
        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLibraryLoaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryLoaded)

        plugin.handleShortcutAction(id: "paste-sequentially")
        let firstPasteStarted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(firstPasteStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newer"])
        plugin.deactivate(reason: .hostShutdown)
        sender.completeNextPaste()
        for _ in 0..<50 { await Task.yield() }

        plugin.controller.start()
        plugin.savedLibraryController.start()
        await waitUntilLoaded(plugin.controller)
        let savedLibraryReloaded = await waitUntil { plugin.savedLibraryController.isLoaded }
        XCTAssertTrue(savedLibraryReloaded)
        plugin.handleShortcutAction(id: "paste-sequentially")
        let secondPasteStarted = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(secondPasteStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newer", "Older"])
        sender.completeNextPaste()
        plugin.deactivate(reason: .hostShutdown)
    }

    func testDeletingAnExplicitQueueItemCancelsTheImmutableQueueFirst() async throws {
        let queuedID = UUID()
        let initialSession = try ClipboardSequentialPasteSession(explicitSnapshots: [
            ClipboardSequentialPasteSnapshot(
                sourceItemID: queuedID,
                payload: .plainText("Queued"),
                expandsSnippetVariables: false
            ),
        ])
        let plugin = makePlugin(initialExplicitSession: initialSession)
        defer { plugin.deactivate(reason: .hostShutdown) }

        let prepared = await plugin.prepareForPermanentDeletionForTesting(itemIDs: [queuedID])

        XCTAssertTrue(prepared)
        XCTAssertNil(plugin.sequentialPasteSessionForTesting)
    }

    func testExternalCopyCancelsBufferedPastesWithoutClearingNewWorkerReservations() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = BlockingClipboardPasteCommandSender { pasteboard.text }
        let plugin = makePlugin(
            pasteboard: pasteboard, pasteCommandSender: sender,
            accessibilityTrusted: { true }, frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        for (index, text) in ["Older", "Newer"].enumerated() {
            pasteboard.simulateCopy(text)
            plugin.controller.processPasteboardChange()
            let captured = await waitUntil { plugin.controller.items.count == index + 1 }
            XCTAssertTrue(captured)
        }
        plugin.handleShortcutAction(id: "paste-sequentially")
        plugin.handleShortcutAction(id: "paste-sequentially")
        let oldStarted = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(oldStarted)

        pasteboard.simulateCopy("Fresh")
        plugin.controller.processPasteboardChange()
        let freshCaptured = await waitUntil { plugin.controller.items.count == 3 }
        XCTAssertTrue(freshCaptured)
        plugin.handleShortcutAction(id: "paste-sequentially")
        plugin.handleShortcutAction(id: "paste-sequentially")
        let newStarted = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(newStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newer", "Fresh"])

        // Finishing the old sender must not advance the new queue or discard its request.
        sender.completeNextPaste()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(sender.sendCount, 2)
        sender.completeNextPaste()
        let nextStarted = await waitUntil { sender.sendCount == 3 }
        XCTAssertTrue(nextStarted)
        XCTAssertEqual(sender.pastedTexts, ["Newer", "Fresh", "Newer"])
        sender.completeNextPaste()
        plugin.deactivate(reason: .hostShutdown)
    }

    func testClearingHistoryEndsAnActiveImplicitQueue() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = BlockingClipboardPasteCommandSender { pasteboard.text }
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        defer {
            sender.completeNextPaste()
            plugin.deactivate(reason: .hostShutdown)
        }
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        pasteboard.simulateCopy("Queued")
        plugin.controller.processPasteboardChange()
        let didCapture = await waitUntil { plugin.controller.items.count == 1 }
        XCTAssertTrue(didCapture)

        plugin.handleShortcutAction(id: "paste-sequentially")
        let didStartPaste = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(didStartPaste)
        XCTAssertEqual(plugin.sequentialPasteSessionForTesting?.source, .recentHistory)

        let didClear = await plugin.controller.clearAllHistory()
        XCTAssertTrue(didClear)
        XCTAssertNil(plugin.sequentialPasteSessionForTesting)
        XCTAssertFalse(plugin.hasPendingSequentialPasteForTesting)
    }

    func testExternalCopyDuringPayloadLoadCancelsImplicitPasteBeforePolling() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let item = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [item])
        persistence.allowSaveToFinish()
        let plugin = makePlugin(pasteboard: pasteboard, persistence: persistence,
            pasteCommandSender: sender, accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 }, sequentialPasteStabilizationDelay: .zero)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        // Keep the loaded items but disable polling to exercise the pre-write check alone.
        plugin.controller.stop()
        let gate = PluginTestPayloadGate()
        item.configurePayloadLoader({ gate.load() }, discardCachedPayload: true)
        plugin.handleShortcutAction(id: "paste-sequentially")
        let started = await waitUntil { gate.started }
        XCTAssertTrue(started)
        pasteboard.simulateCopy("new external copy")
        gate.release.signal()
        let finished = await waitUntil { !plugin.hasPendingSequentialPasteForTesting }
        XCTAssertTrue(finished)
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(pasteboard.text, "new external copy")
        plugin.deactivate(reason: .hostShutdown)
    }

    func testExternalCopyCancelsRequestBeforeFirstImplicitSessionStarts() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(pasteboard: pasteboard, pasteCommandSender: sender,
            accessibilityTrusted: { true }, frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        pasteboard.simulateCopy("old")
        plugin.controller.processPasteboardChange()
        let captured = await waitUntil { plugin.controller.items.count == 1 }
        XCTAssertTrue(captured)
        plugin.handleShortcutAction(id: "paste-sequentially")
        pasteboard.simulateCopy("new")
        plugin.controller.processPasteboardChange()
        XCTAssertFalse(plugin.hasPendingSequentialPasteForTesting)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(pasteboard.text, "new")
        plugin.deactivate(reason: .hostShutdown)
    }

    func testExpandedTextLimitDefaultsPersistsAndRejectsUnknownStoredValues() {
        let suiteName = "ClipboardExpandedLimitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsPluginStorage(pluginID: ClipboardHistoryPlugin.pluginID, userDefaults: defaults)
        let settings = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertEqual(settings.maximumExpandedTextByteCount, 5 * 1_024 * 1_024)
        for value in ClipboardHistorySettingsStore.allowedExpandedTextByteCounts {
            settings.maximumExpandedTextByteCount = value
            XCTAssertEqual(ClipboardHistorySettingsStore(storage: storage).maximumExpandedTextByteCount, value)
        }
        storage.set(-1, forKey: "snippet-maximum-expanded-text-byte-count")
        XCTAssertEqual(ClipboardHistorySettingsStore(storage: storage).maximumExpandedTextByteCount, 5 * 1_024 * 1_024)
    }

    func testExternalCopyResetsImplicitQueueBeforeStartingANewRecentSnapshot() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardPasteCommandSender()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            pasteCommandSender: sender,
            accessibilityTrusted: { true },
            frontmostProcessIdentifier: { 42 },
            sequentialPasteStabilizationDelay: .zero
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        for (index, text) in ["Older", "Newer"].enumerated() {
            pasteboard.simulateCopy(text)
            plugin.controller.processPasteboardChange()
            let didCapture = await waitUntil { plugin.controller.items.count == index + 1 }
            XCTAssertTrue(didCapture)
        }

        plugin.handleShortcutAction(id: "paste-sequentially")
        let didPasteNewer = await waitUntil { sender.sendCount == 1 }
        XCTAssertTrue(didPasteNewer)
        XCTAssertEqual(pasteboard.text, "Newer")

        pasteboard.simulateCopy("Fresh external copy")
        plugin.controller.processPasteboardChange()
        let didCaptureFreshCopy = await waitUntil { plugin.controller.items.count == 3 }
        XCTAssertTrue(didCaptureFreshCopy)
        plugin.handleShortcutAction(id: "paste-sequentially")
        let didPasteFreshCopy = await waitUntil { sender.sendCount == 2 }
        XCTAssertTrue(didPasteFreshCopy)
        XCTAssertEqual(pasteboard.text, "Fresh external copy")
        plugin.deactivate(reason: .hostShutdown)
    }

    func testPrivacyShortcutsFailClosedWhileHistoryIsLoading() async {
        let persistence = BlockingLoadClipboardHistoryPersistence()
        let sender = FakeClipboardCopyCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            persistence: persistence,
            copyCommandSender: sender,
            privacyHUDPresenter: hud
        )
        plugin.controller.start()
        let didStartLoading = await waitUntil { persistence.loadStarted }
        XCTAssertTrue(didStartLoading)

        plugin.handleShortcutAction(id: "ignore-next-copy")
        plugin.handleShortcutAction(id: "private-copy")
        let didShowFailures = await waitUntil { hud.failures.count == 2 }

        XCTAssertTrue(didShowFailures)
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertFalse(plugin.controller.isIgnoringNextCopy)
        XCTAssertEqual(hud.events, [])
        XCTAssertEqual(hud.failures, [
            "剪贴板历史尚未准备好",
            "剪贴板历史尚未准备好",
        ])

        persistence.allowLoadToFinish()
        await waitUntilLoaded(plugin.controller)
        plugin.controller.stop()
    }

    func testIgnoreNextCopyShortcutPublishesArmedAndConsumedHUDStates() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(pasteboard: pasteboard, privacyHUDPresenter: hud)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)

        plugin.handleShortcutAction(id: "ignore-next-copy")
        XCTAssertEqual(hud.events, [.armed(mode: .ignoreNextCopy, timeout: 15)])

        pasteboard.simulateCopy("private context-menu copy")
        plugin.controller.processPasteboardChange()
        XCTAssertEqual(hud.events, [
            .armed(mode: .ignoreNextCopy, timeout: 15),
            .consumed(mode: .ignoreNextCopy),
        ])
        plugin.controller.stop()
    }

    func testClearActionWaitsForDurablePersistenceBeforeReportingSuccess() async throws {
        let originalItem = historyItem()
        let persistence = BlockingClipboardHistoryPersistence(items: [originalItem])
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = FakeClipboardCopyCommandSender()
        let hud = FakeClipboardPrivacyHUDPresenter()
        let plugin = makePlugin(
            pasteboard: pasteboard,
            persistence: persistence,
            copyCommandSender: sender,
            privacyHUDPresenter: hud
        )
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        XCTAssertTrue(plugin.controller.ignoreNextCopy(expiringAfter: 60))
        pasteboard.simulateCopy("private copy before clear")
        let clearAll = reference(plugin, actionID: ClipboardHistoryPlugin.ActionID.clearAllHistory)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: clearAll, source: .test, mode: .background)
        )
        var result: ActionExecutionResult?
        let resultTask = Task { @MainActor in
            result = await handle.result()
        }

        let didStartSaving = await waitUntil { persistence.saveStarted }
        XCTAssertTrue(didStartSaving)
        XCTAssertNil(result)
        XCTAssertTrue(plugin.controller.isClearingHistory)

        plugin.controller.processPasteboardChange()
        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(hud.events, [
            .armed(mode: .ignoreNextCopy, timeout: 60),
            .consumed(mode: .ignoreNextCopy),
        ])
        // Suppression intentionally remains armed through a quiet interval after the consumed
        // transition. End that separately verified privacy state before exercising the unrelated
        // clear-in-progress rejection below.
        plugin.controller.cancelNextCaptureSuppression()

        let didCopy = await plugin.controller.copyItem(id: originalItem.id)
        XCTAssertFalse(didCopy)
        _ = await plugin.controller.deleteItem(id: originalItem.id)
        plugin.controller.settings.maximumItemCount = 100
        XCTAssertEqual(plugin.controller.items, [originalItem])

        plugin.handleShortcutAction(id: "private-copy")
        let didShowFailure = await waitUntil { !hud.failures.isEmpty }
        XCTAssertTrue(didShowFailure)
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(hud.failures, ["剪贴板历史尚未准备好"])

        persistence.allowSaveToFinish()
        await resultTask.value
        XCTAssertEqual(result, .succeeded())
        XCTAssertFalse(plugin.controller.isClearingHistory)
        XCTAssertTrue(persistence.savedItems.isEmpty)
        plugin.controller.stop()
    }

    func testClearActionReportsPersistenceFailure() async throws {
        let persistence = FailingClipboardHistoryPersistence(items: [historyItem()])
        let plugin = makePlugin(persistence: persistence)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        let clearAll = reference(plugin, actionID: ClipboardHistoryPlugin.ActionID.clearAllHistory)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: clearAll, source: .test, mode: .background)
        ).result()

        guard case let .failed(message) = result else {
            return XCTFail("Expected a failed clear action, got \(result)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotNil(plugin.controller.errorMessage)
        XCTAssertFalse(plugin.controller.isClearingHistory)
        XCTAssertEqual(plugin.controller.items, persistence.items)
        XCTAssertFalse(plugin.actionAvailability(for: clearAll).isAvailable)

        let retryResult = try await plugin.beginAction(
            ActionInvocation(reference: clearAll, source: .test, mode: .background)
        ).result()
        guard case .failed = retryResult else {
            return XCTFail("Expected clear-all to remain unavailable while storage is blocked")
        }
        XCTAssertEqual(persistence.saveCount, 1)
        XCTAssertEqual(plugin.controller.items, persistence.items)
        XCTAssertNotNil(plugin.controller.errorMessage)
        plugin.controller.stop()
    }

    func testUnreadablePersistentHistoryRequiresExplicitReset() async throws {
        let persistence = LoadFailingResettableClipboardHistoryPersistence()
        let plugin = makePlugin(persistence: persistence)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        XCTAssertNotNil(plugin.controller.errorMessage)
        let clearAll = reference(plugin, actionID: ClipboardHistoryPlugin.ActionID.clearAllHistory)
        XCTAssertFalse(plugin.actionAvailability(for: clearAll).isAvailable)
        XCTAssertTrue(plugin.controller.canResetUnreadablePersistentHistory)

        let result = await plugin.controller.resetUnreadablePersistentHistory()

        XCTAssertTrue(result)
        XCTAssertEqual(persistence.resetCount, 1)
        XCTAssertNil(plugin.controller.errorMessage)
        XCTAssertTrue(plugin.controller.items.isEmpty)
        XCTAssertTrue(plugin.controller.canSuppressNextCapture)
        plugin.controller.stop()
    }

    func testTemporaryKeychainFailureCanRetryWithoutResettingHistory() async throws {
        let item = historyItem()
        let persistence = RetryableKeychainClipboardHistoryPersistence(items: [item])
        let plugin = makePlugin(persistence: persistence)
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        XCTAssertEqual(plugin.controller.storageError, .keychain(errSecInteractionNotAllowed))
        XCTAssertTrue(plugin.controller.items.isEmpty)

        plugin.controller.retryStorageAccess()
        await waitUntilLoaded(plugin.controller)

        XCTAssertNil(plugin.controller.errorMessage)
        XCTAssertNil(plugin.controller.storageError)
        XCTAssertEqual(plugin.controller.items.map(\.id), [item.id])
        XCTAssertEqual(persistence.resetCount, 0)
        plugin.controller.stop()
    }

    func testCollectionActionsAndPrimaryStateReflectBlockingStorageError() async throws {
        let plugin = makePlugin(persistence: LoadFailingResettableClipboardHistoryPersistence())
        plugin.controller.start()
        await waitUntilLoaded(plugin.controller)
        XCTAssertNotNil(plugin.controller.errorMessage)
        XCTAssertFalse(plugin.primaryPanelState.isOn)

        let actionIDs = [
            ClipboardHistoryPlugin.ActionID.pauseCollection,
            ClipboardHistoryPlugin.ActionID.resumeCollection,
            ClipboardHistoryPlugin.ActionID.toggleCollection,
        ]
        for actionID in actionIDs {
            let actionReference = reference(plugin, actionID: actionID)
            XCTAssertFalse(plugin.actionAvailability(for: actionReference).isAvailable)
            let wasPaused = plugin.controller.settings.isPaused
            let result = try await plugin.beginAction(
                ActionInvocation(reference: actionReference, source: .test, mode: .background)
            ).result()
            guard case .failed = result else {
                return XCTFail("Expected \(actionID) to fail while storage is blocked")
            }
            XCTAssertEqual(plugin.controller.settings.isPaused, wasPaused)
        }
        plugin.controller.stop()
    }

    private func makePlugin(
        pasteboard: (any ClipboardPasteboardAccess)? = nil,
        persistence: (any ClipboardHistoryPersisting)? = nil,
        savedPersistence: (any ClipboardSavedLibraryPersisting)? = nil,
        copyCommandSender: (any ClipboardCopyCommandSending)? = nil,
        pasteCommandSender: (any ClipboardPasteCommandSending)? = nil,
        privacyHUDPresenter: (any ClipboardPrivacyHUDPresenting)? = nil,
        imageTextRecognizer: (any ClipboardImageTextRecognizing)? = nil,
        accessibilityTrusted: @escaping () -> Bool = { true },
        accessibilityRequester: @escaping (Bool) -> Bool = { _ in true },
        frontmostProcessIdentifier: @escaping () -> pid_t? = { 1234 },
        sequentialPasteStabilizationDelay: Duration = .milliseconds(120),
        initialExplicitSession: ClipboardSequentialPasteSession? = nil,
        snippetPasteboardReader: ClipboardPasteboardReaderProcess? = nil,
        storage providedStorage: (any PluginStorage)? = nil
    ) -> ClipboardHistoryPlugin {
        let storage: any PluginStorage
        if let providedStorage {
            storage = providedStorage
        } else {
            let suiteName = "ClipboardHistoryPluginTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            addTeardownBlock {
                defaults.removePersistentDomain(forName: suiteName)
            }
            storage = UserDefaultsPluginStorage(
                pluginID: ClipboardHistoryPlugin.pluginID,
                userDefaults: defaults
            )
        }
        storage.set(false, forKey: "collection-paused")
        let context = PluginRuntimeContext(
            pluginID: ClipboardHistoryPlugin.pluginID,
            storage: storage
        )
        return ClipboardHistoryPlugin(
            context: context,
            pasteboard: pasteboard,
            persistence: persistence ?? EmptyClipboardHistoryPersistence(),
            savedPersistence: savedPersistence,
            copyCommandSender: copyCommandSender,
            pasteCommandSender: pasteCommandSender,
            privacyHUDPresenter: privacyHUDPresenter ?? FakeClipboardPrivacyHUDPresenter(),
            imageTextRecognizer: imageTextRecognizer,
            accessibilityTrusted: accessibilityTrusted,
            accessibilityRequester: accessibilityRequester,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            sequentialPasteStabilizationDelay: sequentialPasteStabilizationDelay,
            snippetPasteboardReader: snippetPasteboardReader,
            sequentialPasteStore: ClipboardSequentialPasteMemoryStore(
                session: initialExplicitSession
            ),
            initialSequentialPasteSession: initialExplicitSession
        )
    }

    private func waitUntilLoaded(_ controller: ClipboardHistoryController) async {
        let didLoad = await waitUntil { controller.isLoaded }
        XCTAssertTrue(didLoad)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func reference(_ plugin: ClipboardHistoryPlugin, actionID: String) -> ActionReference {
        plugin.actionCatalogEntries.first { $0.reference.key.actionID == actionID }!.reference
    }

    private func historyItem() -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: "saved item",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
    }

    private func imagePayload() -> ClipboardHistoryPayload {
        ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data([0x01, 0x02, 0x03])
                ),
            ]),
        ])
    }
}

private struct FakePluginClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    let text: String?

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        text
    }
}

private final class PluginTestPayloadGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didStart = false
    var started: Bool { lock.withLock { didStart } }
    func load() -> ClipboardHistoryPayload {
        lock.withLock { didStart = true }
        release.wait()
        return .plainText("old queued payload")
    }
}

private final class RestartableClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardHistoryItem] = []
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { lock.withLock { items } }
    func save(_ items: [ClipboardHistoryItem]) throws { lock.withLock { self.items = items } }
    func reset() throws { lock.withLock { items = [] } }
    func removeAll() throws { try reset() }
}

private struct EmptyClipboardHistoryPersistence: ClipboardHistoryPersisting {
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { [] }
    func save(_ items: [ClipboardHistoryItem]) throws {}
    func reset() throws {}
    func removeAll() throws {}
}

private final class BlockingUsageClipboardSavedPersistence: ClipboardSavedLibraryPersisting, @unchecked Sendable {
    private let base = InMemoryClipboardSavedLibraryPersistence()
    private let condition = NSCondition()
    private var started = false
    private var mayFinish = false

    init(item: ClipboardSavedItem) throws {
        try base.save(item, payloadChanged: true)
    }

    var usageUpdateStarted: Bool { condition.withLock { started } }

    func prepare() throws { try base.prepare() }
    func load() throws -> [ClipboardSavedItem] { try base.load() }
    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {
        try base.save(item, payloadChanged: payloadChanged)
    }
    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload { try base.loadPayload(id: id) }
    func delete(id: UUID) throws { try base.delete(id: id) }
    func removeAll() throws { try base.removeAll() }

    func updateLastUsedAt(id: UUID, date: Date) throws {
        condition.lock()
        started = true
        condition.broadcast()
        let deadline = Date().addingTimeInterval(10)
        while !mayFinish, condition.wait(until: deadline) {}
        condition.unlock()
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func finishUsageUpdate() {
        condition.withLock {
            mayFinish = true
            condition.broadcast()
        }
    }
}

private final class InMemoryClipboardSavedLibraryPersistence:
    ClipboardSavedLibraryPersisting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var items: [UUID: ClipboardSavedItem] = [:]
    private var payloads: [UUID: ClipboardHistoryPayload] = [:]

    func prepare() throws {}

    func load() throws -> [ClipboardSavedItem] {
        lock.withLock { Array(items.values) }
    }

    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {
        let payload = try item.loadPayload()
        lock.withLock {
            items[item.id] = item
            payloads[item.id] = payload
        }
    }

    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload {
        try lock.withLock {
            guard let payload = payloads[id] else {
                throw ClipboardHistoryPayloadAccessError.unavailable
            }
            return payload
        }
    }

    func updateLastUsedAt(id: UUID, date: Date) throws {}

    func delete(id: UUID) throws {
        lock.withLock {
            items.removeValue(forKey: id)
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

private final class BlockingLoadClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var mayFinish = false

    var loadStarted: Bool {
        condition.withLock { started }
    }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] {
        condition.lock()
        started = true
        condition.broadcast()
        while !mayFinish {
            condition.wait()
        }
        condition.unlock()
        return []
    }

    func save(_ items: [ClipboardHistoryItem]) throws {}
    func reset() throws {}
    func removeAll() throws {}

    func allowLoadToFinish() {
        condition.withLock {
            mayFinish = true
            condition.broadcast()
        }
    }
}

private final class BlockingClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let condition = NSCondition()
    private var storedItems: [ClipboardHistoryItem]
    private var started = false
    private var mayFinish = false

    init(items: [ClipboardHistoryItem]) {
        storedItems = items
    }

    var saveStarted: Bool {
        condition.withLock { started }
    }

    var savedItems: [ClipboardHistoryItem] {
        condition.withLock { storedItems }
    }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] {
        condition.withLock { storedItems }
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        condition.lock()
        started = true
        condition.broadcast()
        while !mayFinish {
            condition.wait()
        }
        storedItems = items
        condition.unlock()
    }

    func reset() throws {
        condition.withLock { storedItems = [] }
    }

    func removeAll() throws {}

    func allowSaveToFinish() {
        condition.withLock {
            mayFinish = true
            condition.broadcast()
        }
    }
}

private final class FailingClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    let items: [ClipboardHistoryItem]
    private(set) var saveCount = 0
    private(set) var resetCount = 0

    init(items: [ClipboardHistoryItem]) {
        self.items = items
    }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] { items }

    func save(_ items: [ClipboardHistoryItem]) throws {
        saveCount += 1
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func reset() throws {
        resetCount += 1
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func removeAll() throws {}
}

private final class LoadFailingResettableClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var resets = 0

    var resetCount: Int { lock.withLock { resets } }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] {
        throw ClipboardHistoryStoreError.authenticationFailed
    }

    func save(_ items: [ClipboardHistoryItem]) throws {}

    func reset() throws {
        lock.withLock { resets += 1 }
    }

    func removeAll() throws {}
}

private final class RetryableKeychainClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private let items: [ClipboardHistoryItem]
    private var loadCount = 0
    private var resets = 0

    init(items: [ClipboardHistoryItem]) {
        self.items = items
    }

    var resetCount: Int { lock.withLock { resets } }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] {
        try lock.withLock {
            loadCount += 1
            if loadCount == 1 {
                throw ClipboardHistoryStoreError.keychain(errSecInteractionNotAllowed)
            }
            return items
        }
    }

    func save(_ items: [ClipboardHistoryItem]) throws {}

    func reset() throws {
        lock.withLock { resets += 1 }
    }

    func removeAll() throws {}
}

@MainActor
private final class PluginTestClipboardPasteboard: ClipboardPasteboardAccess {
    var changeCount = 0
    var typeNames: Set<String> = [ClipboardRepresentationType.plainText]
    var text: String?
    var payload: ClipboardHistoryPayload?
    private(set) var plainTextReadCount = 0
    private(set) var plainTextWriteCount = 0

    func readPlainText() -> String? {
        text
    }

    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult {
        plainTextReadCount += 1
        let payload = payload ?? text.map(ClipboardHistoryPayload.plainText)
        guard let payload else { return .empty }
        return payload.byteCount <= maximumByteCount ? .payload(payload) : .oversized
    }

    func writePlainText(_ text: String) -> Bool {
        plainTextWriteCount += 1
        return writePayload(.plainText(text))
    }

    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool {
        self.payload = payload
        text = payload.plainText
        typeNames = Set(payload.representations.map(\.typeIdentifier))
        changeCount += 1
        return true
    }

    func simulateCopy(_ text: String) {
        self.text = text
        payload = .plainText(text)
        typeNames = [ClipboardRepresentationType.plainText]
        changeCount += 1
    }

    func simulateCopy(_ payload: ClipboardHistoryPayload) {
        self.payload = payload
        text = payload.plainText
        typeNames = Set(payload.representations.map(\.typeIdentifier))
        changeCount += 1
    }
}

@MainActor
private final class FakeClipboardCopyCommandSender: ClipboardCopyCommandSending {
    var onSend: (() -> Void)?
    var shouldSend: ((pid_t) -> Bool)?
    var waitUntilCancelled = false
    private(set) var sendCount = 0
    private(set) var didArmBeforeSending = false
    private(set) var didFinish = false
    private(set) var targetProcessIdentifiers: [pid_t] = []

    func sendCopyCommand(
        to processIdentifier: pid_t,
        beforeSending: () -> Bool
    ) async -> Bool {
        defer { didFinish = true }
        sendCount += 1
        targetProcessIdentifiers.append(processIdentifier)
        guard shouldSend?(processIdentifier) ?? true else { return false }
        didArmBeforeSending = beforeSending()
        guard didArmBeforeSending else { return false }
        onSend?()
        while waitUntilCancelled, !Task.isCancelled {
            await Task.yield()
        }
        return !Task.isCancelled
    }
}

@MainActor
private final class FakeClipboardPasteCommandSender: ClipboardPasteCommandSending {
    var shouldSucceed = true
    private(set) var sendCount = 0
    private(set) var targetProcessIdentifiers: [pid_t] = []

    func sendPasteCommand(to processIdentifier: pid_t, beforeSending: () -> Bool) async -> Bool {
        guard beforeSending() else { return false }
        sendCount += 1
        targetProcessIdentifiers.append(processIdentifier)
        return shouldSucceed
    }
}

@MainActor
private final class DelayedReadClipboardPasteCommandSender: ClipboardPasteCommandSending {
    private let delay: Duration
    private let currentPasteboardText: () -> String?
    private(set) var pastedTexts: [String] = []

    init(delay: Duration, currentPasteboardText: @escaping () -> String?) {
        self.delay = delay
        self.currentPasteboardText = currentPasteboardText
    }

    func sendPasteCommand(to processIdentifier: pid_t, beforeSending: () -> Bool) async -> Bool {
        guard beforeSending() else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            pastedTexts.append(currentPasteboardText() ?? "")
        }
        return true
    }
}

@MainActor
private final class PreDispatchClipboardPasteCommandSender: ClipboardPasteCommandSending {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var sentCount = 0
    private(set) var finishedCount = 0
    var isWaiting: Bool { continuation != nil }
    func sendPasteCommand(to processIdentifier: pid_t, beforeSending: () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
        let maySend = !Task.isCancelled && beforeSending()
        finishedCount += 1
        guard maySend else { return false }
        sentCount += 1
        return true
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class BlockingClipboardPasteCommandSender: ClipboardPasteCommandSending {
    private let currentPasteboardText: () -> String?
    private var completions: [CheckedContinuation<Bool, Never>] = []
    private var pendingCompletionCredits = 0
    private(set) var sendCount = 0
    private(set) var pastedTexts: [String] = []

    init(currentPasteboardText: @escaping () -> String?) {
        self.currentPasteboardText = currentPasteboardText
    }

    func sendPasteCommand(to processIdentifier: pid_t, beforeSending: () -> Bool) async -> Bool {
        guard beforeSending() else { return false }
        sendCount += 1
        pastedTexts.append(currentPasteboardText() ?? "")
        return await withCheckedContinuation { continuation in
            if pendingCompletionCredits > 0 {
                pendingCompletionCredits -= 1
                continuation.resume(returning: true)
            } else {
                completions.append(continuation)
            }
        }
    }

    func completeNextPaste() {
        guard !completions.isEmpty else {
            pendingCompletionCredits += 1
            return
        }
        completions.removeFirst().resume(returning: true)
    }
}

@MainActor
private final class FakeClipboardPrivacyHUDPresenter: ClipboardPrivacyHUDPresenting {
    private(set) var events: [ClipboardCaptureSuppressionEvent] = []
    private(set) var successes: [String] = []
    private(set) var failures: [String] = []
    private(set) var dismissCount = 0

    func handleSuppressionEvent(_ event: ClipboardCaptureSuppressionEvent) {
        events.append(event)
    }

    func showSuccess(_ message: String) {
        successes.append(message)
    }

    func showFailure(_ message: String) {
        failures.append(message)
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private final class ClipboardShortcutConflictActionPlugin: MacToolsPlugin, PluginActionProviding {
    let metadata = PluginMetadata(
        id: "clipboard-shortcut-conflict-action-test",
        title: "Other Plugin",
        iconName: "keyboard",
        iconTint: .blue,
        order: 1,
        defaultDescription: "Tests action shortcut ownership"
    )
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: "run"),
            title: "Other Action",
            description: "Run another action",
            systemImage: "keyboard",
            externalInvocationPolicy: .allowed,
            capabilities: [.foregroundInteractive]
        )]
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        [ActionCatalogEntry(
            reference: ActionReference(key: ActionKey(providerID: metadata.id, actionID: "run")),
            title: "Other Action"
        )]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability { .available }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        ActionExecutionHandle { .succeeded(message: nil) }
    }
}
