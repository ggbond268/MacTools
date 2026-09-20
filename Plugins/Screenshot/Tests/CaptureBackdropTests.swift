import AppKit
import MacToolsPluginKit
import QuartzCore
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class CaptureBackdropTests: XCTestCase {
    func testSelectionChangesKeepTheOriginalImageWithoutAnimations() throws {
        let bounds = CGRect(x: 0, y: 0, width: 16, height: 12)
        let root = CALayer()
        root.frame = bounds
        let backdrop = CaptureBackdrop(parent: root)
        let image = try fixture()
        backdrop.prepare(image: image, bounds: bounds, scale: 2)
        for x in 0..<8 {
            backdrop.update(bounds: bounds, selection: CGRect(x: x, y: 2, width: 4, height: 6), radius: 1)
        }
        XCTAssertTrue((backdrop.imageLayer.contents as AnyObject?) === image)
        XCTAssertEqual(backdrop.imageLayer.contentsScale, 2)
        XCTAssertTrue(backdrop.imageLayer.animationKeys()?.isEmpty ?? true)
        XCTAssertTrue(backdrop.dimLayer.animationKeys()?.isEmpty ?? true)
        backdrop.clear()
        XCTAssertNil(backdrop.imageLayer.contents)
        XCTAssertNil(backdrop.dimLayer.path)
    }

    func testCompositorKeepsSelectedColorsAndOrientationAndDimsOtherPixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        let root = CALayer()
        root.frame = bounds
        let backdrop = CaptureBackdrop(parent: root)
        backdrop.prepare(image: try fixture(), bounds: bounds, scale: 1)
        backdrop.update(bounds: bounds, selection: CGRect(x: 4, y: 2, width: 24, height: 20), radius: 0)
        let context = try bitmap()
        root.render(in: context)
        let output = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        // Bitmap rows start at the top; layer/view coordinates start at the bottom.
        let top = try XCTUnwrap(output.colorAt(x: 16, y: 5)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(output.colorAt(x: 16, y: 19)?.usingColorSpace(.sRGB))
        let dimmed = try XCTUnwrap(output.colorAt(x: 1, y: 5)?.usingColorSpace(.sRGB))
        XCTAssertEqual(top.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(top.blueComponent, 0, accuracy: 0.01)
        XCTAssertEqual(bottom.blueComponent, 1, accuracy: 0.01)
        XCTAssertLessThan(dimmed.redComponent, top.redComponent - 0.2)
        XCTAssertEqual(dimmed.alphaComponent, 1, accuracy: 0.01)
    }

    func testPointerMovementInsideTheSameTargetDoesNotReplaceTheMaskPath() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        let selection = CGRect(x: 4, y: 2, width: 24, height: 20)
        let backdrop = CaptureBackdrop(parent: CALayer())
        backdrop.prepare(image: try fixture(), bounds: bounds, scale: 1)
        backdrop.update(bounds: bounds, selection: selection, radius: 0)
        let path = backdrop.dimLayer.path
        for _ in 0..<100 { backdrop.update(bounds: bounds, selection: selection, radius: 0) }
        XCTAssertTrue(backdrop.dimLayer.path === path)
    }

    func testSelectionChromeReusesGeometryWithoutAnimatingOrCoveringSelectedPixels() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        let parent = CALayer()
        parent.frame = bounds
        let chrome = CaptureSelectionChrome(parent: parent)
        let rect = CGRect(x: 8, y: 6, width: 16, height: 12)
        chrome.update(bounds: bounds, selection: rect, radius: 2, shadowSize: 4, shadowColor: .black, scale: 1)
        let border = chrome.inner.path
        let shadow = chrome.shadow.shadowPath
        for _ in 0..<100 {
            chrome.update(bounds: bounds, selection: rect, radius: 2, shadowSize: 4, shadowColor: .black, scale: 1)
        }
        XCTAssertTrue(chrome.inner.path === border)
        XCTAssertTrue(chrome.shadow.shadowPath === shadow)
        for layer in [chrome.root, chrome.shadow, chrome.inner, chrome.outer] {
            XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true)
        }
        XCTAssertEqual(chrome.shadow.shadowRadius, 4)
        XCTAssertEqual(chrome.shadow.shadowOpacity, 0.5)
        XCTAssertFalse(chrome.shadow.isHidden)
        let mask = try XCTUnwrap(chrome.shadow.mask as? CAShapeLayer)
        XCTAssertEqual(mask.fillRule, .evenOdd)
        let maskPath = try XCTUnwrap(mask.path)
        XCTAssertFalse(maskPath.contains(NSPoint(x: 16, y: 12), using: .evenOdd))
        XCTAssertTrue(maskPath.contains(NSPoint(x: 16, y: 4), using: .evenOdd))
        let context = try bitmap()
        parent.render(in: context)
        let output = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(try XCTUnwrap(output.colorAt(x: 16, y: 12)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(output.colorAt(x: 16, y: 18)).alphaComponent, 0)
        chrome.clear()
        XCTAssertTrue(chrome.root.isHidden)
        XCTAssertNil(chrome.inner.path)
        XCTAssertNil(chrome.shadow.shadowPath)
    }

    func testMagnifierKeepsImageOrientationAndColorAtScreenEdges() throws {
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(
            pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let magnifier = CaptureMagnifierView(environment: environment)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(magnifier)
        magnifier.prepare(image: try fixture(), size: NSSize(width: 32, height: 24))
        defer { magnifier.clear(); window.close() }
        XCTAssertEqual(magnifier.color(at: NSPoint(x: 16, y: 24))?.hex, "#FF0000")
        XCTAssertEqual(magnifier.color(at: NSPoint(x: 16, y: 0))?.hex, "#0000FF")
        magnifier.update(at: NSPoint(x: 16, y: 18), format: .rgb,
                         in: NSRect(x: 0, y: 0, width: 800, height: 600))
        let context = try XCTUnwrap(CGContext(data: nil, width: 140, height: 216, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        magnifier.draw(magnifier.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let output = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let top = try XCTUnwrap(output.colorAt(x: 40, y: 40)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(output.colorAt(x: 40, y: 130)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9)
        XCTAssertGreaterThan(bottom.blueComponent, 0.9)
        let rgbPixels = try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data
        magnifier.update(at: NSPoint(x: 16, y: 18), format: .rgb,
                         in: NSRect(x: 0, y: 0, width: 800, height: 600))
        magnifier.update(at: NSPoint(x: 16, y: 18), format: .hex,
                         in: NSRect(x: 0, y: 0, width: 800, height: 600))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        magnifier.draw(magnifier.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let hexPixels = try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data
        XCTAssertNotEqual(rgbPixels, hexPixels)
    }

    func testMagnifierPlacementStaysInsideEachCornerOfTheDisplay() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = NSSize(width: 140, height: 216)
        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 600),
                      NSPoint(x: 800, y: 0), NSPoint(x: 800, y: 600)] {
            let origin = CaptureMagnifierView.placement(at: point, size: size, in: bounds)
            XCTAssertTrue(bounds.contains(NSRect(origin: origin, size: size)))
        }
    }

    private func fixture() throws -> CGImage {
        let context = try bitmap()
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 12))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 12, width: 32, height: 12))
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
