import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherChooserFocusTests: XCTestCase {
    func testCyclingPreviewAcquiresFocusWithoutPromotingToSearch() throws {
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
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(controller.session?.isPersistent, false)
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
