import AppKit
import XCTest
@testable import MacTools

/// Pure-function coverage for the macOS 27 secondary-click event tap hit test.
///
/// The CLICK locations mirror the on-device facts from 26A5353q: the menu bar
/// band sits at CG y≈17…22 (origin top-left, y down) and our icon click lands
/// at x≈1438 (built-in) or x≈2330 (external display). The CG location must flip
/// to AppKit global coordinates (origin bottom-left, y up) before it can be
/// compared against the status item button window frame, which is AppKit-global.
///
/// NOTE on the FRAME inputs below: the "healthy" frames (x≈1430…1480,
/// y≈960…982) are FABRICATED — they describe what a normal pre-27 status item
/// window would report, used here to exercise the geometry math. On the actual
/// macOS 27 stub host the production `buttonFrameProvider` returns a degenerate
/// `(0,0,51,0)` window frame (zero height, origin at the screen corner — see
/// MenuBarStatusItemCompatibility.swift and the impact-audit probe
/// `probe_dropzone_anchor_degradation`). `testStubHostFrameFailsClosed` below
/// feeds that real production frame so the suite documents that the tap is inert
/// (fails closed) under the stub host that motivated it.
final class MenuBarSecondaryClickTapTests: XCTestCase {
    // MARK: - Coordinate flip

    func testAppKitPointFlipsYAndKeepsX() {
        // CG y measured down from the top; AppKit y measured up from the bottom.
        let cg = CGPoint(x: 1438, y: 18)
        let mainDisplayHeight: CGFloat = 1000
        let point = MenuBarSecondaryClickHitTest.appKitPoint(
            fromCGGlobal: cg,
            mainDisplayHeight: mainDisplayHeight
        )
        XCTAssertEqual(point.x, 1438, accuracy: 0.0001)
        XCTAssertEqual(point.y, 982, accuracy: 0.0001)
    }

