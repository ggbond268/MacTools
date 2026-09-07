import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistorySemanticClassificationTests: XCTestCase {
    func testClassifiesPlainTextLinksAndEmailAddresses() {
        let traits = ClipboardHistorySemanticClassification.traits(
            text: "Contact hello@example.com or visit https://example.com/docs.",
            linkURLs: [],
            imageSearchText: nil
        )

        XCTAssertEqual(traits, [.link, .email])
    }

    func testRecognizedImageTextCanBelongToMultipleSemanticFilters() {
        let traits = ClipboardHistorySemanticClassification.traits(
            text: "",
            linkURLs: [],
            imageSearchText: "Support: help@example.com\nhttps://example.com/help"
        )

        XCTAssertEqual(traits, [.link, .email, .recognizedText])
    }

    func testOrdinaryAtSignAndDottedWordsAreNotMisclassified() {
        let traits = ClipboardHistorySemanticClassification.traits(
            text: "Use @MainActor and version 1.2.3",
            linkURLs: [],
            imageSearchText: nil
        )

        XCTAssertTrue(traits.isEmpty)
    }

    func testClassifiesCommonHexColorLiteralsWithoutChangingTheItemKind() {
        XCTAssertEqual(
            ClipboardHistorySemanticClassification.traits(
                text: " #fff000\n",
                linkURLs: [],
                imageSearchText: nil
            ),
            [.color]
        )
        XCTAssertTrue(
            ClipboardHistorySemanticClassification.traits(
                text: "Not colors: #12 #toolonggg",
                linkURLs: [],
                imageSearchText: nil
            ).isEmpty
        )
    }

    func testIssueNumbersAndEmbeddedHexValuesDoNotClassifyDocumentsAsColors() {
        for text in ["#351 opened 1 day ago", "Issue #fff", "Brand colors: #fff000 and (#0af)", "#123 #456"] {
            XCTAssertFalse(ClipboardHistorySemanticClassification.traits(
                text: text, linkURLs: [], imageSearchText: nil
            ).contains(.color), text)
        }
    }

    func testOCRNeverChangesAnImageIntoTheColorType() {
        for recognizedText in ["#351 opened 1 day ago\n#350 feature", "#ffffff"] {
            var item = ClipboardHistoryItem(
                id: UUID(),
                payload: ClipboardHistoryPayload(pasteboardItems: [
                    ClipboardStoredPasteboardItem(representations: [
                        ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.png, data: Data([1])),
                    ]),
                ]),
                capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
            )
            item.setImageSearchText(recognizedText)
            XCTAssertEqual(item.kind, .image)
            XCTAssertFalse(item.semanticTraits.contains(.color))
            XCTAssertFalse(ClipboardHistoryContentFilter.color.matches(item))
            XCTAssertTrue(ClipboardHistoryContentFilter.image.matches(item))
            XCTAssertTrue(ClipboardHistorySemanticFilter.recognizedText.matches(item))
        }
    }

    func testItemRefreshesSemanticTraitsWhenOCRCompletes() {
        var item = ClipboardHistoryItem(
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
            lastUsedAt: nil
        )

        XCTAssertTrue(item.semanticTraits.isEmpty)
        item.setImageSearchText("team@example.com")
        XCTAssertEqual(item.semanticTraits, [.email, .recognizedText])
    }
}
