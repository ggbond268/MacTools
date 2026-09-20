import AppKit
import XCTest
@testable import MacTools

final class MenuBarStatusItemControllerTests: XCTestCase {
    func testLeftMouseDownOpensComponentPanelImmediately() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
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

    func testRightMouseDownOpensFeaturePanelImmediately() {
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
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

    func testModifierLeftClicksRouteOnlyOptionToRightClickAction() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: mouseEvent(.leftMouseUp, modifiers: [.control])),
            .componentPanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: mouseEvent(.leftMouseUp, modifiers: [.option])),
            .featurePanel
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    }

    func testTypedPanelRequestsKeepTheirExplicitTargets() {
        XCTAssertEqual(
            MenuBarStatusItemPresentationAction(request: .toggleDashboard),
            .toggleComponentPanel
        )
        XCTAssertEqual(
            MenuBarStatusItemPresentationAction(request: .toggleFeaturePanel),
            .toggleFeaturePanel
        )
        XCTAssertEqual(
            MenuBarStatusItemPresentationAction(request: .toggleCommandPalette),
            .toggleCommandPalette
        )
        XCTAssertEqual(
            MenuBarStatusItemPresentationAction(request: .showDashboard),
            .showComponentPanel
        )
        XCTAssertEqual(
            MenuBarStatusItemPresentationAction(request: .showFeaturePanel),
            .showFeaturePanel
        )
        XCTAssertEqual(
            MenuBarStatusItemPresentationAction(request: .showUnifiedSearch),
            .showUnifiedSearch
        )
    }

    func testGlobalMousePolicyRecognizesStatusItemLocation() {
        let buttonFrame = NSRect(x: 100, y: 900, width: 24, height: 24)

        XCTAssertTrue(
            MenuBarGlobalMouseEventPolicy.isStatusItemClick(
                for: globalMouseEvent(x: 110, y: 910),
                buttonFrame: buttonFrame
            )
        )
        XCTAssertFalse(
            MenuBarGlobalMouseEventPolicy.isStatusItemClick(
                for: globalMouseEvent(x: 400, y: 400),
                buttonFrame: buttonFrame
            )
        )
    }

    private func globalMouseEvent(
        x: Double,
        y: Double
    ) -> MenuBarGlobalMouseEvent {
        MenuBarGlobalMouseEvent(screenX: x, screenY: y)
    }

}
