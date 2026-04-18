import XCTest
@testable import MacTools

@MainActor
final class HideNotchDesktopMaskGeometryTests: XCTestCase {
    func testMaskFramePinsBlackBarToTopEdgeUsingNotchHeight() {
        let display = makeHideNotchDisplayRecord(
            id: 6,
            displayIdentifier: "BUILTIN-GEOMETRY",
            frame: CGRect(x: 40, y: 20, width: 1512, height: 982),
            notchHeightPoints: 42
        ).context

        let frame = HideNotchDesktopMaskManager.maskFrame(for: display)

        XCTAssertEqual(frame.origin.x, 40)
        XCTAssertEqual(frame.origin.y, 960)
        XCTAssertEqual(frame.width, 1512)
        XCTAssertEqual(frame.height, 42)
    }

    func testMaskFrameIsEmptyWhenNotchHeightIsZero() {
        let display = makeHideNotchDisplayRecord(
            id: 7,
            displayIdentifier: "BUILTIN-ZERO",
            notchHeightPoints: 0
        ).context

        XCTAssertEqual(HideNotchDesktopMaskManager.maskFrame(for: display), .zero)
    }
}
