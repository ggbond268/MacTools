import CoreGraphics
import XCTest
@testable import MacTools
@testable import MenuBarHiddenPlugin

/// Shape plausibility rules behind the fail-closed host gate. Pure-function
/// tests: window and display geometry come in as fixtures (CG global
/// coordinates, top-left origin), no real displays or CGS calls.
@MainActor
final class MenuBarHiddenHostProbeTests: XCTestCase {
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func window(
        _ id: CGWindowID,
        x: CGFloat,
        y: CGFloat = 0,
        width: CGFloat = 24,
        height: CGFloat = 24
    ) -> MenuBarHiddenHostProbe.WindowShape {
        MenuBarHiddenHostProbe.WindowShape(
            windowID: id,
            bounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func assertImplausible(
        _ verdict: MenuBarHiddenHostProbe.Verdict,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .implausible = verdict else {
            XCTFail("Expected .implausible, got \(verdict)", file: file, line: line)
            return
        }
    }

    // MARK: - Healthy pre-27 shapes must pass

    func testHealthySingleDisplayMenuBarIsPlausible() {
        let windows = [
            window(1, x: 1480, width: 32),
            window(2, x: 1440),
            window(3, x: 1380, width: 56, height: 37),
            window(4, x: 900, width: 150, height: 22),
        ]
        XCTAssertEqual(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay]),
            .plausible
        )
    }

    func testItemsPushedOffscreenLeftByAHiderAppStayPlausible() {
        // This plugin (and Ice/Bartender) hide items by pushing them to far
        // negative X while keeping menu bar Y — the gate must not reject that.
        let windows = [
            window(1, x: 1480),
            window(2, x: -10000),
            window(3, x: -9930, width: 40),
        ]
        XCTAssertEqual(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay]),
            .plausible
        )
    }

    func testSecondaryDisplayTopBandIsPlausible() {
        let secondary = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let windows = [
            window(1, x: 1480),
            window(2, x: 3300, y: -200),
            window(3, x: 3200, y: -176),
        ]
        XCTAssertEqual(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay, secondary]),
            .plausible
        )
    }

    func testHiderSpacerWindowAmongHealthyItemsStaysPlausible() {
        // A hider in hidden state (this plugin, Ice, Hidden Bar) keeps a
        // ~10000pt expanding spacer status item in the menu bar window list.
        // Far wider than any display = spacer, not the composited 27 bar.
        let windows = [
            window(1, x: 1480, width: 32),
            window(2, x: -10000, width: 10000),
            window(3, x: 1440),
        ]
        XCTAssertEqual(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay]),
            .plausible
        )
    }

    func testAutoHiddenMenuBarItemsJustAboveTopEdgeStayPlausible() {
        let windows = [
            window(1, x: 1480, y: -24),
            window(2, x: 1440, y: -37, height: 37),
        ]
        XCTAssertEqual(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay]),
            .plausible
        )
    }

    // MARK: - macOS 27 beta fingerprints must fail closed

    func testSingleFullWidthMenuBarWindowIsRejected() {
        let windows = [window(1, x: 0, width: 1512, height: 24)]
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay])
        )
    }

    func testFullWidthZeroHeightWindowIsRejected() {
        let windows = [window(1, x: 0, width: 1512, height: 0)]
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay])
        )
    }

    func testFullWidthWindowAmongHealthyItemsIsStillRejected() {
        let windows = [
            window(1, x: 1480),
            window(2, x: 0, width: 1500, height: 24),
            window(3, x: 1400),
        ]
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay])
        )
    }

    func testWindowSlightlyWiderThanItsDisplayIsStillRejected() {
        // Wider than the display but inside the spacer-exemption margin:
        // still the composited-bar fingerprint, not a hider spacer — the
        // exemption must not weaken the full-width rejection.
        let windows = [window(1, x: 0, width: 1600, height: 24)]
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay])
        )
    }

    func testWidthFractionComparesAgainstNarrowestHostingDisplay() {
        // A window vertically inside two displays' top bands is checked
        // against the narrower one — fail-closed bias.
        let narrow = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let wide = CGRect(x: 1024, y: 0, width: 3440, height: 1440)
        let windows = [window(1, x: 1100, width: 1000)]
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [narrow, wide])
        )
    }

    // MARK: - Degenerate geometry must fail closed

    func testZeroHeightItemWindowIsRejected() {
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(
                for: [window(1, x: 100, height: 0)],
                displayBounds: [mainDisplay]
            )
        )
    }

    func testTooTallWindowIsRejected() {
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(
                for: [window(1, x: 100, height: 120)],
                displayBounds: [mainDisplay]
            )
        )
    }

    func testWindowBelowEveryTopBandIsRejected() {
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(
                for: [window(1, x: 100, y: 500)],
                displayBounds: [mainDisplay]
            )
        )
    }

    func testWindowFarAboveEveryTopBandIsRejected() {
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(
                for: [window(1, x: 100, y: -200)],
                displayBounds: [mainDisplay]
            )
        )
    }

    func testNonFiniteBoundsAreRejected() {
        let bad = MenuBarHiddenHostProbe.WindowShape(
            windowID: 9,
            bounds: CGRect(x: CGFloat.nan, y: 0, width: 24, height: 24)
        )
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: [bad], displayBounds: [mainDisplay])
        )
    }

    func testExcessiveWindowCountIsRejected() {
        let windows = (0..<260).map { index in
            window(CGWindowID(index + 1), x: CGFloat(index) * 5)
        }
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: windows, displayBounds: [mainDisplay])
        )
    }

    // MARK: - Edge inputs

    func testEmptyEnumerationYieldsEmptyVerdict() {
        XCTAssertEqual(
            MenuBarHiddenHostProbe.verdict(for: [], displayBounds: [mainDisplay]),
            .empty
        )
    }

    func testNoValidDisplaysFailsClosed() {
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(for: [window(1, x: 100)], displayBounds: [])
        )
        assertImplausible(
            MenuBarHiddenHostProbe.verdict(
                for: [window(1, x: 100)],
                displayBounds: [CGRect.null, .zero]
            )
        )
    }
}
