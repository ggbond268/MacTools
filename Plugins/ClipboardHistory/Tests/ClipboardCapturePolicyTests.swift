import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardCapturePolicyTests: XCTestCase {
    private let source = ClipboardSourceApplication(
        bundleIdentifier: "com.example.Editor",
        name: "Editor"
    )

    func testEmptyClipboardIsIgnored() {
        XCTAssertEqual(
            ClipboardCapturePolicy.evaluateText(
                "  \n ",
                sourceApplication: source,
                settings: .defaults,
                newestItem: nil
            ),
            .ignore(.empty)
        )
    }

    func testUnsupportedAndProducerMarkedTypesAreRejectedBeforeReadingPayload() {
        XCTAssertEqual(
            ClipboardCapturePolicy.preflight(
                types: ["com.example.unsupported"],
                sourceApplication: source,
                settings: .defaults
            ),
            .unsupportedType
        )
        XCTAssertEqual(
            ClipboardCapturePolicy.preflight(
                types: [
                    ClipboardRepresentationType.plainText,
                    "org.nspasteboard.ConcealedType",
                ],
                sourceApplication: source,
                settings: .defaults
            ),
            .producerMarkedPrivate
        )
    }

    func testStandardRichContentTypesPassPreflight() {
        for type in [
            ClipboardRepresentationType.rtf,
            ClipboardRepresentationType.html,
            ClipboardRepresentationType.png,
            ClipboardRepresentationType.pdf,
            ClipboardRepresentationType.fileURL,
            ClipboardRepresentationType.sound,
            "public.mpeg-4",
            "public.mp3",
        ] {
            XCTAssertNil(
                ClipboardCapturePolicy.preflight(
                    types: [type],
                    sourceApplication: source,
                    settings: .defaults
                ),
                "Expected \(type) to be supported"
            )
        }
    }

    func testConsecutiveDuplicateUsesNormalizedTextWithoutChangingStoredText() {
        let existing = item(text: "Cafe\u{301}\r\n")
        XCTAssertEqual(
            ClipboardCapturePolicy.evaluateText(
                "Café\n",
                sourceApplication: source,
                settings: .defaults,
                newestItem: existing
            ),
            .ignore(.duplicateNewestItem)
        )

        let original = "  keep surrounding whitespace  "
        let decision = ClipboardCapturePolicy.evaluateText(
            original,
            sourceApplication: source,
            settings: .defaults,
            newestItem: nil,
            makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )
        guard case let .capture(captured) = decision else {
            return XCTFail("Expected a captured item")
        }
        XCTAssertEqual(captured.text, original)
    }

    func testConsecutiveLongDuplicateUsesTheCompleteReloadablePayload() {
        let longText = String(repeating: "long normalized text ", count: 400)
        let existing = item(text: longText + "\r\n")
        existing.configurePayloadLoader({ .plainText(longText + "\r\n") }, discardCachedPayload: true)

        XCTAssertEqual(
            ClipboardCapturePolicy.evaluateText(
                longText + "\n",
                sourceApplication: source,
                settings: .defaults,
                newestItem: existing
            ),
            .ignore(.duplicateNewestItem)
        )
        XCTAssertNil(existing.payload)
    }

    func testOversizedTextIsIgnoredByUTF8ByteCount() {
        var settings = ClipboardHistorySettings.defaults
        settings.maximumItemByteCount = 3
        XCTAssertEqual(
            ClipboardCapturePolicy.evaluateText(
                "éé",
                sourceApplication: source,
                settings: settings,
                newestItem: nil
            ),
            .ignore(.oversized)
        )
    }

    func testRichContentDuplicatesRequireTheSameRepresentations() {
        let png = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                ),
            ]),
        ])
        let existing = ClipboardHistoryItem(
            id: UUID(),
            payload: png,
            capturedAt: Date(),
            sourceApplication: source,
            isPinned: false,
            lastUsedAt: nil
        )

        XCTAssertEqual(
            ClipboardCapturePolicy.evaluatePayload(
                png,
                sourceApplication: source,
                settings: .defaults,
                newestItem: existing
            ),
            .ignore(.duplicateNewestItem)
        )

        let differentPNG = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.png,
                    data: Data([0x89, 0x50, 0x4E, 0x48])
                ),
            ]),
        ])
        guard case .capture = ClipboardCapturePolicy.evaluatePayload(
            differentPNG,
            sourceApplication: source,
            settings: .defaults,
            newestItem: existing
        ) else {
            return XCTFail("Expected a different image payload to be captured")
        }
    }

    func testPauseAndExcludedApplicationAreAppliedBeforeCapture() {
        var settings = ClipboardHistorySettings.defaults
        settings.isPaused = true
        XCTAssertEqual(
            ClipboardCapturePolicy.preflight(
                types: [ClipboardRepresentationType.plainText],
                sourceApplication: source,
                settings: settings
            ),
            .paused
        )

        settings.isPaused = false
        settings.excludedApplications = [
            ClipboardExcludedApplication(
                bundleIdentifier: source.bundleIdentifier.lowercased(),
                name: source.name
            ),
        ]
        XCTAssertEqual(
            ClipboardCapturePolicy.preflight(
                types: [ClipboardRepresentationType.plainText],
                sourceApplication: source,
                settings: settings
            ),
            .excludedApplication
        )
    }

    func testMissingSourceContextDoesNotBlockCapture() {
        XCTAssertNil(ClipboardCapturePolicy.preflight(
            types: [ClipboardRepresentationType.plainText],
            sourceApplication: nil,
            settings: .defaults
        ))
    }

    func testRapidChangesKeepDifferentConsecutiveValues() {
        let firstDecision = ClipboardCapturePolicy.evaluateText(
            "first",
            sourceApplication: source,
            settings: .defaults,
            newestItem: nil
        )
        guard case let .capture(first) = firstDecision else {
            return XCTFail("Expected the first item")
        }
        let secondDecision = ClipboardCapturePolicy.evaluateText(
            "second",
            sourceApplication: source,
            settings: .defaults,
            newestItem: first
        )
        guard case let .capture(second) = secondDecision else {
            return XCTFail("Expected the second item")
        }
        XCTAssertNotEqual(first.text, second.text)
    }

    private func item(text: String) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: Date(),
            sourceApplication: source,
            isPinned: false,
            lastUsedAt: nil
        )
    }
}
