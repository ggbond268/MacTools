import AppKit
import XCTest
@testable import ScreenshotPlugin

final class CaptureRegionTests: XCTestCase {
    private let display = CaptureDisplay(id: 7, frame: CGRect(x: -500, y: 0, width: 500, height: 1000),
                                         captureRect: CGRect(x: -500, y: 0, width: 500, height: 1000), scale: 2)

    func testFractionalRetinaSelectionKeepsTheExactPixelRegion() throws {
        let region = try CaptureRegion(selection: CGRect(x: 10.5, y: 10.5, width: 100, height: 100), display: display)
        XCTAssertEqual(region.sourceRect, CGRect(x: 10.5, y: 889.5, width: 100, height: 100))
        XCTAssertEqual(region.width, 200)
        XCTAssertEqual(region.height, 200)
        XCTAssertEqual(region.globalRect, CGRect(x: -489.5, y: 10.5, width: 100, height: 100))
    }

    func testSelectionIsClippedBeforePixelAlignment() throws {
        let region = try CaptureRegion(selection: CGRect(x: -10, y: 980.25, width: 100, height: 100), display: display)
        XCTAssertEqual(region.sourceRect, CGRect(x: 0, y: 0, width: 90, height: 20))
        XCTAssertEqual(region.width, 180)
        XCTAssertEqual(region.height, 40)
    }

    func testDisplayIDAloneCannotValidateAChangedScale() throws {
        let region = try CaptureRegion(selection: CGRect(x: 0, y: 0, width: 100, height: 100), display: display)
        let changed = CaptureDisplay(id: display.id, frame: display.frame, captureRect: display.captureRect, scale: 1)
        XCTAssertThrowsError(try region.validate(displays: [changed]))
        XCTAssertNoThrow(try region.validate(displays: [changed, display]))
    }

    func testInvalidAndOffscreenSelectionsAreRejected() {
        XCTAssertThrowsError(try CaptureRegion(selection: .zero, display: display))
        XCTAssertThrowsError(try CaptureRegion(selection: CGRect(x: 600, y: 0, width: 100, height: 100), display: display))
        XCTAssertThrowsError(try CaptureRegion(selection: CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), display: display))
    }

    func testFullScreenControlsStayInsideTheTargetDisplay() {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        for selection in [screen, CGRect(x: -1800, y: -1070, width: 1700, height: 1050)] {
            let frame = CaptureControlPlacement.frame(size: CGSize(width: 350, height: 40), near: selection, visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame))
        }
    }
}
