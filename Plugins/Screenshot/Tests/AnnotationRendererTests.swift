import AppKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class AnnotationRendererTests: XCTestCase {

    func testCropClipsToSelectionAndImageAndConvertsRetinaCoordinates() throws {
        let source = try makeImage(width: 80, height: 60)
        let renderer = AnnotationRenderer(image: source, scale: 2, size: NSSize(width: 40, height: 30))
        let selection = NSRect(x: -5, y: 5, width: 35, height: 20)
        let (crop, rect) = try XCTUnwrap(renderer.crop(NSRect(x: -10, y: 10, width: 50, height: 30), selection: selection))
        XCTAssertTrue(rect == NSRect(x: 0, y: 10, width: 30, height: 15))
        XCTAssertTrue(crop.width == 60)
        XCTAssertTrue(crop.height == 30)
        let original = NSBitmapImageRep(cgImage: source)
        let cropped = NSBitmapImageRep(cgImage: crop)
        XCTAssertTrue(cropped.colorAt(x: 0, y: 0) == original.colorAt(x: 0, y: 10))
        XCTAssertTrue(cropped.colorAt(x: 59, y: 29) == original.colorAt(x: 59, y: 39))
        XCTAssertTrue(renderer.crop(.zero, selection: selection) == nil)
        XCTAssertTrue(renderer.crop(NSRect(x: 50, y: 50, width: 10, height: 10), selection: selection) == nil)
    }

    func testExportPreservesRetinaPixelsLogicalSizeAndImageOrientation() throws {
        let source = try makeImage(width: 160, height: 120)
        let renderer = AnnotationRenderer(image: source, scale: 2, size: NSSize(width: 80, height: 60))
        let selection = NSRect(x: 10, y: 5, width: 40, height: 30)
        let png = try XCTUnwrap(renderer.render(selection: selection, items: [], radius: 0, shadowSize: 0, shadowColor: .black))
        let result = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertTrue(result.pixelsWide == 80)
        XCTAssertTrue(result.pixelsHigh == 60)
        XCTAssertTrue(abs(result.size.width - 40) <= 0.01)
        XCTAssertTrue(abs(result.size.height - 30) <= 0.01)
        let original = NSBitmapImageRep(cgImage: source)
        for (x, y) in [(5, 5), (70, 50)] {
            let actual = try XCTUnwrap(result.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let expected = try XCTUnwrap(original.colorAt(x: x + 20, y: y + 50)?.usingColorSpace(.sRGB))
            XCTAssertTrue(abs(actual.redComponent - expected.redComponent) <= 0.02)
            XCTAssertTrue(abs(actual.greenComponent - expected.greenComponent) <= 0.02)
            XCTAssertTrue(abs(actual.blueComponent - expected.blueComponent) <= 0.02)
        }
        XCTAssertTrue(renderer.render(selection: .zero, items: [], radius: 0, shadowSize: 10, shadowColor: .black) == nil)
    }

    func testRoundedCornersStayTransparentAndShadowGetsMargin() throws {
        let source = try makeImage(width: 160, height: 160)
        let renderer = AnnotationRenderer(image: source, scale: 2, size: NSSize(width: 80, height: 80))
        let selection = NSRect(x: 10, y: 10, width: 60, height: 60)
        let rounded = try XCTUnwrap(renderer.render(selection: selection, items: [], radius: 12, shadowSize: 0, shadowColor: .black))
        let plain = try XCTUnwrap(NSBitmapImageRep(data: rounded))
        XCTAssertTrue(try XCTUnwrap(plain.colorAt(x: 0, y: 0)).alphaComponent == 0)
        XCTAssertTrue(try XCTUnwrap(plain.colorAt(x: 60, y: 60)).alphaComponent == 1)

        let png = try XCTUnwrap(renderer.render(selection: selection, items: [], radius: 12, shadowSize: 6, shadowColor: .black))
        let shadowed = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertTrue(AnnotationRenderer.shadowMargin(for: 0) == 0)
        XCTAssertTrue(AnnotationRenderer.shadowMargin(for: 6) == 14)
        XCTAssertTrue(shadowed.pixelsWide == 176)
        XCTAssertTrue(shadowed.pixelsHigh == 176)
        XCTAssertTrue(abs(shadowed.size.width - 88) <= 0.01)
        XCTAssertTrue(try XCTUnwrap(shadowed.colorAt(x: 0, y: 0)).alphaComponent < 0.01)
        XCTAssertTrue(try XCTUnwrap(shadowed.colorAt(x: 26, y: 88)).alphaComponent > 0)
        XCTAssertTrue(try XCTUnwrap(shadowed.colorAt(x: 88, y: 88)).alphaComponent == 1)
    }

    func testPreviewAndExportShareAnnotationsAndCacheDoesNotChangeResult() throws {
        let source = try makeImage(width: 160, height: 160)
        let size = NSSize(width: 160, height: 160)
        let selection = NSRect(origin: .zero, size: size)
        let renderer = AnnotationRenderer(image: source, scale: 1, size: size)
        let stroke = Stroke(color: .red, width: 4)
        let shapes: [Shape] = [
            .rect(NSRect(x: 10, y: 90, width: 20, height: 20)),
            .ellipse(NSRect(x: 40, y: 90, width: 20, height: 20)),
            .line(from: NSPoint(x: 70, y: 90), to: NSPoint(x: 100, y: 110)),
            .arrow(from: NSPoint(x: 110, y: 90), to: NSPoint(x: 145, y: 110)),
            .pen([NSPoint(x: 10, y: 120), NSPoint(x: 30, y: 145), NSPoint(x: 50, y: 130)]),
            .pen([]),
            .text("Snap", at: NSPoint(x: 70, y: 125)),
            .tag(1, at: NSPoint(x: 135, y: 135)),
            .mosaic(NSRect(x: 10, y: 10, width: 60, height: 60)),
            .blur(NSRect(x: 80, y: 10, width: 60, height: 60)),
        ]
        let items = shapes.map { Item(shape: $0, stroke: stroke) }
        let draft = Item(shape: .line(from: NSPoint(x: 10, y: 80), to: NSPoint(x: 140, y: 80)),
                         stroke: Stroke(color: .blue, width: 4))
        let exported = try XCTUnwrap(renderer.render(selection: selection, items: items, draft: draft,
                                                    radius: 0, shadowSize: 0, shadowColor: .black))
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSImage(cgImage: source, size: size).draw(in: selection)
        renderer.drawItems(items, draft: draft, selection: selection)
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        XCTAssertTrue(rep.representation(using: .png, properties: [:]) == exported)

        let result = try XCTUnwrap(NSBitmapImageRep(data: exported))
        let lineColor = try XCTUnwrap(result.colorAt(x: 75, y: 80)?.usingColorSpace(.deviceRGB))
        XCTAssertTrue(lineColor.blueComponent > 0.9)
        XCTAssertTrue(lineColor.redComponent < 0.1)
        renderer.clearCache()
        XCTAssertTrue(renderer.render(selection: selection, items: items, draft: draft,
                                radius: 0, shadowSize: 0, shadowColor: .black) == exported)
    }

    func testStrokeWidthsSelectExistingFontSizes() {
        XCTAssertTrue(Stroke(color: .red, width: 2).fontSize == 14)
        XCTAssertTrue(Stroke(color: .red, width: 4).fontSize == 18)
        XCTAssertTrue(Stroke(color: .red, width: 6).fontSize == 24)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(x * 255 / width)
                pixels[offset + 1] = UInt8(y * 255 / height)
                pixels[offset + 2] = UInt8((x + y) % 256)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))

        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
