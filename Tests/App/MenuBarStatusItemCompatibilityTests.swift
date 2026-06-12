import AppKit
import XCTest
@testable import MacTools

/// Pure-function coverage for the macOS 27 beta menu bar host detection and
/// the OS-gated sendAction mask decision. The on-device facts these encode:
/// the stub backing window reports windowNumber 4294967296 (2^32, beyond the
/// 32-bit CGWindowID space) and a zero-height frame (0,0,51,0).
final class MenuBarStatusItemCompatibilityTests: XCTestCase {
    // MARK: - Stub backing window detection

    func testObservedMacOS27StubWindowValuesAreDetected() {
        // Exact values measured on 26A5353q.
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: 4_294_967_296,
                frameHeight: 0
            )
        )
    }

    func testSentinelWindowNumberAloneIsStubEvenWithRealHeight() {
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: 4_294_967_296,
                frameHeight: 24
            )
        )
    }

    func testZeroHeightFrameAloneIsStub() {
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: 1234,
                frameHeight: 0
            )
        )
    }

    func testNonPositiveWindowNumberIsStub() {
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: 0,
                frameHeight: 24
            )
        )
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: -1,
                frameHeight: 24
            )
        )
    }

    func testHealthyLegacyStatusBarWindowIsNotStub() {
        // A typical real status bar window: small positive number, menu bar
        // height frame.
        XCTAssertFalse(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: 1234,
                frameHeight: 24
            )
        )
    }

    func testLargestRealWindowNumberIsNotStub() {
        // CGWindowID is 32-bit: UInt32.max is still inside the real space.
        XCTAssertFalse(
            MenuBarStatusItemHostCompatibility.isStubBackingWindow(
                windowNumber: Int(UInt32.max),
                frameHeight: 24
            )
        )
    }

    func testMissingBackingWindowIsTreatedAsStub() {
        XCTAssertTrue(MenuBarStatusItemHostCompatibility.isStubBackingWindow(nil))
    }

    // MARK: - sendAction mask gating

    func testLegacyHostKeepsHistoricalDownMaskByteForByte() {
        // Hard requirement: on old systems the mask must stay exactly the
        // historical down mask, otherwise down+up double-triggers.
        XCTAssertEqual(
            MenuBarStatusItemHostCompatibility.sendActionMask(
                buttonWindowIsStub: false,
                isMacOS27OrLater: false
            ),
            [.leftMouseDown, .rightMouseDown]
        )
    }

    func testStubWindowSwitchesToUpMask() {
        XCTAssertEqual(
            MenuBarStatusItemHostCompatibility.sendActionMask(
                buttonWindowIsStub: true,
                isMacOS27OrLater: false
            ),
            [.leftMouseUp, .rightMouseUp]
        )
    }

    func testMacOS27GateSwitchesToUpMaskEvenWithoutStubProbe() {
        XCTAssertEqual(
            MenuBarStatusItemHostCompatibility.sendActionMask(
                buttonWindowIsStub: false,
                isMacOS27OrLater: true
            ),
            [.leftMouseUp, .rightMouseUp]
        )
    }

    func testStubAndOSGateTogetherStillUpMask() {
        XCTAssertEqual(
            MenuBarStatusItemHostCompatibility.sendActionMask(
                buttonWindowIsStub: true,
                isMacOS27OrLater: true
            ),
            [.leftMouseUp, .rightMouseUp]
        )
    }

    // MARK: - Degenerate anchor rect → nil (rescues QuitApps/XcodeClean/FixDamagedApp)

    func testStubWindowDegeneratesAnchorToNilEvenWithPositiveHeight() {
        // The observed beta degenerate rect ({{0,-11},{22,22}}) has a positive
        // height, so the stub flag alone must force the nil fallback.
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.anchorRectDegeneratesToNil(
                screenRectHeight: 22,
                windowIsStub: true
            )
        )
    }

    func testZeroHeightAnchorRectDegeneratesToNil() {
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.anchorRectDegeneratesToNil(
                screenRectHeight: 0,
                windowIsStub: false
            )
        )
        XCTAssertTrue(
            MenuBarStatusItemHostCompatibility.anchorRectDegeneratesToNil(
                screenRectHeight: -11,
                windowIsStub: false
            )
        )
    }

    func testHealthyAnchorRectIsNotDegenerate() {
        // macOS 14…26: real window, menu-bar-height frame → keep the genuine
        // rect (no regression in plugin anchoring).
        XCTAssertFalse(
            MenuBarStatusItemHostCompatibility.anchorRectDegeneratesToNil(
                screenRectHeight: 22,
                windowIsStub: false
            )
        )
    }
}
