import AppKit
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardImageTextRecognizerTests: XCTestCase {
    func testSourceDimensionPolicyRejectsPixelBombsAndOverflow() {
        XCTAssertTrue(VisionClipboardImageTextRecognizer.allowsSourceDimensions(
            width: 8_000,
            height: 8_000
        ))
        XCTAssertFalse(VisionClipboardImageTextRecognizer.allowsSourceDimensions(
            width: 8_001,
            height: 8_000
        ))
        XCTAssertFalse(VisionClipboardImageTextRecognizer.allowsSourceDimensions(
            width: VisionClipboardImageTextRecognizer.maximumSourceDimension + 1,
            height: 1
        ))
        XCTAssertFalse(VisionClipboardImageTextRecognizer.allowsSourceDimensions(
            width: Int.max,
            height: 2
        ))
        XCTAssertFalse(VisionClipboardImageTextRecognizer.allowsSourceDimensions(
            width: 0,
            height: 1
        ))
    }

    func testMalformedImageReturnsNoText() async {
        let payload = imagePayload(data: Data("not an image".utf8))

        let text = await VisionClipboardImageTextRecognizer().recognizeText(in: payload)
        XCTAssertNil(text)
    }

    func testCancelledRecognitionReturnsNoText() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let task = Task {
            await VisionClipboardImageTextRecognizer().recognizeText(in: imagePayload(data: data))
        }
        task.cancel()

        let text = await task.value
        XCTAssertNil(text)
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
