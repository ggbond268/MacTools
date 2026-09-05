import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardColorPreviewTests: XCTestCase {
    func testHexParsingSupportsRGBAndAlphaForms() throws {
        for (input, expected) in [("#fff", "#FFFFFF"), (" #0aF\n", "#00AAFF"), ("#1234", "#11223344"), ("#fff000", "#FFF000"), ("#12345678", "#12345678"), ("#0000", "#00000000")] {
            XCTAssertEqual(try XCTUnwrap(ClipboardColorValue(hex: input)).hex, expected)
        }
        let value = try XCTUnwrap(ClipboardColorValue(hex: "#f008"))
        XCTAssertEqual(value.red, 1)
        XCTAssertEqual(value.green, 0)
        XCTAssertEqual(value.alpha, 136.0 / 255, accuracy: 0.0001)
    }

    func testHexParsingRejectsProseAndMalformedValues() {
        for input in ["", "fff", "#12", "#12345", "#1234567", "#123456789", "#ggg", "#fff text", "color: #fff", "#fff\n#000", "(#fff)", "#１２３"] {
            XCTAssertNil(ClipboardColorValue(hex: input), input)
        }
    }

    func testNativeColorArchiveAndInvalidPayloads() throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5),
            requiringSecureCoding: true
        )
        XCTAssertEqual(try XCTUnwrap(ClipboardColorValue.decodeNative(data)).hex, "#FF000080")
        XCTAssertNil(ClipboardColorValue.decodeNative(Data([1, 2, 3])))
        XCTAssertNil(ClipboardColorValue.decodeNative(Data(repeating: 0, count: 1_024 * 1_024 + 1)))
    }

    func testNativePasteboardRepresentationDecodesWithoutAccessingTheClipboard() throws {
        let native = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let data = try XCTUnwrap(native.pasteboardPropertyList(forType: .color) as? Data)
        XCTAssertEqual(try XCTUnwrap(ClipboardColorValue.decodeNative(data)).hex, "#00FF00")
    }

    func testImagesWithTextRepresentationsAreNotLiteralColorPreviews() {
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: ClipboardHistoryPayload(pasteboardItems: [ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.png, data: Data([1])),
                ClipboardStoredRepresentation(typeIdentifier: ClipboardRepresentationType.plainText, data: Data("#fff".utf8)),
            ])]),
            capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil
        )
        XCTAssertNil(ClipboardColorValue.literal(for: item))
        XCTAssertFalse(ClipboardHistoryContentFilter.color.matches(item))
    }

    @MainActor
    func testColorCanvasAndSwatchDoNotChangeWithAppearance() throws {
        for literal in ["#fff", "#000", "#f008"] {
            let value = try XCTUnwrap(ClipboardColorValue(hex: literal))
            var samples: [[NSColor]] = []
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: ClipboardColorSwatchView(
                    value: value, localization: PluginLocalization(bundle: Bundle(for: Self.self))
                ).frame(width: 320, height: 280).environment(\.colorScheme, scheme))
                renderer.scale = 1
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                samples.append(try [(20, 80), (160, 140)].map { x, y in
                    try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                })
            }
            for index in 0..<2 {
                XCTAssertEqual(samples[0][index].redComponent, samples[1][index].redComponent, accuracy: 0.005)
                XCTAssertEqual(samples[0][index].greenComponent, samples[1][index].greenComponent, accuracy: 0.005)
                XCTAssertEqual(samples[0][index].blueComponent, samples[1][index].blueComponent, accuracy: 0.005)
            }
            // The renderer's color profile can change the numeric gray value;
            // neutrality and appearance independence are the visual contract.
            let canvas = samples[0][0]
            XCTAssertEqual(canvas.redComponent, canvas.greenComponent, accuracy: 0.005)
            XCTAssertEqual(canvas.greenComponent, canvas.blueComponent, accuracy: 0.005)
            XCTAssertGreaterThan(canvas.redComponent, 0.3)
            XCTAssertLessThan(canvas.redComponent, 0.7)
            if literal == "#fff" {
                XCTAssertGreaterThan(samples[0][1].redComponent, 0.95)
            } else if literal == "#000" {
                XCTAssertLessThan(samples[0][1].redComponent, 0.05)
            }
        }
    }
}
