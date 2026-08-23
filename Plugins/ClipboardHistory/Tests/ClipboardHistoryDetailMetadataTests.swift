import AppKit
import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryDetailMetadataTests: XCTestCase {
    func testTextMetadataIncludesCharacterAndMultilineCounts() async {
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: "First\nSecond",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )

        let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item)

        XCTAssertEqual(metadata.values, [.characterCount(12), .lineCount(2)])
    }

    func testEmbeddedImageMetadataReadsFormatDimensionsAndStoredSize() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 3,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let payload = payload(
            typeIdentifier: ClipboardRepresentationType.png,
            data: data
        )
        let item = item(payload: payload)

        let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item)

        XCTAssertEqual(metadata.values.first, .format("PNG"))
        XCTAssertTrue(metadata.values.contains(.dimensions(width: 3, height: 2)))
        XCTAssertTrue(metadata.values.contains(.byteCount(Int64(payload.byteCount))))
    }

    func testFileMetadataCountsFilesAndSumsRegularFileSizesWithoutReadingContents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryDetailMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data([0x01, 0x02, 0x03]).write(to: first)
        try Data([0x04, 0x05, 0x06, 0x07]).write(to: second)
        let payload = ClipboardHistoryPayload(pasteboardItems: [first, second].map { url in
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(url.absoluteString.utf8)
                ),
            ])
        })

        let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item(payload: payload))

        XCTAssertEqual(metadata.values, [.fileCount(2), .byteCount(7)])
    }

    func testLinkMetadataUsesTheURLHost() async {
        let payload = payload(
            typeIdentifier: ClipboardRepresentationType.url,
            data: Data("https://github.com/ggbond268/MacTools".utf8)
        )

        let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item(payload: payload))

        XCTAssertEqual(metadata.values, [.host("github.com")])
    }

    private func item(payload: ClipboardHistoryPayload) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
    }

    private func payload(typeIdentifier: String, data: Data) -> ClipboardHistoryPayload {
        ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(typeIdentifier: typeIdentifier, data: data),
            ]),
        ])
    }
}
