import AppKit
@testable import MacToolsPluginKit
import XCTest

@MainActor
final class PluginPanelPresentationTests: XCTestCase {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    func testNonactivatingPanelAcceptsTextWithoutChangingForegroundApplication() throws {
        let panel = makePanel()
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 220, height: 24))
        panel.contentView?.addSubview(field)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        defer { panel.close() }

        PluginPanelPresentation.present(panel)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Panel input", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(field.stringValue, "Panel input")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
    }

    func testFocusLossDismissesButTemporaryFocusTransferDoesNot() async {
        let panel = makePanel()
        PluginPanelPresentation.present(panel)
        defer { panel.close() }
        let monitor = PluginPanelDismissalMonitor()
        var dismissals = 0
        monitor.start(for: panel) { dismissals += 1 }

        let other = makePanel()
        defer { other.close() }
        PluginPanelPresentation.present(other)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        panel.makeKey()
        await drainEvents()
        XCTAssertEqual(dismissals, 0)

        other.makeKey()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        await drainEvents()
        XCTAssertEqual(dismissals, 1)
    }

    func testRecordingAndMenusProtectTheOwningPanel() async {
        let panel = makePanel()
        PluginPanelPresentation.present(panel)
        defer { panel.close() }
        let monitor = PluginPanelDismissalMonitor()
        var suspended = true
        var dismissals = 0
        monitor.start(for: panel, isSuspended: { suspended }) { dismissals += 1 }
        let other = makePanel()
        defer { other.close() }
        PluginPanelPresentation.present(other)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        await drainEvents()
        XCTAssertEqual(dismissals, 0)

        suspended = false
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        await drainEvents()
        XCTAssertEqual(dismissals, 0)
        panel.makeKey()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await drainEvents()
        XCTAssertEqual(dismissals, 0)
        monitor.stop()
    }

    func testDeferredDismissalCannotCloseReopenedPanel() async {
        let panel = makePanel()
        PluginPanelPresentation.present(panel)
        defer { panel.close() }
        let monitor = PluginPanelDismissalMonitor()
        var dismissals = 0
        monitor.start(for: panel) { dismissals += 1 }
        let other = makePanel()
        defer { other.close() }
        PluginPanelPresentation.present(other)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
        monitor.start(for: panel) { dismissals += 1 }
        await drainEvents()
        XCTAssertEqual(dismissals, 0)
        monitor.stop()
    }

    func testOutsideClicksProtectMarkedTextAndDismissOnceAfterComposition() async throws {
        let panel = makePanel()
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 220, height: 24))
        panel.contentView?.addSubview(field)
        PluginPanelPresentation.present(panel)
        defer { panel.close() }
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let monitor = PluginPanelDismissalMonitor()
        var dismissals = 0
        monitor.start(for: panel) { dismissals += 1 }
        let outside = NSPoint(x: panel.frame.maxX + 50, y: panel.frame.maxY + 50)

        monitor.mouseDown(in: panel, at: outside)
        monitor.mouseDown(in: nil, at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        monitor.mouseDown(in: nil, at: outside)
        // Keep synthetic composition synchronous: yielding may let AppKit end
        // editing independently of the candidate interaction being modeled.
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        await drainEvents()
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(field.stringValue, "你")

        monitor.mouseDown(in: nil, at: outside)
        monitor.mouseDown(in: nil, at: outside)
        await drainEvents()
        XCTAssertEqual(dismissals, 1)
    }

    func testCancellationRestoresOnlyWhenHostAcquiredApplicationFocus() {
        var hostIsActive = false
        var captures = 0
        var restorations = 0
        let focus = PluginPanelFocusRestoration(captureRestoration: {
            captures += 1
            return { restorations += 1 }
        }, canRestore: { hostIsActive })
        focus.prepareForPresentation()
        focus.prepareForPresentation()
        focus.dismiss(wasVisible: true, restoringFocus: true)
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(restorations, 0)

        focus.prepareForPresentation()
        hostIsActive = true
        focus.dismiss(wasVisible: true, restoringFocus: true)
        focus.dismiss(wasVisible: true, restoringFocus: true)
        XCTAssertEqual(restorations, 1)
        focus.prepareForPresentation()
        focus.dismiss(wasVisible: true, restoringFocus: false)
        XCTAssertEqual(restorations, 1)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 100, y: 100, width: 260, height: 100),
                          styleMask: PluginPanelPresentation.styleMask, backing: .buffered, defer: false)
        PluginPanelPresentation.configure(panel)
        return panel
    }

    private func drainEvents() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
