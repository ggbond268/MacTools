import AppKit
import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherShortcutTapTests: XCTestCase {
    private func event(_ code: Int, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
        event.flags = flags
        return event
    }

    func testCompanionLeavesNativeCommandTabAloneAndDeliversPressReleaseInOrder() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding,
                      currentAppBinding: WindowSwitcherShortcutBindingStore.currentAppBinding)
        var phases: [String] = []
        tap.onShortcutPressed = { reverse, _, _ in phases.append(reverse ? "reverse" : "press") }
        tap.onShortcutReleased = { phases.append("release") }
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskCommand)) != nil)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: [.maskAlternate, .maskShift])) == nil)
        XCTAssertTrue(tap.handle(type: .flagsChanged, event: try event(kVK_Option)) != nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(phases, ["reverse", "release"])
    }

    func testPendingSessionEscapeWorksAfterModifierReleaseButEditingOwnsEscape() async throws {
        let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        tap.setSessionActive(true)
        var escapes = 0
        tap.onEscape = { escapes += 1 }
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Escape)) == nil)
        tap.setEditing(true)
        XCTAssertTrue(tap.handle(type: .keyDown, event: try event(kVK_Escape)) != nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(escapes, 1)
    }

    func testExplicitShiftBindingWinsOverImplicitReverseInEitherScope() async throws {
        for shiftedCurrentApp in [true, false] {
            let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
            let base = ShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.option])
            let shifted = ShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.option, .shift])
            tap.configure(allBinding: shiftedCurrentApp ? base : shifted, currentAppBinding: shiftedCurrentApp ? shifted : base)
            var scopes: [Bool] = [], reversals: [Bool] = []
            tap.onShortcutPressed = { reverse, _, currentApp in scopes.append(currentApp); reversals.append(reverse) }
            XCTAssertNil(tap.handle(type: .keyDown, event: try event(kVK_Tab, flags: [.maskAlternate, .maskShift])))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(scopes, [shiftedCurrentApp])
            XCTAssertEqual(reversals, [false])
        }
    }

    func testRevokedPermissionReportsOnceIncludingDisabledTapEvents() async throws {
        for type in [CGEventType.keyDown, .tapDisabledByTimeout, .tapDisabledByUserInput] {
            let tap = WindowSwitcherShortcutTap(accessibilityTrusted: { false })
            var reports = 0
            tap.onAccessibilityRevoked = { reports += 1 }
            let key = try event(kVK_Tab, flags: .maskAlternate)
            XCTAssertNotNil(tap.handle(type: type, event: key))
            XCTAssertNotNil(tap.handle(type: type, event: key))
            let deadline = ContinuousClock.now + .seconds(1)
            while reports == 0, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(reports, 1)
        }
    }

    func testDeniedPermissionAndClearedBindingsNeverConsumeKeys() throws {
        let denied = WindowSwitcherShortcutTap(accessibilityTrusted: { false })
        denied.configure(allBinding: WindowSwitcherShortcutBindingStore.defaultBinding, currentAppBinding: nil)
        XCTAssertTrue(denied.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate)) != nil)
        let cleared = WindowSwitcherShortcutTap(accessibilityTrusted: { true })
        cleared.configure(allBinding: nil, currentAppBinding: nil)
        XCTAssertTrue(cleared.handle(type: .keyDown, event: try event(kVK_Tab, flags: .maskAlternate)) != nil)
    }
}
