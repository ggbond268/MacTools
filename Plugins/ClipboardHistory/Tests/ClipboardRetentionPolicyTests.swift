import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardRetentionPolicyTests: XCTestCase {

    func testMaximumCountUsesNewestHistoryRegardlessOfLegacyPinFlag() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 2
        settings.expiration = .ninetyDays
        let pin = item(text: "pin", date: now.addingTimeInterval(-30), pinned: true)
        let older = item(text: "older", date: now.addingTimeInterval(-20), pinned: false)
        let newer = item(text: "newer", date: now.addingTimeInterval(-10), pinned: false)

        let retained = ClipboardRetentionPolicy.prune(
            [older, pin, newer],
            settings: settings,
            now: now
        )
        XCTAssertEqual(Set(retained.map(\.id)), Set([older.id, newer.id]))
    }

    func testOversizedNewestItemDoesNotPreventOlderItemsFromUsingRemainingCapacity() {
        var settings = ClipboardHistorySettings.defaults
        settings.expiration = .never
        settings.maximumItemCount = 21
        settings.maximumTotalPayloadByteCount = 64 * 1_024 * 1_024
        let now = Date()
        let pin = logicalItem(
            text: "pin",
            date: now.addingTimeInterval(-30),
            payloadByteCount: 30 * 1_024 * 1_024,
            pinned: true
        )
        let newestThatDoesNotFit = logicalItem(
            text: "new capture",
            date: now,
            payloadByteCount: 40 * 1_024 * 1_024
        )
        let existingRecent = (0..<20).map { offset in
            logicalItem(
                text: "existing-\(offset)",
                date: now.addingTimeInterval(TimeInterval(-offset - 1)),
                payloadByteCount: 1 * 1_024 * 1_024
            )
        }

        let retained = ClipboardRetentionPolicy.prune(
            [newestThatDoesNotFit, pin] + existingRecent,
            settings: settings,
            now: now
        )

        XCTAssertTrue(retained.contains(where: { $0.id == newestThatDoesNotFit.id }))
        XCTAssertFalse(retained.contains(where: { $0.id == pin.id }))
        XCTAssertEqual(retained.count, existingRecent.count + 1)
    }

    func testTotalPayloadBudgetBoundsMaximumConfiguredHistory() {
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = ClipboardHistorySettings.maximumSupportedItemCount
        settings.maximumItemByteCount = 1_024 * 1_024
        settings.maximumTotalPayloadByteCount = 64 * 1_024 * 1_024
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data(repeating: 0xA5, count: 1_024 * 1_024)
                ),
            ]),
        ])
        let now = Date()
        let items = (0..<65).map { offset in
            ClipboardHistoryItem(
                id: UUID(),
                payload: payload,
                capturedAt: now.addingTimeInterval(TimeInterval(-offset)),
                sourceApplication: nil,
                isPinned: false,
                lastUsedAt: nil
            )
        }

        let retained = ClipboardRetentionPolicy.prune(items, settings: settings, now: now)

        XCTAssertEqual(retained.count, 64)
        XCTAssertLessThanOrEqual(
            retained.reduce(0) { $0 + $1.payloadByteCount },
            settings.maximumTotalPayloadByteCount
        )
        XCTAssertTrue(ClipboardHistorySearch.filter(retained, query: "z").isEmpty)
    }

    func testNeverExpirationKeepsOldUnpinnedItems() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.expiration = .never
        let old = item(
            text: "old",
            date: now.addingTimeInterval(-10 * 365 * 24 * 60 * 60),
            pinned: false
        )

        XCTAssertEqual(
            ClipboardRetentionPolicy.prune([old], settings: settings, now: now),
            [old]
        )
    }

    func testHistoryRetentionDemotesSavedItemInsteadOfDeletingItsRecord() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 1
        let newest = item(text: "newest", date: now, pinned: false)
        var olderSaved = item(
            text: "older saved",
            date: now.addingTimeInterval(-60),
            pinned: false
        )
        olderSaved.setSavedMetadata(ClipboardHistorySavedMetadata(
            title: "Saved",
            savedAt: now
        ))

        let retained = ClipboardRetentionPolicy.prune(
            [newest, olderSaved],
            settings: settings,
            now: now
        )

        XCTAssertEqual(Set(retained.map(\.id)), Set([newest.id, olderSaved.id]))
        XCTAssertEqual(retained.first { $0.id == olderSaved.id }?.isInHistory, false)
        XCTAssertEqual(retained.first { $0.id == olderSaved.id }?.isSaved, true)
    }

    func testSavedOnlyItemDoesNotConsumeHistoryCountOrPayloadBudget() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 1
        settings.maximumTotalPayloadByteCount = 1
        let historyItem = logicalItem(text: "history", date: now, payloadByteCount: 1)
        var savedOnly = logicalItem(
            text: "saved only",
            date: now.addingTimeInterval(-60),
            payloadByteCount: 10_000
        )
        savedOnly.setHistoryMembership(false)
        savedOnly.setSavedMetadata(ClipboardHistorySavedMetadata(
            title: "Saved",
            savedAt: now
        ))

        let retained = ClipboardRetentionPolicy.prune(
            [historyItem, savedOnly],
            settings: settings,
            now: now
        )

        XCTAssertEqual(Set(retained.map(\.id)), Set([historyItem.id, savedOnly.id]))
        XCTAssertEqual(retained.filter(\.isInHistory).map(\.id), [historyItem.id])
    }

    private func logicalItem(
        text: String,
        date: Date,
        payloadByteCount: Int,
        pinned: Bool = false
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: date,
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

    func testExplicitQueueProtectionSurvivesExpirationAndCountEviction() {
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 100
        settings.expiration = .oneDay
        let now = Date()
        let queued = item(
            text: "queued",
            date: now.addingTimeInterval(-10 * 24 * 60 * 60),
            pinned: false
        )
        let recent = (0..<100).map { offset in
            item(
                text: "recent-\(offset)",
                date: now.addingTimeInterval(TimeInterval(-offset)),
                pinned: false
            )
        }

        let result = ClipboardRetentionPolicy.evaluate(
            recent + [queued],
            settings: settings,
            now: now,
            protectedItemIDs: [queued.id]
        )

        XCTAssertTrue(result.items.contains(where: { $0.id == queued.id }))
        XCTAssertEqual(result.items.count, 100)
        XCTAssertFalse(result.isCaptureBlockedByProtectedItems)
    }

    func testTimedShortcutRetainsHistoryWithoutBlockingNewCaptures() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 1
        settings.maximumTotalPayloadByteCount = 1
        settings.expiration = .oneDay
        let oldShortcutItem = logicalItem(
            text: "shortcut", date: now.addingTimeInterval(-2 * 24 * 60 * 60),
            payloadByteCount: 10_000
        )
        let recent = logicalItem(text: "recent", date: now, payloadByteCount: 1)

        let retained = ClipboardRetentionPolicy.evaluate(
            [recent, oldShortcutItem], settings: settings, now: now,
            shortcutRetainedItemIDs: [oldShortcutItem.id]
        )
        XCTAssertEqual(Set(retained.items.map(\.id)), [recent.id, oldShortcutItem.id])
        XCTAssertFalse(retained.isCaptureBlockedByProtectedItems)
        XCTAssertEqual(retained.items.first { $0.id == oldShortcutItem.id }?.isInHistory, true)

        let afterShortcutExpires = ClipboardRetentionPolicy.prune(retained.items, settings: settings, now: now)
        XCTAssertEqual(afterShortcutExpires.map(\.id), [recent.id])
    }

    func testSearchMatchesEachQueryTokenByWordPrefix() {
        let matching = item(text: "foo bar baz", date: Date(), pinned: false)
        let unrelated = item(text: "food bar qux", date: Date(), pinned: false)

        XCTAssertEqual(
            ClipboardHistorySearch.filter([matching, unrelated], query: "fo baz"),
            [matching]
        )
    }

    func testSearchMatchesFullMultilineClipAfterSearchFieldWhitespaceNormalization() {
        let text = (0..<64).map { "word\($0)" }.joined(separator: "\n")
        let normalizedQuery = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let matching = item(text: text, date: Date(), pinned: false)

        XCTAssertGreaterThan(
            normalizedQuery.split(separator: " ").count,
            ClipboardHistorySearch.maximumPrimaryTextTokenCount
        )
        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: normalizedQuery), [matching])
    }

    func testSearchMatchesOnDeviceImageTextIndex() {
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data([0x01])
                ),
            ]),
        ])
        let image = ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: "Quarterly invoice total",
            hasCompletedImageTextIndexing: true
        )

        XCTAssertEqual(ClipboardHistorySearch.filter([image], query: "inv tot"), [image])
        XCTAssertEqual(ClipboardHistorySearch.filter([image], query: "quainv"), [image])
    }

    func testSearchPreservesCaseDiacriticAndSubstringMatching() {
        let item = item(text: "Café Foo", date: Date(), pinned: false)

        XCTAssertEqual(ClipboardHistorySearch.filter([item], query: "CAFE"), [item])
        XCTAssertEqual(ClipboardHistorySearch.filter([item], query: "afé"), [item])
    }

    private func item(text: String, date: Date, pinned: Bool) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: date,
            sourceApplication: nil,
            isPinned: pinned,
            lastUsedAt: nil
        )
    }
}
