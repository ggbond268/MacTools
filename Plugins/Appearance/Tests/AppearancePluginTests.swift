import XCTest
@testable import AppearancePlugin

/// The dark-mode toggle drives `NSAppleScript` directly (not an injectable runner), so
/// the testable seam for the "silent failure → actionable guidance" fix is the
/// `AutomationDenial` classifier the plugin consults when the script reports an error.
final class AppearanceAutomationDenialTests: XCTestCase {
    func testDeniedForNotPermittedErrorNumber() {
        // -1743 == errAEEventNotPermitted: the user denied the Automation permission.
        XCTAssertTrue(AutomationDenial.isDenied(errorNumber: -1743))
    }

    func testDeniedForConsentRequiredErrorNumber() {
        // -1744 == errAEEventWouldRequireUserConsent: consent not yet granted.
        XCTAssertTrue(AutomationDenial.isDenied(errorNumber: -1744))
    }

    func testNotDeniedForOtherOrMissingErrorNumbers() {
        XCTAssertFalse(AutomationDenial.isDenied(errorNumber: -30720))   // generic Apple Event failure
        XCTAssertFalse(AutomationDenial.isDenied(errorNumber: 0))
        XCTAssertFalse(AutomationDenial.isDenied(errorNumber: nil))      // no errorNumber on the NSAppleScript error
    }

    func testGuidanceMessageIsActionableAndNamesTarget() {
        let message = AutomationDenial.message(targetAppName: "系统事件")
        // Actionable: points at the exact Settings pane, names the controlled target.
        XCTAssertTrue(message.contains("自动化"))
        XCTAssertTrue(message.contains("系统设置"))
        XCTAssertTrue(message.contains("系统事件"))
    }
}
