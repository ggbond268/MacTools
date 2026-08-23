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

    func testEmbeddedPreviewDecodesOffTheCallerAndReleasesReloadablePayload() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 3,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let payload = payload(typeIdentifier: ClipboardRepresentationType.png, data: data)
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: "",
            capturedAt: Date(),
            sourceApplication: nil,
            kind: .image,
            payloadByteCount: payload.byteCount,
            filterContentKinds: [.image],
            fileURLs: [],
            representationTypeIdentifiers: [ClipboardRepresentationType.png],
            payloadDigest: Data("preview".utf8),
            allowsRichTextImport: false,
            textCharacterCount: 0,
            textLineCount: 0,
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: nil,
            hasCompletedImageTextIndexing: false,
            payloadLoader: { payload }
        )

        XCTAssertNil(item.payload)
        let preview = await ClipboardEmbeddedPreviewLoader.load(for: item)
        XCTAssertNotNil(preview)
        XCTAssertNil(item.payload)
    }

    func testEmbeddedPreviewPolicyRejectsExtremeImageAndPDFSources() {
        XCTAssertTrue(ClipboardEmbeddedPreviewPolicy.allowsImageSourceDimensions(
            width: 8_000,
            height: 8_000
        ))
        XCTAssertFalse(ClipboardEmbeddedPreviewPolicy.allowsImageSourceDimensions(
            width: 8_001,
            height: 8_000
        ))
        XCTAssertTrue(ClipboardEmbeddedPreviewPolicy.allowsPDF(
            pageCount: 1,
            mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792)
        ))
        XCTAssertFalse(ClipboardEmbeddedPreviewPolicy.allowsPDF(
            pageCount: ClipboardEmbeddedPreviewPolicy.maximumPDFPageCount + 1,
            mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792)
        ))
        XCTAssertFalse(ClipboardEmbeddedPreviewPolicy.allowsPDF(
            pageCount: 1,
            mediaBox: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(VisionClipboardImageTextRecognizer.maximumSourceDimension + 1),
                height: 1
            )
        ))
    }

    func testEmbeddedPDFPreviewUsesBoundedRenderer() async throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 10, y: 10, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        let item = item(payload: payload(
            typeIdentifier: ClipboardRepresentationType.pdf,
            data: data as Data
        ))

        let preview = await ClipboardEmbeddedPreviewLoader.load(for: item)

        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview?.size.width ?? .infinity, 1_600)
        XCTAssertLessThanOrEqual(preview?.size.height ?? .infinity, 1_600)
    }

    func testCancelledEmbeddedPreviewReleasesPayloadAndReturnsNoImage() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let payload = payload(typeIdentifier: ClipboardRepresentationType.png, data: Data([0x01]))
        let item = lazyItem(kind: .image, payload: payload) {
            started.signal()
            release.wait()
        }
        let task = Task { await ClipboardEmbeddedPreviewLoader.load(for: item) }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        task.cancel()
        release.signal()

        let image = await task.value
        XCTAssertNil(image)
        XCTAssertNil(item.payload)
    }

    func testCancelledRichTextPreviewDoesNotRepopulatePayloadCache() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let payload = payload(
            typeIdentifier: ClipboardRepresentationType.rtf,
            data: Data("{\\rtf1 Private preview}".utf8)
        )
        let item = lazyItem(kind: .richText, payload: payload) {
            started.signal()
            release.wait()
        }
        let task = Task {
            await ClipboardRichTextPreviewLoader.load(for: item, fallbackText: "Private preview")
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        task.cancel()
        release.signal()
        _ = await task.value

        XCTAssertNil(item.payload)
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

    func testGroupedFilePresentationBoundsVisibleRows() {
        let urls = (0..<150).map { URL(fileURLWithPath: "/tmp/file-\($0)") }

        let visible = ClipboardFileReferencePresentation.visibleURLs(from: urls)

        XCTAssertEqual(visible.count, 100)
        XCTAssertEqual(visible.first, urls.first)
        XCTAssertEqual(visible.last, urls[99])
        XCTAssertEqual(ClipboardFileReferencePresentation.remainingCount(for: urls), 50)
    }

    func testFileAvailabilityLoadsOutsidePanelRendering() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardFileAvailability-\(UUID().uuidString)")
        try Data().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let isAvailable = await ClipboardFileAvailabilityCache.shared.isAvailable(url)

        XCTAssertTrue(isAvailable)
    }

    func testLinkMetadataUsesTheURLHost() async {
        let payload = payload(
            typeIdentifier: ClipboardRepresentationType.url,
            data: Data("https://github.com/ggbond268/MacTools".utf8)
        )

        let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item(payload: payload))

        XCTAssertEqual(metadata.values, [.host("github.com")])
    }

    func testLinkMetadataAndPlainTextUseDurableURLWhenPayloadIsUnavailable() async {
        let url = try! XCTUnwrap(URL(string: "https://example.com/private/path"))
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: url.absoluteString,
            capturedAt: Date(),
            sourceApplication: nil,
            kind: .link,
            payloadByteCount: 100,
            filterContentKinds: [.link],
            fileURLs: [],
            linkURLs: [url],
            representationTypeIdentifiers: [ClipboardRepresentationType.url],
            payloadDigest: Data("link".utf8),
            allowsRichTextImport: false,
            textCharacterCount: url.absoluteString.count,
            textLineCount: 1,
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: nil,
            hasCompletedImageTextIndexing: false,
            payloadLoader: { throw ClipboardHistoryPayloadAccessError.unavailable }
        )

        let metadata = await ClipboardHistoryDetailMetadataLoader.load(for: item)
        XCTAssertEqual(metadata.values, [.host("example.com")])
        XCTAssertEqual(ClipboardPlainTextConversion.text(for: item), url.absoluteString)
        XCTAssertEqual(ClipboardHistorySearch.filter([item], query: "example private"), [item])
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

    private func lazyItem(
        kind: ClipboardHistoryContentKind,
        payload: ClipboardHistoryPayload,
        beforeReturningPayload: @escaping @Sendable () -> Void
    ) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: "",
            capturedAt: Date(),
            sourceApplication: nil,
            kind: kind,
            payloadByteCount: payload.byteCount,
            filterContentKinds: [kind],
            fileURLs: [],
            representationTypeIdentifiers: payload.representations.map(\.typeIdentifier),
            payloadDigest: Data("lazy-preview".utf8),
            allowsRichTextImport: kind == .richText,
            textCharacterCount: 0,
            textLineCount: 0,
            isSearchTextTruncated: false,
            isPinned: false,
            lastUsedAt: nil,
            imageSearchText: nil,
            hasCompletedImageTextIndexing: false,
            payloadLoader: {
                beforeReturningPayload()
                return payload
            }
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
