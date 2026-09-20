import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherHostWindowsTests: XCTestCase {
    private final class FixtureWindow: NSWindow {
        var shown = true
        var minimized = false
        override var isVisible: Bool { shown }
        override var isMiniaturized: Bool { minimized }
        override var canBecomeMain: Bool { true }
    }

    private func window() -> FixtureWindow {
        _ = NSApplication.shared
        let window = FixtureWindow(contentRect: CGRect(x: 10, y: 20, width: 600, height: 400),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MacTools Settings"
        return window
    }

    func testIncludesSettingsButExcludesOrderedOutWindowsAndChooser() {
        let settings = window()
        XCTAssertTrue(WindowSwitcherHostWindows.isEligible(settings))
        settings.shown = false
        XCTAssertFalse(WindowSwitcherHostWindows.isEligible(settings))
        settings.minimized = true
        XCTAssertTrue(WindowSwitcherHostWindows.isEligible(settings))
        settings.minimized = false
        settings.shown = true
        settings.styleMask = [.borderless]
        XCTAssertFalse(WindowSwitcherHostWindows.isEligible(settings))
        let chooser = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        chooser.isReleasedWhenClosed = false
        XCTAssertFalse(WindowSwitcherHostWindows.isEligible(chooser))
    }

    func testCancelledActivationDoesNotRaiseTheWindow() async {
        let settings = window()
        let catalog = WindowSwitcherHostWindows(windows: { [settings] })
        let entry = catalog.entries()[0]
        let task = Task { await catalog.activate(entry) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(settings.isKeyWindow)
    }

    func testRowsUseObjectIdentityAndRejectClosedOrReplacedWindows() {
        let first = window()
        var live: [NSWindow] = [first]
        let catalog = WindowSwitcherHostWindows(windows: { live })
        let entry = catalog.entries()[0]
        XCTAssertTrue(entry.isWindowEntry)
        XCTAssertEqual(catalog.entries()[0].id, entry.id)
        XCTAssertTrue(catalog.window(for: entry) === first)
        live = [window()]
        XCTAssertNil(catalog.window(for: entry))
        XCTAssertNotEqual(catalog.entries()[0].id, entry.id, "Closed window identities must not route to a replacement")
        live = []
        XCTAssertTrue(catalog.entries().isEmpty)
        XCTAssertNil(catalog.window(for: entry))
    }
}
