import AppKit
import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryControllerTests: XCTestCase {
    func testBackupSuspensionBlocksUsageAndSettingsWritesUntilReload() async throws {
        let original = item(text: "original", pinned: false)
        let fixture = makeFixture(initialItems: [original])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.controller.suspendForBackup()
        fixture.controller.recordSuccessfulUse(id: original.id)
        fixture.settings.maximumItemCount = 1
        XCTAssertNil(fixture.controller.items.first?.lastUsedAt)
        let deleted = await fixture.controller.deleteItem(id: original.id)
        XCTAssertFalse(deleted)
        let restored = item(text: "restored", pinned: false)
        try fixture.persistence.save([restored])
        fixture.controller.resumeAfterBackup(restored: true)
        await waitUntilLoaded(fixture.controller)
        XCTAssertEqual(fixture.controller.items.map(\.id), [restored.id])
        fixture.controller.stop()
    }

    func testPendingLargeCaptureRespectsPauseResumeAndNewExclusions() async {
        for excludeSource in [false, true] {
            let fixture = makeFixture()
            fixture.source.application = ClipboardSourceApplication(bundleIdentifier: "test.producer", name: "Producer")
            fixture.controller.start()
            await waitUntilLoaded(fixture.controller)
            fixture.pasteboard.simulateCopy(String(repeating: "x", count: ClipboardHistoryController.maximumSynchronousCaptureByteCount + 1))
            fixture.controller.processPasteboardChange()
            if excludeSource {
                fixture.settings.addExcludedApplications([
                    ClipboardExcludedApplication(bundleIdentifier: "test.producer", name: "Producer"),
                ])
            } else {
                fixture.settings.setPaused(true)
                fixture.settings.setPaused(false)
            }
            await fixture.controller.waitForCaptureProcessingForTesting()
            // Let cancelled workers drain without allowing them to resurrect their capture.
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(fixture.controller.items.isEmpty)
            fixture.controller.stop()
        }
    }

    func testDeclaredAndRemoteSourcesCannotBypassForegroundExclusion() async {
        let fixture = makeFixture()
        defer { fixture.controller.stop() }
        fixture.source.application = .init(bundleIdentifier: "com.example.Private", name: "Private")
        fixture.settings.excludedApplications = [.init(bundleIdentifier: "com.example.Private", name: "Private")]
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        for (index, hint) in [ClipboardPasteboardSourceHint.universalClipboard, .application("com.example.Allowed")].enumerated() {
            fixture.pasteboard.captureSourceHint = hint
            fixture.pasteboard.simulateCopy("Private \(index)")
            fixture.controller.processPasteboardChange()
        }
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
    }

    func testAsynchronousPayloadReadDoesNotBlockAndAppliesCompletedCapture() async {
        let fixture = makeFixture()
        fixture.pasteboard.requiresAsynchronousPayloadRead = true
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy("large payload")

        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        let didStartRead = await waitUntil { fixture.pasteboard.asyncReadStarted }
        XCTAssertTrue(didStartRead)
        XCTAssertTrue(fixture.pasteboard.asyncReadStarted)
        XCTAssertTrue(fixture.controller.items.isEmpty)

        fixture.pasteboard.completeAsynchronousRead()
        let didCapturePayload = await waitUntil { !fixture.controller.items.isEmpty }
        XCTAssertTrue(didCapturePayload)
        XCTAssertEqual(fixture.controller.items.map(\.text), ["large payload"])
        fixture.controller.stop()
    }

    func testPauseResumeAndExcludedApplicationFiltering() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.settings.setPaused(true)
        fixture.pasteboard.simulateCopy("paused")
        fixture.controller.processPasteboardChange()
        XCTAssertTrue(fixture.controller.items.isEmpty)

        fixture.settings.setPaused(false)
        fixture.source.application = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        fixture.settings.addExcludedApplications([
            ClipboardExcludedApplication(
                bundleIdentifier: "com.example.Secret",
                name: "Secret"
            ),
        ])
        fixture.pasteboard.simulateCopy("excluded")
        fixture.controller.processPasteboardChange()
        XCTAssertTrue(fixture.controller.items.isEmpty)

        fixture.source.application = nil
        // One stable poll establishes that focus has left the excluded producer. The first
        // ambiguous pasteboard change after an app switch is intentionally suppressed.
        fixture.controller.processPasteboardChange()
        fixture.pasteboard.simulateCopy("allowed")
        fixture.controller.processPasteboardChange()
        XCTAssertEqual(fixture.controller.items.map(\.text), ["allowed"])
        fixture.controller.stop()
    }

    func testProtectedQueueAtCapacityBlocksCaptureBeforeReadingClipboardPayload() async {
        let queuedItems = (0..<100).map { index in
            item(text: "queued-\(index)", pinned: false)
        }
        let fixture = makeFixture(initialItems: queuedItems)
        fixture.settings.maximumItemCount = 100
        fixture.controller.updateSequentialPasteProtectedItemIDs(Set(queuedItems.map(\.id)))
        var rejection: ClipboardCaptureIgnoreReason?
        fixture.controller.onCaptureRejection = { reason, _ in rejection = reason }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        XCTAssertTrue(fixture.controller.isCaptureBlockedByProtectedItems)
        fixture.pasteboard.simulateCopy("not retained")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(rejection, .historyCapacityFull)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.controller.items.count, 100)
        fixture.controller.stop()
    }

    func testRecapturingOlderPayloadRefreshesExistingItemWithoutAddingDuplicate() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let firstCaptureDate = Date()
        let secondCaptureDate = firstCaptureDate.addingTimeInterval(1)
        let recaptureDate = secondCaptureDate.addingTimeInterval(1)

        fixture.pasteboard.simulateCopy("first")
        fixture.controller.processPasteboardChange(now: firstCaptureDate)
        let originalFirstID = try XCTUnwrap(fixture.controller.items.first?.id)

        fixture.pasteboard.simulateCopy("second")
        fixture.controller.processPasteboardChange(now: secondCaptureDate)
        fixture.pasteboard.simulateCopy("first")
        fixture.controller.processPasteboardChange(now: recaptureDate)

        XCTAssertEqual(fixture.controller.items.count, 2)
        XCTAssertEqual(fixture.controller.items.map(\.text), ["first", "second"])
        XCTAssertEqual(fixture.controller.items.first?.id, originalFirstID)
        XCTAssertEqual(fixture.controller.items.first?.capturedAt, recaptureDate)
        fixture.controller.stop()
    }

    func testCopyingHistoryItemPromotesItWithoutRecaptureOrChangingQueueOrder() async throws {
        let existing = ClipboardHistoryItem(
            id: UUID(),
            text: "reuse me",
            capturedAt: Date().addingTimeInterval(-60),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let newer = item(text: "newer capture", pinned: false)
        let fixture = makeFixture(initialItems: [newer, existing])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: fixture.controller.items)
        await model.waitForSearchForTesting()
        let subscription = fixture.controller.itemUpdates.sink { update in
            model.updateItems(update.items, changedIDs: update.changedIDs)
        }

        let didCopy = await fixture.controller.copyItem(id: existing.id)
        XCTAssertTrue(didCopy)
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.map(\.id), [newer.id, existing.id])
        XCTAssertEqual(fixture.controller.recentItemIDsForSequentialPaste, [newer.id, existing.id])
        XCTAssertEqual(fixture.pasteboard.text, existing.text)
        XCTAssertEqual(fixture.controller.items.last?.capturedAt, existing.capturedAt)
        XCTAssertNotNil(fixture.controller.items.last?.lastUsedAt)
        XCTAssertEqual(model.visibleItems.map(\.id), [existing.id, newer.id])
        XCTAssertFalse(model.isSearching)
        withExtendedLifetime(subscription) {}
        fixture.controller.stop()
    }

    func testRichPayloadIsCapturedAndReplayedWithoutFlattening() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("Formatted note".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data("{\\rtf1 Formatted note}".utf8)
                ),
            ]),
        ])
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy(payload)
        fixture.controller.processPasteboardChange()

        let item = try XCTUnwrap(fixture.controller.items.first)
        XCTAssertEqual(item.payload, payload)
        XCTAssertEqual(item.text, "Formatted note")
        XCTAssertEqual(item.kind, .richText)
        let didCopy = await fixture.controller.copyItem(id: item.id)
        XCTAssertTrue(didCopy)
        XCTAssertEqual(fixture.pasteboard.lastWrittenPayload, payload)
        fixture.controller.stop()
    }

    func testCombinedPlainTextFailsAtomicallyWhenAnyCompletePayloadIsUnavailable() async {
        let available = ClipboardHistoryItem(
            id: UUID(),
            text: "complete",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let unavailable = ClipboardHistoryItem(
            id: UUID(),
            text: String(repeating: "bounded metadata ", count: 400),
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        unavailable.configurePayloadLoader({
            throw ClipboardHistoryPayloadAccessError.unavailable
        }, discardCachedPayload: true)
        let fixture = makeFixture(initialItems: [available, unavailable])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let ids = [available.id, unavailable.id]
        let combinedText = await fixture.controller.combinedPlainText(ids: ids)
        let didCopy = await fixture.controller.copyCombinedItemsAsPlainText(ids: ids)
        XCTAssertNil(combinedText)
        XCTAssertFalse(didCopy)
        XCTAssertNil(fixture.pasteboard.lastWrittenPayload)
        fixture.controller.stop()
    }

    func testCopyRevalidatesQueueOwnershipAfterPayloadLoadBeforeWriting() async {
        let loader = BlockingCountingClipboardPayloadLoader(payload: .plainText("old queue payload"))
        let item = ClipboardHistoryItem(id: UUID(), text: "metadata", capturedAt: Date(),
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        item.configurePayloadLoader({ try loader.load() }, discardCachedPayload: true)
        let fixture = makeFixture(initialItems: [item])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        var queueIsCurrent = true
        let task = Task { await fixture.controller.copyItem(id: item.id, canWrite: { queueIsCurrent }) }
        let started = await waitUntil { loader.loadCount == 1 }
        XCTAssertTrue(started)
        queueIsCurrent = false
        fixture.pasteboard.text = "new external copy"
        loader.release.signal()
        let copied = await task.value
        XCTAssertFalse(copied)
        XCTAssertNil(fixture.pasteboard.lastWrittenPayload)
        XCTAssertEqual(fixture.pasteboard.text, "new external copy")
        XCTAssertNil(fixture.controller.items.first?.lastUsedAt)
        fixture.controller.stop()
    }

    func testMissingFileReferenceIsNotCopiedAsAStalePasteboardItem() async throws {
        let missingURL = URL(fileURLWithPath: "/private/tmp/clipboard-history-missing-\(UUID().uuidString)")
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(missingURL.absoluteString.utf8)
                ),
            ]),
        ])
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let fixture = makeFixture(initialItems: [item])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let didCopy = await fixture.controller.copyItem(id: item.id)
        XCTAssertFalse(didCopy)
        XCTAssertNil(fixture.pasteboard.lastWrittenPayload)
        fixture.controller.stop()
    }

    func testOversizedRichPayloadIsRejectedWithFeedback() async throws {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data(repeating: 0xA5, count: 1_024 * 1_024 + 1)
                ),
            ]),
        ])
        let fixture = makeFixture()
        fixture.settings.maximumItemByteCount = 1_024 * 1_024
        var rejection: (ClipboardCaptureIgnoreReason, Int)?
        fixture.controller.onCaptureRejection = { rejection = ($0, $1) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy(payload)
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(rejection?.0, .oversized)
        XCTAssertEqual(rejection?.1, 1_024 * 1_024)
        fixture.controller.stop()
    }

    func testIgnoreNextCopySuppressesCopyBurstWithoutReadingPrivatePayload() async throws {
        let fixture = makeFixture()
        var suppressionEvents: [ClipboardCaptureSuppressionEvent] = []
        fixture.controller.onCaptureSuppressionEvent = { suppressionEvents.append($0) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let sourceReadBaseline = fixture.source.readCount

        fixture.controller.ignoreNextCopy(expiringAfter: 60)
        XCTAssertTrue(fixture.controller.isIgnoringNextCopy)

        fixture.pasteboard.simulateCopy("private value")
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.isIgnoringNextCopy)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, sourceReadBaseline)
        XCTAssertEqual(suppressionEvents, [
            .armed(mode: .ignoreNextCopy, timeout: 60),
            .consumed(mode: .ignoreNextCopy),
        ])

        fixture.pasteboard.simulateCopy("private value, delayed representation")
        fixture.controller.processPasteboardChange()
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, sourceReadBaseline)

        fixture.controller.cancelNextCaptureSuppression()
        fixture.pasteboard.simulateCopy("ordinary value")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.map(\.text), ["ordinary value"])
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 1)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 1)
        XCTAssertEqual(fixture.source.readCount, sourceReadBaseline + 1)
        fixture.controller.stop()
    }

    func testClearAllPersistsEmptyHistory() async throws {
        let recent = item(text: "recent", pinned: false)
        let fixture = makeFixture(initialItems: [recent])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let clearedAll = await fixture.controller.clearAllHistory()
        XCTAssertTrue(clearedAll)
        XCTAssertTrue(fixture.persistence.savedItems.isEmpty)
        XCTAssertEqual(fixture.persistence.resetCount, 0)
        fixture.controller.stop()
    }

    func testSavingAndRecapturingPreservesOneStableCapturedItemIdentity() async throws {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy("shared value")
        fixture.controller.processPasteboardChange()
        let originalID = try XCTUnwrap(fixture.controller.items.first?.id)

        let didSaveOriginal = await fixture.controller.toggleSaved(id: originalID)
        XCTAssertTrue(didSaveOriginal)
        XCTAssertEqual(fixture.controller.historyItems.map(\.id), [originalID])
        XCTAssertEqual(fixture.controller.savedItems.map(\.id), [originalID])
        XCTAssertEqual(fixture.controller.items.count, 1)

        let didClearHistory = await fixture.controller.clearAllHistory()
        XCTAssertTrue(didClearHistory)
        XCTAssertTrue(fixture.controller.historyItems.isEmpty)
        XCTAssertEqual(fixture.controller.savedItems.map(\.id), [originalID])
        XCTAssertEqual(fixture.controller.items.count, 1)

        fixture.pasteboard.simulateCopy("shared value")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.count, 1)
        XCTAssertEqual(fixture.controller.historyItems.map(\.id), [originalID])
        XCTAssertEqual(fixture.controller.savedItems.map(\.id), [originalID])
        fixture.controller.stop()
    }

    func testSavedToggleFailureKeepsOriginalMetadataAndAllowsStorageRetry() async throws {
        for initiallySaved in [false, true] {
            var original = item(text: "retain on save failure", pinned: false)
            if initiallySaved {
                original.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Saved", savedAt: Date()))
            }
            let fixture = makeFixture()
            let persistence = SaveFailingClipboardHistoryPersistence(initialItems: [original])
            let controller = ClipboardHistoryController(
                settings: fixture.settings,
                pasteboard: fixture.pasteboard,
                sourceContext: fixture.source,
                persistence: persistence,
                monitoringInterval: 60,
                errorMessageProvider: { _ in "Save failed" }
            )
            defer { controller.stop() }
            controller.start()
            await waitUntilLoaded(controller)

            let didSave = await controller.toggleSaved(id: original.id)
            XCTAssertFalse(didSave)
            XCTAssertEqual(controller.items, [original])
            XCTAssertEqual(try persistence.load(), [original])
            XCTAssertEqual(controller.errorMessage, "Save failed")
            XCTAssertFalse(controller.isClearingHistory)

            // A failed metadata write must release the internal mutation barrier.
            controller.retryStorageAccess()
            await waitUntilLoaded(controller)
            XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(controller.items, [original])
        }
    }

    func testPermanentDeleteRemovesUnifiedHistoryAndSavedItem() async throws {
        let historyItem = item(text: "delete everywhere", pinned: false)
        let fixture = makeFixture(initialItems: [historyItem])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let didSave = await fixture.controller.toggleSaved(id: historyItem.id)
        XCTAssertTrue(didSave)
        XCTAssertEqual(fixture.controller.historyItems.map(\.id), [historyItem.id])
        XCTAssertEqual(fixture.controller.savedItems.map(\.id), [historyItem.id])

        let didDelete = await fixture.controller.deletePermanently(id: historyItem.id)
        XCTAssertTrue(didDelete)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertTrue(fixture.persistence.savedItems.isEmpty)
        fixture.controller.stop()
    }

    func testClearAllCancelsPendingAsynchronousCapture() async {
        let fixture = makeFixture()
        fixture.pasteboard.requiresAsynchronousPayloadRead = true
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy("pending capture")
        fixture.controller.processPasteboardChange()
        let didStartRead = await waitUntil { fixture.pasteboard.asyncReadStarted }
        XCTAssertTrue(didStartRead)

        let didClear = await fixture.controller.clearAllHistory()
        XCTAssertTrue(didClear)
        fixture.pasteboard.completeAsynchronousRead()
        let didFinishRead = await waitUntil { fixture.pasteboard.asyncReadCompleted }
        XCTAssertTrue(didFinishRead)

        XCTAssertTrue(fixture.controller.items.isEmpty)
        fixture.controller.stop()
    }

    func testUninstallCleanupInvalidatesPersistence() async throws {
        let fixture = makeFixture(initialItems: [item(text: "secret", pinned: false)])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.controller.removePersistentDataForUninstall()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertTrue(fixture.persistence.didRemoveAll)
    }

    func testDeleteFailureKeepsItemVisibleAndPersisted() async throws {
        let existing = item(text: "sensitive item", pinned: false)
        let fixture = makeFixture()
        let persistence = SaveFailingClipboardHistoryPersistence(initialItems: [existing])
        let controller = ClipboardHistoryController(
            settings: fixture.settings,
            pasteboard: fixture.pasteboard,
            sourceContext: fixture.source,
            persistence: persistence,
            monitoringInterval: 60,
            errorMessageProvider: { _ in "Localized storage failure" }
        )
        controller.start()
        await waitUntilLoaded(controller)

        let deleted = await controller.deleteItem(id: existing.id)

        XCTAssertFalse(deleted)
        XCTAssertEqual(controller.items, [existing])
        XCTAssertEqual(try persistence.load(), [existing])
        XCTAssertEqual(controller.errorMessage, "Localized storage failure")
        controller.stop()
    }

    func testInvalidPrivateStorageStopsCollectionBeforePayloadRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryPreparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let nonDirectory = directory.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: nonDirectory)
        let store = EncryptedClipboardHistoryStore(
            fileURL: nonDirectory.appendingPathComponent("history.mth"),
            keyStore: ControllerTestClipboardHistoryKeyStore()
        )

        await assertPreparationFailureStopsPayloadReads(persistence: store)
    }

    func testKeychainPreparationFailureStopsCollectionBeforePayloadRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryPreparationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedClipboardHistoryStore(
            fileURL: directory.appendingPathComponent("history.mth"),
            keyStore: FailingPreparationClipboardHistoryKeyStore()
        )

        await assertPreparationFailureStopsPayloadReads(persistence: store)
    }

    func testQueuedSavesCoalesceAndStopFlushesTheLatestRevision() async throws {
        let suiteName = "ClipboardHistoryControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ClipboardHistorySettingsStore(
            storage: UserDefaultsPluginStorage(pluginID: "clipboard-history-coalescing-tests", userDefaults: defaults)
        )
        settings.setPaused(false)
        settings.excludedApplications = []
        let pasteboard = FakeClipboardPasteboard()
        let persistence = BlockingFirstSaveClipboardHistoryPersistence()
        let controller = ClipboardHistoryController(
            settings: settings,
            pasteboard: pasteboard,
            sourceContext: FakeClipboardSourceContext(),
            persistence: persistence,
            monitoringInterval: 60
        )
        controller.start()
        await waitUntilLoaded(controller)

        pasteboard.simulateCopy("one")
        controller.processPasteboardChange()
        for _ in 0..<100 where !persistence.saveStarted {
            await Task.yield()
        }
        XCTAssertTrue(persistence.saveStarted)

        pasteboard.simulateCopy("two")
        controller.processPasteboardChange()
        pasteboard.simulateCopy("three")
        controller.processPasteboardChange()

        persistence.allowFirstSaveToFinish()
        controller.stop()

        XCTAssertEqual(persistence.savedSnapshots.count, 2)
        XCTAssertEqual(persistence.savedSnapshots.last?.map(\.text), ["three", "two", "one"])
    }

    private func makeFixture(
        initialItems: [ClipboardHistoryItem] = [],
        captureSuppressionSettlingInterval: TimeInterval = 0.75,
        imageIndexBatchPauseNanoseconds: UInt64 = 0,
        imageTextRecognizer: any ClipboardImageTextRecognizing = VisionClipboardImageTextRecognizer(),
        copyEventMonitor: (any ClipboardCopyEventMonitoring)? = nil
    ) -> (
        controller: ClipboardHistoryController,
        settings: ClipboardHistorySettingsStore,
        pasteboard: FakeClipboardPasteboard,
        source: FakeClipboardSourceContext,
        persistence: InMemoryClipboardHistoryPersistence
    ) {
        let suiteName = "ClipboardHistoryControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = ClipboardHistorySettingsStore(
            storage: UserDefaultsPluginStorage(pluginID: "clipboard-history-tests", userDefaults: defaults)
        )
        settings.setPaused(false)
        settings.excludedApplications = []
        let pasteboard = FakeClipboardPasteboard()
        let source = FakeClipboardSourceContext()
        let persistence = InMemoryClipboardHistoryPersistence(items: initialItems)
        let controller = ClipboardHistoryController(
            settings: settings,
            pasteboard: pasteboard,
            sourceContext: source,
            persistence: persistence,
            monitoringInterval: 60,
            captureSuppressionSettlingInterval: captureSuppressionSettlingInterval,
            imageIndexBatchPauseNanoseconds: imageIndexBatchPauseNanoseconds,
            imageTextRecognizer: imageTextRecognizer,
            copyEventMonitor: copyEventMonitor
        )
        settings.onChange = { [weak controller] in
            controller?.settingsDidChange()
        }
        return (controller, settings, pasteboard, source, persistence)
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

    private func assertPreparationFailureStopsPayloadReads(
        persistence: any ClipboardHistoryPersisting
    ) async {
        let suiteName = "ClipboardHistoryControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ClipboardHistorySettingsStore(
            storage: UserDefaultsPluginStorage(
                pluginID: "clipboard-history-preparation-tests",
                userDefaults: defaults
            )
        )
        settings.excludedApplications = []
        let pasteboard = FakeClipboardPasteboard()
        let source = FakeClipboardSourceContext()
        let controller = ClipboardHistoryController(
            settings: settings,
            pasteboard: pasteboard,
            sourceContext: source,
            persistence: persistence,
            monitoringInterval: 60
        )
        controller.start()
        await waitUntilLoaded(controller)
        let sourceReadBaseline = source.readCount

        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isCollectionOperational)
        pasteboard.simulateCopy("must not be read")
        controller.processPasteboardChange()
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertEqual(pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(source.readCount, sourceReadBaseline)
        controller.stop()
    }

    private func item(
        text: String,
        pinned: Bool,
        capturedAt: Date = Date()
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: capturedAt,
            sourceApplication: nil,
            isPinned: pinned,
            lastUsedAt: nil
        )
    }

}

