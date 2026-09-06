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

    func testIncrementalResizeAllFourDirectionsCentered() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let windowFrame = CGRect(x: 300, y: 200, width: 400, height: 300)

        let wider = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(wider, CGRect(x: 275, y: 200, width: 450, height: 300))
        XCTAssertEqual(wider.midX, windowFrame.midX)
        XCTAssertEqual(wider.midY, windowFrame.midY)

        let narrower = try calculator.incrementalFrame(
            for: .decreaseWidth,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(narrower, CGRect(x: 325, y: 200, width: 350, height: 300))
        XCTAssertEqual(narrower.midX, windowFrame.midX)
        XCTAssertEqual(narrower.midY, windowFrame.midY)

        let taller = try calculator.incrementalFrame(
            for: .increaseHeight,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(taller, CGRect(x: 300, y: 175, width: 400, height: 350))
        XCTAssertEqual(taller.midX, windowFrame.midX)
        XCTAssertEqual(taller.midY, windowFrame.midY)

        let shorter = try calculator.incrementalFrame(
            for: .decreaseHeight,
            windowFrame: windowFrame,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(shorter, CGRect(x: 300, y: 225, width: 400, height: 250))
        XCTAssertEqual(shorter.midX, windowFrame.midX)
        XCTAssertEqual(shorter.midY, windowFrame.midY)
    }

    func testIncrementalResizeOneEdgeAnchoring() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        // Left-aligned window
        let leftAligned = CGRect(x: 0, y: 200, width: 400, height: 300)
        let leftGrow = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: leftAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(leftGrow, CGRect(x: 0, y: 200, width: 450, height: 300))
        let leftShrink = try calculator.incrementalFrame(
            for: .decreaseWidth,
            windowFrame: leftAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(leftShrink, CGRect(x: 0, y: 200, width: 350, height: 300))

        // Right-aligned window
        let rightAligned = CGRect(x: 800, y: 200, width: 400, height: 300)
        let rightGrow = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: rightAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(rightGrow, CGRect(x: 750, y: 200, width: 450, height: 300))
        let rightShrink = try calculator.incrementalFrame(
            for: .decreaseWidth,
            windowFrame: rightAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(rightShrink, CGRect(x: 850, y: 200, width: 350, height: 300))

        // Top-aligned window
        let topAligned = CGRect(x: 300, y: 0, width: 400, height: 300)
        let topGrow = try calculator.incrementalFrame(
            for: .increaseHeight,
            windowFrame: topAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(topGrow, CGRect(x: 300, y: 0, width: 400, height: 350))
        let topShrink = try calculator.incrementalFrame(
            for: .decreaseHeight,
            windowFrame: topAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(topShrink, CGRect(x: 300, y: 0, width: 400, height: 250))

        // Bottom-aligned window
        let bottomAligned = CGRect(x: 300, y: 500, width: 400, height: 300)
        let bottomGrow = try calculator.incrementalFrame(
            for: .increaseHeight,
            windowFrame: bottomAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(bottomGrow, CGRect(x: 300, y: 450, width: 400, height: 350))
        let bottomShrink = try calculator.incrementalFrame(
            for: .decreaseHeight,
            windowFrame: bottomAligned,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(bottomShrink, CGRect(x: 300, y: 550, width: 400, height: 250))
    }

    func testIncrementalResizeBothEdgesAlignedShrinksAroundCenter() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let fullWidth = CGRect(x: 0, y: 200, width: 1200, height: 300)
        let narrower = try calculator.incrementalFrame(
            for: .decreaseWidth,
            windowFrame: fullWidth,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(narrower, CGRect(x: 25, y: 200, width: 1150, height: 300))
        XCTAssertEqual(narrower.midX, fullWidth.midX)

        let fullHeight = CGRect(x: 300, y: 0, width: 400, height: 800)
        let shorter = try calculator.incrementalFrame(
            for: .decreaseHeight,
            windowFrame: fullHeight,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(shorter, CGRect(x: 300, y: 25, width: 400, height: 750))
        XCTAssertEqual(shorter.midY, fullHeight.midY)
    }

    func testIncrementalResizeGrowthClampedToSafeFrame() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        // Floating near left edge (not aligned, 10pt away)
        let nearLeft = CGRect(x: 10, y: 200, width: 400, height: 300)
        let leftGrown = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: nearLeft,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(leftGrown, CGRect(x: 0, y: 200, width: 450, height: 300))

        // Floating near right edge (not aligned, 10pt away)
        let nearRight = CGRect(x: 790, y: 200, width: 400, height: 300)
        let rightGrown = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: nearRight,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(rightGrown, CGRect(x: 750, y: 200, width: 450, height: 300))

        // Floating near top edge (not aligned, 10pt away)
        let nearTop = CGRect(x: 300, y: 10, width: 400, height: 300)
        let topGrown = try calculator.incrementalFrame(
            for: .increaseHeight,
            windowFrame: nearTop,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(topGrown, CGRect(x: 300, y: 0, width: 400, height: 350))

        // Floating near bottom edge (not aligned, 10pt away)
        let nearBottom = CGRect(x: 300, y: 490, width: 400, height: 300)
        let bottomGrown = try calculator.incrementalFrame(
            for: .increaseHeight,
            windowFrame: nearBottom,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(bottomGrown, CGRect(x: 300, y: 450, width: 400, height: 350))
    }

    func testIncrementalResizeRespectsConfiguredGap() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let gap: CGFloat = 20
        // Effective safe bounds: (20, 20, 1160, 760), maxX = 1180, maxY = 780

        let leftAligned = CGRect(x: 20, y: 200, width: 400, height: 300)
        let leftGrow = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: leftAligned,
            visibleFrame: visibleFrame,
            gap: gap
        )
        XCTAssertEqual(leftGrow, CGRect(x: 20, y: 200, width: 450, height: 300))

        let rightAligned = CGRect(x: 780, y: 200, width: 400, height: 300)
        let rightGrow = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: rightAligned,
            visibleFrame: visibleFrame,
            gap: gap
        )
        XCTAssertEqual(rightGrow, CGRect(x: 730, y: 200, width: 450, height: 300))
    }

    func testIncrementalResizeNegativeDisplayOriginsAndOddDimensions() throws {
        let visibleFrame = CGRect(x: -1511, y: -967, width: 1511, height: 967)
        let oddWindow = CGRect(x: -1000, y: -600, width: 501, height: 301)

        let wider = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: oddWindow,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(wider.width, 551)
        XCTAssertEqual(wider.height, 301)
        XCTAssertEqual(wider.midX, oddWindow.midX)

        let shorter = try calculator.incrementalFrame(
            for: .decreaseHeight,
            windowFrame: oddWindow,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(shorter.width, 501)
        XCTAssertEqual(shorter.height, 251)
        XCTAssertEqual(shorter.midY, oddWindow.midY)
    }

    func testIncrementalResizeThrowsAtLimits() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // At or near maximum width
        let fullWidth = CGRect(x: 0, y: 100, width: 1000, height: 400)
        XCTAssertThrowsError(
            try calculator.incrementalFrame(
                for: .increaseWidth,
                windowFrame: fullWidth,
                visibleFrame: visibleFrame,
                gap: 0
            )
        ) { error in
            XCTAssertEqual(error as? WindowLayoutError, .windowCannotResizeFurther)
        }

        let nearFullWidth = CGRect(x: 0, y: 100, width: 999, height: 400)
        XCTAssertThrowsError(
            try calculator.incrementalFrame(
                for: .increaseWidth,
                windowFrame: nearFullWidth,
                visibleFrame: visibleFrame,
                gap: 0
            )
        ) { error in
            XCTAssertEqual(error as? WindowLayoutError, .windowCannotResizeFurther)
        }

        // At or near minimum width floor (100)
        let minWidth = CGRect(x: 200, y: 100, width: 100, height: 400)
        XCTAssertThrowsError(
            try calculator.incrementalFrame(
                for: .decreaseWidth,
                windowFrame: minWidth,
                visibleFrame: visibleFrame,
                gap: 0
            )
        ) { error in
            XCTAssertEqual(error as? WindowLayoutError, .windowCannotResizeFurther)
        }

        let nearMinWidth = CGRect(x: 200, y: 100, width: 101, height: 400)
        XCTAssertThrowsError(
            try calculator.incrementalFrame(
                for: .decreaseWidth,
                windowFrame: nearMinWidth,
                visibleFrame: visibleFrame,
                gap: 0
            )
        ) { error in
            XCTAssertEqual(error as? WindowLayoutError, .windowCannotResizeFurther)
        }

        // At maximum height
        let fullHeight = CGRect(x: 100, y: 0, width: 400, height: 800)
        XCTAssertThrowsError(
            try calculator.incrementalFrame(
                for: .increaseHeight,
                windowFrame: fullHeight,
                visibleFrame: visibleFrame,
                gap: 0
            )
        ) { error in
            XCTAssertEqual(error as? WindowLayoutError, .windowCannotResizeFurther)
        }

        // At minimum height floor
        let minHeight = CGRect(x: 100, y: 200, width: 400, height: 100)
        XCTAssertThrowsError(
            try calculator.incrementalFrame(
                for: .decreaseHeight,
                windowFrame: minHeight,
                visibleFrame: visibleFrame,
                gap: 0
            )
        ) { error in
            XCTAssertEqual(error as? WindowLayoutError, .windowCannotResizeFurther)
        }
    }

    func testIncrementalResizeClampsToLimitsWhenDifferenceLessThanStep() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        // Clamping to 100 floor when starting at 120
        let nearFloor = CGRect(x: 300, y: 200, width: 120, height: 130)
        let shrunkWidth = try calculator.incrementalFrame(
            for: .decreaseWidth,
            windowFrame: nearFloor,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(shrunkWidth.width, 100)

        let shrunkHeight = try calculator.incrementalFrame(
            for: .decreaseHeight,
            windowFrame: nearFloor,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(shrunkHeight.height, 100)

        // Clamping to maximum ceiling when starting at 980
        let nearCeiling = CGRect(x: 0, y: 100, width: 980, height: 400)
        let grownWidth = try calculator.incrementalFrame(
            for: .increaseWidth,
            windowFrame: nearCeiling,
            visibleFrame: visibleFrame,
            gap: 0
        )
        XCTAssertEqual(grownWidth.width, 1000)
    }
}
