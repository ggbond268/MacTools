import AppKit
import Foundation
import MacToolsPluginKit
import Security
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryPluginTests: XCTestCase {
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

    func testSettingsFormPublishesGroupedActionAndPluginShortcutSections() throws {
        let plugin = makePlugin()
        let page = try XCTUnwrap(plugin.settingsPage)
        XCTAssertEqual(page.body.layout, .form)
        XCTAssertEqual(page.body.integratedShortcutGroupIDs, [
            "sequential-paste-shortcuts", "clipboard-window-shortcuts", "collection-shortcuts",
        ])
        guard case let .form(sections) = page.body else {
            return XCTFail("Expected form settings")
        }
        XCTAssertEqual(sections.map(\.id), [
            "clipboard-essential-settings",
            "clipboard-queue-settings",
            "clipboard-snippet-settings",
            "clipboard-advanced-settings",
            "clipboard-additional-shortcuts",
            "clipboard-retention-settings",
            "clipboard-exclusion-settings",
            "clipboard-data-settings",
        ])
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
            ["clipboard-window-shortcuts", "collection-shortcuts"]
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
                "clipboard-snippet-settings",
                "clipboard-additional-shortcuts",
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
                "panel-copy-combined",
                "panel-paste-combined",
            ]
        )
        XCTAssertEqual(shortcuts.filter { $0.scope == .whilePluginActive }.count, 11)
        let selectionShortcut = shortcuts.first { $0.id == ClipboardHistoryPlugin.ShortcutID.panelToggleSelection }
        XCTAssertEqual(selectionShortcut?.defaultBinding, ShortcutBinding(keyCode: 36, modifiers: [.command]))
        XCTAssertEqual(selectionShortcut?.defaultBinding,
                       ClipboardHistoryPlugin.defaultPanelShortcutBinding(ClipboardHistoryPlugin.ShortcutID.panelToggleSelection))
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

    func testUnlimitedItemCountRemainsExplicitlyUnlimited() {
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
            ClipboardHistorySettings.noItemCountLimit
        )
        XCTAssertTrue(ClipboardHistorySettingsStore.allowedItemCounts.contains(
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
        for _ in 0..<100 where !plugin.savedLibraryController.isLoaded {
            await Task.yield()
        }
        XCTAssertTrue(plugin.savedLibraryController.isLoaded)

        plugin.setKeywordExpansionEnabledForTesting(true)
        let attemptsBeforeKeyword = plugin.keywordExpansionStartAttemptCountForTesting
        XCTAssertFalse(plugin.hasConfiguredKeywordExpansionForTesting)

        let saved = await plugin.savedLibraryController.saveSnippet(ClipboardSnippetDraft(
            id: nil,
            title: "Build",
            content: "Build the app",
            tags: [],
            keyword: ";bb",
            isFavorite: false
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

    func testSuccessfulPasteFinishingDuringDeactivationDoesNotAdvanceOrPersistImplicitQueue() async {
        let pasteboard = PluginTestClipboardPasteboard()
        let sender = BlockingClipboardPasteCommandSender { pasteboard.text }
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

        for _ in 0..<100 where !persistence.saveStarted {
            await Task.yield()
        }
        XCTAssertTrue(persistence.saveStarted)
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
        _ = await plugin.controller.deleteItem(id: originalItem.id)
        plugin.controller.settings.maximumItemCount = 100
        XCTAssertEqual(plugin.controller.items, [originalItem])

        plugin.handleShortcutAction(id: "private-copy")
        for _ in 0..<100 where hud.failures.isEmpty {
            await Task.yield()
        }
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
        sequentialPasteStabilizationDelay: Duration = .milliseconds(120)
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
            savedPersistence: savedPersistence,
            copyCommandSender: copyCommandSender,
            pasteCommandSender: pasteCommandSender,
            privacyHUDPresenter: privacyHUDPresenter ?? FakeClipboardPrivacyHUDPresenter(),
            imageTextRecognizer: imageTextRecognizer,
            accessibilityTrusted: accessibilityTrusted,
            accessibilityRequester: accessibilityRequester,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            sequentialPasteStabilizationDelay: sequentialPasteStabilizationDelay
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
    var shouldSucceed = true
    private(set) var sendCount = 0
    private(set) var targetProcessIdentifiers: [pid_t] = []

    func sendPasteCommand(to processIdentifier: pid_t) async -> Bool {
        sendCount += 1
        targetProcessIdentifiers.append(processIdentifier)
        return shouldSucceed
    }
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

    func sendPasteCommand(to processIdentifier: pid_t) async -> Bool {
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
