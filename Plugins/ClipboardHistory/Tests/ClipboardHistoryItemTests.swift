import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryItemTests: XCTestCase {
    func testPlainTextOnlyRequiresOnlyPlainTextRepresentations() {
        let plain = item(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Hello".utf8)),
        ])
        XCTAssertTrue(plain.isPlainTextOnly)

        let rich = item(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Hello".utf8)),
            .init(typeIdentifier: ClipboardRepresentationType.rtf, data: Data("{\\rtf1 Hello}".utf8)),
        ])
        XCTAssertFalse(rich.isPlainTextOnly)

        let additionalData = item(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Hello".utf8)),
            .init(typeIdentifier: "com.example.custom-content", data: Data([1])),
        ])
        XCTAssertFalse(additionalData.isPlainTextOnly)

        let alternateTextType = item(representations: [
            .init(typeIdentifier: "public.utf16-plain-text", data: Data([0, 72])),
        ])
        XCTAssertFalse(alternateTextType.isPlainTextOnly)

        let multipleItems = ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                .init(representations: [
                    .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("First".utf8)),
                ]),
                .init(representations: [
                    .init(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("Second".utf8)),
                ]),
            ]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        XCTAssertFalse(multipleItems.isPlainTextOnly)
        XCTAssertEqual(multipleItems.representationTypeIdentifiers, plain.representationTypeIdentifiers)
    }

    private func item(representations: [ClipboardStoredRepresentation]) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [
                ClipboardStoredPasteboardItem(representations: representations),
            ]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
    }
}
