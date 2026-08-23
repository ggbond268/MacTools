import AppKit
import Foundation
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryControllerTests: XCTestCase {
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
        fixture.pasteboard.simulateCopy("allowed")
        fixture.controller.processPasteboardChange()
        XCTAssertEqual(fixture.controller.items.map(\.text), ["allowed"])
        fixture.controller.stop()
    }

    func testPinnedItemsAtCapacityBlockCaptureBeforeReadingClipboardPayload() async {
        let pins = (0..<100).map { index in
            item(text: "pin-\(index)", pinned: true)
        }
        let fixture = makeFixture(initialItems: pins)
        fixture.settings.maximumItemCount = 100
        var rejection: ClipboardCaptureIgnoreReason?
        fixture.controller.onCaptureRejection = { reason, _ in rejection = reason }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        XCTAssertTrue(fixture.controller.isCaptureBlockedByPinnedItems)
        fixture.pasteboard.simulateCopy("not retained")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(rejection, .pinnedItemsFillCapacity)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.controller.items.count, 100)
        fixture.controller.stop()
    }

    func testCapturedImageIsIndexedForSearchAndPersisted() async throws {
        let recognizer = FakeClipboardImageTextRecognizer(text: "Invoice total 42 dollars")
        let fixture = makeFixture(imageTextRecognizer: recognizer)
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
        for _ in 0..<100 where fixture.controller.items.first?.hasCompletedImageTextIndexing != true {
            await Task.yield()
        }

        XCTAssertEqual(fixture.controller.matchingItems(query: "inv tot").count, 1)
        XCTAssertEqual(fixture.controller.items.first?.imageSearchText, "Invoice total 42 dollars")
        XCTAssertEqual(fixture.controller.rewriteCurrentClipboardAsPlainText(), .succeeded)
        XCTAssertEqual(
            fixture.pasteboard.lastWrittenPayload,
            .plainText("Invoice total 42 dollars")
        )
        fixture.controller.stop()
        XCTAssertEqual(fixture.persistence.savedItems.first?.imageSearchText, "Invoice total 42 dollars")
    }

    func testPlainTextRewriteDoesNotUseOCRAfterThePasteboardChanges() async {
        let recognizer = FakeClipboardImageTextRecognizer(text: "Stale recognized text")
        let fixture = makeFixture(imageTextRecognizer: recognizer)
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy(imagePayload(data: Data([0x01])))
        fixture.controller.processPasteboardChange()
        for _ in 0..<100 where fixture.controller.items.first?.hasCompletedImageTextIndexing != true {
            await Task.yield()
        }

        fixture.pasteboard.simulateCopy(imagePayload(data: Data([0x02])))

        XCTAssertEqual(fixture.controller.rewriteCurrentClipboardAsPlainText(), .unavailable)
        XCTAssertNil(fixture.pasteboard.lastWrittenPayload)
        fixture.controller.stop()
    }

    func testPlainTextRewriteReportsPendingImageRecognition() async {
        let fixture = makeFixture(imageTextRecognizer: SlowClipboardImageTextRecognizer())
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)
        fixture.pasteboard.simulateCopy(imagePayload(data: Data([0x01])))
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(
            fixture.controller.rewriteCurrentClipboardAsPlainText(),
            .imageTextRecognitionPending
        )
        fixture.controller.stop()
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

        XCTAssertTrue(fixture.controller.copyItem(id: existing.id))
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.count, 1)
        XCTAssertEqual(fixture.pasteboard.text, existing.text)
        XCTAssertNotNil(fixture.controller.items.first?.lastUsedAt)
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
        XCTAssertTrue(fixture.controller.copyItem(id: item.id))
        XCTAssertEqual(fixture.pasteboard.lastWrittenPayload, payload)
        fixture.controller.stop()
    }

    func testHistoryItemCanBeReplayedAsPlainTextFromRichTextOrImageOCR() async throws {
        let richPayload = ClipboardHistoryPayload(pasteboardItems: [
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

        XCTAssertFalse(fixture.controller.copyItem(id: item.id))
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

        fixture.controller.ignoreNextCopy(expiringAfter: 60)
        XCTAssertTrue(fixture.controller.isIgnoringNextCopy)

        fixture.pasteboard.simulateCopy("private value")
        fixture.controller.processPasteboardChange()

        XCTAssertTrue(fixture.controller.isIgnoringNextCopy)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, 0)
        XCTAssertEqual(suppressionEvents, [
            .armed(mode: .ignoreNextCopy, timeout: 60),
            .consumed(mode: .ignoreNextCopy),
        ])

        fixture.pasteboard.simulateCopy("private value, delayed representation")
        fixture.controller.processPasteboardChange()
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, 0)

        fixture.controller.cancelNextCaptureSuppression()
        fixture.pasteboard.simulateCopy("ordinary value")
        fixture.controller.processPasteboardChange()

        XCTAssertEqual(fixture.controller.items.map(\.text), ["ordinary value"])
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 1)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 1)
        XCTAssertEqual(fixture.source.readCount, 1)
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

    func testSuppressionChurnCannotExtendPastHardDeadlineWithoutReadingPayload() async throws {
        let fixture = makeFixture(captureSuppressionSettlingInterval: 0.2)
        var suppressionEvents: [ClipboardCaptureSuppressionEvent] = []
        fixture.controller.onCaptureSuppressionEvent = { suppressionEvents.append($0) }
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        XCTAssertTrue(fixture.controller.ignoreNextCopy(expiringAfter: 0.5))
        fixture.pasteboard.simulateCopy("private first write")
        fixture.controller.processPasteboardChange()
        for index in 1...4 {
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(fixture.controller.isIgnoringNextCopy)
            fixture.pasteboard.simulateCopy("private transition \(index)")
            fixture.controller.processPasteboardChange()
        }
        XCTAssertEqual(suppressionEvents, [
            .armed(mode: .ignoreNextCopy, timeout: 0.5),
            .consumed(mode: .ignoreNextCopy),
        ])

        try await Task.sleep(nanoseconds: 200_000_000)
        for _ in 0..<100 where fixture.controller.isIgnoringNextCopy {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertFalse(fixture.controller.isIgnoringNextCopy)
        XCTAssertTrue(fixture.controller.items.isEmpty)
        XCTAssertEqual(fixture.pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(fixture.pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(fixture.source.readCount, 0)

        fixture.pasteboard.simulateCopy("ordinary value after hard deadline")
        fixture.controller.processPasteboardChange()
        XCTAssertEqual(fixture.controller.items.map(\.text), ["ordinary value after hard deadline"])
        fixture.controller.stop()
    }

    func testClearOperationsPersistOnlyExpectedItems() async throws {
        let pin = item(text: "pin", pinned: true)
        let recent = item(text: "recent", pinned: false)
        let fixture = makeFixture(initialItems: [recent, pin])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        let clearedUnpinned = await fixture.controller.clearUnpinnedHistory()
        XCTAssertTrue(clearedUnpinned)
        XCTAssertEqual(fixture.controller.items, [pin])
        XCTAssertEqual(fixture.persistence.savedItems, [pin])

        let clearedAll = await fixture.controller.clearAllHistory()
        XCTAssertTrue(clearedAll)
        XCTAssertTrue(fixture.persistence.savedItems.isEmpty)
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
        let pinnedItem = ClipboardHistoryItem(
            id: UUID(),
            text: "pinned",
            capturedAt: referenceDate.addingTimeInterval(-expiration - 60),
            sourceApplication: nil,
            isPinned: true,
            lastUsedAt: nil
        )
        let fixture = makeFixture(initialItems: [expiringItem, pinnedItem])
        fixture.controller.start()
        await waitUntilLoaded(fixture.controller)

        fixture.controller.processPasteboardChange(
            now: referenceDate.addingTimeInterval(120)
        )
        await waitForPersistence()

        XCTAssertEqual(fixture.controller.items, [pinnedItem])
        XCTAssertEqual(fixture.persistence.savedItems, [pinnedItem])
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

    func testPinFailureRestoresLastDurableState() async throws {
        let existing = item(text: "keep unpinned", pinned: false)
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

        controller.togglePin(id: existing.id)
        for _ in 0..<100 where controller.errorMessage == nil { await Task.yield() }

        XCTAssertEqual(controller.items, [existing])
        XCTAssertEqual(try persistence.load(), [existing])
        XCTAssertEqual(controller.errorMessage, "Localized storage failure")
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

        controller.processPasteboardChange(now: referenceDate.addingTimeInterval(120))
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
        XCTAssertTrue(persistence.savedSnapshots.last?.isEmpty == true)
        controller.stop()
    }

    func testNoOpClearUnpinnedStillWaitsForPendingPinsOnlySnapshot() async throws {
        let pin = item(text: "pin", pinned: true)
        let recent = item(
            text: "recent",
            pinned: false,
            capturedAt: Date().addingTimeInterval(-ClipboardHistorySettings.defaults.expiration.interval! - 60)
        )
        let fixture = makeFixture()
        let persistence = BlockingFirstSaveClipboardHistoryPersistence(initialItems: [recent, pin])
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
        XCTAssertEqual(controller.items, [pin])

        var result: Bool?
        let clearTask = Task { @MainActor in
            result = await controller.clearUnpinnedHistory()
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result)
        XCTAssertTrue(controller.isClearingHistory)

        persistence.allowFirstSaveToFinish()
        await clearTask.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(persistence.savedSnapshots.last, [pin])
        controller.stop()
    }

    private func makeFixture(
        initialItems: [ClipboardHistoryItem] = [],
        captureSuppressionSettlingInterval: TimeInterval = 0.75,
        imageTextRecognizer: any ClipboardImageTextRecognizing = VisionClipboardImageTextRecognizer()
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
            imageTextRecognizer: imageTextRecognizer
        )
        settings.onChange = { [weak controller] in
            controller?.settingsDidChange()
        }
        return (controller, settings, pasteboard, source, persistence)
    }

    private func waitUntilLoaded(_ controller: ClipboardHistoryController) async {
        for _ in 0..<100 where !controller.isLoaded {
            await Task.yield()
        }
        XCTAssertTrue(controller.isLoaded)
    }

    private func waitForPersistence() async {
        for _ in 0..<10 {
            await Task.yield()
        }
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

        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isCollectionOperational)
        pasteboard.simulateCopy("must not be read")
        controller.processPasteboardChange()
        XCTAssertTrue(controller.items.isEmpty)
        XCTAssertEqual(pasteboard.typeNamesReadCount, 0)
        XCTAssertEqual(pasteboard.plainTextReadCount, 0)
        XCTAssertEqual(source.readCount, 0)
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

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboardAccess {
    var changeCount = 0
    var simulatedTypeNames: Set<String> = [ClipboardRepresentationType.plainText]
    var text: String?
    var payload: ClipboardHistoryPayload?
    var onRead: (() -> Void)?
    private(set) var lastWrittenPayload: ClipboardHistoryPayload?
    private(set) var typeNamesReadCount = 0
    private(set) var plainTextReadCount = 0

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
    private(set) var readCount = 0

    func frontmostApplication() -> ClipboardSourceApplication? {
        readCount += 1
        return application
    }
}

private final class InMemoryClipboardHistoryPersistence: ClipboardHistoryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardHistoryItem]
    private var removed = false

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

    func load() throws -> [ClipboardHistoryItem] {
        lock.withLock { items }
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        lock.withLock { self.items = items }
    }

    func reset() throws {
        lock.withLock { items = [] }
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
    private let initialItems: [ClipboardHistoryItem]

    init(initialItems: [ClipboardHistoryItem] = []) {
        self.initialItems = initialItems
    }

    func prepare() throws {}

    var saveStarted: Bool { condition.withLock { started } }
    var savedSnapshots: [[ClipboardHistoryItem]] { condition.withLock { snapshots } }

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
        condition.withLock { snapshots = [] }
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
