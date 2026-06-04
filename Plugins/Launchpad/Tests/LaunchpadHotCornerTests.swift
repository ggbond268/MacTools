import XCTest
@testable import MacTools
@testable import LaunchpadPlugin

final class LaunchpadHotCornerTests: XCTestCase {
    // Screen coords: bottom-left origin, y up.
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let t: CGFloat = 4

    private func hit(_ p: CGPoint, _ c: LaunchpadPreferences.HotCorner) -> Bool {
        LaunchpadHotCornerMonitor.isInCorner(p, corner: c, screenFrame: frame, threshold: t)
    }

    func testCornersHit() {
        XCTAssertTrue(hit(CGPoint(x: 2, y: 798), .topLeft))       // top-left = (minX, maxY)
        XCTAssertTrue(hit(CGPoint(x: 998, y: 798), .topRight))
        XCTAssertTrue(hit(CGPoint(x: 2, y: 2), .bottomLeft))
        XCTAssertTrue(hit(CGPoint(x: 998, y: 2), .bottomRight))
    }

    func testNearEdgeButWrongAxisMisses() {
        XCTAssertFalse(hit(CGPoint(x: 2, y: 400), .topLeft))      // near left edge, not top
        XCTAssertFalse(hit(CGPoint(x: 500, y: 798), .topLeft))    // near top edge, not left
    }

    func testWrongCornerMisses() {
        XCTAssertFalse(hit(CGPoint(x: 2, y: 798), .bottomLeft))   // it's top-left, not bottom-left
        XCTAssertFalse(hit(CGPoint(x: 2, y: 798), .topRight))
    }

    func testCenterMissesAll() {
        let center = CGPoint(x: 500, y: 400)
        for corner in LaunchpadPreferences.HotCorner.allCases {
            XCTAssertFalse(hit(center, corner))
        }
    }

    func testOffNeverHits() {
        XCTAssertFalse(hit(CGPoint(x: 0, y: 800), .off))
    }

    func testNegativeOriginScreen() {
        // Secondary display to the left of main (negative x).
        let secondary = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        XCTAssertTrue(LaunchpadHotCornerMonitor.isInCorner(
            CGPoint(x: -998, y: 798), corner: .topLeft, screenFrame: secondary, threshold: t))
        XCTAssertTrue(LaunchpadHotCornerMonitor.isInCorner(
            CGPoint(x: -2, y: 2), corner: .bottomRight, screenFrame: secondary, threshold: t))
    }

    // Regression for the pause/resume restart bug (Codex P1): a non-`.off` re-apply after
    // `stop()` must restart the poll — the old `guard corner != self.corner` early-return broke it.
    @MainActor
    func testUpdateRestartsPollAfterStop() {
        let monitor = LaunchpadHotCornerMonitor()
        XCTAssertFalse(monitor.isPolling)
        monitor.update(corner: .topLeft)
        XCTAssertTrue(monitor.isPolling)
        monitor.stop()
        XCTAssertFalse(monitor.isPolling)
        monitor.update(corner: .topLeft)        // same value as before stop → must still restart
        XCTAssertTrue(monitor.isPolling)
        monitor.update(corner: .off)
        XCTAssertFalse(monitor.isPolling)
        monitor.stop()                           // cleanup
    }
}
