import CoreGraphics
import XCTest
@testable import WindowLayoutsPlugin

final class WindowLayoutCalculatorTests: XCTestCase {
    private let calculator = WindowLayoutCalculator()

    func testHalvesCoverOddVisibleFrameWithoutLeavingAPoint() throws {
        let visibleFrame = CGRect(x: -1511, y: -967, width: 1511, height: 967)
        let windowFrame = CGRect(x: -1000, y: -800, width: 500, height: 400)

        let left = try XCTUnwrap(calculator.placementFrame(
            for: .leftHalf,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        ))
        let right = try XCTUnwrap(calculator.placementFrame(
            for: .rightHalf,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        ))
        let top = try XCTUnwrap(calculator.placementFrame(
            for: .topHalf,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        ))
        let bottom = try XCTUnwrap(calculator.placementFrame(
            for: .bottomHalf,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        ))

        XCTAssertEqual(left.minX, visibleFrame.minX)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(right.maxX, visibleFrame.maxX)
        XCTAssertEqual(left.width + right.width, visibleFrame.width)
        XCTAssertEqual(top.minY, visibleFrame.minY)
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(bottom.maxY, visibleFrame.maxY)
        XCTAssertEqual(top.height + bottom.height, visibleFrame.height)
    }

    func testHalfCycleFramesRemainPinnedToTheirRequestedOrientation() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 1200, height: 900)

        XCTAssertEqual(
            calculator.halfCycleFrames(
                for: .leftHalf,
                windowFrame: .zero,
                visibleFrame: visibleFrame,
                gap: 0
            ),
            [
                CGRect(x: 0, y: 24, width: 600, height: 900),
                CGRect(x: 0, y: 24, width: 800, height: 900),
                CGRect(x: 0, y: 24, width: 400, height: 900),
            ]
        )
        XCTAssertEqual(
            calculator.halfCycleFrames(
                for: .topHalf,
                windowFrame: .zero,
                visibleFrame: visibleFrame,
                gap: 0
            ),
            [
                CGRect(x: 0, y: 24, width: 1200, height: 450),
                CGRect(x: 0, y: 24, width: 1200, height: 600),
                CGRect(x: 0, y: 24, width: 1200, height: 300),
            ]
        )
        XCTAssertEqual(
            calculator.halfCycleFrames(
                for: .bottomHalf,
                windowFrame: .zero,
                visibleFrame: visibleFrame,
                gap: 0
            ),
            [
                CGRect(x: 0, y: 474, width: 1200, height: 450),
                CGRect(x: 0, y: 324, width: 1200, height: 600),
                CGRect(x: 0, y: 624, width: 1200, height: 300),
            ]
        )
    }

    func testQuarterUsesTopLeftAccessibilityCoordinatesAndGap() throws {
        let visibleFrame = CGRect(x: -1200, y: 50, width: 1200, height: 900)

        let frame = try XCTUnwrap(calculator.placementFrame(
            for: .topLeftQuarter,
            windowFrame: .zero,
            visibleFrame: visibleFrame,
            gap: 12
        ))

        XCTAssertEqual(frame, CGRect(x: -1188, y: 62, width: 582, height: 432))
    }

    func testCenterPreservesOversizedWindowSize() throws {
        let visibleFrame = CGRect(x: 0, y: 24, width: 1000, height: 700)
        let windowFrame = CGRect(x: -100, y: 0, width: 1400, height: 900)

        let centered = try XCTUnwrap(calculator.placementFrame(
            for: .center,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 20
        ))

        XCTAssertEqual(centered.size, windowFrame.size)
        XCTAssertEqual(centered.midX, visibleFrame.midX)
        XCTAssertEqual(centered.midY, visibleFrame.midY)
        XCTAssertGreaterThan(centered.intersection(visibleFrame).width, 0)
        XCTAssertGreaterThan(centered.intersection(visibleFrame).height, 0)
    }

    func testEdgeMovePreservesOversizedWindowSize() throws {
        let visibleFrame = CGRect(x: 0, y: 20, width: 1_000, height: 700)
        let windowFrame = CGRect(x: -300, y: -300, width: 1_400, height: 900)

        let moved = try XCTUnwrap(calculator.placementFrame(
            for: .moveToLeftEdge,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        ))

        XCTAssertEqual(moved.size, windowFrame.size)
        XCTAssertEqual(moved.minX, visibleFrame.minX)
        XCTAssertEqual(moved.minY, visibleFrame.maxY - windowFrame.height)
    }

    func testCustomCurrentDimensionsPreserveOversizedWindowSize() {
        let visibleFrame = CGRect(x: 0, y: 20, width: 1_000, height: 700)
        let windowFrame = CGRect(x: -300, y: -300, width: 1_400, height: 900)
        let command = WindowCustomCommand(
            name: "Keep Current",
            width: .current,
            height: .current,
            anchor: .bottomRight
        )

        let moved = calculator.customFrame(
            for: command,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 10
        )

        XCTAssertEqual(moved.size, windowFrame.size)
        XCTAssertEqual(moved.maxX, visibleFrame.maxX - 10)
        XCTAssertEqual(moved.maxY, visibleFrame.maxY - 10)
    }

    func testMoveBetweenDifferentDisplaySizesPreservesRelativePlacementAndSize() {
        let source = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let destination = CGRect(x: -2560, y: -300, width: 2560, height: 1400)
        let window = CGRect(x: 720, y: 462, width: 720, height: 438)

        let moved = calculator.movedFrame(window, from: source, to: destination)

        XCTAssertEqual(moved, CGRect(x: -1280, y: 400, width: 1280, height: 700))
    }

    func testMovePreservingSizeMapsOnlyPositionAcrossDifferentDisplays() {
        let source = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let destination = CGRect(x: 1440, y: -276, width: 2560, height: 1416)
        let window = CGRect(x: 720, y: 462, width: 720, height: 438)

        let moved = calculator.movedFrame(
            window,
            from: source,
            to: destination,
            preservingSize: true
        )

        XCTAssertEqual(moved, CGRect(x: 3280, y: 702, width: 720, height: 438))
    }

    func testMovePreservingSizeDoesNotShrinkOversizedWindow() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let destination = CGRect(x: 1000, y: -400, width: 600, height: 400)
        let oversized = CGRect(x: -500, y: -300, width: 2000, height: 1600)

        let moved = calculator.movedFrame(
            oversized,
            from: source,
            to: destination,
            preservingSize: true
        )

        XCTAssertEqual(moved.size, oversized.size)
        XCTAssertEqual(moved.minY, destination.minY)
        XCTAssertGreaterThan(moved.intersection(destination).width, 0)
        XCTAssertEqual(moved.intersection(destination).height, destination.height)
    }

    func testMoveOversizedWindowClampsInsideDestination() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let destination = CGRect(x: 1000, y: -400, width: 600, height: 400)
        let oversized = CGRect(x: -500, y: -300, width: 2000, height: 1600)

        let moved = calculator.movedFrame(oversized, from: source, to: destination)

        XCTAssertEqual(moved, destination)
    }

    func testGapIsSharedAtInternalSeamAndPreservedAtOuterEdges() throws {
        let visible = CGRect(x: 0, y: 20, width: 1200, height: 800)
        let left = try XCTUnwrap(calculator.placementFrame(
            for: .leftHalf,
            windowFrame: .zero,
            visibleFrame: visible,
            gap: 12
        ))
        let right = try XCTUnwrap(calculator.placementFrame(
            for: .rightHalf,
            windowFrame: .zero,
            visibleFrame: visible,
            gap: 12
        ))

        XCTAssertEqual(left.minX - visible.minX, 12)
        XCTAssertEqual(right.minX - left.maxX, 12)
        XCTAssertEqual(visible.maxX - right.maxX, 12)
    }

    func testThirdsFourthsAndSixthsUseExpectedGridCells() throws {
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 900)
        XCTAssertEqual(
            calculator.placementFrame(for: .firstTwoThirds, windowFrame: .zero, visibleFrame: visible, gap: 0),
            CGRect(x: 0, y: 0, width: 800, height: 900)
        )
        XCTAssertEqual(
            calculator.placementFrame(for: .thirdFourth, windowFrame: .zero, visibleFrame: visible, gap: 0),
            CGRect(x: 600, y: 0, width: 300, height: 900)
        )
        XCTAssertEqual(
            calculator.placementFrame(for: .bottomCenterSixth, windowFrame: .zero, visibleFrame: visible, gap: 0),
            CGRect(x: 400, y: 450, width: 400, height: 450)
        )
    }

    func testReasonableSizeUsesSixtyPercentWithRaycastCaps() throws {
        let frame = try XCTUnwrap(calculator.placementFrame(
            for: .reasonableSize,
            windowFrame: .zero,
            visibleFrame: CGRect(x: 0, y: 0, width: 3000, height: 2000),
            gap: 0
        ))

        XCTAssertEqual(frame.size, CGSize(width: 1025, height: 900))
        XCTAssertEqual(frame.midX, 1500)
        XCTAssertEqual(frame.midY, 1000)
    }

    func testCustomCommandResolvesRelativeSizeAnchorOffsetAndClamp() {
        let command = WindowCustomCommand(
            name: "Editor",
            width: .fraction(0.5),
            height: .points(600),
            anchor: .bottomRight,
            offsetX: 200,
            offsetY: 100
        )

        let frame = calculator.customFrame(
            for: command,
            windowFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
            visibleFrame: CGRect(x: 0, y: 20, width: 1400, height: 880),
            gap: 10
        )

        XCTAssertEqual(frame, CGRect(x: 700, y: 290, width: 690, height: 600))
    }
}
