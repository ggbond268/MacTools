import CoreGraphics
import XCTest
@testable import WindowLayoutsPlugin

final class WindowEnhancedUIFrameGuardTests: XCTestCase {
    private enum Failure: Error { case write }

    func testSuppressesEnabledStateOnlyDuringTransaction() throws {
        var enabled = true
        var writes: [Bool] = []
        let result = try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { enabled = $0; writes.append($0); return true }
        ) {
            XCTAssertFalse(enabled)
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes, [false, true])
    }

    func testDisabledOrUnsupportedAttributeIsUntouched() throws {
        for state: Bool? in [false, nil] {
            var didRun = false
            try WindowEnhancedUIFrameGuard.perform(
                preserveEnhancedUI: false, readEnabled: { state },
                setEnabled: { _ in XCTFail("Attribute must not change"); return false }
            ) { didRun = true }
            XCTAssertTrue(didRun)
        }
    }

    func testAssistiveTechnologyPolicySkipsAttributeReadsAndWrites() throws {
        var didRun = false
        try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: true,
            readEnabled: { XCTFail("Do not inspect enhanced UI for suppression"); return true },
            setEnabled: { _ in XCTFail("Do not suppress assistive technology"); return false }
        ) { didRun = true }
        XCTAssertTrue(didRun)
    }

    func testRestoresEnabledStateAfterFailureAndCancellation() {
        for error in [Failure.write as Error, CancellationError()] {
            var enabled = true
            XCTAssertThrowsError(try WindowEnhancedUIFrameGuard.perform(
                preserveEnhancedUI: false, readEnabled: { enabled },
                setEnabled: { enabled = $0; return true }
            ) { throw error }) { observed in
                XCTAssertEqual(observed is CancellationError, error is CancellationError)
            }
            XCTAssertTrue(enabled)
        }
    }

    func testFailedDisableMayHaveAppliedAndStillRequiresRestoration() throws {
        var enabled = true
        var writes: [Bool] = []
        try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { enabled = $0; writes.append($0); return $0 }
        ) { XCTAssertFalse(enabled) }
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes, [false, true])
    }

    func testReadOnlyEnabledAttributeDoesNotBreakFrameWrites() throws {
        var writes: [Bool] = []
        var didRun = false
        try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { true },
            setEnabled: { writes.append($0); return false }
        ) { didRun = true }
        XCTAssertTrue(didRun)
        XCTAssertEqual(writes, [false, true])
    }

    func testRestorationRetriesAreBoundedAndRecoverTransientFailure() throws {
        var enabled = true
        var restoreAttempts = 0
        try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { value in
                if value {
                    restoreAttempts += 1
                    if restoreAttempts < 3 { return false }
                }
                enabled = value
                return true
            }
        ) { XCTAssertFalse(enabled) }
        XCTAssertTrue(enabled)
        XCTAssertEqual(restoreAttempts, 3)
    }

    func testExhaustedRestorationDoesNotReportSuccessfulFrameTransaction() {
        var enabled = true
        var restoreAttempts = 0
        XCTAssertThrowsError(try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { value in
                if value { restoreAttempts += 1; return false }
                enabled = false
                return true
            }
        ) {}) { error in
            XCTAssertEqual(error as? WindowLayoutError, .frameWriteFailed)
        }
        XCTAssertEqual(restoreAttempts, 3)
    }

    func testOriginalErrorSurvivesRestorationFailure() {
        var enabled = true
        XCTAssertThrowsError(try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { value in
                if value { return false }
                enabled = false
                return true
            }
        ) { throw CancellationError() }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFrameRollbackFinishesBeforeEnhancedUIIsRestored() {
        let original = CGRect(x: 10, y: 20, width: 600, height: 400)
        let target = CGRect(x: -1400, y: 40, width: 900, height: 700)
        var observed = original
        var enabled = true
        XCTAssertThrowsError(try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { value in
                if value { XCTAssertEqual(observed, original) }
                enabled = value
                return true
            }
        ) {
            try WindowFrameWriteTransaction.apply(
                originalFrame: original, targetFrame: target,
                setPosition: { value in
                    XCTAssertFalse(enabled)
                    if value == target.origin { throw Failure.write }
                    observed.origin = value
                },
                setSize: { XCTAssertFalse(enabled); observed.size = $0 }
            )
        })
        XCTAssertEqual(observed, original)
        XCTAssertTrue(enabled)
    }

    func testConstrainedAndCrossDisplayFramesKeepExistingReadbackBehavior() throws {
        let original = CGRect(x: 10, y: 20, width: 600, height: 400)
        let target = CGRect(x: -1400, y: -700, width: 300, height: 250)
        var observed = original
        var enabled = true
        try WindowEnhancedUIFrameGuard.perform(
            preserveEnhancedUI: false, readEnabled: { enabled },
            setEnabled: { enabled = $0; return true }
        ) {
            try WindowFrameWriteTransaction.apply(
                originalFrame: original, targetFrame: target,
                setPosition: { XCTAssertFalse(enabled); observed.origin = $0 },
                setSize: { XCTAssertFalse(enabled); observed.size = CGSize(width: max(500, $0.width), height: max(400, $0.height)) },
                readFrame: { XCTAssertFalse(enabled); return observed }
            )
        }
        XCTAssertTrue(enabled)
        XCTAssertEqual(observed.origin, target.origin)
        XCTAssertEqual(observed.size, CGSize(width: 500, height: 400))
    }
}
