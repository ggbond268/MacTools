import AppKit
import MacToolsPluginKit
import XCTest

@testable import ScreenshotPlugin

@MainActor
final class OverlayWindowTests: XCTestCase {
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
        XCTAssertTrue(view.trackingAreas.isEmpty)
    }

    private func makeWindow() throws -> OverlayWindow {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("A display is required for an AppKit overlay window") }
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let image = try XCTUnwrap(context?.makeImage())
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        return OverlayWindow(screen: screen, frozen: image, windows: [], quick: false, environment: environment)
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
