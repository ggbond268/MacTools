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
        XCTAssertNotNil(plugin.controller.items.first(where: { $0.id == historyItem.id })?.lastUsedAt)
        XCTAssertEqual(plugin.controller.items.first?.capturedAt, historyItem.capturedAt)

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
        let historyUsageRecorded = await waitUntil {
            plugin.controller.items.first(where: { $0.id == historyItem.id })?.lastUsedAt != nil
        }
        XCTAssertTrue(historyUsageRecorded)
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
        let snippetUsageRecorded = await waitUntil {
            plugin.savedLibraryController.items.first(where: { $0.id == snippet.id })?.lastUsedAt != nil
        }
        XCTAssertTrue(snippetUsageRecorded)
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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
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
        XCTAssertNil(plugin.controller.items.first?.lastUsedAt)

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
            pluginOrderingStore: PluginOrderingStore(userDefaults: defaults),
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

}

private struct EmptyClipboardHistoryPersistence: ClipboardHistoryPersisting {
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { [] }
    func save(_ items: [ClipboardHistoryItem]) throws {}
    func reset() throws {}
    func removeAll() throws {}
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