private final class BlockingCountingClipboardPayloadLoader: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let payload: ClipboardHistoryPayload
    private var count = 0

    init(payload: ClipboardHistoryPayload) {
        self.payload = payload
    }

    var loadCount: Int {
        lock.withLock { count }
    }

    func load() throws -> ClipboardHistoryPayload {
        lock.withLock { count += 1 }
        started.signal()
        release.wait()
        return payload
    }
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboardAccess {
    var changeCount = 0
    var captureSourceHint: ClipboardPasteboardSourceHint?
    var requiresAsynchronousPayloadRead = false
    var simulatedTypeNames: Set<String> = [ClipboardRepresentationType.plainText]
    var text: String?
    var payload: ClipboardHistoryPayload?
    var onRead: (() -> Void)?
    private(set) var lastWrittenPayload: ClipboardHistoryPayload?
    private(set) var typeNamesReadCount = 0
    private(set) var plainTextReadCount = 0
    private(set) var asyncReadStarted = false
    private(set) var asyncReadStartCount = 0
    private(set) var asyncReadCompleted = false
    private var asyncReadContinuation: CheckedContinuation<ClipboardPasteboardReadResult, Never>?
    private var asyncReadMaximumByteCount = 0
    private var asyncReadExpectedChangeCount = 0

    var typeNames: Set<String> {
        typeNamesReadCount += 1
        return simulatedTypeNames
    }

    func readPlainText() -> String? {
        text
    }

    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult {
        plainTextReadCount += 1
        onRead?()
        guard let payload else { return .empty }
        return payload.byteCount <= maximumByteCount ? .payload(payload) : .oversized
    }

    func readSemanticTextAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        readPayload(
            maximumByteCount: maximumByteCount,
            expectedChangeCount: expectedChangeCount
        )
    }

    func readPayloadAsynchronously(
        maximumByteCount: Int,
        expectedChangeCount: Int
    ) async -> ClipboardPasteboardReadResult {
        asyncReadStarted = true
        asyncReadStartCount += 1
        asyncReadMaximumByteCount = maximumByteCount
        asyncReadExpectedChangeCount = expectedChangeCount
        let result = await withCheckedContinuation { continuation in
            asyncReadContinuation = continuation
        }
        asyncReadCompleted = true
        return result
    }

    func completeAsynchronousRead() {
        guard let continuation = asyncReadContinuation else { return }
        asyncReadContinuation = nil
        let result = readPayload(
            maximumByteCount: asyncReadMaximumByteCount,
            expectedChangeCount: asyncReadExpectedChangeCount
        )
        continuation.resume(returning: result)
    }

    func readCapture(maximumByteCount: Int, expectedChangeCount: Int) -> ClipboardPasteboardCaptureReadResult {
        .init(result: readPayload(maximumByteCount: maximumByteCount, expectedChangeCount: expectedChangeCount),
              sourceHint: captureSourceHint)
    }

    func readCaptureAsynchronously(maximumByteCount: Int, expectedChangeCount: Int) async -> ClipboardPasteboardCaptureReadResult {
        let hint = captureSourceHint
        return .init(result: await readPayloadAsynchronously(maximumByteCount: maximumByteCount, expectedChangeCount: expectedChangeCount),
                     sourceHint: hint)
    }

    func writePlainText(_ text: String) -> Bool {
        writePayload(.plainText(text))
    }

    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool {
        lastWrittenPayload = payload
        self.payload = payload
        text = payload.plainText
        changeCount += 1
        return true
    }

    func simulateCopy(_ text: String) {
        self.text = text
        payload = .plainText(text)
        changeCount += 1
    }

    func simulateCopy(_ payload: ClipboardHistoryPayload) {
        self.payload = payload
        text = payload.plainText
        changeCount += 1
    }
}

