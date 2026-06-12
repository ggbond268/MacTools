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

    // MARK: - Geometry-first status button hit test

    /// A typical healthy button rect: 30pt wide item at the top of a
    /// 1000pt-tall screen (menu bar height 24).
    private let healthyButtonRect = NSRect(x: 100, y: 976, width: 30, height: 24)

    func testLocationInsideHealthyButtonRectIsInside() {
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 110, y: 990),
                buttonScreenRect: healthyButtonRect
            ),
            true
        )
    }

    func testTopEdgeCountsAsInsideForSlamToTopClicks() {
        // Cursor pinned against the top of the screen reports y == rect.maxY
        // in flipped screen coordinates; menu bar items must stay clickable
        // there.
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 110, y: 1000),
                buttonScreenRect: healthyButtonRect
            ),
            true
        )
    }

    func testLocationOutsideHealthyButtonRectIsOutside() {
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 99, y: 990),
                buttonScreenRect: healthyButtonRect
            ),
            false
        )
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 110, y: 900),
                buttonScreenRect: healthyButtonRect
            ),
            false
        )
    }

    func testTrailingEdgeBelongsToNeighborItem() {
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 130, y: 990),
                buttonScreenRect: healthyButtonRect
            ),
            false
        )
    }

    func testNilButtonRectMeansGeometryCannotDecide() {
        // Stub host: the rect collapses to nil → the caller must fall back
        // to the window-identity comparison instead of treating the click as
        // outside outright.
        XCTAssertNil(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 110, y: 990),
                buttonScreenRect: nil
            )
        )
    }

    func testDegenerateButtonRectMeansGeometryCannotDecide() {
        XCTAssertNil(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 110, y: 990),
                buttonScreenRect: NSRect(x: 100, y: 976, width: 0, height: 24)
            )
        )
        XCTAssertNil(
            MenuBarStatusItemClickGeometry.isLocationInsideButton(
                NSPoint(x: 110, y: 990),
                buttonScreenRect: NSRect(x: 100, y: 976, width: 30, height: 0)
            )
        )
    }

    // MARK: - Menu bar band

    private let screenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)

    func testMenuBarBandContainsClickInTopStrip() {
        XCTAssertTrue(
            MenuBarStatusItemClickGeometry.isLocationInMenuBarBand(
                NSPoint(x: 700, y: 970),
                screenFrame: screenFrame,
                bandHeight: 24
            )
        )
    }

    func testMenuBarBandTopEdgeIsInclusive() {
        XCTAssertTrue(
            MenuBarStatusItemClickGeometry.isLocationInMenuBarBand(
                NSPoint(x: 700, y: 982),
                screenFrame: screenFrame,
                bandHeight: 24
            )
        )
    }

    func testMenuBarBandRejectsClickBelowBand() {
        XCTAssertFalse(
            MenuBarStatusItemClickGeometry.isLocationInMenuBarBand(
                NSPoint(x: 700, y: 957),
                screenFrame: screenFrame,
                bandHeight: 24
            )
        )
    }

    func testMenuBarBandRejectsClickOutsideScreenXRange() {
        // A second display to the right: its x range must not match this
        // screen's band.
        XCTAssertFalse(
            MenuBarStatusItemClickGeometry.isLocationInMenuBarBand(
                NSPoint(x: 1600, y: 970),
                screenFrame: screenFrame,
                bandHeight: 24
            )
        )
    }

    func testBandHeightDerivedFromVisibleFrameInset() {
        // Notched / beta menu bars are taller than the status bar thickness;
        // the visible-frame inset tracks the real height.
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.menuBarBandHeight(
                screenFrameMaxY: 982,
                visibleFrameMaxY: 944,
                statusBarThickness: 24
            ),
            38
        )
    }

    func testBandHeightFallsBackToThicknessWhenMenuBarAutoHidden() {
        // Auto-hidden menu bar: visibleFrame reaches the screen top, so the
        // derived inset is 0 and the status bar thickness keeps a usable
        // minimum.
        XCTAssertEqual(
            MenuBarStatusItemClickGeometry.menuBarBandHeight(
                screenFrameMaxY: 982,
                visibleFrameMaxY: 982,
                statusBarThickness: 24
            ),
            24
        )
    }

    // MARK: - Toggle suppression (stub-host icon-click bounce)

    private static let iconPoint = CGPoint(x: 2343, y: 16)

    func testZeroEventNumbersMatchByLocationOnTheBeta() {
        // On-device reality on 26A5353q: BOTH the monitor's down and the
        // forwarded action's up carry eventNumber 0, so the number equality
        // is vacuous and the location must carry the identity. Small jitter
        // between down and up stays within the drift bound.
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 0, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.componentPanel]
        )

        XCTAssertTrue(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 0,
                    timestamp: 100.15,
                    screenLocation: CGPoint(x: Self.iconPoint.x + 2, y: Self.iconPoint.y + 1)
                ),
                target: .componentPanel
            )
        )
    }

    func testFarawayClickWithDegenerateEventNumberIsNotSuppressed() {
        // The trap the location bound closes: with every beta event number
        // being 0, dismissing our panel by clicking a DIFFERENT status item
        // arms a record that would otherwise eat the next icon click for up
        // to the staleness window. Distinct items sit tens of points apart,
        // far beyond the drift bound.
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(
                eventNumber: 0,
                timestamp: 100.00,
                screenLocation: CGPoint(x: 2255, y: 16)
            ),
            dismissedPanels: [.componentPanel]
        )

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 0, timestamp: 100.50, screenLocation: Self.iconPoint),
                target: .componentPanel
            )
        )
    }

    func testSameClickWithinTimeoutSuppressesExactlyOnce() {
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertTrue(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.12, screenLocation: Self.iconPoint),
                target: .featurePanel
            )
        )
        // Consumed: the same identity must not suppress a second time, or a
        // genuine follow-up toggle would be eaten.
        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.13, screenLocation: Self.iconPoint),
                target: .featurePanel
            )
        )
    }

    func testDifferentClickIsNotSuppressed() {
        // A different click is told apart by WHERE it landed, never by the
        // event number — the stub host synthesizes the action's up with a
        // number unrelated to the monitored down.
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 8,
                    timestamp: 100.10,
                    screenLocation: CGPoint(x: Self.iconPoint.x - 60, y: Self.iconPoint.y)
                ),
                target: .featurePanel
            )
        )
    }

    func testPhysicalClickPairWithMismatchedEventNumbersSuppresses() {
        // The on-device bounce on 26A5353q: the monitor saw the physical
        // down with its real number (6845) and the action got a
        // host-synthesized up with an unrelated number ~1s later. Same
        // location + the time window must identify them as one click.
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 6845, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.componentPanel]
        )

        XCTAssertTrue(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 0,
                    timestamp: 101.00,
                    screenLocation: CGPoint(x: Self.iconPoint.x + 1, y: Self.iconPoint.y)
                ),
                target: .componentPanel
            )
        )
    }

    func testSwitchToPanelThatWasNotDismissedIsNotSuppressed() {
        // Stub-host panel switch: the primary panel was open, the user
        // Option-clicks the icon to get the secondary panel. The dismissal
        // closes the primary; the same click's action targets the component
        // panel, which was NOT among the dismissed ones — that is a switch
        // and must proceed (suppressing it would close everything and eat
        // the only pointer channel to the secondary panel on the beta).
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.12, screenLocation: Self.iconPoint),
                target: .componentPanel
            )
        )
    }

    func testBothPanelsDismissedSuppressesEitherTarget() {
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel, .componentPanel]
        )

        XCTAssertTrue(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.12, screenLocation: Self.iconPoint),
                target: .componentPanel
            )
        )
    }

    func testNonMatchingToggleClearsThePendingRecord() {
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 8,
                    timestamp: 100.10,
                    screenLocation: CGPoint(x: Self.iconPoint.x - 60, y: Self.iconPoint.y)
                ),
                target: .featurePanel
            )
        )
        // The newer click superseded the stale record; the old identity must
        // not suppress later.
        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.20, screenLocation: Self.iconPoint),
                target: .featurePanel
            )
        )
    }

    func testExpiredRecordDoesNotSuppress() {
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 7,
                    timestamp: 100.00 + MenuBarStatusItemToggleSuppressor.maximumClickDuration + 0.01,
                    screenLocation: Self.iconPoint
                ),
                target: .featurePanel
            )
        )
    }

    func testExactTimeoutBoundaryStillSuppresses() {
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertTrue(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 7,
                    timestamp: 100.00 + MenuBarStatusItemToggleSuppressor.maximumClickDuration,
                    screenLocation: Self.iconPoint
                ),
                target: .featurePanel
            )
        )
    }

    func testActionSlightlyOlderThanRecordStillSuppresses() {
        // The activation-dismissal record is stamped with "now", which can
        // postdate the forwarded action's own event timestamp (observed live
        // as a missed suppression). Backward skew within the bound matches.
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 0, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.componentPanel]
        )

        XCTAssertTrue(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 0, timestamp: 99.20, screenLocation: Self.iconPoint),
                target: .componentPanel
            )
        )
    }

    func testActionFarOlderThanRecordDoesNotSuppress() {
        var suppressor = MenuBarStatusItemToggleSuppressor()
        suppressor.recordOutsideDismissal(
            MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
            dismissedPanels: [.featurePanel]
        )

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(
                    eventNumber: 7,
                    timestamp: 100.00 - MenuBarStatusItemToggleSuppressor.maximumTimestampSkew - 0.5,
                    screenLocation: Self.iconPoint
                ),
                target: .featurePanel
            )
        )
    }

    func testNoRecordNeverSuppresses() {
        // Healthy-host invariant: the suppressor is only ever armed on the
        // geometry-less (stub host) dismissal path, so with nothing recorded
        // every toggle must proceed.
        var suppressor = MenuBarStatusItemToggleSuppressor()

        XCTAssertFalse(
            suppressor.shouldSuppressToggle(
                for: MenuBarStatusItemClickIdentity(eventNumber: 7, timestamp: 100.00, screenLocation: Self.iconPoint),
                target: .featurePanel
            )
        )
    }
}
