import AppKit
import XCTest
@testable import MacTools

final class MenuBarStatusItemControllerTests: XCTestCase {
    func testNilEventDefaultsToFeaturePanel() {
        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: nil), .featurePanel)
    }

    func testLeftMouseUpOpensFeaturePanel() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .featurePanel)
    }

    func testRightMouseUpOpensComponentPanel() {
        let event = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .componentPanel)
    }

    func testControlClickOpensComponentPanel() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .componentPanel)
    }
}
