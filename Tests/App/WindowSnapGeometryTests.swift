import AppKit
import XCTest
@testable import MacTools
@testable import MacToolsPluginKit

final class WindowSnapGeometryTests: XCTestCase {
    private let contentSize = CGSize(width: 720, height: 710)

    func testDefaultFrameCentersHorizontallyAndVertically() {
        let visibleFrame = CGRect(x: 0, y: 50, width: 1920, height: 1000)
        let frame = WindowSnapGeometry.defaultFrame(
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.size.width, 720)
        XCTAssertEqual(frame.size.height, 710)
        XCTAssertEqual(frame.minX, 600) // (1920 - 720) / 2
        XCTAssertEqual(frame.minY, 50 + (1000 - 710) / 2) // 50 + 145 = 195
        XCTAssertTrue(visibleFrame.contains(frame))
    }

    func testMultiDisplayWithNegativeCoordinates() {
        let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let leftFrame = WindowSnapGeometry.defaultFrame(
            contentSize: contentSize,
            visibleFrame: leftDisplay
        )

        XCTAssertEqual(leftFrame.size, contentSize)
        XCTAssertEqual(leftFrame.minX, -1920 + (1920 - 720) / 2) // -1320
        XCTAssertEqual(leftFrame.minY, (1055 - 710) / 2) // 172.5
        XCTAssertTrue(leftDisplay.contains(leftFrame))

        let topDisplay = CGRect(x: 0, y: 1080, width: 2560, height: 1400)
        let topFrame = WindowSnapGeometry.defaultFrame(
            contentSize: contentSize,
            visibleFrame: topDisplay
        )

        XCTAssertEqual(topFrame.size, contentSize)
        XCTAssertEqual(topFrame.minX, (2560 - 720) / 2) // 920
        XCTAssertEqual(topFrame.minY, 1080 + (1400 - 710) / 2) // 1425
        XCTAssertTrue(topDisplay.contains(topFrame))
    }

    func testSnapThresholdAndHysteresis() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let defaultFrame = WindowSnapGeometry.defaultFrame(
            contentSize: contentSize,
            visibleFrame: visibleFrame
        ) // minX: 600, minY: 185, maxX: 1320, maxY: 895

        // Within 20pt threshold horizontally: should snap X
        let nearX = CGRect(x: 615, y: 300, width: 720, height: 710)
        let resultNearX = WindowSnapGeometry.calculate(
            proposedFrame: nearX,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            threshold: 20,
            hysteresis: 4,
            currentlySnappingX: false,
            currentlySnappingY: false
        )
        XCTAssertTrue(resultNearX.isSnappingX)
        XCTAssertFalse(resultNearX.isSnappingY)
        XCTAssertEqual(resultNearX.snappedFrame.minX, defaultFrame.minX)
        XCTAssertEqual(resultNearX.snappedFrame.minY, 300)

        // Left and right guides should be highlighted when snapping X
        let leftGuide = resultNearX.guides.first { $0.role == .leftEdge }
        let rightGuide = resultNearX.guides.first { $0.role == .rightEdge }
        let topGuide = resultNearX.guides.first { $0.role == .topEdge }
        XCTAssertEqual(leftGuide?.isHighlighted, true)
        XCTAssertEqual(rightGuide?.isHighlighted, true)
        XCTAssertEqual(topGuide?.isHighlighted, false)

        // Beyond 20pt threshold horizontally without previous snap: should not snap X
        let farX = CGRect(x: 622, y: 300, width: 720, height: 710)
        let resultFarX = WindowSnapGeometry.calculate(
            proposedFrame: farX,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            threshold: 20,
            hysteresis: 4,
            currentlySnappingX: false,
            currentlySnappingY: false
        )
        XCTAssertFalse(resultFarX.isSnappingX)
        XCTAssertEqual(resultFarX.snappedFrame.minX, 622)

        // With hysteresis: when currentlySnappingX is true, 22pt (<= 24pt) should stay snapped
        let hysteresisX = WindowSnapGeometry.calculate(
            proposedFrame: farX,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            threshold: 20,
            hysteresis: 4,
            currentlySnappingX: true,
            currentlySnappingY: false
        )
        XCTAssertTrue(hysteresisX.isSnappingX)
        XCTAssertEqual(hysteresisX.snappedFrame.minX, defaultFrame.minX)

        // Beyond 24pt (threshold + hysteresis): should break snap even with hysteresis
        let brokenX = CGRect(x: 626, y: 300, width: 720, height: 710)
        let resultBrokenX = WindowSnapGeometry.calculate(
            proposedFrame: brokenX,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            threshold: 20,
            hysteresis: 4,
            currentlySnappingX: true,
            currentlySnappingY: false
        )
        XCTAssertFalse(resultBrokenX.isSnappingX)

