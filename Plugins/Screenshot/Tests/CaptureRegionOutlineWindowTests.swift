import AppKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class CaptureRegionOutlineWindowTests: XCTestCase {
    private let display = CaptureDisplay(id: 7, frame: CGRect(x: -500, y: -200, width: 500, height: 400),
                                         captureRect: CGRect(x: -500, y: 0, width: 500, height: 400), scale: 2)

    func testRegionOutlineStaysHiddenAndDoesNotInterceptInput() throws {
        let region = try CaptureRegion(selection: CGRect(x: 40, y: 50, width: 200, height: 100), display: display)
        let outline = CaptureRegionOutlineWindow(region: region)
        defer { outline.orderOut(nil) }
        XCTAssertEqual(outline.frame, region.globalRect.insetBy(dx: -3, dy: -3))
        XCTAssertFalse(outline.isVisible)
        XCTAssertTrue(outline.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(outline.ignoresMouseEvents)
        XCTAssertFalse(outline.canBecomeKey)
        XCTAssertFalse(outline.canBecomeMain)
        XCTAssertFalse(outline.hidesOnDeactivate)
        XCTAssertFalse(outline.hasShadow)
        XCTAssertFalse(outline.isOpaque)
        XCTAssertEqual(outline.animationBehavior, .none)
    }

    func testScreenEdgeAndFullScreenOutlinesRemainInsideTheSelectedDisplay() throws {
        for selection in [CGRect(origin: .zero, size: display.frame.size),
                          CGRect(x: 0, y: 0, width: 100, height: 100),
                          CGRect(x: 400, y: 300, width: 100, height: 100)] {
            let region = try CaptureRegion(selection: selection, display: display)
            let outline = CaptureRegionOutlineWindow(region: region)
            defer { outline.orderOut(nil) }
            XCTAssertTrue(display.frame.contains(outline.frame))
            XCTAssertTrue(outline.frame.contains(region.globalRect))
            XCTAssertEqual(outline.frame, region.globalRect.insetBy(dx: -3, dy: -3).intersection(display.frame))
        }
    }

    func testOutlineDrawsOnlyItsBorder() throws {
        let region = try CaptureRegion(selection: CGRect(x: 40, y: 50, width: 200, height: 100), display: display)
        let outline = CaptureRegionOutlineWindow(region: region)
        defer { outline.orderOut(nil) }
        let view = try XCTUnwrap(outline.contentView)
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(view.bounds)
        view.draw(view.bounds)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: width / 2, y: height / 2)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 1, y: height / 2)).alphaComponent, 0.9)
    }

    func testOutlineAndStatusPanelMustBothBeResolvedForCaptureExclusion() throws {
        let region = try CaptureRegion(selection: CGRect(x: 40, y: 50, width: 200, height: 100), display: display)
        let outline = CaptureRegionOutlineWindow(region: region)
        let panel = CaptureStatusPanel(primaryTitle: "Stop")
        let controls = CaptureControls([outline, panel])
        defer { controls.hide() }
        controls.prepare()
        let outlineID = CGWindowID(outline.windowNumber), panelID = CGWindowID(panel.windowNumber)
        XCTAssertThrowsError(try controls.windowIDs(available: [panelID]))
        XCTAssertEqual(try controls.windowIDs(available: [outlineID, panelID]), [outlineID, panelID])
        XCTAssertFalse(outline.isVisible)
        XCTAssertFalse(panel.isVisible)
    }
}
