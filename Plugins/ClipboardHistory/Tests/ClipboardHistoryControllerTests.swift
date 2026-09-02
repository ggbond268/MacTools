import AppKit
import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryControllerTests: XCTestCase {
    func testCommittedItemUpdatesPatchPanelAndDeletionStillReconciles() async throws {
        let fixture = makeFixture(initialItems: [item(text: "First", pinned: false), item(text: "Second", pinned: false)])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: fixture.controller.items)
        await model.waitForSearchForTesting()
        let id = try XCTUnwrap(model.selectedItemID)
        var changedIDs: Set<UUID>?
        let subscription = fixture.controller.itemUpdates.sink { update in
            changedIDs = update.changedIDs
            model.updateItems(update.items, changedIDs: update.changedIDs)
        }
        let saved = await fixture.controller.toggleSaved(id: id)
        XCTAssertTrue(saved)
        XCTAssertEqual(changedIDs, [id])
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.visibleItems.first(where: { $0.id == id })?.isSaved, true)
        fixture.controller.recordSuccessfulUse(id: id)
        XCTAssertEqual(changedIDs, [id])
        XCTAssertFalse(model.isSearching)
        XCTAssertNotNil(model.visibleItems.first(where: { $0.id == id })?.lastUsedAt)
        let deleted = await fixture.controller.deleteItem(id: id)
        XCTAssertTrue(deleted)
        await model.waitForSearchForTesting()
        XCTAssertFalse(model.visibleItems.contains { $0.id == id })
        XCTAssertEqual(model.scopedItemCount, 1)
        withExtendedLifetime(subscription) {}
    }

    func testAbandonedPayloadLoadCannotPublishAfterCancellation() async {
        let loader = BlockingCountingClipboardPayloadLoader(payload: .plainText("secret"))
        let reference = ClipboardHistoryPayloadReference(loader: { try loader.load() })
        let load = Task { try await reference.loadAsync() }
        let started = await waitUntil { loader.loadCount == 1 }
        XCTAssertTrue(started)
        load.cancel()
        _ = try? await load.value
        reference.discardCachedPayloadIfReloadable()
        XCTAssertNil(reference.cached)
        loader.release.signal()
        let finished = await waitUntil { !reference.isLoadingForTesting }
        XCTAssertTrue(finished)
        XCTAssertNil(reference.cached)
        XCTAssertEqual(loader.loadCount, 1)
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

    func testAbandonedMixedSyncAndAsyncPayloadConsumersDoNotRetainResult() async {
        let loader = BlockingCountingClipboardPayloadLoader(payload: .plainText("secret"))
        let reference = ClipboardHistoryPayloadReference(loader: { try loader.load() })
        let first = Task { try await reference.loadAsync() }
        let started = await waitUntil { loader.loadCount == 1 }
        XCTAssertTrue(started)
        let second = Task.detached { try reference.load() }
        let waiting = await waitUntil { reference.waitingLoaderCountForTesting == 2 }
        XCTAssertTrue(waiting)
        first.cancel()
        _ = try? await first.value
        second.cancel()
        _ = try? await second.value
        loader.release.signal()
        let finished = await waitUntil { !reference.isLoadingForTesting }
        XCTAssertTrue(finished)
        XCTAssertNil(reference.cached)
    }

    func testCancelledSynchronousPayloadLoaderDoesNotRetainResult() async {
        let loader = BlockingCountingClipboardPayloadLoader(payload: .plainText("secret"))
        let reference = ClipboardHistoryPayloadReference(loader: { try loader.load() })
        let task = Task.detached { try reference.load() }
        let started = await waitUntil { loader.loadCount == 1 }
        XCTAssertTrue(started)
        task.cancel()
        loader.release.signal()
        _ = try? await task.value
        XCTAssertNil(reference.cached)
    }

    func testGeneralPasteboardRoundTripsGroupedRichRepresentations() throws {
        let namedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryControllerTests.\(UUID().uuidString)")
        )
        let pasteboard = GeneralClipboardPasteboard(pasteboard: namedPasteboard)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("Formatted".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data("{\\rtf1 Formatted}".utf8)
                ),
            ]),
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data("file:///tmp/example.mov".utf8)
                ),
            ]),
        ])

        XCTAssertTrue(pasteboard.writePayload(payload))
        XCTAssertEqual(
            pasteboard.readPayload(maximumByteCount: 1_024 * 1_024),
            .payload(payload)
        )
        namedPasteboard.clearContents()
    }

    func testGeneralPasteboardWritesFileReferencesAsNativeFileURLs() throws {
        let namedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryFilePasteTests.\(UUID().uuidString)")
        )
        let pasteboard = GeneralClipboardPasteboard(pasteboard: namedPasteboard)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryFilePasteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            namedPasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURLs = [
            directory.appendingPathComponent("first.txt"),
            directory.appendingPathComponent("second.txt"),
        ]
        for fileURL in fileURLs {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
        let payload = ClipboardHistoryPayload(pasteboardItems: fileURLs.map { fileURL in
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(fileURL.absoluteString.utf8)
                ),
            ])
        })

        XCTAssertTrue(pasteboard.writePayload(payload))
        let nativeURLs = try XCTUnwrap(namedPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])
        XCTAssertEqual(nativeURLs, fileURLs)
    }

    func testGeneralPasteboardCapturesMixedFileItemsAsPathReferencesOnly() throws {
        let namedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryMixedFilePasteTests.\(UUID().uuidString)")
        )
        let pasteboard = GeneralClipboardPasteboard(pasteboard: namedPasteboard)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-document.pdf")
        let sourceItem = NSPasteboardItem()
        sourceItem.setString(fileURL.absoluteString, forType: .fileURL)
        sourceItem.setData(Data(repeating: 0x41, count: 1_024), forType: .pdf)
        sourceItem.setData(Data(repeating: 0x42, count: 1_024), forType: .png)
        namedPasteboard.clearContents()
        XCTAssertTrue(namedPasteboard.writeObjects([sourceItem]))
        addTeardownBlock { namedPasteboard.clearContents() }

        guard case let .payload(payload) = pasteboard.readPayload(maximumByteCount: 1_024 * 1_024)
        else {
            return XCTFail("Expected a file-reference payload")
        }
        XCTAssertEqual(payload.pasteboardItems.count, 1)
        XCTAssertEqual(
            payload.pasteboardItems[0].representations.map(\.typeIdentifier),
            [ClipboardRepresentationType.fileURL]
        )
        XCTAssertEqual(payload.fileURLs, [fileURL])
        XCTAssertEqual(payload.byteCount, Data(fileURL.absoluteString.utf8).count)
    }

    func testGeneralPasteboardRejectsExcessiveItemAndRepresentationCounts() {
        let excessiveItems = (0...GeneralClipboardPasteboard.maximumPasteboardItemCount).map { index in
            let item = NSPasteboardItem()
            item.setString("item-\(index)", forType: .string)
            return item
        }
        XCTAssertFalse(GeneralClipboardPasteboard.captureComplexityIsWithinLimits(excessiveItems))

        let excessiveRepresentations = NSPasteboardItem()
        for index in 0...GeneralClipboardPasteboard.maximumRepresentationCountPerItem {
            excessiveRepresentations.setString(
                "value",
                forType: NSPasteboard.PasteboardType("com.example.clipboard.\(index)")
            )
        }
        XCTAssertFalse(GeneralClipboardPasteboard.captureComplexityIsWithinLimits([
            excessiveRepresentations,
        ]))
    }

    func testClipboardOwnershipChangingDuringReadKeepsObservedSourceSnapshot() async throws {
        let fixture = makeFixture()
        fixture.source.application = ClipboardSourceApplication(
            bundleIdentifier: "com.example.SourceA",
            name: "Source A"
        )
        fixture.pasteboard.onRead = {
            fixture.source.application = ClipboardSourceApplication(
                bundleIdentifier: "com.example.SourceB",
                name: "Source B"
            )
        }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy("captured")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.count, 1)
        XCTAssertEqual(
            fixture.controller.items.first?.sourceApplication?.bundleIdentifier,
            "com.example.SourceA"
        )
        fixture.controller.stop()
    }

    func testPasteboardChangeAfterPreflightDiscardsReplacementPayload() async {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy("ordinary")
        fixture.source.onRead = {
            fixture.pasteboard.simulatedTypeNames = ["org.nspasteboard.ConcealedType"]
            fixture.pasteboard.simulateCopy("private replacement")
        }

        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        fixture.controller.stop()
    }

    func testPasteboardChangeDuringPayloadReadDiscardsCapturedRevision() async {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy("first revision")
        fixture.pasteboard.onRead = {
            fixture.pasteboard.simulateCopy("second revision")
        }

        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 1)
        fixture.controller.stop()
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

    func testCopyCommittedAfterLeavingExcludedApplicationIsNotRead() async throws {
        let fixture = makeFixture()
        fixture.settings.addExcludedApplications([
            ClipboardExcludedApplication(
                bundleIdentifier: "com.example.Secret",
                name: "Secret"
            ),
        ])
        fixture.source.application = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.controller.processPasteboardChange()
        fixture.source.application = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        fixture.pasteboard.simulateCopy("delayed secret")
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)

        fixture.controller.processPasteboardChange()
        fixture.pasteboard.simulateCopy("ordinary value")
        fixture.controller.processPasteboardChange()
        XCTAssertEqual(fixture.controller.items.map(\.text), ["ordinary value"])
        fixture.controller.stop()
    }

    func testExcludedApplicationAlreadyFrontmostAtStartupIsSeededBeforeClipboardBaseline() async {
        let fixture = makeFixture()
        let secret = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        fixture.settings.addExcludedApplications([
            ClipboardExcludedApplication(
                bundleIdentifier: secret.bundleIdentifier,
                name: secret.name
            ),
        ])
        fixture.source.application = secret
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.source.application = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        fixture.pasteboard.simulateCopy("startup secret")
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        fixture.controller.stop()
    }

    func testExcludedApplicationRoundTripBetweenPollsIsNotRead() async throws {
        let fixture = makeFixture()
        let editor = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        let secret = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        fixture.settings.addExcludedApplications([
            ClipboardExcludedApplication(
                bundleIdentifier: secret.bundleIdentifier,
                name: secret.name
            ),
        ])
        fixture.source.application = editor
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.controller.processPasteboardChange()

        fixture.source.recordActivation(secret)
        fixture.source.recordActivation(editor)
        fixture.pasteboard.simulateCopy("rapid secret")
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        fixture.controller.stop()
    }

    func testExcludedActivationWithoutCopyDoesNotDropLaterAllowedCopy() async throws {
        let fixture = makeFixture()
        let editor = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        let secret = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        fixture.settings.addExcludedApplications([
            ClipboardExcludedApplication(
                bundleIdentifier: secret.bundleIdentifier,
                name: secret.name
            ),
        ])
        fixture.source.application = editor
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let activationTime = Date()
        fixture.controller.processPasteboardChange(now: activationTime)

        fixture.source.recordActivation(secret)
        fixture.source.recordActivation(editor)
        fixture.controller.processPasteboardChange(now: activationTime.addingTimeInterval(0.1))

        fixture.pasteboard.simulateCopy("ordinary editor copy")
        fixture.controller.processPasteboardChange(
            now: activationTime.addingTimeInterval(
                ClipboardHistoryController.sourceApplicationAttributionGraceInterval + 0.2
            )
        )

        XCTAssertEqual(fixture.controller.items.map(\.text), ["ordinary editor copy"])
        fixture.controller.stop()
    }

    func testDelayedExcludedCopyAfterStablePollIsNotRead() async throws {
        let fixture = makeFixture()
        let editor = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )
        let secret = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        fixture.settings.addExcludedApplications([
            ClipboardExcludedApplication(
                bundleIdentifier: secret.bundleIdentifier,
                name: secret.name
            ),
        ])
        fixture.source.application = editor
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let activationTime = Date()
        fixture.controller.processPasteboardChange(now: activationTime)

        fixture.source.recordActivation(secret)
        fixture.source.recordActivation(editor)
        fixture.controller.processPasteboardChange(now: activationTime.addingTimeInterval(0.1))

        fixture.pasteboard.simulateCopy("delayed secret")
        fixture.controller.processPasteboardChange(now: activationTime.addingTimeInterval(0.5))

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
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

    func testRejectedCaptureDoesNotEvictHistoryWhenProtectedQueueUsesCapacity() async {
        let queued = logicalItem(
            text: "queued",
            payloadByteCount: 30 * 1_024 * 1_024,
            pinned: false
        )
        let existing = logicalItem(
            text: "existing",
            payloadByteCount: 1 * 1_024 * 1_024,
            pinned: false
        )
        let fixture = makeFixture(initialItems: [queued, existing])
        fixture.settings.maximumItemByteCount = 50 * 1_024 * 1_024
        fixture.settings.maximumTotalPayloadByteCount = 64 * 1_024 * 1_024
        fixture.controller.updateSequentialPasteProtectedItemIDs([queued.id])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let originalIDs = fixture.controller.items.map(\.id)
        let baselineSaveCount = fixture.persistence.saveCount
        var rejection: ClipboardCaptureIgnoreReason?
        fixture.controller.onCaptureRejection = { reason, _ in rejection = reason }

        fixture.pasteboard.simulateCopy(imagePayload(
            data: Data(repeating: 0x01, count: 40 * 1_024 * 1_024)
        ))
        fixture.controller.processPasteboardChange()
        await fixture.controller.waitForCaptureProcessingForTesting()

        XCTAssertEqual(rejection, .historyCapacityFull)
        XCTAssertEqual(fixture.controller.items.map(\.id), originalIDs)
        XCTAssertEqual(fixture.persistence.saveCount, baselineSaveCount)
        fixture.controller.stop()
    }

    func testCapturedImageIsIndexedForSearchAndPersisted() async throws {
        let recognizer = FakeClipboardImageTextRecognizer(text: "Invoice total 42 dollars")
        let fixture = makeFixture(imageTextRecognizer: recognizer)
        var indexedChangedIDs: Set<UUID>?
        let subscription = fixture.controller.itemUpdates.sink { update in
            if update.items.contains(where: { $0.hasCompletedImageTextIndexing }) {
                indexedChangedIDs = update.changedIDs
            }
        }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data([0x01, 0x02, 0x03])
                ),
            ]),
        ])

        fixture.pasteboard.simulateCopy(payload)
        fixture.controller.processPasteboardChange()
        for _ in 0..<5_000 where fixture.controller.items.first?.hasCompletedImageTextIndexing != true {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(fixture.controller.matchingItems(query: "inv tot").count, 1)
        XCTAssertEqual(fixture.controller.items.first?.imageSearchText, "Invoice total 42 dollars")
        XCTAssertEqual(indexedChangedIDs, Set(fixture.controller.items.prefix(1).map(\.id)))
        let rewriteResult = await fixture.controller.rewriteCurrentClipboardAsPlainText()
        XCTAssertEqual(rewriteResult, .succeeded)
        XCTAssertEqual(
            fixture.pasteboard.lastWrittenPayload,
            .plainText("Invoice total 42 dollars")
        )
        fixture.controller.stop()
        XCTAssertEqual(fixture.persistence.savedItems.first?.imageSearchText, "Invoice total 42 dollars")
        withExtendedLifetime(subscription) {}
    }

    func testImageIndexingContinuesAfterPayloadLoadFailureAndBatchesPersistence() async {
        let failing = lazyImageItem(payloadLoader: {
            throw ClipboardHistoryPayloadAccessError.unavailable
        })
        let successful = (0..<3).map { byte in
            let payload = imagePayload(data: Data([UInt8(byte)]))
            return lazyImageItem(payloadLoader: { payload })
        }
        let fixture = makeFixture(
            initialItems: [failing] + successful,
            imageTextRecognizer: FakeClipboardImageTextRecognizer(text: "recognized")
        )
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        for _ in 0..<5_000 where fixture.controller.items.filter(\.hasCompletedImageTextIndexing).count < 3 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertFalse(fixture.controller.items.first(where: { $0.id == failing.id })!.hasCompletedImageTextIndexing)
        XCTAssertEqual(fixture.controller.items.filter(\.hasCompletedImageTextIndexing).count, 3)
        XCTAssertTrue(successful.allSatisfy { item in
            fixture.controller.items.first(where: { $0.id == item.id })?.payload == nil
        })
        fixture.controller.stop()
        XCTAssertLessThanOrEqual(fixture.persistence.saveCount, 2)
        XCTAssertEqual(fixture.persistence.savedItems.filter(\.hasCompletedImageTextIndexing).count, 3)
    }

    func testStartupImageIndexingUsesBoundedBudgetAndStillIndexesOnDemand() async {
        let imageCount = ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount + 5
        let images = (0..<imageCount).map { byte in
            let payload = imagePayload(data: Data([UInt8(byte % 255)]))
            return lazyImageItem(payloadLoader: { payload })
        }
        let fixture = makeFixture(
            initialItems: images,
            imageIndexBatchPauseNanoseconds: 0,
            imageTextRecognizer: FakeClipboardImageTextRecognizer(text: "recognized")
        )
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let didUseBudget = await waitUntil(timeout: .seconds(5)) {
            fixture.controller.items.filter(\.hasCompletedImageTextIndexing).count
                == ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount
        }

        XCTAssertTrue(didUseBudget)
        XCTAssertEqual(
            fixture.controller.items.filter(\.hasCompletedImageTextIndexing).count,
            ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount
        )

        let onDemandItem = fixture.controller.items[
            ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount
        ]
        fixture.controller.requestImageTextIndexing(id: onDemandItem.id)
        let didIndexOnDemand = await waitUntil {
            fixture.controller.items.first(where: { $0.id == onDemandItem.id })?
                .hasCompletedImageTextIndexing == true
        }
        XCTAssertTrue(didIndexOnDemand)
        fixture.controller.stop()
    }

    func testStartupImageIndexingQueuesOnlyOneBoundedBatchAtATime() async throws {
        let recognizer = BlockingCountingClipboardImageTextRecognizer()
        let images = (0..<105).map { byte in
            let payload = imagePayload(data: Data([UInt8(byte % 255)]))
            return lazyImageItem(payloadLoader: { payload })
        }
        let fixture = makeFixture(
            initialItems: images,
            imageIndexBatchPauseNanoseconds: 60_000_000_000,
            imageTextRecognizer: recognizer
        )
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        for _ in 0..<5_000 {
            if await recognizer.callCount > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let recognitionCallCount = await recognizer.callCount
        XCTAssertEqual(recognitionCallCount, 1)
        XCTAssertEqual(
            fixture.controller.pendingImageIndexItemCountForTesting,
            ClipboardHistoryController.imageTextIndexBatchSize - 1
        )

        fixture.controller.stop()
        await recognizer.releaseAll()
    }

    func testConcurrentLazyPayloadLoadsAreSingleFlightAndCancellationDoesNotReload() async throws {
        let loader = BlockingCountingClipboardPayloadLoader(payload: .plainText("secret"))
        let item = lazyImageItem(payloadLoader: { try loader.load() })
        let first = Task { try await item.loadPayloadAsync() }
        let loaderStarted = await waitUntil {
            loader.loadCount == 1
        }
        XCTAssertTrue(loaderStarted)
        let cancelledWaiter = Task { try await item.loadPayloadAsync() }
        let waiterEnteredSingleFlightPath = await waitUntil {
            item.waitingPayloadLoaderCountForTesting == 2
        }
        XCTAssertTrue(waiterEnteredSingleFlightPath)
        XCTAssertEqual(loader.loadCount, 1)
        cancelledWaiter.cancel()

        let cancellationFinished = expectation(description: "Cancelled payload waiter finished")
        Task {
            defer { cancellationFinished.fulfill() }
            do {
                _ = try await cancelledWaiter.value
                XCTFail("A cancelled waiter must not receive or reload the payload")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Expected cancellation, received \(error)")
            }
        }
        await fulfillment(of: [cancellationFinished], timeout: 2)

        loader.release.signal()

        let firstPayload = try await first.value
        XCTAssertEqual(firstPayload, .plainText("secret"))
        XCTAssertEqual(loader.loadCount, 1)
    }

    func testCancelledPayloadPreparationDiscardsReloadablePayloadCache() async {
        let loaders = (0..<2).map { index in
            BlockingCountingClipboardPayloadLoader(payload: .plainText("secret-\(index)"))
        }
        let items = loaders.enumerated().map { index, loader in
            let item = item(text: "secret-\(index)", pinned: false)
            item.configurePayloadLoader({ try loader.load() }, discardCachedPayload: true)
            return item
        }
        let fixture = makeFixture(initialItems: items)
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        for (item, loader) in zip(items, loaders) {
            let preparation = Task { @MainActor in
                await fixture.controller.preparePayloadForUse(id: item.id)
            }
            let didStart = await waitUntil { loader.loadCount == 1 }
            XCTAssertTrue(didStart)

            preparation.cancel()
            loader.release.signal()

            let didPrepare = await preparation.value
            XCTAssertFalse(didPrepare)
            XCTAssertNil(item.payload)
        }

        XCTAssertTrue(items.allSatisfy { $0.payload == nil })
        fixture.controller.stop()
    }

    func testDeletingAnItemDoesNotDuplicateContinuouslyQueuedImageIndexing() async throws {
        let recognizer = BlockingCountingClipboardImageTextRecognizer()
        let imageCount = 101
        let images = (0..<imageCount).map { byte in
            let payload = imagePayload(data: Data([UInt8(byte % 255)]))
            return lazyImageItem(payloadLoader: { payload })
        }
        let unrelatedText = item(text: "delete me", pinned: false)
        let fixture = makeFixture(
            initialItems: [unrelatedText] + images,
            imageTextRecognizer: recognizer
        )
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        for _ in 0..<5_000 {
            if await recognizer.callCount > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let deleted = await fixture.controller.deleteItem(id: unrelatedText.id)
        XCTAssertTrue(deleted)
        await recognizer.releaseAll()
        let didUseBudget = await waitUntil(timeout: .seconds(5)) {
            fixture.controller.items.filter(\.hasCompletedImageTextIndexing).count
                == ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount
        }
        XCTAssertTrue(didUseBudget)

        let recognitionCallCount = await recognizer.callCount
        XCTAssertEqual(
            recognitionCallCount,
            ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount
        )
        XCTAssertEqual(
            fixture.controller.items.filter { !$0.hasCompletedImageTextIndexing }.count,
            imageCount - ClipboardHistoryController.maximumBackgroundImageTextIndexItemCount
        )
        fixture.controller.stop()
    }

    func testFirstSuppressedWriteNearArmDeadlineGetsACompleteSettlingInterval() async throws {
        let fixture = makeFixture(captureSuppressionSettlingInterval: 0.2)
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let sourceReadBaseline = fixture.source.readCount

        XCTAssertTrue(fixture.controller.ignoreNextCopy(expiringAfter: 0.1))
        try await Task.sleep(nanoseconds: 80_000_000)
        fixture.pasteboard.simulateCopy("private first write")
        fixture.controller.processPasteboardChange()

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(fixture.controller.isIgnoringNextCopy)
        fixture.pasteboard.simulateCopy("private delayed representation")
        fixture.controller.processPasteboardChange()

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(fixture.controller.isIgnoringNextCopy)
        fixture.pasteboard.simulateCopy("private final delayed representation")
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, sourceReadBaseline)

        try await Task.sleep(nanoseconds: 220_000_000)
        for _ in 0..<100 where fixture.controller.isIgnoringNextCopy {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(fixture.controller.isIgnoringNextCopy)
        fixture.controller.stop()
    }

    func testLargeCapturesArePreparedOffMainActorAndAppliedInCaptureOrder() async {
        let fixture = makeFixture()
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let first = String(
            repeating: "a",
            count: ClipboardHistoryController.maximumSynchronousCaptureByteCount + 1
        )
        let second = String(
            repeating: "b",
            count: ClipboardHistoryController.maximumSynchronousCaptureByteCount + 1
        )

        fixture.pasteboard.simulateCopy(first)
        fixture.controller.processPasteboardChange()
        fixture.pasteboard.simulateCopy(second)
        fixture.controller.processPasteboardChange()

        // Applying the prepared item requires a later MainActor turn, so capture preprocessing did
        // not synchronously monopolize this turn.
        XCTAssertTrue(fixture.controller.items.isEmpty)
        await fixture.controller.waitForCaptureProcessingForTesting()
        XCTAssertEqual(
            fixture.controller.items.map(\.text),
            [
                String(second.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount)),
                String(first.prefix(ClipboardHistoryItem.maximumSearchableCharacterCount)),
            ]
        )
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

    func testPlainTextRewriteDoesNotUseOCRAfterThePasteboardChanges() async {
        let recognizer = FakeClipboardImageTextRecognizer(text: "Stale recognized text")
        let fixture = makeFixture(imageTextRecognizer: recognizer)
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy(imagePayload(data: Data([0x01])))
        fixture.controller.processPasteboardChange()
        for _ in 0..<5_000 where fixture.controller.items.first?.hasCompletedImageTextIndexing != true {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }

        fixture.pasteboard.simulateCopy(imagePayload(data: Data([0x02])))

        let rewriteResult = await fixture.controller.rewriteCurrentClipboardAsPlainText()
        XCTAssertEqual(rewriteResult, .unavailable)
        XCTAssertNil(fixture.pasteboard.lastWrittenPayload)
        fixture.controller.stop()
    }

    func testCopyEventAssistCapturesBeforeSlowPollingFallback() async {
        let monitor = FakeClipboardCopyEventMonitor()
        let fixture = makeFixture(copyEventMonitor: monitor)
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        monitor.fire()
        fixture.pasteboard.simulateCopy("event-assisted")

        let captured = await waitUntil { fixture.controller.items.first?.text == "event-assisted" }
        XCTAssertTrue(captured)
        XCTAssertEqual(monitor.startCount, 1)
        fixture.controller.stop()
        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testPlainTextRewriteReportsPendingImageRecognition() async {
        let fixture = makeFixture(imageTextRecognizer: SlowClipboardImageTextRecognizer())
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy(imagePayload(data: Data([0x01])))
        fixture.controller.processPasteboardChange()

        let rewriteResult = await fixture.controller.rewriteCurrentClipboardAsPlainText()
        XCTAssertEqual(rewriteResult, .imageTextRecognitionPending)
        fixture.controller.stop()
    }

    func testPlainTextRewritePrefersVisibleRichTextOverProducerPlainText() async {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("\"CSV wrapped\"".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.html,
                    data: Data("<meta charset='utf-8'><span>Visible text with “quotes”</span>".utf8)
                ),
            ]),
        ])
        let fixture = makeFixture()
        fixture.pasteboard.simulateCopy(payload)

        let rewriteResult = await fixture.controller.rewriteCurrentClipboardAsPlainText()

        XCTAssertEqual(rewriteResult, .succeeded)
        XCTAssertEqual(
            fixture.pasteboard.lastWrittenPayload,
            .plainText("Visible text with “quotes”")
        )
    }

    func testCopyingHistoryItemDoesNotRecapturePluginWrite() async throws {
        let existing = ClipboardHistoryItem(
            id: UUID(),
            text: "reuse me",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let fixture = makeFixture(initialItems: [existing])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let didCopy = await fixture.controller.copyItem(id: existing.id)
        XCTAssertTrue(didCopy)
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.count, 1)
        XCTAssertEqual(fixture.pasteboard.text, existing.text)
        XCTAssertNotNil(fixture.controller.items.first?.lastUsedAt)
        fixture.controller.stop()
    }

    func testHistoryPasteReceiptDoesNotAdoptALaterExternalCopy() async throws {
        let existing = item(text: "history payload", pinned: false)
        let fixture = makeFixture(initialItems: [existing])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let prepared = await fixture.controller.copyItemForPaste(id: existing.id)
        let writtenVersion = try XCTUnwrap(prepared)
        XCTAssertEqual(writtenVersion, fixture.controller.currentPasteboardVersion)
        fixture.pasteboard.simulateCopy("external copy")
        XCTAssertNotEqual(writtenVersion, fixture.controller.currentPasteboardVersion)
        XCTAssertEqual(fixture.pasteboard.text, "external copy")
        fixture.controller.stop()
    }

    func testCombinedPasteOwnsOnlyItsPreparedClipboardVersion() async {
        let existing = item(text: "one", pinned: false)
        let fixture = makeFixture(initialItems: [existing])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        XCTAssertTrue(fixture.controller.writeCombinedPlainText("one\ntwo", historyItemIDs: [existing.id]))
        let writtenVersion = fixture.controller.currentPasteboardVersion
        XCTAssertEqual(fixture.pasteboard.text, "one\ntwo")
        fixture.pasteboard.simulateCopy("external copy")
        XCTAssertNotEqual(writtenVersion, fixture.controller.currentPasteboardVersion)
        XCTAssertEqual(fixture.pasteboard.text, "external copy")
        fixture.controller.stop()
    }

    func testRecordingNonClipboardUseDoesNotSwallowPendingExternalCopy() async {
        let existing = item(text: "existing", pinned: false)
        let fixture = makeFixture(initialItems: [existing])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy("new external copy")
        fixture.controller.recordSuccessfulUse(id: existing.id)
        fixture.controller.processPasteboardChange()

        let captured = await waitUntil {
            fixture.controller.items.contains(where: { $0.text == "new external copy" })
        }
        XCTAssertTrue(captured)
        XCTAssertNotNil(fixture.controller.items.first(where: { $0.id == existing.id })?.lastUsedAt)
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

    func testHistoryItemCanBeReplayedAsPlainTextFromRichTextOrImageOCR() async throws {
        let richPayload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("\"CSV wrapped\"".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data("{\\rtf1 Formatted note}".utf8)
                ),
            ]),
        ])
        let richItem = ClipboardHistoryItem(
            id: UUID(),
            payload: richPayload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let imageItem = ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                ClipboardStoredPasteboardItem(representations: [
                    ClipboardStoredRepresentation(
                        typeIdentifier: ClipboardRepresentationType.png,
                        data: Data([0x01])
                    ),
                ]),
            ]),
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: "Recognized screenshot text",
            hasCompletedImageTextIndexing: true
        )
        let fixture = makeFixture(initialItems: [richItem, imageItem])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        XCTAssertTrue(fixture.controller.copyItemAsPlainText(id: richItem.id))
        XCTAssertEqual(fixture.pasteboard.lastWrittenPayload, .plainText("Formatted note"))

        XCTAssertTrue(fixture.controller.copyItemAsPlainText(id: imageItem.id))
        XCTAssertEqual(
            fixture.pasteboard.lastWrittenPayload,
            .plainText("Recognized screenshot text")
        )
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

    func testCancellingCombinedCopyBeforePayloadLoadFinishesDoesNotMutatePasteboard() async {
        let loader = BlockingCountingClipboardPayloadLoader(payload: .plainText("complete"))
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: "bounded metadata",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        item.configurePayloadLoader({ try loader.load() }, discardCachedPayload: true)
        let fixture = makeFixture(initialItems: [item])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let copyTask = Task {
            await fixture.controller.copyCombinedItemsAsPlainText(ids: [item.id])
        }
        let didStartLoading = await waitUntil { loader.loadCount == 1 }
        XCTAssertTrue(didStartLoading)
        copyTask.cancel()
        loader.release.signal()

        let didCopy = await copyTask.value
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

    func testQueuedCaptureReevaluatesChangedItemSizeLimit() async {
        let fixture = makeFixture()
        let payload = imagePayload(data: Data(repeating: 0xA5, count: 2 * 1_024 * 1_024))
        var rejection: (ClipboardCaptureIgnoreReason, Int)?
        fixture.controller.onCaptureRejection = { rejection = ($0, $1) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy(payload)
        fixture.controller.processPasteboardChange()
        fixture.settings.maximumItemByteCount = 1 * 1_024 * 1_024
        fixture.controller.settingsDidChange()
        await fixture.controller.waitForCaptureProcessingForTesting()

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(rejection?.0, .oversized)
        XCTAssertEqual(rejection?.1, 1 * 1_024 * 1_024)
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

    func testIgnoreNextCopyExpiresWithoutConsumingLaterChanges() async throws {
        let fixture = makeFixture()
        var suppressionEvents: [ClipboardCaptureSuppressionEvent] = []
        fixture.controller.onCaptureSuppressionEvent = { suppressionEvents.append($0) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.controller.ignoreNextCopy(expiringAfter: 0)
        for _ in 0..<20 where fixture.controller.isIgnoringNextCopy {
            await Task.yield()
        }
        XCTAssertFalse(fixture.controller.isIgnoringNextCopy)
        XCTAssertEqual(suppressionEvents, [
            .armed(mode: .ignoreNextCopy, timeout: 0),
            .expired(mode: .ignoreNextCopy),
        ])

        fixture.pasteboard.simulateCopy("after timeout")
        fixture.controller.processPasteboardChange()
        XCTAssertEqual(fixture.controller.items.map(\.text), ["after timeout"])
        fixture.controller.stop()
    }

    func testIgnoreNextCopyDoesNotConsumeAChangeFromBeforeItWasArmed() async throws {
        let fixture = makeFixture()
        var suppressionEvents: [ClipboardCaptureSuppressionEvent] = []
        fixture.controller.onCaptureSuppressionEvent = { suppressionEvents.append($0) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.pasteboard.simulateCopy("ordinary copy before shortcut")
        XCTAssertTrue(fixture.controller.ignoreNextCopy(expiringAfter: 60))
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(suppressionEvents, [.armed(mode: .ignoreNextCopy, timeout: 60)])
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)

        fixture.pasteboard.simulateCopy("sensitive context-menu copy")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(suppressionEvents, [
            .armed(mode: .ignoreNextCopy, timeout: 60),
            .consumed(mode: .ignoreNextCopy),
        ])
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        fixture.controller.stop()
    }

    func testSuppressionChurnSettlesAfterLastObservedWriteWithoutReadingPayload() async throws {
        let fixture = makeFixture(captureSuppressionSettlingInterval: 0.2)
        var suppressionEvents: [ClipboardCaptureSuppressionEvent] = []
        fixture.controller.onCaptureSuppressionEvent = { suppressionEvents.append($0) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let sourceReadBaseline = fixture.source.readCount

        XCTAssertTrue(fixture.controller.ignoreNextCopy(expiringAfter: 0.5))
        fixture.pasteboard.simulateCopy("private first write")
        fixture.controller.processPasteboardChange()
        for index in 1...4 {
            XCTAssertTrue(fixture.controller.isIgnoringNextCopy)
            fixture.pasteboard.simulateCopy("private transition \(index)")
            fixture.controller.processPasteboardChange()
        }
        XCTAssertEqual(suppressionEvents, [
            .armed(mode: .ignoreNextCopy, timeout: 0.5),
            .consumed(mode: .ignoreNextCopy),
        ])

        try await Task.sleep(nanoseconds: 550_000_000)
        for _ in 0..<100 where fixture.controller.isIgnoringNextCopy {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertFalse(fixture.controller.isIgnoringNextCopy)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, sourceReadBaseline)

        fixture.pasteboard.simulateCopy("ordinary value after hard deadline")
        fixture.controller.processPasteboardChange()
        XCTAssertEqual(fixture.controller.items.map(\.text), ["ordinary value after hard deadline"])
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

    func testSavingClipDoesNotDisableHistoryDuringPersistence() async throws {
        await assertSavedToggleKeepsHistoryInteractive(initiallySaved: false)
    }

    func testUnsavingClipDoesNotDisableHistoryDuringPersistence() async throws {
        await assertSavedToggleKeepsHistoryInteractive(initiallySaved: true)
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

    private func assertSavedToggleKeepsHistoryInteractive(initiallySaved: Bool) async {
        var original = item(text: "keep the preview visible", pinned: false)
        if initiallySaved {
            original.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Saved", savedAt: Date()))
        }
        let fixture = makeFixture()
        let persistence = BlockingFirstSaveClipboardHistoryPersistence(initialItems: [original])
        let controller = ClipboardHistoryController(
            settings: fixture.settings,
            pasteboard: fixture.pasteboard,
            sourceContext: fixture.source,
            persistence: persistence,
            monitoringInterval: 60
        )
        defer {
            persistence.allowFirstSaveToFinish()
            controller.stop()
        }
        controller.start()
        await waitUntilLoaded(controller)
        var clearingStates: [Bool] = []
        controller.onChange = { [weak controller] in
            if let controller { clearingStates.append(controller.isClearingHistory) }
        }
        let id = original.id
        let saveTask = Task { await controller.toggleSaved(id: id) }
        let didStart = await waitUntil { persistence.saveStarted }
        XCTAssertTrue(didStart)

        // The same state controls the list, preview, footer, and toolbar buttons.
        // A metadata write must not give them a transient disabled appearance.
        XCTAssertFalse(controller.isClearingHistory)
        XCTAssertTrue(controller.isCollectionOperational)
        XCTAssertEqual(controller.items, [original])
        XCTAssertNil(controller.errorMessage)

        persistence.allowFirstSaveToFinish()
        let didSave = await saveTask.value
        XCTAssertTrue(didSave)
        XCTAssertEqual(controller.items.map(\.id), [id])
        XCTAssertEqual(controller.items.first?.isSaved, !initiallySaved)
        XCTAssertEqual(controller.items.first?.text, original.text)
        XCTAssertFalse(controller.isClearingHistory)
        XCTAssertTrue(controller.isCollectionOperational)
        XCTAssertFalse(clearingStates.isEmpty)
        XCTAssertTrue(clearingStates.allSatisfy { !$0 })
        XCTAssertEqual(persistence.savedSnapshots.count, 1)
        XCTAssertEqual(persistence.savedSnapshots.last, controller.items)
    }

    func testRemovingSavedRoleKeepsHistoryButRemovesSavedOnlyRecord() async throws {
        let historyItem = item(text: "history", pinned: false)
        let fixture = makeFixture(initialItems: [historyItem])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let didSaveHistoryItem = await fixture.controller.toggleSaved(id: historyItem.id)
        XCTAssertTrue(didSaveHistoryItem)
        let didRemoveFirstSavedRole = await fixture.controller.deleteSavedItem(id: historyItem.id)
        XCTAssertTrue(didRemoveFirstSavedRole)
        XCTAssertEqual(fixture.controller.historyItems.map(\.id), [historyItem.id])
        XCTAssertTrue(fixture.controller.savedItems.isEmpty)

        let didSaveAgain = await fixture.controller.toggleSaved(id: historyItem.id)
        XCTAssertTrue(didSaveAgain)
        let didClearHistory = await fixture.controller.clearAllHistory()
        XCTAssertTrue(didClearHistory)
        let didRemoveSavedOnlyRecord = await fixture.controller.deleteSavedItem(id: historyItem.id)
        XCTAssertTrue(didRemoveSavedOnlyRecord)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        fixture.controller.stop()
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

    func testPermanentBatchDeleteIsAllOrNothingForCapturedTargets() async {
        let first = item(text: "First", pinned: false)
        let second = item(text: "Second", pinned: false)
        let retained = item(text: "Retained", pinned: false)
        let fixture = makeFixture(initialItems: [first, second, retained])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let staleDelete = await fixture.controller.deletePermanently(ids: [first.id, UUID()])
        XCTAssertFalse(staleDelete)
        XCTAssertEqual(Set(fixture.controller.items.map(\.id)), [first.id, second.id, retained.id])

        let deleted = await fixture.controller.deletePermanently(ids: [first.id, second.id])
        XCTAssertTrue(deleted)
        XCTAssertEqual(fixture.controller.items.map(\.id), [retained.id])
        XCTAssertEqual(fixture.persistence.savedItems.map(\.id), [retained.id])
        fixture.controller.stop()
    }

    func testClearSavedRolesLeavesHistoryItemsInPlace() async throws {
        var savedHistoryItem = item(text: "saved", pinned: false)
        savedHistoryItem.setSavedMetadata(ClipboardHistorySavedMetadata(
            title: "Saved",
            savedAt: Date()
        ))
        let ordinaryHistoryItem = item(text: "ordinary", pinned: false)
        let fixture = makeFixture(initialItems: [savedHistoryItem, ordinaryHistoryItem])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let didClearSavedItems = await fixture.controller.clearAllSavedItems()
        XCTAssertTrue(didClearSavedItems)

        XCTAssertEqual(
            Set(fixture.controller.historyItems.map(\.id)),
            Set([savedHistoryItem.id, ordinaryHistoryItem.id])
        )
        XCTAssertTrue(fixture.controller.savedItems.isEmpty)
        fixture.controller.stop()
    }

    func testClearSavedClipsDeletesSavedOnlyContentButKeepsHistory() async throws {
        var savedOnly = item(text: "saved only", pinned: false)
        savedOnly.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Saved", savedAt: Date()))
        savedOnly.setHistoryMembership(false)
        var shared = item(text: "both", pinned: false)
        shared.setSavedMetadata(ClipboardHistorySavedMetadata(title: "Shared", savedAt: Date()))
        let history = item(text: "history only", pinned: false)
        let fixture = makeFixture(initialItems: [savedOnly, shared, history])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        let cleared = await fixture.controller.clearAllSavedItems()
        XCTAssertTrue(cleared)
        XCTAssertEqual(Set(fixture.controller.historyItems.map(\.id)), Set([shared.id, history.id]))
        XCTAssertTrue(fixture.controller.savedItems.isEmpty)
        XCTAssertFalse(fixture.persistence.savedItems.contains { $0.id == savedOnly.id })
        XCTAssertEqual(fixture.persistence.resetCount, 0)
        fixture.controller.stop()
    }

    func testClearAllCancelsInFlightImageIndexingBeforeSavingEmptyHistory() async throws {
        let recognizer = BlockingCountingClipboardImageTextRecognizer()
        let payload = imagePayload(data: Data([0x01]))
        let image = lazyImageItem(payloadLoader: { payload })
        let fixture = makeFixture(
            initialItems: [image],
            imageIndexBatchPauseNanoseconds: 60_000_000_000,
            imageTextRecognizer: recognizer
        )
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        for _ in 0..<5_000 {
            if await recognizer.callCount > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let cleared = await fixture.controller.clearAllHistory()
        XCTAssertTrue(cleared)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.persistence.resetCount, 0)
        XCTAssertEqual(fixture.controller.pendingImageIndexItemCountForTesting, 0)

        await recognizer.releaseAll()
        await Task.yield()
        XCTAssertTrue(fixture.controller.items.isEmpty)
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

    func testRepeatedRestartDoesNotAccumulateBlockedPasteboardReaders() async {
        let fixture = makeFixture()
        fixture.pasteboard.requiresAsynchronousPayloadRead = true
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy("blocked first capture")
        fixture.controller.processPasteboardChange()
        let didStartRead = await waitUntil { fixture.pasteboard.asyncReadStartCount == 1 }
        XCTAssertTrue(didStartRead)

        for revision in 1...3 {
            fixture.controller.stop()
            fixture.controller.start()
            fixture.pasteboard.simulateCopy("new revision \(revision)")
            fixture.controller.processPasteboardChange()
        }

        XCTAssertEqual(fixture.pasteboard.asyncReadStartCount, 1)
        fixture.pasteboard.completeAsynchronousRead()
        let didFinishRead = await waitUntil { fixture.pasteboard.asyncReadCompleted }
        XCTAssertTrue(didFinishRead)
        XCTAssertTrue(fixture.controller.items.isEmpty)

        fixture.controller.processPasteboardChange()
        let didStartLatestRead = await waitUntil { fixture.pasteboard.asyncReadStartCount == 2 }
        XCTAssertTrue(didStartLatestRead)
        fixture.pasteboard.completeAsynchronousRead()
        let didCaptureLatest = await waitUntil { fixture.controller.items.first?.text == "new revision 3" }
        XCTAssertTrue(didCaptureLatest)
        fixture.controller.stop()
    }

    func testIdleMonitoringPrunesExpiredItemsWithoutAClipboardChange() async throws {
        let expiration = try XCTUnwrap(ClipboardHistorySettings.defaults.expiration.interval)
        let referenceDate = Date()
        let expiringItem = ClipboardHistoryItem(
            id: UUID(),
            text: "expires while idle",
            capturedAt: referenceDate.addingTimeInterval(-expiration + 60),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        let legacyPinnedItem = ClipboardHistoryItem(
            id: UUID(),
            text: "pinned",
            capturedAt: referenceDate.addingTimeInterval(-expiration - 60),
            sourceApplication: nil,
            isPinned: true,
            lastUsedAt: nil
        )
        let fixture = makeFixture(initialItems: [expiringItem, legacyPinnedItem])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.controller.processRetentionExpiration(
            now: referenceDate.addingTimeInterval(120)
        )
        let didPersistPruning = await waitUntil {
            fixture.persistence.savedItems.isEmpty
        }

        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertTrue(didPersistPruning)
        XCTAssertTrue(fixture.persistence.savedItems.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
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

    func testPersistenceFailureUsesInjectedLocalizedMessage() async throws {
        let suiteName = "ClipboardHistoryControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = ClipboardHistorySettingsStore(
            storage: UserDefaultsPluginStorage(
                pluginID: "clipboard-history-localization-tests",
                userDefaults: defaults
            )
        )
        settings.setPaused(false)
        settings.excludedApplications = []
        let pasteboard = FakeClipboardPasteboard()
        let persistence = SaveFailingClipboardHistoryPersistence()
        let controller = ClipboardHistoryController(
            settings: settings,
            pasteboard: pasteboard,
            sourceContext: FakeClipboardSourceContext(),
            persistence: persistence,
            monitoringInterval: 60,
            errorMessageProvider: { _ in "Localized storage failure" }
        )
        controller.start()
        await waitUntilLoaded(controller)

        pasteboard.simulateCopy("trigger save")
        controller.processPasteboardChange()
        for _ in 0..<100 where controller.errorMessage == nil {
            await Task.yield()
        }

        XCTAssertEqual(controller.errorMessage, "Localized storage failure")
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertTrue(try persistence.load().isEmpty)
        controller.stop()
    }

    func testSettingsPruneFailureRestoresLastDurableItems() async throws {
        let existing = item(
            text: "older than one day",
            pinned: false,
            capturedAt: Date().addingTimeInterval(-2 * 24 * 60 * 60)
        )
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
        fixture.settings.onChange = { [weak controller] in controller?.settingsDidChange() }
        controller.start()
        await waitUntilLoaded(controller)

        fixture.settings.expiration = .oneDay
        for _ in 0..<100 where controller.errorMessage == nil { await Task.yield() }

        XCTAssertEqual(controller.items, [existing])
        XCTAssertEqual(try persistence.load(), [existing])
        XCTAssertEqual(controller.errorMessage, "Localized storage failure")
        controller.stop()
    }

    func testIdlePruneFailureRestoresLastDurableItems() async throws {
        let referenceDate = Date()
        let existing = item(
            text: "expires while idle",
            pinned: false,
            capturedAt: referenceDate.addingTimeInterval(
                -ClipboardHistorySettings.defaults.expiration.interval! + 60
            )
        )
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

        controller.processRetentionExpiration(now: referenceDate.addingTimeInterval(120))
        for _ in 0..<100 where controller.errorMessage == nil { await Task.yield() }

        XCTAssertEqual(controller.items, [existing])
        XCTAssertEqual(try persistence.load(), [existing])
        XCTAssertEqual(controller.errorMessage, "Localized storage failure")
        controller.stop()
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

    func testNoOpClearAllStillWaitsForPendingEmptySnapshot() async throws {
        let fixture = makeFixture()
        let expired = item(
            text: "expired before clear",
            pinned: false,
            capturedAt: Date().addingTimeInterval(-ClipboardHistorySettings.defaults.expiration.interval! - 60)
        )
        let persistence = BlockingFirstSaveClipboardHistoryPersistence(initialItems: [expired])
        let controller = ClipboardHistoryController(
            settings: fixture.settings,
            pasteboard: fixture.pasteboard,
            sourceContext: fixture.source,
            persistence: persistence,
            monitoringInterval: 60
        )
        controller.start()
        await waitUntilLoaded(controller)
        for _ in 0..<100 where !persistence.saveStarted { await Task.yield() }
        XCTAssertTrue(controller.items.isEmpty)

        var result: Bool?
        let clearTask = Task { @MainActor in
            result = await controller.clearAllHistory()
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result)
        XCTAssertTrue(controller.isClearingHistory)

        persistence.allowFirstSaveToFinish()
        await clearTask.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(persistence.resetCount, 0)
        XCTAssertEqual(persistence.savedSnapshots.last, [])
        controller.stop()
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

    private func imagePayload(data: Data) -> ClipboardHistoryPayload {
        ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: data
                ),
            ]),
        ])
    }

    private func logicalItem(
        text: String,
        payloadByteCount: Int,
        pinned: Bool
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: Date(),
            sourceApplication: nil,
            kind: .plainText,
            payloadByteCount: payloadByteCount,
            filterContentKinds: [.plainText],
            fileURLs: [],
            representationTypeIdentifiers: [ClipboardRepresentationType.plainText],
            payloadDigest: Data(text.utf8),
            allowsRichTextImport: false,
            textCharacterCount: text.count,
            textLineCount: 1,
            isSearchTextTruncated: false,
            isPinned: pinned,
            lastUsedAt: nil,
            imageSearchText: nil,
            hasCompletedImageTextIndexing: false,
            payloadLoader: { .plainText(text) }
        )
    }

    private func lazyImageItem(
        payloadLoader: @escaping @Sendable () throws -> ClipboardHistoryPayload
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: "",
            capturedAt: Date(),
            sourceApplication: nil,
            kind: .image,
            payloadByteCount: 1,
            filterContentKinds: [.image],
            fileURLs: [],
            representationTypeIdentifiers: [ClipboardRepresentationType.png],
            payloadDigest: Data(UUID().uuidString.utf8),
            allowsRichTextImport: false,
            textCharacterCount: 0,
            textLineCount: 0,
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: nil,
            hasCompletedImageTextIndexing: false,
            payloadLoader: payloadLoader
        )
    }
}

@MainActor
private final class FakeClipboardCopyEventMonitor: ClipboardCopyEventMonitoring {
    private var action: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onCopyOrCut: @escaping @MainActor () -> Void) {
        startCount += 1
        action = onCopyOrCut
    }

    func stop() {
        stopCount += 1
        action = nil
    }

    func fire() { action?() }
}

private struct FakeClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    let text: String?

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        text
    }
}

private struct SlowClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return nil
    }
}

private actor BlockingCountingClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    private(set) var callCount = 0
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func recognizeText(in payload: ClipboardHistoryPayload) async -> String? {
        callCount += 1
        if !isReleased {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        return "recognized"
    }

    func releaseAll() {
        isReleased = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
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
