import XCTest
@testable import WindowLayoutsPlugin

final class WindowEnhancedUIFrameGuardTests: XCTestCase {
    private enum Failure: Error { case write }

    func testRestoresEnhancedUIAfterSuccessfulAndFailedFrameWrites() {
        for fails in [false, true] {
            var enabled = true
            let result = Result {
                try WindowEnhancedUIFrameGuard.perform(
                    preserveEnhancedUI: false,
                    readEnabled: { enabled },
                    setEnabled: { enabled = $0; return true }
                ) {
                    XCTAssertFalse(enabled)
                    if fails { throw Failure.write }
                    return 42
                }
            }
            XCTAssertTrue(enabled, "Frame write failed: \(fails)")
            switch result {
            case .success(let value):
                XCTAssertFalse(fails)
                XCTAssertEqual(value, 42)
            case .failure(let error):
                XCTAssertTrue(fails)
                XCTAssertTrue(error is Failure)
            }
        }
    }

    func testAssistiveTechnologyPolicyLeavesEnhancedUIUntouched() throws {
        let value = try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: true,
            readEnabled: { XCTFail("Do not inspect assistive technology state"); return true },
            setEnabled: { _ in XCTFail("Do not disable assistive technology"); return false }
        ) { 42 }
        XCTAssertEqual(value, 42)
    }
}
