import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardRetentionPolicyTests: XCTestCase {
    func testExpirationAppliesToLegacyPinnedRows() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.expiration = .oneDay
        let oldDate = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let oldRecent = item(text: "old", date: oldDate, pinned: false)
        let oldPin = item(text: "pin", date: oldDate, pinned: true)
        let current = item(text: "new", date: now, pinned: false)

        XCTAssertEqual(
            Set(ClipboardRetentionPolicy.prune(
                [oldRecent, oldPin, current],
                settings: settings,
                now: now
            ).map(\.id)),
            Set([current.id])
        )
    }

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

    func testLegacyPinnedRowsDoNotExceedReducedHistoryLimit() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 2
        let items = (0..<3).map { offset in
            item(
                text: "pin-\(offset)",
                date: now.addingTimeInterval(TimeInterval(offset)),
                pinned: true
            )
        }
        let result = ClipboardRetentionPolicy.evaluate(items, settings: settings, now: now)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items.map(\.text), ["pin-2", "pin-1"])
        XCTAssertFalse(result.isCaptureBlockedByProtectedItems)
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
        settings.maximumItemCount = ClipboardHistorySettings.noItemCountLimit
        settings.maximumItemByteCount = 1_024 * 1_024
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
            ClipboardRetentionPolicy.maximumTotalPayloadByteCount
        )
        XCTAssertTrue(ClipboardHistorySearch.filter(retained, query: "z").isEmpty)
    }

    func testFiveGigabyteLimitEvictsOldestUnpinnedLogicalPayload() {
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = 100
        settings.expiration = .never
        settings.maximumTotalPayloadByteCount = ClipboardHistorySettings.maximumSupportedTotalPayloadByteCount
        let twoGigabytes = 2 * 1_024 * 1_024 * 1_024
        let items = (0..<3).map { offset in
            logicalItem(
                text: "large-\(offset)",
                date: Date(timeIntervalSince1970: TimeInterval(offset)),
                payloadByteCount: twoGigabytes
            )
        }

        let retained = ClipboardRetentionPolicy.prune(items, settings: settings)

        XCTAssertEqual(retained.map(\.text), ["large-2", "large-1"])
        XCTAssertEqual(retained.reduce(0) { $0 + $1.payloadByteCount }, 4 * 1_024 * 1_024 * 1_024)
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

    func testMaximumSupportedHistoryEvictsOnlyTheOldestUnpinnedItem() {
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemCount = ClipboardHistorySettings.maximumSupportedItemCount
        settings.expiration = .never
        let now = Date()
        let items = (0...ClipboardHistorySettings.maximumSupportedItemCount).map { offset in
            item(
                text: "item-\(offset)",
                date: now.addingTimeInterval(TimeInterval(offset)),
                pinned: false
            )
        }

        let result = ClipboardRetentionPolicy.evaluate(items, settings: settings, now: now)

        XCTAssertEqual(result.items.count, ClipboardHistorySettings.maximumSupportedItemCount)
        XCTAssertFalse(result.items.contains(where: { $0.text == "item-0" }))
        XCTAssertEqual(result.evictedItemCount, 1)
        XCTAssertFalse(result.isCaptureBlockedByProtectedItems)
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

    func testTenThousandCachedItemsCanBeFullyScannedWithinInteractiveBudget() {
        let items = (0..<ClipboardHistorySettings.maximumSupportedItemCount).map { offset in
            item(text: "clipboard entry \(offset)", date: Date(), pinned: false)
        }
        let startedAt = Date()

        let result = ClipboardHistorySearch.result(
            items,
            query: "definitely-not-present",
            limit: ClipboardHistoryPanelModel.resultPageSize
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.hasMore)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testWorstCaseSearchIndexesStayBoundedAcrossTenThousandItems() {
        let longText = Array(repeating: "search-token-with-a-long-suffix", count: 300)
            .joined(separator: " ")
        let items = (0..<ClipboardHistorySettings.maximumSupportedItemCount).map { offset in
            item(text: "\(offset) \(longText)", date: Date(), pinned: false)
        }

        XCTAssertTrue(items.allSatisfy {
            $0.searchIndex.normalizedText.count <= ClipboardHistorySearch.maximumNormalizedCharacterCount
                && $0.searchIndex.tokens.count <= ClipboardHistorySearch.maximumTokenCount
                && $0.searchIndex.tokens.allSatisfy {
                    $0.count <= ClipboardHistorySearch.maximumTokenCharacterCount
                }
        })
        let startedAt = Date()
        let result = ClipboardHistorySearch.result(
            items,
            query: "definitely-not-present",
            limit: ClipboardHistoryPanelModel.resultPageSize
        )
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }

    func testLongPrimaryTextDoesNotStarveSecondarySearchFields() {
        let source = ClipboardSourceApplication(
            bundleIdentifier: "com.example.source-token",
            name: "Unique Source Token"
        )
        let fileURL = URL(fileURLWithPath: "/tmp/unique-file-token.pdf")
        let linkURL = URL(string: "https://example.com/unique-link-token")!
        let longOCRText = Array(repeating: "fillerword", count: 50)
            .joined(separator: " ") + " Unique OCR Token"
        XCTAssertGreaterThan(longOCRText.range(of: "Unique")!.lowerBound.utf16Offset(in: longOCRText), 508)
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: String(repeating: "x", count: ClipboardHistoryItem.maximumSearchableCharacterCount),
            capturedAt: Date(),
            sourceApplication: source,
            kind: .image,
            payloadByteCount: 1,
            filterContentKinds: [.image],
            fileURLs: [fileURL],
            linkURLs: [linkURL],
            representationTypeIdentifiers: [ClipboardRepresentationType.png],
            payloadDigest: Data("search-fields".utf8),
            allowsRichTextImport: false,
            textCharacterCount: ClipboardHistoryItem.maximumSearchableCharacterCount,
            textLineCount: 1,
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: longOCRText,
            hasCompletedImageTextIndexing: true,
            payloadLoader: { .plainText("payload") }
        )

        for query in [
            "source-token",
            "unique source",
            "unique-file-token",
            "unique-link-token",
            "unique ocr",
        ] {
            XCTAssertEqual(ClipboardHistorySearch.filter([item], query: query), [item], query)
        }
        XCTAssertLessThanOrEqual(
            item.searchIndex.normalizedText.count,
            ClipboardHistorySearch.maximumNormalizedCharacterCount
        )
        XCTAssertLessThanOrEqual(
            item.searchIndex.tokens.count,
            ClipboardHistorySearch.maximumTokenCount
        )
    }

    func testURLOnlyLinkIsSearchableAndConvertibleToPlainText() {
        let url = "https://github.com/ggbond268/MacTools/issues/306"
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.url,
                    data: Data(url.utf8)
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

        XCTAssertEqual(item.text, url)
        XCTAssertEqual(item.linkURLs.map(\.absoluteString), [url])
        XCTAssertEqual(ClipboardHistorySearch.filter([item], query: "github issues 306"), [item])
        XCTAssertEqual(ClipboardPlainTextConversion.text(for: item), url)
    }

    func testSearchMatchesEachQueryTokenByWordPrefix() {
        let matching = item(text: "foo bar baz", date: Date(), pinned: false)
        let unrelated = item(text: "food bar qux", date: Date(), pinned: false)

        XCTAssertEqual(
            ClipboardHistorySearch.filter([matching, unrelated], query: "fo baz"),
            [matching]
        )
    }

    func testSearchMatchesCompactPrefixesAcrossConsecutiveWords() {
        let matching = item(text: "foo bar baz", date: Date(), pinned: false)
        let wrongMiddleWord = item(text: "food qux baz", date: Date(), pinned: false)

        XCTAssertEqual(
            ClipboardHistorySearch.filter([matching, wrongMiddleWord], query: "foba"),
            [matching]
        )
        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: "fbb"), [matching])
        XCTAssertTrue(ClipboardHistorySearch.filter([matching], query: "fz").isEmpty)
    }

    func testSearchMatchesMeaningfulWordFragmentsAcrossSeparators() {
        let matching = item(text: "foo bar baz", date: Date(), pinned: false)

        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: "fbaz"), [matching])
        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: "oobaz"), [matching])
        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: "oo baz"), [matching])
        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: "fo baz"), [matching])
        XCTAssertEqual(ClipboardHistorySearch.filter([matching], query: "oo"), [matching])
    }

    func testSearchMatchesTwoCharacterSubstringsInsideWords() {
        let cases: [(text: String, query: String, expected: Bool)] = [
            ("MT88 tripod", "88", true),
            ("MT88 tripod", " 88 ", true),
            ("MT88 tripod", "t8", true),
            ("MT88 tripod", "89", false),
            ("MT88 tripod", "8", false),
            ("MT88 tripod", "m", true),
            ("foo bar baz", "oo", true),
            ("Café", "AF", true),
            ("foo bar baz", "oz", false),
        ]
        for testCase in cases {
            let candidate = item(text: testCase.text, date: Date(), pinned: false)
            let context = "\(testCase.text) / \(testCase.query)"
            XCTAssertEqual(
                ClipboardHistorySearch.matches(index: candidate.searchIndex, query: testCase.query),
                testCase.expected, context
            )
            XCTAssertEqual(
                ClipboardHistorySearch.filter([candidate], query: testCase.query),
                testCase.expected ? [candidate] : [], context
            )
        }
    }

    func testTwoCharacterSearchScansTenThousandItemsWithinInteractiveBudget() {
        let items = (0..<ClipboardHistorySettings.maximumSupportedItemCount).map { offset in
            item(text: "MT88 tripod \(offset)", date: Date(), pinned: false)
        }
        for query in ["88", "zz"] {
            let startedAt = ContinuousClock.now
            let count = items.reduce(0) { count, item in
                count + (ClipboardHistorySearch.matches(index: item.searchIndex, query: query) ? 1 : 0)
            }
            XCTAssertEqual(count, query == "88" ? items.count : 0)
            XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(2), query)
        }
        let result = ClipboardHistorySearch.result(
            items, query: "88", limit: ClipboardHistoryPanelModel.resultPageSize
        )
        XCTAssertEqual(result.items.count, ClipboardHistoryPanelModel.resultPageSize)
        XCTAssertTrue(result.hasMore)
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

    func testSearchTokenPrefixesCanMatchAcrossContentAndSourceApplication() {
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: "quarterly summary",
            capturedAt: Date(),
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.apple.Safari",
                name: "Safari"
            ),
            isPinned: false,
            lastUsedAt: nil
        )

        XCTAssertEqual(ClipboardHistorySearch.filter([item], query: "qua saf"), [item])
        XCTAssertEqual(ClipboardHistorySearch.filter([item], query: "qua com app"), [item])
        XCTAssertTrue(ClipboardHistorySearch.filter([item], query: "qua chr").isEmpty)
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