        // Vertical snapping: within 20pt of maxY (895)
        let resultNearY = WindowSnapGeometry.calculate(
            proposedFrame: CGRect(x: 400, y: 195, width: 720, height: 710),
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            threshold: 20,
            hysteresis: 4,
            currentlySnappingX: false,
            currentlySnappingY: false
        )
        XCTAssertFalse(resultNearY.isSnappingX)
        XCTAssertTrue(resultNearY.isSnappingY)
        XCTAssertEqual(resultNearY.snappedFrame.minY, defaultFrame.minY)

        let topGuideHighlighted = resultNearY.guides.first { $0.role == .topEdge }
        XCTAssertEqual(topGuideHighlighted?.isHighlighted, true)

        // Both X and Y snapping
        let fullySnapped = WindowSnapGeometry.calculate(
            proposedFrame: CGRect(x: 610, y: 190, width: 720, height: 710),
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            threshold: 20,
            hysteresis: 4,
            currentlySnappingX: false,
            currentlySnappingY: false
        )
        XCTAssertTrue(fullySnapped.isFullySnapped)
        XCTAssertEqual(fullySnapped.snappedFrame, defaultFrame)
    }

    func testReferenceInsetsAlignGuidesWithoutChangingTheSnapFrame() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let result = WindowSnapGeometry.calculate(
            proposedFrame: CGRect(x: 600, y: 185, width: 720, height: 710),
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            referenceInsets: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        )

        XCTAssertEqual(result.defaultFrame, CGRect(x: 600, y: 185, width: 720, height: 710))
        XCTAssertEqual(result.snappedFrame, result.defaultFrame)
        XCTAssertEqual(
            try XCTUnwrap(result.guides.first { $0.role == .leftEdge }).start.x,
            result.defaultFrame.minX + 24
        )
        XCTAssertEqual(
            try XCTUnwrap(result.guides.first { $0.role == .rightEdge }).start.x,
            result.defaultFrame.maxX - 24
        )
        XCTAssertEqual(
            try XCTUnwrap(result.guides.first { $0.role == .topEdge }).start.y,
            result.defaultFrame.maxY - 24
        )
    }

    func testPaletteSurfaceInsetsMatchTheVisiblePalettePadding() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let result = WindowSnapGeometry.calculate(
            proposedFrame: WindowSnapGeometry.defaultFrame(
                contentSize: StandaloneCommandPaletteLayout.contentSize,
                visibleFrame: visibleFrame
            ),
            contentSize: StandaloneCommandPaletteLayout.contentSize,
            visibleFrame: visibleFrame,
            referenceInsets: StandaloneCommandPaletteLayout.surfaceInsets
        )

        let expectedSurface = result.defaultFrame.insetBy(
            dx: StandaloneCommandPaletteLayout.surfaceInset,
            dy: StandaloneCommandPaletteLayout.surfaceInset
        )
        XCTAssertEqual(
            try XCTUnwrap(result.guides.first { $0.role == .leftEdge }).start.x,
            expectedSurface.minX
        )
        XCTAssertEqual(
            try XCTUnwrap(result.guides.first { $0.role == .rightEdge }).start.x,
            expectedSurface.maxX
        )
        XCTAssertEqual(
            try XCTUnwrap(result.guides.first { $0.role == .topEdge }).start.y,
            expectedSurface.maxY
        )
    }

    func testClampingKeepsWindowFullyAccessible() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)

        // Window partially off left edge
        let offLeft = CGRect(x: 0, y: 100, width: 720, height: 710)
        let clampedLeft = WindowSnapGeometry.clampedFrame(offLeft, in: visibleFrame)
        XCTAssertEqual(clampedLeft.minX, 100)
        XCTAssertEqual(clampedLeft.minY, 100)
        XCTAssertTrue(visibleFrame.contains(clampedLeft))

        // Window partially off right edge
        let offRight = CGRect(x: 800, y: 100, width: 720, height: 710)
        let clampedRight = WindowSnapGeometry.clampedFrame(offRight, in: visibleFrame)
        XCTAssertEqual(clampedRight.maxX, visibleFrame.maxX) // 1300
        XCTAssertEqual(clampedRight.minX, 1300 - 720) // 580
        XCTAssertTrue(visibleFrame.contains(clampedRight))

        // Window partially off top edge
        let offTop = CGRect(x: 300, y: 300, width: 720, height: 710) // maxY = 1010 > 850
        let clampedTop = WindowSnapGeometry.clampedFrame(offTop, in: visibleFrame)
        XCTAssertEqual(clampedTop.maxY, visibleFrame.maxY) // 850
        XCTAssertEqual(clampedTop.minY, 850 - 710) // 140
        XCTAssertTrue(visibleFrame.contains(clampedTop))

        // Window partially off bottom edge
        let offBottom = CGRect(x: 300, y: 0, width: 720, height: 710)
        let clampedBottom = WindowSnapGeometry.clampedFrame(offBottom, in: visibleFrame)
        XCTAssertEqual(clampedBottom.minY, visibleFrame.minY) // 50
        XCTAssertTrue(visibleFrame.contains(clampedBottom))
    }

    func testDisplaysSmallerThanNormalPaletteFrame() {
        let smallVisibleFrame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let frame = WindowSnapGeometry.defaultFrame(
            contentSize: contentSize,
            visibleFrame: smallVisibleFrame
        )

        XCTAssertEqual(frame.size.width, 600)
        XCTAssertEqual(frame.size.height, 500)
        XCTAssertEqual(frame.origin, .zero)
        XCTAssertTrue(smallVisibleFrame.contains(frame))

        let customPoint = CGPoint(x: 0.8, y: 0.8)
        let customFrame = WindowSnapGeometry.frame(
            for: .custom(normalizedPoint: customPoint),
            contentSize: contentSize,
            visibleFrame: smallVisibleFrame
        )
        XCTAssertEqual(customFrame.size.width, 600)
        XCTAssertEqual(customFrame.size.height, 500)
        XCTAssertEqual(customFrame.origin, .zero)
        XCTAssertTrue(smallVisibleFrame.contains(customFrame))
    }

    func testNormalizedPointRoundtripAcrossDifferentDisplays() {
        let display1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let display2 = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let display3 = CGRect(x: -1920, y: 0, width: 1920, height: 1055)

        // Place window at 25% horizontal travel, 75% vertical travel on display1
        let point = CGPoint(x: 0.25, y: 0.75)
        let frame1 = WindowSnapGeometry.frame(
            for: .custom(normalizedPoint: point),
            contentSize: contentSize,
            visibleFrame: display1
        )
        XCTAssertTrue(display1.contains(frame1))

        let normPoint1 = WindowSnapGeometry.normalizedPoint(for: frame1, in: display1)
        XCTAssertEqual(normPoint1.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normPoint1.y, 0.75, accuracy: 0.001)

        // Reproduce on display 2
        let frame2 = WindowSnapGeometry.frame(
            for: .custom(normalizedPoint: normPoint1),
            contentSize: contentSize,
            visibleFrame: display2
        )
        XCTAssertTrue(display2.contains(frame2))
        let normPoint2 = WindowSnapGeometry.normalizedPoint(for: frame2, in: display2)
        XCTAssertEqual(normPoint2.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normPoint2.y, 0.75, accuracy: 0.001)

        // Reproduce on negative-coordinate display 3
        let frame3 = WindowSnapGeometry.frame(
            for: .custom(normalizedPoint: normPoint1),
            contentSize: contentSize,
            visibleFrame: display3
        )
        XCTAssertTrue(display3.contains(frame3))
        let normPoint3 = WindowSnapGeometry.normalizedPoint(for: frame3, in: display3)
        XCTAssertEqual(normPoint3.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(normPoint3.y, 0.75, accuracy: 0.001)
    }

    func testDefaultAnchorPreservedAcrossDisplays() {
        let display1 = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let display2 = CGRect(x: -1920, y: 100, width: 1440, height: 900)

        let frame1 = WindowSnapGeometry.frame(
            for: .defaultAnchor,
            contentSize: contentSize,
            visibleFrame: display1
        )
        XCTAssertEqual(frame1, WindowSnapGeometry.defaultFrame(contentSize: contentSize, visibleFrame: display1))

        let frame2 = WindowSnapGeometry.frame(
            for: .defaultAnchor,
            contentSize: contentSize,
            visibleFrame: display2
        )
        XCTAssertEqual(frame2, WindowSnapGeometry.defaultFrame(contentSize: contentSize, visibleFrame: display2))
    }
}

