import AppKit
import SwiftUI
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardRichTextPreviewAppearanceTests: XCTestCase {
    func testDefaultCanvasTracksAppAppearanceAndToggleCanResumeFollowingIt() {
        var selection = ClipboardRichTextCanvasSelection()
        XCTAssertEqual(selection.resolved(for: .light), .light)
        XCTAssertEqual(selection.resolved(for: .dark), .dark)
        selection.toggle(appCanvas: .dark)
        XCTAssertEqual(selection.resolved(for: .dark), .light)
        selection.toggle(appCanvas: .dark)
        XCTAssertNil(selection.override)
        XCTAssertEqual(selection.resolved(for: .light), .light)
        selection.toggle(appCanvas: .light)
        XCTAssertEqual(selection.resolved(for: .light), .dark)
    }

    func testExplicitBlackAndWhiteTextRemainReadableOnBothCanvases() throws {
        for foreground in [NSColor.black, .white, .gray, .clear] {
            let source = try attributed("Readable", attributes: [.foregroundColor: foreground])
            let document = ClipboardRichTextPreviewDocument(source)
            for canvas in [ClipboardRichTextCanvas.light, .dark] {
                let text = document.text(for: canvas)
                let rendered = try XCTUnwrap(text.runs.first?.appKit.foregroundColor)
                XCTAssertGreaterThanOrEqual(ClipboardRichTextPreviewColors.contrast(rendered, canvas.backgroundColor), 4.5)
                XCTAssertEqual(String(text.characters), "Readable")
            }
            XCTAssertEqual(source.runs.first?.appKit.foregroundColor, foreground, "Never mutate the source formatting")
        }
    }

    func testReadableColorsAndHighlightBackgroundsArePreserved() throws {
        let source = try attributed("Highlighted", attributes: [
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.yellow,
        ])
        for canvas in [ClipboardRichTextCanvas.light, .dark] {
            let text = ClipboardRichTextPreviewColors.adapt(source, to: canvas)
            XCTAssertEqual(text.runs.first?.appKit.foregroundColor, canvas.resolve(.black))
            XCTAssertEqual(text.runs.first?.appKit.backgroundColor, canvas.resolve(.yellow))
        }
        let blue = NSColor(srgbRed: 0, green: 0.2, blue: 0.65, alpha: 1)
        XCTAssertEqual(ClipboardRichTextPreviewColors.readable(blue, on: .white), blue)
    }

    func testLowContrastColorsKeepTheirHueWhileBecomingReadable() throws {
        let blue = NSColor(srgbRed: 0.02, green: 0.08, blue: 0.45, alpha: 1)
        let background = ClipboardRichTextCanvas.dark.backgroundColor
        let adjusted = try XCTUnwrap(ClipboardRichTextPreviewColors.readable(blue, on: background).usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(ClipboardRichTextPreviewColors.contrast(adjusted, background), 4.5)
        XCTAssertGreaterThan(adjusted.blueComponent, adjusted.greenComponent)
        XCTAssertGreaterThan(adjusted.greenComponent, adjusted.redComponent)
    }

    func testTranslucentBackgroundUsesTheCanvasWhenCheckingContrast() throws {
        let background = NSColor.white.withAlphaComponent(0.1)
        let source = try attributed("Translucent", attributes: [.foregroundColor: NSColor.black, .backgroundColor: background])
        let text = ClipboardRichTextPreviewColors.adapt(source, to: .dark)
        let adjusted = try XCTUnwrap(text.runs.first?.appKit.foregroundColor)
        XCTAssertNotEqual(adjusted, NSColor.black)
        XCTAssertEqual(text.runs.first?.appKit.backgroundColor?.alphaComponent, 0.1)
    }

    func testFontsLinksAndDecorationsSurviveAppearanceAdaptation() throws {
        let font = NSFont.boldSystemFont(ofSize: 18)
        let url = URL(string: "https://example.com/document")!
        let source = try attributed("Document", attributes: [
            .font: font, .link: url, .foregroundColor: NSColor.black,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.black,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.black,
        ])
        let result = ClipboardRichTextPreviewColors.adapt(source, to: .dark)
        let run = try XCTUnwrap(result.runs.first)
        let renderedFont = NSAttributedString(result).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(renderedFont, font)
        XCTAssertEqual(run.link, url)
        XCTAssertEqual(run.appKit.underlineStyle, .single)
        XCTAssertEqual(run.appKit.strikethroughStyle, .single)
        XCTAssertGreaterThanOrEqual(ClipboardRichTextPreviewColors.contrast(try XCTUnwrap(run.appKit.underlineColor), ClipboardRichTextCanvas.dark.backgroundColor), 4.5)
        XCTAssertGreaterThanOrEqual(ClipboardRichTextPreviewColors.contrast(try XCTUnwrap(run.appKit.strikethroughColor), ClipboardRichTextCanvas.dark.backgroundColor), 4.5)
    }

    func testPreparedVariantsPreserveEveryRunWhenSwitchingRepeatedly() throws {
        let source = NSMutableAttributedString(string: "Black Blue White")
        source.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: 6))
        source.addAttribute(.foregroundColor, value: NSColor.blue, range: NSRange(location: 6, length: 5))
        source.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 11, length: 5))
        let imported = try AttributedString(source, including: \.appKit)
        let document = ClipboardRichTextPreviewDocument(imported)
        for _ in 0..<10 {
            XCTAssertEqual(document.text(for: .light), document.light)
            XCTAssertEqual(document.text(for: .dark), document.dark)
            XCTAssertEqual(document.dark.runs.count, imported.runs.count)
            XCTAssertEqual(String(document.dark.characters), source.string)
        }
    }

    func testHTMLPreviewLoadSupportsFormattingAndBothAppearances() async throws {
        let html = "<html><body><b style='color:black'>Formatted HTML</b></body></html>"
        let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.html, data: Data(html.utf8)),
        ])])
        let item = ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: .now,
            sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        guard case let .formatted(document) = await ClipboardRichTextPreviewLoader.load(for: item, fallbackText: "Formatted HTML") else {
            return XCTFail("HTML should produce a formatted preview")
        }
        XCTAssertTrue(String(document.light.characters).contains("Formatted HTML"))
        XCTAssertEqual(String(document.light.characters), String(document.dark.characters))
    }

    private func attributed(_ text: String, attributes: [NSAttributedString.Key: Any]) throws -> AttributedString {
        try AttributedString(NSAttributedString(string: text, attributes: attributes), including: \.appKit)
    }
}
