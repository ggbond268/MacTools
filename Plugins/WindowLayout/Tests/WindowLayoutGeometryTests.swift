import XCTest
@testable import WindowLayoutPlugin

final class WindowLayoutGeometryTests: XCTestCase {
    private let V = CGRect(x: 100, y: 50, width: 1000, height: 800)

    func testLeftHalf() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .leftHalf,
            visibleFrame: V,
            currentFrame: CGRect(x: 200, y: 100, width: 400, height: 300),
            inset: 8
        )
        XCTAssertEqual(frame, CGRect(x: 100, y: 50, width: 500, height: 800))
    }

    func testCenterHalf() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .centerHalf,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 8
        )
        XCTAssertEqual(frame, CGRect(x: 350, y: 50, width: 500, height: 800))
    }

    func testAlmostMaximizeUsesInset() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .almostMaximize,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 10
        )
        XCTAssertEqual(frame, V.insetBy(dx: 10, dy: 10))
    }

    func testGrowClampsInsideVisibleFrame() {
        let current = V.insetBy(dx: 5, dy: 5)
        let frame = WindowLayoutGeometry.targetFrame(
            action: .grow,
            visibleFrame: V,
            currentFrame: current,
            inset: 8
        )
        XCTAssertEqual(frame, V)
    }

    func testCenterKeepsSize() {
        let current = CGRect(x: 120, y: 80, width: 300, height: 200)
        let frame = WindowLayoutGeometry.targetFrame(
            action: .center,
            visibleFrame: V,
            currentFrame: current,
            inset: 8
        )
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(frame.midX, V.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, V.midY, accuracy: 0.5)
    }

    func testLeftThirdAndTwoThirds() {
        let third = WindowLayoutGeometry.targetFrame(
            action: .leftThird,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 8
        )
        XCTAssertEqual(third.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(third.width, 1000 / 3, accuracy: 0.5)
        XCTAssertEqual(third.height, 800)

        let twoThirds = WindowLayoutGeometry.targetFrame(
            action: .rightTwoThirds,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 8
        )
        XCTAssertEqual(twoThirds.width, 2 * 1000 / 3, accuracy: 0.5)
        XCTAssertEqual(twoThirds.maxX, V.maxX, accuracy: 0.5)
    }

    func testTopLeftQuarter() {
        let frame = WindowLayoutGeometry.targetFrame(
            action: .topLeftQuarter,
            visibleFrame: V,
            currentFrame: .zero,
            inset: 8
        )
        XCTAssertEqual(frame, CGRect(x: 100, y: 450, width: 500, height: 400))
    }

    func testShrinkRespectsMinimumSize() {
        let tiny = CGRect(x: 400, y: 300, width: 210, height: 130)
        let frame = WindowLayoutGeometry.targetFrame(
            action: .shrink,
            visibleFrame: V,
            currentFrame: tiny,
            inset: 8
        )
        XCTAssertGreaterThanOrEqual(frame.width, WindowLayoutGeometry.minimumSize.width)
        XCTAssertGreaterThanOrEqual(frame.height, WindowLayoutGeometry.minimumSize.height)
    }

    func testAllActionsProduceFiniteRectsWithMinimumSize() {
        for action in WindowLayoutAction.allCases where action != .restore {
            let frame = WindowLayoutGeometry.targetFrame(
                action: action,
                visibleFrame: V,
                currentFrame: CGRect(x: 150, y: 100, width: 400, height: 300),
                inset: 8
            )
            XCTAssertFalse(frame.isNull)
            XCTAssertGreaterThanOrEqual(frame.width, WindowLayoutGeometry.minimumSize.width)
            XCTAssertGreaterThanOrEqual(frame.height, WindowLayoutGeometry.minimumSize.height)
        }
    }
}