@MainActor
final class WindowSnapOverlayControllerTests: XCTestCase {
    func testShowGuidesMakesOverlayVisibleAboveRelativeWindow() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let relativeWindow = NSPanel(
            contentRect: CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        relativeWindow.level = .floating
        relativeWindow.orderFrontRegardless()

        let controller = WindowSnapOverlayController()
        defer {
            controller.hide()
            relativeWindow.orderOut(nil)
        }

        let guide = WindowSnapGuide(
            id: "guide.test",
            role: .leftEdge,
            orientation: .vertical,
            start: CGPoint(x: screen.frame.midX, y: screen.frame.minY),
            end: CGPoint(x: screen.frame.midX, y: screen.frame.maxY),
            isHighlighted: false
        )
        controller.showGuides([guide], on: screen, relativeTo: relativeWindow)

        let overlay = try XCTUnwrap(controller.presentedPanelsForTests.first)
        XCTAssertTrue(overlay.isVisible)
        XCTAssertGreaterThan(overlay.windowNumber, 0)
        XCTAssertTrue(overlay.ignoresMouseEvents)
        XCTAssertFalse(overlay.canBecomeKey)
        XCTAssertGreaterThan(overlay.level.rawValue, relativeWindow.level.rawValue)
        XCTAssertEqual(controller.presentedPanelsForTests.count, 1)
        XCTAssertLessThanOrEqual(overlay.frame.width, 6)
        XCTAssertEqual(overlay.frame.height, screen.frame.height, accuracy: 0.001)
        XCTAssertEqual(overlay.frame.midX, screen.frame.midX, accuracy: 0.5)

        let renderedGuide = try XCTUnwrap(controller.renderedGuidesForTests.first)
        XCTAssertEqual(renderedGuide.id, guide.id)
        XCTAssertEqual(renderedGuide.start.x, screen.frame.midX, accuracy: 0.001)
        XCTAssertEqual(renderedGuide.start.y, screen.frame.minY, accuracy: 0.001)
        XCTAssertEqual(renderedGuide.end.x, screen.frame.midX, accuracy: 0.001)
        XCTAssertEqual(renderedGuide.end.y, screen.frame.maxY, accuracy: 0.001)

        controller.hide()
        XCTAssertFalse(overlay.isVisible)
    }
}