    func testAppKitPointFlipIsInvolutory() {
        // Flipping twice returns the original y (the transform is its own
        // inverse around the same display height).
        let mainDisplayHeight: CGFloat = 1000
        let original = CGPoint(x: 500, y: 17)
        let once = MenuBarSecondaryClickHitTest.appKitPoint(
            fromCGGlobal: original,
            mainDisplayHeight: mainDisplayHeight
        )
        let twice = MenuBarSecondaryClickHitTest.appKitPoint(
            fromCGGlobal: once,
            mainDisplayHeight: mainDisplayHeight
        )
        XCTAssertEqual(twice.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(twice.y, original.y, accuracy: 0.0001)
    }

    // MARK: - Hit / miss

    /// A right-click landing on the icon: CG (1438, 18) flips to AppKit
    /// (1438, 982), inside the button frame y=960…982, x=1430…1480.
    func testRightClickOnIconIsHit() {
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 22)
        // CG y=20 → AppKit y=980, strictly inside [960, 982) (CGRect.contains
        // is half-open at the max edge, so the band value must not equal maxY).
        XCTAssertTrue(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 20),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    func testExternalDisplayIconIsHit() {
        // External display icon at x≈2330 with a taller main display.
        let mainDisplayHeight: CGFloat = 1440
        let frame = CGRect(x: 2320, y: 1418, width: 50, height: 22)
        XCTAssertTrue(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 2330, y: 20),
                buttonFrame: frame,
                mainDisplayHeight: mainDisplayHeight
            )
        )
    }

    /// A click in the menu bar band but at a neighboring item's x: same y, but
    /// x sits outside the button frame. No tolerance, so this must NOT hit.
    func testNeighborItemInBandButOutsideXIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                // x=1510 is past the trailing edge (1480), onto the next item.
                cgEventLocation: CGPoint(x: 1510, y: 18),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    /// Correct x but the click is below the menu bar band entirely (CG y large
    /// → AppKit y small, below the frame).
    func testClickBelowMenuBarBandIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 200),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    // MARK: - Boundary semantics (CGRect.contains)

    func testFrameOriginCornerIsContained() {
        // CGRect.contains includes the min edges. Pick a CG location that flips
        // exactly onto the frame origin.
        let mainDisplayHeight: CGFloat = 1000
        let frame = CGRect(x: 100, y: 970, width: 50, height: 20)
        // AppKit (100, 970) ⇐ CG (100, 1000-970=30).
        XCTAssertTrue(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 100, y: 30),
                buttonFrame: frame,
                mainDisplayHeight: mainDisplayHeight
            )
        )
    }

    func testFrameMaxEdgeIsNotContained() {
        // CGRect.contains excludes the max edges. AppKit (150, 970) is exactly
        // maxX of a frame with x=100,width=50 → not contained.
        let mainDisplayHeight: CGFloat = 1000
        let frame = CGRect(x: 100, y: 970, width: 50, height: 20)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 150, y: 30),
                buttonFrame: frame,
                mainDisplayHeight: mainDisplayHeight
            )
        )
    }

    // MARK: - Multi-display: differing main display heights

    func testSameCGLocationDiffersAcrossMainDisplayHeights() {
        // The same physical CG band y maps to different AppKit y depending on
        // the main display height, so a frame valid for one height misses on
        // another. This guards against caching mainDisplayHeight.
        let cg = CGPoint(x: 1438, y: 20)
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 22)

        // Tuned for height 1000 (AppKit y=980, strictly inside [960, 982)).
        XCTAssertTrue(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: cg,
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
        // Height 1440 lifts AppKit y to 1420, far above the frame → miss.
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: cg,
                buttonFrame: frame,
                mainDisplayHeight: 1440
            )
        )
    }

    // MARK: - Degenerate frame: fail-closed

    func testEmptyFrameIsNotHit() {
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: .zero,
                mainDisplayHeight: 1000
            )
        )
    }

    func testNullFrameIsNotHit() {
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: .null,
                mainDisplayHeight: 1000
            )
        )
    }

    func testInfiniteFrameIsNotHit() {
        // An infinite frame would "contain" everything; fail closed instead.
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: .infinite,
                mainDisplayHeight: 1000
            )
        )
    }

    func testZeroWidthFrameIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: 0, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1430, y: 18),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    func testZeroHeightFrameIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 0)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 40),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    func testNaNFrameComponentIsNotHit() {
        let frame = CGRect(x: CGFloat.nan, y: 960, width: 50, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    func testInfiniteFrameComponentIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: CGFloat.infinity, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    /// Production reality on the macOS 27 stub host: the button's backing-window
    /// frame is recorded as `(0,0,51,0)` (zero height) on 26A5353q, while a real
    /// right-click lands in the menu bar band at x≈1438 (built-in) or x≈2330
    /// (external). The zero-height frame is rejected as unusable, so the tap
    /// fails closed there — right-click is NOT revived under the stub host, and
    /// Option+left-click remains the secondary path. This guards the documented
    /// blocker so the suite reflects what the provider actually supplies on the
    /// target OS, not only the fabricated healthy frames used above.
    func testStubHostFrameFailsClosed() {
        let stubFrame = CGRect(x: 0, y: 0, width: 51, height: 0)
        // Built-in display right-click.
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: stubFrame,
                mainDisplayHeight: 1117
            )
        )
        // External display right-click.
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 2330, y: 20),
                buttonFrame: stubFrame,
                mainDisplayHeight: 1440
            )
        )
    }

    // MARK: - Degenerate inputs other than the frame

    func testNonFiniteEventLocationIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: CGFloat.nan, y: 18),
                buttonFrame: frame,
                mainDisplayHeight: 1000
            )
        )
    }

    func testNonFiniteMainDisplayHeightIsNotHit() {
        let frame = CGRect(x: 1430, y: 960, width: 50, height: 22)
        XCTAssertFalse(
            MenuBarSecondaryClickHitTest.isHit(
                cgEventLocation: CGPoint(x: 1438, y: 18),
                buttonFrame: frame,
                mainDisplayHeight: .nan
            )
        )
    }

    // MARK: - Secondary-click tap invocation

    func testSecondaryClickTapSelectsFeaturePanelWhenNotSwapped() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForSecondaryClickTap(swapped: false),
            .featurePanel
        )
    }

    func testSecondaryClickTapSelectsComponentPanelWhenSwapped() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForSecondaryClickTap(swapped: true),
            .componentPanel
        )
    }
}
