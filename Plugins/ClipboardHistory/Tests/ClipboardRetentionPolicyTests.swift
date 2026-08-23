import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardRetentionPolicyTests: XCTestCase {
    func testExpirationDeletesOldUnpinnedItemsButRetainsPins() {
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
            Set([oldPin.id, current.id])
        )
    }

    func testMaximumCountPrioritizesPinsThenNewestHistory() {
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
        XCTAssertEqual(Set(retained.map(\.id)), Set([pin.id, newer.id]))
    }

    func testPinnedItemsRemainBoundedWhenLimitIsReduced() {
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
        let retained = ClipboardRetentionPolicy.prune(items, settings: settings, now: now)
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained.map(\.text), ["pin-2", "pin-1"])
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
        XCTAssertTrue(ClipboardHistorySearch.filter([matching], query: "oo").isEmpty)
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