@MainActor
final class WindowSnapCoordinatorTests: XCTestCase {
    func testGuidesRemainUntilPhysicalMouseButtonRelease() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let window = NSPanel(
            contentRect: CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var pressedButtons = 1
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WindowSnapCoordinatorTests.\(UUID().uuidString)"))
        let controller = WindowSnapOverlayController()
        let coordinator = WindowSnapCoordinator(
            role: .commandPalette,
            positionStore: WindowPositionStore(userDefaults: defaults),
            overlayController: controller,
            pressedMouseButtonsProvider: { pressedButtons },
            dragReleasePollInterval: .milliseconds(5)
        )
        coordinator.attach(to: window)
        defer {
            coordinator.finishDragging()
            controller.hide()
        }

        coordinator.startDragging()
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertTrue(coordinator.isDragging)
        XCTAssertEqual(controller.presentedPanelsForTests.count, 3)
        XCTAssertTrue(controller.presentedPanelsForTests.allSatisfy(\.isVisible))

        pressedButtons = 0
        for _ in 0..<20 where coordinator.isDragging {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(coordinator.isDragging)
        XCTAssertTrue(controller.presentedPanelsForTests.isEmpty)
    }

    func testPluginWindowGuidesFollowTheCurrentResizedFrame() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let window = NSPanel(
            contentRect: CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 420, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let overlayController = WindowSnapOverlayController()
        let coordinator = PluginWindowSnapCoordinator(
            overlayController: overlayController,
            pressedMouseButtonsProvider: { 1 }
        )
        coordinator.attach(to: window)
        defer {
            coordinator.cancelDragging()
            window.orderOut(nil)
        }

        coordinator.startDragging()
        let originalLeftX = try XCTUnwrap(
            overlayController.renderedGuidesForTests.first { $0.role == .leftEdge }
        ).start.x

        window.setFrame(
            CGRect(origin: window.frame.origin, size: CGSize(width: 680, height: 500)),
            display: false
        )
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)

        let resizedTarget = WindowSnapGeometry.defaultFrame(
            contentSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        )
        let resizedLeftX = try XCTUnwrap(
            overlayController.renderedGuidesForTests.first { $0.role == .leftEdge }
        ).start.x
        let resizedRightX = try XCTUnwrap(
            overlayController.renderedGuidesForTests.first { $0.role == .rightEdge }
        ).start.x

        XCTAssertNotEqual(resizedLeftX, originalLeftX)
        XCTAssertEqual(resizedLeftX, resizedTarget.minX, accuracy: 0.001)
        XCTAssertEqual(resizedRightX, resizedTarget.maxX, accuracy: 0.001)
    }
}
