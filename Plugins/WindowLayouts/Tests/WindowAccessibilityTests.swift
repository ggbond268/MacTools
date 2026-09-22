import AppKit
import CoreGraphics
import MacToolsPluginKit
import XCTest
@testable import MacTools
@testable import WindowLayoutsPlugin

final class WindowFrameWriteTransactionTests: XCTestCase {
    private enum TestError: Error {
        case rejectedPosition
    }

    func testRollsBackSizeAndPositionWhenFinalPositionWriteFails() {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        var position = original.origin
        var size = original.size
        var rejectsTargetPosition = true

        XCTAssertThrowsError(try WindowFrameWriteTransaction.apply(
            originalFrame: original,
            targetFrame: target,
            setPosition: { value in
                if value == target.origin && rejectsTargetPosition {
                    rejectsTargetPosition = false
                    throw TestError.rejectedPosition
                }
                position = value
            },
            setSize: { size = $0 }
        ))

        XCTAssertEqual(position, original.origin)
        XCTAssertEqual(size, original.size)
    }

    func testReappliesSizeAfterPositionBeforeFinishingAtTargetPosition() throws {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        var writes: [String] = []

        try WindowFrameWriteTransaction.apply(
            originalFrame: original,
            targetFrame: target,
            setPosition: { _ in writes.append("position") },
            setSize: { _ in writes.append("size") }
        )

        XCTAssertEqual(writes, ["size", "position", "size", "position"])
    }

    func testExpandingWindowCanAcceptSizeAfterMovingToTargetOrigin() throws {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        var observed = original
        var writes: [String] = []

        try WindowFrameWriteTransaction.apply(
            originalFrame: original,
            targetFrame: target,
            setPosition: {
                writes.append("position")
                observed.origin = $0
            },
            setSize: {
                writes.append("size")
                if observed.origin == target.origin {
                    observed.size = $0
                }
            },
            readFrame: { observed }
        )

        XCTAssertEqual(observed, target)
        XCTAssertEqual(writes, ["size", "position", "size", "position"])
    }

    func testRetriesMoveOnlyPositionWhenFirstWriteHasNotSettled() throws {
        let original = CGPoint(x: 10, y: 20)
        let target = CGPoint(x: 700, y: 20)
        var observed = original
        var writeCount = 0

        try WindowFrameWriteTransaction.applyPosition(
            originalPosition: original,
            targetPosition: target,
            setPosition: {
                writeCount += 1
                if writeCount > 1 {
                    observed = $0
                }
            },
            readPosition: { observed }
        )

        XCTAssertEqual(observed, target)
        XCTAssertEqual(writeCount, 2)
    }
}
