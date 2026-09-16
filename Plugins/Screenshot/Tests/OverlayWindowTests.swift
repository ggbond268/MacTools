import AppKit
import MacToolsPluginKit
import QuartzCore
import XCTest

@testable import ScreenshotPlugin

@MainActor
final class OverlayWindowTests: XCTestCase {
    func testCaptureWindowIsNonactivatingAndExcludedFromCapture() throws {
        let window = try makeWindow()
        defer { window.dismiss() }

        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.isFloatingPanel)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.isMovable)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertFalse(try XCTUnwrap(window.contentView).mouseDownCanMoveWindow)
        XCTAssertEqual(window.animationBehavior, .none)
        XCTAssertEqual(window.sharingType, .none)
    }

    func testCaptureWindowKeepsOpaqueBackingAcrossReusedSessions() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try XCTUnwrap(context?.makeImage())

        for quick in [false, true] {
            window.prepare(screen: screen, frozen: image, windows: [], quick: quick)
            window.prepareForPresentation()
            // An opaque image layer does not replace the native window's backing contract.
            XCTAssertTrue(window.isOpaque)
            XCTAssertEqual(window.backgroundColor.alphaComponent, 1)
            XCTAssertEqual(window.alphaValue, 1)
            window.dismiss()
            XCTAssertEqual(window.backgroundColor.alphaComponent, 1)
        }
    }

    func testMagnifierColorValueSwitchesBetweenRGBAndHex() {
        let color = MagnifierColorValue(red: 12, green: 171, blue: 255)
        var format = MagnifierColorFormat.rgb

        XCTAssertEqual(color.value(for: format), "12, 171, 255")
        format.toggle()
        XCTAssertEqual(color.value(for: format), "#0CABFF")
        format.toggle()
        XCTAssertEqual(color.value(for: format), "12, 171, 255")
    }

    func testCopyingMagnifierValueClosesCaptureAfterWritingPasteboard() throws {
        let environment = ScreenshotEnvironment(
            context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage())
        )
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 120), environment: environment)
        let pasteboard = NSPasteboard(name: .init("ScreenshotMagnifierTests.\(UUID().uuidString)"))
        var cancellations = 0
        view.onCancel = { cancellations += 1 }

        XCTAssertTrue(view.copyMagnifierValue("#0CABFF", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "#0CABFF")
        XCTAssertEqual(cancellations, 1)
        pasteboard.clearContents()
    }

    func testSessionBarFittingSizePreservesExactVerticalPadding() {
        let button = NSButton(title: "Action", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        let content = CaptureActionBar.content([button])
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        let buttonFrame = button.convert(button.bounds, to: content)

        XCTAssertEqual(
            size.height,
            button.fittingSize.height + CaptureActionBar.insets.top + CaptureActionBar.insets.bottom,
            accuracy: 0.5
        )
        XCTAssertEqual(buttonFrame.minY, CaptureActionBar.insets.bottom, accuracy: 0.5)
        XCTAssertEqual(content.bounds.maxY - buttonFrame.maxY, CaptureActionBar.insets.top, accuracy: 0.5)
    }

    func testSessionButtonAppearanceMatchesTheModeConfirmationActions() throws {
        let button = NSButton(title: "Action", target: nil, action: nil)

        CaptureActionBar.configure(button, isPrimary: true)

        XCTAssertEqual(button.controlSize, .regular)
        XCTAssertEqual(button.font?.pointSize, 13)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Native capsule button borders require macOS 26 or later")
        }
        XCTAssertEqual(button.borderShape, .capsule)
    }

    func testModeBarOnlyAppearsOnThePointerDisplay() {
        XCTAssertTrue(OverlayView.modeBarShouldBeVisible(
            quick: false,
            pointerInside: true,
            overlapsSelection: false
        ))
        XCTAssertFalse(OverlayView.modeBarShouldBeVisible(
            quick: false,
            pointerInside: false,
            overlapsSelection: false
        ))
        XCTAssertFalse(OverlayView.modeBarShouldBeVisible(
            quick: true,
            pointerInside: true,
            overlapsSelection: false
        ))
        XCTAssertFalse(OverlayView.modeBarShouldBeVisible(
            quick: false,
            pointerInside: true,
            overlapsSelection: true
        ))
    }

    func testModeBarDragLocksHeightClampsEdgesAndSurvivesPointerReentry() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        var pointer = window.convertPoint(toScreen: NSPoint(x: 100, y: 100))
        let tracker = CapturePointerTracker(overlays: [window], mouseLocation: { pointer })
        defer { tracker.stop() }
        let entry = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: NSPoint(x: 100, y: 100), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        view.mouseEntered(with: entry)
        let bar = try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "screenshot.modeBar" })
        bar.layoutSubtreeIfNeeded()
        func findHandle(in root: NSView) -> DragHandle? {
            if let handle = root as? DragHandle { return handle }
            return root.subviews.lazy.compactMap { findHandle(in: $0) }.first
        }
        let handle = try XCTUnwrap(findHandle(in: bar))
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
        }
        let origin = bar.frame.origin
        let start = NSPoint(x: origin.x + 10, y: origin.y + 16)
        handle.mouseDown(with: try mouse(.leftMouseDown, start))
        handle.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + 40, y: start.y - 100)))
        XCTAssertEqual(bar.frame.minX, origin.x + 40, accuracy: 0.5)
        XCTAssertEqual(bar.frame.maxY, view.bounds.maxY - 4, accuracy: 0.5)
        handle.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: start.x + 40, y: start.y + 200)))
        XCTAssertEqual(bar.frame.minX, origin.x + 40, accuracy: 0.5)
        XCTAssertEqual(bar.frame.minY, origin.y, accuracy: 0.5)
        handle.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: start.x + 40, y: start.y + 200)))

        let draggedFrame = bar.frame
        pointer = NSPoint(x: window.frame.maxX + 1, y: window.frame.maxY + 1)
        view.mouseExited(with: entry)
        XCTAssertTrue(bar.isHidden)
        pointer = window.convertPoint(toScreen: NSPoint(x: 100, y: 100))
        view.mouseEntered(with: entry)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame, draggedFrame)

        handle.mouseDown(with: try mouse(.leftMouseDown, start))
        handle.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: -10000, y: 10000)))
        XCTAssertEqual(bar.frame.minX, 4, accuracy: 0.5)
        handle.mouseDragged(with: try mouse(.leftMouseDragged, NSPoint(x: 10000, y: -10000)))
        XCTAssertEqual(bar.frame.maxX, view.bounds.maxX - 4, accuracy: 0.5)
        XCTAssertEqual(bar.frame.minY, origin.y, accuracy: 0.5)
    }

    func testTopModeBarAvoidsNotchWithoutChangingHeight() {
        let bounds = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = NSRect(x: 656, y: 950, width: 200, height: 32)
        let size = NSSize(width: 360, height: 40)
        for x in [CGFloat(16), 400, 656, 800, 1200] {
            let frame = OverlayView.modeBarFrame(size: size, in: bounds, preferredX: x, obscuredArea: notch)
            XCTAssertFalse(frame.intersects(notch))
            XCTAssertEqual(frame.maxY, bounds.maxY - 4)
            XCTAssertTrue(bounds.contains(frame))
        }
    }

    func testHoverTargetOnlyAppearsOnTheDisplayContainingThePointer() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 120)
        let window = NSRect(x: 20, y: 30, width: 80, height: 60)

        XCTAssertNil(OverlayView.hoverTarget(
            at: NSPoint(x: -10, y: 50),
            in: bounds,
            windowRects: [window]
        ))
        XCTAssertEqual(OverlayView.hoverTarget(
            at: NSPoint(x: 40, y: 50),
            in: bounds,
            windowRects: [window]
        ), window)
        XCTAssertEqual(OverlayView.hoverTarget(
            at: NSPoint(x: 150, y: 50),
            in: bounds,
            windowRects: [window]
        ), bounds)
    }

    func testTopEdgeStartsSelectionAndMouseUpCommitsTheFinalPosition() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        let start = NSPoint(x: view.bounds.midX, y: view.bounds.maxY)
        var pointer = window.convertPoint(toScreen: start)
        let tracker = CapturePointerTracker(overlays: [window], mouseLocation: { pointer })
        defer { tracker.stop() }
        tracker.update()
        XCTAssertFalse(try modeBar(in: view).isHidden)
        XCTAssertTrue(view.hitTest(start) === view)
        XCTAssertEqual(OverlayView.hoverTarget(at: start, in: view.bounds, windowRects: []), view.bounds)
        view.mouseDown(with: try pointerEvent(.leftMouseDown, at: start, in: window))
        let intermediate = NSPoint(x: start.x + 40, y: start.y - 40)
        pointer = window.convertPoint(toScreen: intermediate)
        view.mouseDragged(with: try pointerEvent(.leftMouseDragged, at: intermediate, in: window))
        let end = NSPoint(x: start.x + 120, y: start.y - 100)
        pointer = window.convertPoint(toScreen: end)
        view.mouseUp(with: try pointerEvent(.leftMouseUp, at: end, in: window))
        let path = try dimmingPath(in: view)
        XCTAssertFalse(path.contains(NSPoint(x: end.x - 5, y: end.y + 5), using: .evenOdd))
        XCTAssertTrue(path.contains(NSPoint(x: end.x + 5, y: end.y + 5), using: .evenOdd))
    }

    func testVerticallyAdjacentDisplaysHaveOneOwnerOnTheirSharedEdge() throws {
        let lower = try makeWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let upper = try makeWindow(frame: NSRect(x: 0, y: 600, width: 800, height: 600))
        defer { lower.dismiss(); upper.dismiss() }
        let a = try XCTUnwrap(lower.contentView as? OverlayView)
        let b = try XCTUnwrap(upper.contentView as? OverlayView)
        var point = NSPoint(x: 700, y: 600)
        // Enumeration order must not resolve a shared edge by accident.
        let tracker = CapturePointerTracker(overlays: [upper, lower], mouseLocation: { point })
        defer { tracker.stop() }
        tracker.update()
        XCTAssertFalse(try modeBar(in: a).isHidden)
        XCTAssertTrue(try modeBar(in: b).isHidden)
        point.y += 0.5
        tracker.update()
        XCTAssertTrue(try modeBar(in: a).isHidden)
        XCTAssertFalse(try modeBar(in: b).isHidden)
    }

    func testHoverAndNewSelectionKeepTheAnnotationCanvasHiddenUntilConfirmation() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? CaptureAnnotationView }.first)
        let magnifier = try XCTUnwrap(view.subviews.compactMap { $0 as? CaptureMagnifierView }.first)
        let badge = try XCTUnwrap(view.subviews.compactMap { $0 as? CaptureSizeBadge }.first)
        view.updatePointer(at: NSPoint(x: 100, y: 100))
        view.updatePointer(at: NSPoint(x: 120, y: 120))
        view.displayIfNeeded()
        XCTAssertTrue(canvas.isHidden)
        XCTAssertFalse(magnifier.isHidden)
        XCTAssertFalse(badge.isHidden)
        XCTAssertNil(magnifier.hitTest(magnifier.frame.origin))
        view.mouseDown(with: try pointerEvent(.leftMouseDown, at: NSPoint(x: 120, y: 120), in: window))
        for i in 0..<100 {
            view.mouseDragged(with: try pointerEvent(.leftMouseDragged,
                at: NSPoint(x: 300 + i, y: 300 + i), in: window))
            view.displayIfNeeded()
        }
        XCTAssertTrue(canvas.isHidden)
        XCTAssertFalse(magnifier.isHidden)
        XCTAssertFalse(badge.isHidden)
        view.updatePointer(at: nil)
        XCTAssertTrue(magnifier.isHidden)
        view.mouseUp(with: try pointerEvent(.leftMouseUp, at: NSPoint(x: 399, y: 399), in: window))
        view.displayIfNeeded()
        XCTAssertFalse(canvas.isHidden)
    }

    func testCrossDisplayHoverIgnoresLateEventsAndTransfersWithoutAnExit() throws {
        let target = NSRect(x: 80, y: 80, width: 200, height: 180)
        let first = try makeWindow(frame: NSRect(x: -800, y: 120, width: 800, height: 600), windows: [target])
        let second = try makeWindow(frame: NSRect(x: 0, y: -200, width: 800, height: 600), windows: [target])
        defer { first.dismiss(); second.dismiss() }
        let a = try XCTUnwrap(first.contentView as? OverlayView)
        let b = try XCTUnwrap(second.contentView as? OverlayView)
        let local = NSPoint(x: target.midX, y: target.midY)
        var pointer = first.convertPoint(toScreen: local)
        let tracker = CapturePointerTracker(overlays: [first, second], mouseLocation: { pointer })
        defer { tracker.stop() }
        tracker.update()
        try assertPreview(a, at: local, visible: true)
        try assertPreview(b, at: local, visible: false)

        // Enter B before A receives an exit. No frame may retain both hover holes.
        pointer = second.convertPoint(toScreen: local)
        b.mouseEntered(with: try pointerEvent(.mouseEntered, at: local, in: second))
        try assertPreview(a, at: local, visible: false)
        try assertPreview(b, at: local, visible: true)
        let firstPath = try dimmingPath(in: a)
        let secondPath = try dimmingPath(in: b)

        // Stale coordinates still lie inside A; only the current global pointer owns hover.
        a.mouseExited(with: try pointerEvent(.mouseExited, at: local, in: first))
        a.mouseMoved(with: try pointerEvent(.mouseMoved, at: local, in: first))
        a.mouseEntered(with: try pointerEvent(.mouseEntered, at: local, in: first))
        try assertPreview(a, at: local, visible: false)
        try assertPreview(b, at: local, visible: true)
        XCTAssertTrue(try dimmingPath(in: a) === firstPath)
        XCTAssertTrue(try dimmingPath(in: b) === secondPath)

        // A delayed exit from B must not clear the new owner on the return trip.
        pointer = first.convertPoint(toScreen: local)
        b.mouseExited(with: try pointerEvent(.mouseExited, at: local, in: second))
        try assertPreview(a, at: local, visible: true)
        try assertPreview(b, at: local, visible: false)
        pointer = NSPoint(x: 900, y: 900)
        a.mouseExited(with: try pointerEvent(.mouseExited, at: local, in: first))
        try assertPreview(a, at: local, visible: false)
        try assertPreview(b, at: local, visible: false)
    }

    func testCrossDisplayExitClearsTransientHoverDuringMouseDrag() throws {
        let first = try makeWindow(frame: NSRect(x: -800, y: 0, width: 800, height: 600))
        let second = try makeWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { first.dismiss(); second.dismiss() }
        let a = try XCTUnwrap(first.contentView as? OverlayView)
        let b = try XCTUnwrap(second.contentView as? OverlayView)
        let local = NSPoint(x: 100, y: 100)
        var pointer = first.convertPoint(toScreen: local)
        let tracker = CapturePointerTracker(overlays: [first, second], mouseLocation: { pointer })
        defer { tracker.stop() }
        tracker.update()
        XCTAssertTrue(a.trackingAreas.allSatisfy { $0.options.contains(.enabledDuringMouseDrag) })
        a.mouseDown(with: try pointerEvent(.leftMouseDown, at: local, in: first))

        pointer = second.convertPoint(toScreen: local)
        a.mouseExited(with: try pointerEvent(.mouseExited, at: local, in: first))
        try assertPreview(a, at: local, visible: false)
        try assertPreview(b, at: local, visible: true)
        a.mouseMoved(with: try pointerEvent(.mouseMoved, at: local, in: first))
        try assertPreview(a, at: local, visible: false)
    }

    func testCrossDisplayPointerTransferPreservesConfirmedSelection() throws {
        let target = NSRect(x: 80, y: 80, width: 200, height: 180)
        let first = try makeWindow(frame: NSRect(x: -800, y: 0, width: 800, height: 600), windows: [target])
        let second = try makeWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600), windows: [target])
        defer { first.dismiss(); second.dismiss() }
        let a = try XCTUnwrap(first.contentView as? OverlayView)
        let b = try XCTUnwrap(second.contentView as? OverlayView)
        let local = NSPoint(x: target.midX, y: target.midY)
        var pointer = first.convertPoint(toScreen: local)
        let tracker = CapturePointerTracker(overlays: [first, second], mouseLocation: { pointer })
        defer { tracker.stop() }
        tracker.update()
        a.mouseDown(with: try pointerEvent(.leftMouseDown, at: local, in: first))
        a.mouseUp(with: try pointerEvent(.leftMouseUp, at: local, in: first))
        let selectedPath = try dimmingPath(in: a)

        pointer = second.convertPoint(toScreen: local)
        b.mouseEntered(with: try pointerEvent(.mouseEntered, at: local, in: second))
        XCTAssertTrue(try modeBar(in: a).isHidden)
        XCTAssertTrue(try dimmingPath(in: a) === selectedPath)
        XCTAssertFalse(selectedPath.contains(local, using: .evenOdd))
        try assertPreview(b, at: local, visible: true)
    }

    func testStoppingPointerTrackerDisconnectsEventsAndCannotAffectNextSession() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        let local = NSPoint(x: 100, y: 100)
        let pointer = window.convertPoint(toScreen: local)
        let tracker = CapturePointerTracker(overlays: [window], mouseLocation: { pointer })
        tracker.update()
        let queuedCallback = try XCTUnwrap(view.onPointerActivity)
        tracker.stop()
        XCTAssertNil(view.onPointerActivity)
        try assertPreview(view, at: local, visible: false)
        queuedCallback()
        try assertPreview(view, at: local, visible: false)

        let nextTracker = CapturePointerTracker(overlays: [window], mouseLocation: { pointer })
        defer { nextTracker.stop() }
        nextTracker.update()
        queuedCallback()
        tracker.stop()
        XCTAssertNotNil(view.onPointerActivity)
        try assertPreview(view, at: local, visible: true)
    }

    func testToolbarButtonHoverUsesAnInsetCircle() throws {
        let button = BarButton(frame: NSRect(x: 0, y: 0, width: 32, height: 36))
        button.isBordered = false
        button.usesCircularBackground = true
        button.backgroundVerticalInset = 6
        button.isHovered = true

        let hovered = try render(button)
        let center = try XCTUnwrap(hovered.colorAt(x: 16, y: 18))
        let corner = try XCTUnwrap(hovered.colorAt(x: 0, y: 0))
        let outsideCircle = try XCTUnwrap(hovered.colorAt(x: 16, y: 4))
        let insideCircle = try XCTUnwrap(hovered.colorAt(x: 16, y: 8))
        XCTAssertGreaterThan(center.alphaComponent, corner.alphaComponent)
        XCTAssertGreaterThan(center.alphaComponent, outsideCircle.alphaComponent)
        XCTAssertGreaterThan(insideCircle.alphaComponent, outsideCircle.alphaComponent)
    }

    func testModeButtonBackgroundLeavesAdditionalVerticalSpace() throws {
        let button = BarButton(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
        button.isBordered = false
        button.backgroundVerticalInset = 3
        button.isSelectedLook = true

        let selected = try render(button)
        let center = try XCTUnwrap(selected.colorAt(x: 40, y: 14))
        let verticalEdge = try XCTUnwrap(selected.colorAt(x: 40, y: 0))
        XCTAssertGreaterThan(center.alphaComponent, verticalEdge.alphaComponent)
    }

    func testEditingShortcutsStayWithTheFocusedEditorWithoutReplacingTheHostMenu() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let hostMenu = NSApp.mainMenu
        let editor = RecordingOverlayTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        for (key, code) in [("a", UInt16(0)), ("c", 8), ("x", 7), ("v", 9)] {
            XCTAssertTrue(window.performKeyEquivalent(with: try event(key, code: code, in: window)))
        }
        XCTAssertEqual(editor.commands, ["selectAll", "copy", "cut", "paste"])
        XCTAssertTrue(NSApp.mainMenu === hostMenu)

        _ = window.performKeyEquivalent(with: try event("c", code: 8, modifiers: [.command, .option], in: window))
        XCTAssertEqual(editor.commands, ["selectAll", "copy", "cut", "paste"])
    }

    func testFieldEditorUsesTheSameLocalEditingShortcuts() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let editor = RecordingOverlayTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        editor.isFieldEditor = true
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.performKeyEquivalent(with: try event("v", code: 9, in: window)))
        XCTAssertEqual(editor.commands, ["paste"])
    }

    func testDismissDisconnectsOverlayCallbacksAndTracking() throws {
        let window = try makeWindow()
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        XCTAssertNotNil(view.onCancel)
        window.dismiss()
        window.dismiss()
        XCTAssertNil(view.onCancel)
        XCTAssertNil(view.onComplete)
        XCTAssertNil(view.onPin)
        XCTAssertNil(view.onRecord)
        XCTAssertNil(view.onScroll)
        XCTAssertNil(view.onPointerActivity)
        XCTAssertTrue(view.trackingAreas.isEmpty)
    }

    func testReusableWindowReleasesPixelsAndReconnectsOnlyTheNewSession() throws {
        let window = try makeWindow()
        defer { window.dismiss() }
        let view = try XCTUnwrap(window.contentView as? OverlayView)
        let imageLayer = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertNotNil(imageLayer.contents)
        window.dismiss()
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(imageLayer.contents)

        let screen = try XCTUnwrap(NSScreen.screens.first)
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let secondImage = try XCTUnwrap(context?.makeImage())
        window.prepare(screen: screen, frozen: secondImage, windows: [], quick: true)
        XCTAssertTrue(window.contentView === view)
        XCTAssertTrue((imageLayer.contents as AnyObject?) === secondImage)
        XCTAssertEqual(view.trackingAreas.count, 1)
        var cancellations = 0
        window.onCancel = { cancellations += 1 }
        view.onCancel?()
        XCTAssertEqual(cancellations, 1)
        window.dismiss()
        XCTAssertNil(imageLayer.contents)
        XCTAssertNil(view.onCancel)
    }

    func testIdlePoolReusesHiddenSurfacesWithoutCapturingPixels() throws {
        _ = NSApplication.shared
        let display = try XCTUnwrap(CaptureDisplay.current().first)
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let pool = CaptureOverlayPool(environment: environment)
        defer { pool.release() }
        pool.prepare()
        let window = try XCTUnwrap(pool.window(for: display))
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(window.contentView?.layer?.sublayers?.first?.contents)
        pool.prepare()
        XCTAssertTrue(pool.window(for: display) === window)
        pool.release()
        XCTAssertNil(pool.window(for: display))
    }

    private func makeWindow(frame: NSRect? = nil, windows: [NSRect] = []) throws -> OverlayWindow {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("A display is required for an AppKit overlay window") }
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(context?.makeImage())
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let window = OverlayWindow(screen: screen, frozen: image, windows: windows, quick: false, environment: environment)
        if let frame { window.setFrame(frame, display: false) }
        return window
    }

    private func modeBar(in view: OverlayView) throws -> NSView {
        try XCTUnwrap(view.subviews.first { $0.identifier?.rawValue == "screenshot.modeBar" })
    }

    private func dimmingPath(in view: OverlayView) throws -> CGPath {
        let layer = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        return try XCTUnwrap(layer.path)
    }

    private func assertPreview(_ view: OverlayView, at point: NSPoint, visible: Bool,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try modeBar(in: view).isHidden, !visible, file: file, line: line)
        XCTAssertEqual(try dimmingPath(in: view).contains(point, using: .evenOdd), !visible, file: file, line: line)
    }

    private func pointerEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil
            ))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private func event(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command,
                       in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class RecordingOverlayTextView: NSTextView {
    var commands: [String] = []

    override func selectAll(_ sender: Any?) { commands.append("selectAll") }
    override func copy(_ sender: Any?) { commands.append("copy") }
    override func cut(_ sender: Any?) { commands.append("cut") }
    override func paste(_ sender: Any?) { commands.append("paste") }
}
