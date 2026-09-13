import AppKit
import XCTest
import MacToolsPluginKit
@testable import ClipboardHistoryPlugin

final class ClipboardHistoryPanelPositionTrackerTests: XCTestCase {
    private let laptop = ClipboardHistoryPanelScreen(
        id: "laptop", frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: NSRect(x: 0, y: 40, width: 1440, height: 835)
    )
    private let external = ClipboardHistoryPanelScreen(
        id: "external", frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 1440, y: 40, width: 1920, height: 1015)
    )
    private let size = NSSize(width: 900, height: 620)

    func testAutomaticRelocationDoesNotSaveButNextLaptopDragDoes() throws {
        var tracker = ClipboardHistoryPanelPositionTracker()
        let original = ClipboardHistoryPanelPlacement.frame(size: size, on: external, savedPosition: nil)
        let relocated = ClipboardHistoryPanelPlacement.frame(size: size, on: laptop, savedPosition: nil)
        tracker.reset(frame: original, screens: [laptop, external])
        XCTAssertTrue(tracker.refreshScreens(frame: relocated, screens: [laptop]))
        XCTAssertNil(tracker.positionToRemember(frame: relocated, screens: [laptop]))
        // A later automatic move must not become a saved user preference either.
        let automatic = relocated.offsetBy(dx: 10, dy: 10)
        XCTAssertNil(tracker.positionToRemember(frame: automatic, screens: [laptop]))

        tracker.beginUserMovement(frame: automatic, screens: [laptop])
        let dragged = NSRect(x: 500, y: 240, width: size.width, height: size.height)
        let saved = try XCTUnwrap(tracker.positionToRemember(frame: dragged, screens: [laptop]))
        XCTAssertEqual(saved.screenID, laptop.id)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: laptop, savedPosition: saved.position), dragged)
        tracker.endUserMovement()
        XCTAssertNil(tracker.positionToRemember(frame: dragged.offsetBy(dx: -20, dy: 0), screens: [laptop]))
    }

    func testResolutionChangeDuringDragRequiresNewUserMovement() throws {
        var tracker = ClipboardHistoryPanelPositionTracker()
        let original = ClipboardHistoryPanelPlacement.frame(size: size, on: laptop, savedPosition: nil)
        let resized = ClipboardHistoryPanelScreen(
            id: laptop.id, frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: NSRect(x: 0, y: 40, width: 1280, height: 735)
        )
        let adjusted = ClipboardHistoryPanelPlacement.frame(size: size, on: resized, savedPosition: nil)
        tracker.beginUserMovement(frame: original, screens: [laptop])
        // Movement notifications can arrive before the host's display-change callback.
        XCTAssertNil(tracker.positionToRemember(frame: adjusted, screens: [resized]))
        XCTAssertNil(tracker.positionToRemember(frame: adjusted.offsetBy(dx: 5, dy: 0), screens: [resized]))
        tracker.beginUserMovement(frame: adjusted, screens: [resized])
        let dragged = adjusted.offsetBy(dx: 30, dy: -20)
        let saved = try XCTUnwrap(tracker.positionToRemember(frame: dragged, screens: [resized]))
        XCTAssertEqual(saved.screenID, laptop.id)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: resized, savedPosition: saved.position), dragged)
    }

    func testCrossDisplayDragUsesDestinationWithoutTreatingItAsReconfiguration() throws {
        var tracker = ClipboardHistoryPanelPositionTracker()
        let screens = [laptop, external]
        let original = ClipboardHistoryPanelPlacement.frame(size: size, on: laptop, savedPosition: nil)
        let dragged = NSRect(x: 1550, y: 150, width: size.width, height: size.height)
        tracker.beginUserMovement(frame: original, screens: screens)
        XCTAssertFalse(tracker.refreshScreens(frame: dragged, screens: screens))
        let saved = try XCTUnwrap(tracker.positionToRemember(frame: dragged, screens: screens))
        XCTAssertEqual(saved.screenID, external.id)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: external, savedPosition: saved.position), dragged)
        XCTAssertNil(tracker.positionToRemember(frame: dragged, screens: screens))
    }

    func testFinalSnapReplacesTheDragPositionBeforeMovementEnds() throws {
        var tracker = ClipboardHistoryPanelPositionTracker()
        let screens = [laptop, external]
        let target = WindowSnapGeometry.defaultFrame(contentSize: size, visibleFrame: external.visibleFrame)
        let proposed = target.offsetBy(dx: 12, dy: -10)
        tracker.beginUserMovement(frame: proposed.offsetBy(dx: 80, dy: 60), screens: screens)
        let intermediate = try XCTUnwrap(tracker.positionToRemember(frame: proposed, screens: screens))
        let snapped = WindowSnapGeometry.calculate(
            proposedFrame: proposed, contentSize: size, visibleFrame: external.visibleFrame
        )
        XCTAssertTrue(snapped.isFullySnapped)
        let final = try XCTUnwrap(tracker.positionToRemember(frame: snapped.snappedFrame, screens: screens))
        tracker.endUserMovement()
        XCTAssertNotEqual(final.position, intermediate.position)
        XCTAssertEqual(final.screenID, external.id)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: external, savedPosition: final.position), target)
    }

    func testReconnectionPreservesEachDisplaysIndependentPosition() throws {
        var tracker = ClipboardHistoryPanelPositionTracker()
        let externalPosition = ClipboardHistoryPanelPosition(left: 110, top: 90)
        let externalFrame = ClipboardHistoryPanelPlacement.frame(size: size, on: external, savedPosition: externalPosition)
        tracker.reset(frame: externalFrame, screens: [laptop, external])
        let laptopFrame = ClipboardHistoryPanelPlacement.frame(size: size, on: laptop, savedPosition: nil)
        tracker.refreshScreens(frame: laptopFrame, screens: [laptop])
        tracker.beginUserMovement(frame: laptopFrame, screens: [laptop])
        let dragged = laptopFrame.offsetBy(dx: 25, dy: 10)
        let laptopPosition = try XCTUnwrap(tracker.positionToRemember(frame: dragged, screens: [laptop]))
        var positions = [external.id: externalPosition]
        positions[laptopPosition.screenID] = laptopPosition.position
        tracker.endUserMovement()
        tracker.refreshScreens(frame: dragged, screens: [laptop, external])
        XCTAssertNil(tracker.positionToRemember(frame: externalFrame, screens: [laptop, external]))
        XCTAssertEqual(positions[external.id], externalPosition)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: laptop, savedPosition: positions[laptop.id]), dragged)
        XCTAssertEqual(ClipboardHistoryPanelPlacement.frame(size: size, on: external, savedPosition: positions[external.id]), externalFrame)
    }
}
