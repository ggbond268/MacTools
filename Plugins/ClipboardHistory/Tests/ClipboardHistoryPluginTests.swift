import Foundation
import MacToolsPluginKit
import Security
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryPluginTests: XCTestCase {
    func testPublishesOnlyTheSixCanonicalPayloadFreeActions() {
        let plugin = makePlugin()
        let definitions = plugin.actionDefinitions

        XCTAssertEqual(Set(definitions.map(\.key.actionID)), ClipboardHistoryPlugin.ActionID.all)
        XCTAssertEqual(definitions.count, 6)
        XCTAssertTrue(definitions.allSatisfy(\.parameters.isEmpty))
        XCTAssertTrue(definitions.allSatisfy { $0.externalInvocationPolicy == .unavailable })
        XCTAssertEqual(
            definitions.first {
                $0.key.actionID == ClipboardHistoryPlugin.ActionID.clearUnpinnedHistory
            }?.risk,
            .confirmationRequired
        )
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

    func testSettingsFormPublishesGroupedActionAndPluginShortcutSections() throws {
        let plugin = makePlugin()
        let page = try XCTUnwrap(plugin.settingsPage)
        XCTAssertEqual(page.body.layout, .form)
        XCTAssertTrue(page.body.integratedShortcutGroupIDs.isEmpty)
        guard case let .form(sections) = page.body else {
            return XCTFail("Expected form settings")
        }
        XCTAssertEqual(sections.map(\.id), [
            "clipboard-essential-settings",
            "clipboard-retention-settings",
            "clipboard-exclusion-settings",
            "clipboard-data-settings",
        ])
        XCTAssertEqual(plugin.shortcutSettingsGroups.map(\.id), [
            "primary-shortcuts",
            "privacy-copy-shortcuts",
            "collection-shortcuts",
        ])
        XCTAssertNil(plugin.shortcutSettingsGroups[0].description)
        XCTAssertNil(plugin.shortcutSettingsGroups[1].description)
        XCTAssertNotNil(plugin.shortcutSettingsGroups[2].description)
        XCTAssertEqual(plugin.shortcutSettingsGroups[0].actionIDs, [ClipboardHistoryPlugin.ActionID.openHistory])
        XCTAssertEqual(
            plugin.shortcutSettingsGroups[0].shortcutDefinitionIDs,
            ["paste-clipboard-as-plain-text"]
        )
        XCTAssertEqual(
            Set(plugin.shortcutSettingsGroups.flatMap(\.actionIDs)),
            ClipboardHistoryPlugin.ActionID.all
        )
        XCTAssertEqual(plugin.shortcutSettingsGroups[2].actionIDs, [
            ClipboardHistoryPlugin.ActionID.toggleCollection,
            ClipboardHistoryPlugin.ActionID.pauseCollection,
            ClipboardHistoryPlugin.ActionID.resumeCollection,
            ClipboardHistoryPlugin.ActionID.clearUnpinnedHistory,
            ClipboardHistoryPlugin.ActionID.clearAllHistory,
        ])
        XCTAssertEqual(
            plugin.shortcutSettingsGroups.map(\.placementAfterSectionID),
            [
                "clipboard-essential-settings",
                "clipboard-essential-settings",
                "clipboard-data-settings",
            ]
        )
        XCTAssertNotNil(plugin.primaryPanel)
        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
    }

    func testPublishesFocusedClipboardOperationsAsPluginShortcutsInsteadOfCanonicalActions() {
        let plugin = makePlugin()
        let shortcuts = plugin.shortcutDefinitions

        XCTAssertEqual(
            Set(shortcuts.map(\.actionID)),
            ["private-copy", "ignore-next-copy", "paste-clipboard-as-plain-text"]
        )
        XCTAssertTrue(shortcuts.allSatisfy { $0.defaultBinding == nil })
        XCTAssertEqual(
            shortcuts.map(\.settingsControlTitle),
            ["立即私密复制", "忽略下一次复制", "粘贴当前剪贴板为纯文本"]
        )
        XCTAssertEqual(
            shortcuts.map(\.settingsControlSystemImage),
            ["keyboard", "cursorarrow.click", "textformat"]
        )
        XCTAssertEqual(
            Set(shortcuts.compactMap(\.settingsGroupTitle)),
            ["敏感内容复制快捷键", "纯文本粘贴快捷键"]
        )
        XCTAssertFalse(plugin.actionDefinitions.contains { $0.key.actionID == "private-copy" })
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
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

    func testLegacyUnlimitedItemCountMigratesToTenThousand() {
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
        storage.set(ClipboardHistorySettings.noItemCountLimit, forKey: "maximum-item-count")

        let settings = ClipboardHistorySettingsStore(storage: storage)

        XCTAssertEqual(
            settings.maximumItemCount,
            ClipboardHistorySettings.maximumSupportedItemCount
        )
        XCTAssertFalse(ClipboardHistorySettingsStore.allowedItemCounts.contains(
            ClipboardHistorySettings.noItemCountLimit
        ))
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
        for _ in 0..<100 where sender.sendCount == 0 {
            await Task.yield()
        }
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
        for _ in 0..<100 where !permissionWasRequested {
            await Task.yield()
        }

        XCTAssertTrue(permissionWasRequested)
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
        for _ in 0..<100 where sender.sendCount == 0 {
            await Task.yield()
        }

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
        for _ in 0..<100 where hud.failures.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(pasteboard.plainTextWriteCount, 0)
        XCTAssertEqual(hud.failures, ["剪贴板中没有可粘贴的文本"])
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
        for _ in 0..<100 where !persistence.loadStarted {
            await Task.yield()
        }

        plugin.handleShortcutAction(id: "ignore-next-copy")
        plugin.handleShortcutAction(id: "private-copy")
        for _ in 0..<100 where hud.failures.count < 2 {
            await Task.yield()
        }

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

        for _ in 0..<100 where !persistence.resetStarted {
            await Task.yield()
        }
        XCTAssertTrue(persistence.resetStarted)
        XCTAssertNil(result)
        XCTAssertTrue(plugin.controller.isClearingHistory)

        plugin.controller.processPasteboardChange()
        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(hud.events, [
            .armed(mode: .ignoreNextCopy, timeout: 60),
            .consumed(mode: .ignoreNextCopy),
        ])

        let didCopy = await plugin.controller.copyItem(id: originalItem.id)
        XCTAssertFalse(didCopy)
        plugin.controller.togglePin(id: originalItem.id)
        _ = await plugin.controller.deleteItem(id: originalItem.id)
        plugin.controller.settings.maximumItemCount = 100
        XCTAssertEqual(plugin.controller.items, [originalItem])

        plugin.handleShortcutAction(id: "private-copy")
        for _ in 0..<100 where hud.failures.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(sender.sendCount, 0)
        XCTAssertEqual(hud.failures, ["剪贴板历史尚未准备好"])

        persistence.allowResetToFinish()
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
        XCTAssertEqual(persistence.resetCount, 1)
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
        copyCommandSender: (any ClipboardCopyCommandSending)? = nil,
        pasteCommandSender: (any ClipboardPasteCommandSending)? = nil,
        privacyHUDPresenter: (any ClipboardPrivacyHUDPresenting)? = nil,
        imageTextRecognizer: (any ClipboardImageTextRecognizing)? = nil,
        accessibilityTrusted: @escaping () -> Bool = { true },
        accessibilityRequester: @escaping (Bool) -> Bool = { _ in true },
        frontmostProcessIdentifier: @escaping () -> pid_t? = { 1234 }
    ) -> ClipboardHistoryPlugin {
        let suiteName = "ClipboardHistoryPluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let storage = UserDefaultsPluginStorage(
            pluginID: ClipboardHistoryPlugin.pluginID,
            userDefaults: defaults
        )
        storage.set(false, forKey: "collection-paused")
        let context = PluginRuntimeContext(
            pluginID: ClipboardHistoryPlugin.pluginID,
            storage: storage
        )
        return ClipboardHistoryPlugin(
            context: context,
            pasteboard: pasteboard,
            persistence: persistence ?? EmptyClipboardHistoryPersistence(),
            copyCommandSender: copyCommandSender,
            pasteCommandSender: pasteCommandSender,
            privacyHUDPresenter: privacyHUDPresenter ?? FakeClipboardPrivacyHUDPresenter(),
            imageTextRecognizer: imageTextRecognizer,
            accessibilityTrusted: accessibilityTrusted,
            accessibilityRequester: accessibilityRequester,
            frontmostProcessIdentifier: frontmostProcessIdentifier
        )
    }

    private func waitUntilLoaded(_ controller: ClipboardHistoryController) async {
        for _ in 0..<100 where !controller.isLoaded {
            await Task.yield()
        }
        XCTAssertTrue(controller.isLoaded)
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

private struct EmptyClipboardHistoryPersistence: ClipboardHistoryPersisting {
    func prepare() throws {}
    func load() throws -> [ClipboardHistoryItem] { [] }
    func save(_ items: [ClipboardHistoryItem]) throws {}
    func reset() throws {}
    func removeAll() throws {}
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

    var resetStarted: Bool {
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
        condition.withLock { storedItems = items }
    }

    func reset() throws {
        condition.lock()
        started = true
        condition.broadcast()
        while !mayFinish {
            condition.wait()
        }
        storedItems = []
        condition.unlock()
    }

    func removeAll() throws {}

    func allowResetToFinish() {
        condition.withLock {
            mayFinish = true
            condition.broadcast()
        }
    }
}

private final class FailingClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    let items: [ClipboardHistoryItem]
    private(set) var resetCount = 0

    init(items: [ClipboardHistoryItem]) {
        self.items = items
    }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] { items }

    func save(_ items: [ClipboardHistoryItem]) throws {
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
    private(set) var sendCount = 0
    private(set) var didArmBeforeSending = false
    private(set) var targetProcessIdentifiers: [pid_t] = []

    func sendCopyCommand(
        to processIdentifier: pid_t,
        beforeSending: () -> Bool
    ) async -> Bool {
        sendCount += 1
        targetProcessIdentifiers.append(processIdentifier)
        guard shouldSend?(processIdentifier) ?? true else { return false }
        didArmBeforeSending = beforeSending()
        guard didArmBeforeSending else { return false }
        onSend?()
        return true
    }
}

@MainActor
private final class FakeClipboardPasteCommandSender: ClipboardPasteCommandSending {
    private(set) var sendCount = 0
    private(set) var targetProcessIdentifiers: [pid_t] = []

    func sendPasteCommand(to processIdentifier: pid_t) async -> Bool {
        sendCount += 1
        targetProcessIdentifiers.append(processIdentifier)
        return true
    }
}

@MainActor
private final class FakeClipboardPrivacyHUDPresenter: ClipboardPrivacyHUDPresenting {
    private(set) var events: [ClipboardCaptureSuppressionEvent] = []
    private(set) var failures: [String] = []
    private(set) var dismissCount = 0

    func handleSuppressionEvent(_ event: ClipboardCaptureSuppressionEvent) {
        events.append(event)
    }

    func showFailure(_ message: String) {
        failures.append(message)
    }

    func dismiss() {
        dismissCount += 1
    }
}