@MainActor
private final class FakeClipboardSourceContext: ClipboardSourceContextProviding {
    var application: ClipboardSourceApplication?
    var onRead: (() -> Void)?
    private(set) var readCount = 0
    private var recentlyActivatedApplications: [ClipboardSourceApplication] = []

    func frontmostApplication() -> ClipboardSourceApplication? {
        readCount += 1
        onRead?()
        return application
    }

    func recordActivation(_ application: ClipboardSourceApplication) {
        self.application = application
        recentlyActivatedApplications.append(application)
    }

    func takeRecentlyActivatedApplications() -> [ClipboardSourceApplication] {
        defer { recentlyActivatedApplications.removeAll() }
        return recentlyActivatedApplications
    }

    func discardRecentlyActivatedApplications() {
        recentlyActivatedApplications.removeAll()
    }
}

private final class InMemoryClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardHistoryItem]
    private var removed = false
    private var saves = 0
    private var resets = 0

    init(items: [ClipboardHistoryItem]) {
        self.items = items
    }

    func prepare() throws {}

    var savedItems: [ClipboardHistoryItem] {
        lock.withLock { items }
    }

    var didRemoveAll: Bool {
        lock.withLock { removed }
    }

    var saveCount: Int {
        lock.withLock { saves }
    }

    var resetCount: Int {
        lock.withLock { resets }
    }

    func load() throws -> [ClipboardHistoryItem] {
        lock.withLock { items }
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        lock.withLock {
            self.items = items
            saves += 1
        }
    }

    func reset() throws {
        lock.withLock {
            items = []
            resets += 1
        }
    }

    func removeAll() throws {
        lock.withLock {
            items = []
            removed = true
        }
    }
}

