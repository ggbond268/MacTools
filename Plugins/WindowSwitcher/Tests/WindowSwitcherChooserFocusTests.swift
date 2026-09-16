import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherChooserFocusTests: XCTestCase {
    private func makeItem() -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: "test", processIdentifier: 42, bundleIdentifier: "org.example.test",
            appName: "Test", windowTitle: "Document", icon: nil, windowElement: nil,
            isMinimized: false, shortcutToken: nil)
    }

    func testOriginCapturedBeforePanelOrderingAndActivation() throws {
        var stages: [String] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: {
            stages.append("capture")
            XCTAssertFalse(NSApp.windows.contains {
                $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
            }, "Capture the origin before ordering can transfer focus")
            return 42
        }, activateHost: {
            stages.append("activate")
            XCTAssertTrue(NSApp.windows.contains {
                $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible &&
                    !$0.styleMask.contains(.nonactivatingPanel)
            }, "A background accessory app needs its normal panel visible before activation")
        }, activateApplication: { _ in })
        let controller = WindowSwitcherOverlayController(
            preview: WindowSwitcherPreview(hasPermission: { false }), focus: focus)
        let item = makeItem()
        controller.show(WindowSwitcherSession(entries: [item], selectedID: item.id,
            isPersistent: false, originalWindowID: item.id), currentPID: 42, showsPreview: true)
        defer { controller.hide(restoringFocus: false) }
        XCTAssertEqual(stages, ["capture", "activate"])
    }

    func testImmediateDismissRestoresFocusWithoutLateActivation() async throws {
        var frontmost: pid_t? = 42
        var activations = 0
        var restored: [pid_t] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
            activateHost: { activations += 1; frontmost = 7 },
            activateApplication: { restored.append($0); frontmost = $0 })
        let controller = WindowSwitcherOverlayController(
            preview: WindowSwitcherPreview(hasPermission: { false }), focus: focus)
        let item = makeItem()
        controller.show(WindowSwitcherSession(entries: [item], selectedID: item.id,
            isPersistent: false, originalWindowID: item.id), currentPID: 42, showsPreview: true)
        XCTAssertEqual(activations, 1, "Activation happens during opening, not in a deferred task")
        controller.hide()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(restored, [42])
    }

    func testAllInvocationModesAcquireFocusWithoutChangingSession() throws {
        for persistent in [false, true] {
            for showsPreview in [false, true] {
                var frontmost: pid_t? = 42
                var activations = 0
                var restored: [pid_t] = []
                let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
                    activateHost: { activations += 1; frontmost = 7 },
                    activateApplication: { restored.append($0) })
                let controller = WindowSwitcherOverlayController(
                    preview: WindowSwitcherPreview(hasPermission: { false }), focus: focus)
                let item = makeItem()
                let session = WindowSwitcherSession(entries: [item], selectedID: item.id,
                    isPersistent: persistent, originalWindowID: item.id)
                controller.show(session, currentPID: 42, showsPreview: showsPreview)
                defer { controller.hide() }
                let panel = try XCTUnwrap(NSApp.windows.first {
                    $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
                })
                XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
                XCTAssertFalse(panel.canBecomeMain, "The chooser must not become the host's main window")
                XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
                XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
                XCTAssertEqual(activations, 1)
                XCTAssertEqual(controller.session?.isPersistent, persistent)
                XCTAssertEqual(controller.session?.selectedID, item.id)
                XCTAssertEqual(controller.session?.originalWindowID, item.id)
                controller.hide()
                XCTAssertEqual(restored, [42])
            }
        }
    }

    func testPreviewClickCanReacquireFocusWithoutPromotingCycling() throws {
        var activations = 0
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { 42 },
            activateHost: { activations += 1 }, activateApplication: { _ in })
        let controller = WindowSwitcherOverlayController(
            preview: WindowSwitcherPreview(hasPermission: { false }), focus: focus)
        let item = makeItem()
        controller.show(WindowSwitcherSession(entries: [item], selectedID: item.id,
            isPersistent: false, originalWindowID: item.id), currentPID: 42, showsPreview: true)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
        })
        try XCTSkipIf(panel.screen?.visibleFrame.height ?? 0 < 600, "Preview requires a sufficiently tall display")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let stage = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView))
            .compactMap { $0 as? WindowSwitcherPreviewStage }.first)
        stage.image = NSImage(size: NSSize(width: 300, height: 200))
        panel.contentView?.layoutSubtreeIfNeeded()
        let margin = stage.convert(NSPoint(x: stage.bounds.minX + 3, y: stage.bounds.minY + 3), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: margin,
            modifierFlags: [.command], timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        panel.sendEvent(click)
        XCTAssertEqual(activations, 2)
        XCTAssertTrue(panel.firstResponder === stage)
        XCTAssertEqual(controller.session?.isPersistent, false)
        XCTAssertEqual(controller.session?.selectedID, item.id)
    }

    func testLosingKeyFocusDoesNotReactivateOriginEvenWithinHostApp() {
        var frontmost: pid_t? = 42
        var restored: [pid_t] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
            activateHost: { frontmost = 7 }, activateApplication: { restored.append($0) })
        let controller = WindowSwitcherOverlayController(
            preview: WindowSwitcherPreview(hasPermission: { false }), focus: focus)
        let item = makeItem()
        controller.onCancel = { [weak controller] in controller?.hide() }
        controller.show(WindowSwitcherSession(entries: [item], selectedID: item.id,
            isPersistent: false, originalWindowID: item.id), currentPID: 42, showsPreview: false)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(restored.isEmpty)
    }

    func testCancelRestoresOriginalAppAfterRepeatedAcquisition() {
        var frontmost: pid_t? = 42
        var activations = 0
        var restored: [pid_t] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
            activateHost: { activations += 1; frontmost = 7 },
            activateApplication: { restored.append($0) })
        focus.acquire()
        focus.acquire()
        focus.release(restoring: true)
        focus.release(restoring: true)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(restored, [42])
    }

    func testSelectionAndExternalFocusChangeDoNotRestoreOriginalApp() {
        var frontmost: pid_t? = 42
        var restored: [pid_t] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
            activateHost: { frontmost = 7 }, activateApplication: { restored.append($0) })
        focus.acquire()
        focus.release(restoring: false)
        frontmost = 42
        focus.acquire()
        frontmost = 99
        focus.release(restoring: true)
        XCTAssertTrue(restored.isEmpty)
    }

    func testNewInvocationCapturesNewOriginalAppAndMissingOriginIsSafe() {
        var frontmost: pid_t?
        var restored: [pid_t] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
            activateHost: { frontmost = 7 }, activateApplication: { restored.append($0) })
        focus.acquire()
        focus.release(restoring: true)
        frontmost = 42
        focus.acquire()
        focus.release(restoring: true)
        frontmost = 99
        focus.acquire()
        focus.release(restoring: true)
        XCTAssertEqual(restored, [42, 99])
    }
}
