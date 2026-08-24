import CoreGraphics
import XCTest
@testable import WindowLayoutsPlugin

final class WindowScreenResolverTests: XCTestCase {
    private let resolver = WindowScreenResolver()

    func testChoosesLargestIntersectionAcrossNegativeOrigins() {
        let left = WindowScreen(
            id: "left",
            frame: CGRect(x: -1600, y: -200, width: 1600, height: 1000),
            visibleFrame: CGRect(x: -1600, y: -176, width: 1600, height: 976)
        )
        let main = WindowScreen(
            id: "main",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )
        let window = CGRect(x: -300, y: 100, width: 500, height: 500)

        XCTAssertEqual(resolver.screen(for: window, among: [main, left])?.id, "left")
    }

    func testWindowOutsideEveryDisplayUsesNearestDisplay() {
        let left = WindowScreen(
            id: "left",
            frame: CGRect(x: -1600, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: -1600, y: 24, width: 1600, height: 976)
        )
        let right = WindowScreen(
            id: "right",
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976)
        )

        XCTAssertEqual(
            resolver.screen(
                for: CGRect(x: 1800, y: 100, width: 200, height: 200),
                among: [left, right]
            )?.id,
            "right"
        )
    }

    func testAdjacentScreenOrderIsDeterministicForVerticalAndHorizontalDisplays() {
        let top = WindowScreen(
            id: "top",
            frame: CGRect(x: 0, y: -900, width: 1200, height: 900),
            visibleFrame: CGRect(x: 0, y: -876, width: 1200, height: 876)
        )
        let main = WindowScreen(
            id: "main",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1200, height: 876)
        )
        let right = WindowScreen(
            id: "right",
            frame: CGRect(x: 1200, y: 100, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 1200, y: 124, width: 1600, height: 976)
        )
        let screens = [right, main, top]

        XCTAssertEqual(
            resolver.adjacentScreen(to: top, direction: .moveToNextDisplay, among: screens)?.id,
            "main"
        )
        XCTAssertEqual(
            resolver.adjacentScreen(to: top, direction: .moveToPreviousDisplay, among: screens)?.id,
            "right"
        )
    }
}