private struct SaveFailingClipboardHistoryPersistence: ClipboardHistoryPersisting {
    let initialItems: [ClipboardHistoryItem]

    init(initialItems: [ClipboardHistoryItem] = []) {
        self.initialItems = initialItems
    }

    func prepare() throws {}

    func load() throws -> [ClipboardHistoryItem] { initialItems }

    func save(_ items: [ClipboardHistoryItem]) throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func reset() throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func removeAll() throws {}
}

private final class BlockingFirstSaveClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var mayFinish = false
    private var snapshots: [[ClipboardHistoryItem]] = []
    private var resets = 0
    private let initialItems: [ClipboardHistoryItem]

    init(initialItems: [ClipboardHistoryItem] = []) {
        self.initialItems = initialItems
    }

    func prepare() throws {}

    var saveStarted: Bool { condition.withLock { started } }
    var savedSnapshots: [[ClipboardHistoryItem]] { condition.withLock { snapshots } }
    var resetCount: Int { condition.withLock { resets } }

    func load() throws -> [ClipboardHistoryItem] { initialItems }

    func save(_ items: [ClipboardHistoryItem]) throws {
        condition.lock()
        if !started {
            started = true
            condition.broadcast()
            while !mayFinish {
                condition.wait()
            }
        }
        snapshots.append(items)
        condition.unlock()
    }

    func reset() throws {
        condition.withLock {
            snapshots = []
            resets += 1
        }
    }

    func removeAll() throws {}

    func allowFirstSaveToFinish() {
        condition.withLock {
            mayFinish = true
            condition.broadcast()
        }
    }
}

private final class ControllerTestClipboardHistoryKeyStore: ClipboardHistoryKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func loadKey() throws -> Data? { lock.withLock { key } }
    func saveKey(_ data: Data) throws { lock.withLock { key = data } }
    func deleteKey() throws { lock.withLock { key = nil } }
}

private struct FailingPreparationClipboardHistoryKeyStore: ClipboardHistoryKeyStoring {
    func loadKey() throws -> Data? {
        throw ClipboardHistoryStoreError.keychain(-50)
    }

    func saveKey(_ data: Data) throws {
        throw ClipboardHistoryStoreError.keychain(-50)
    }

    func deleteKey() throws {}
}
