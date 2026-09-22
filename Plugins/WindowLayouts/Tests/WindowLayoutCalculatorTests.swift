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

    func testMoveBetweenDifferentDisplaySizesPreservesRelativePlacementAndSize() {
        let source = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let destination = CGRect(x: -2560, y: -300, width: 2560, height: 1400)
        let window = CGRect(x: 720, y: 462, width: 720, height: 438)

        let moved = calculator.movedFrame(window, from: source, to: destination)

        XCTAssertEqual(moved, CGRect(x: -1280, y: 400, width: 1280, height: 700))
    }

    func testMoveOversizedWindowClampsInsideDestination() {
        let source = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let destination = CGRect(x: 1000, y: -400, width: 600, height: 400)
        let oversized = CGRect(x: -500, y: -300, width: 2000, height: 1600)

        let moved = calculator.movedFrame(oversized, from: source, to: destination)

        XCTAssertEqual(moved, destination)
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

}
