import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherChooserFocusTests: XCTestCase {
    func testDismissBeforeDeferredFocusDoesNotActivate() async throws {
        var activations = 0
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { 42 },
            activateHost: { activations += 1 }, activateApplication: { _ in
                XCTFail("An unactivated chooser must not restore focus")
            })
        let controller = WindowSwitcherOverlayController(
            preview: WindowSwitcherPreview(hasPermission: { false }), focus: focus)
        let item = WindowSwitcherAppEntry(id: "test", processIdentifier: 42, bundleIdentifier: "org.example.test",
            appName: "Test", windowTitle: "Document", icon: nil, windowElement: nil,
            isMinimized: false, shortcutToken: nil)
        controller.show(WindowSwitcherSession(entries: [item], selectedID: item.id,
            isPersistent: false, originalWindowID: item.id), currentPID: 42, showsPreview: true)
        controller.hide()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(activations, 0)
    }

    func testCyclingPreviewAcquiresFocusWithoutPromotingToSearch() async throws {
        var frontmost: pid_t? = 42
        var activations = 0
        var restored: [pid_t] = []
        let focus = WindowSwitcherChooserFocus(hostPID: 7, frontmostPID: { frontmost },
            activateHost: { activations += 1; frontmost = 7 },
            activateApplication: { restored.append($0) })
        let preview = WindowSwitcherPreview(hasPermission: { false })
        let controller = WindowSwitcherOverlayController(preview: preview, focus: focus)
        let item = WindowSwitcherAppEntry(id: "test", processIdentifier: 42, bundleIdentifier: "org.example.test",
            appName: "Test", windowTitle: "Document", icon: nil, windowElement: nil,
            isMinimized: false, shortcutToken: nil)
        let session = WindowSwitcherSession(entries: [item], selectedID: item.id,
            isPersistent: false, originalWindowID: item.id)
        controller.show(session, currentPID: 42, showsPreview: false)
        XCTAssertEqual(activations, 0)
        controller.hide()
        controller.show(session, currentPID: 42, showsPreview: true)
        defer { controller.hide() }
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "WindowSwitcherChooser" && $0.isVisible
        })
        try XCTSkipIf(panel.screen?.visibleFrame.height ?? 0 < 600, "Preview requires a sufficiently tall display")
        let deadline = ContinuousClock.now + .seconds(1)
        while activations == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(controller.session?.isPersistent, false)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let stage = try XCTUnwrap(descendants(try XCTUnwrap(panel.contentView))
            .compactMap { $0 as? WindowSwitcherPreviewStage }.first)
        stage.image = NSImage(size: NSSize(width: 300, height: 200))
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(stage.acceptsFirstMouse(for: nil))
        let margin = stage.convert(NSPoint(x: stage.bounds.minX + 3, y: stage.bounds.minY + 3), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: margin,
            modifierFlags: [.command], timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        panel.sendEvent(click)
        XCTAssertEqual(activations, 2, "Clicking a margin requests application focus immediately")
        XCTAssertTrue(panel.firstResponder === stage)
        XCTAssertEqual(controller.session?.isPersistent, false)
        XCTAssertEqual(controller.session?.selectedID, item.id)
        controller.hide()
        XCTAssertEqual(restored, [42])
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
