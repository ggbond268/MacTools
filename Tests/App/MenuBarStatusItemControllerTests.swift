import AppKit
import XCTest
@testable import MacTools

final class MenuBarStatusItemControllerTests: XCTestCase {
    func testNilEventDefaultsToComponentPanel() {
        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: nil), .componentPanel)
    }

    func testLeftMouseDownOpensComponentPanelImmediately() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .componentPanel)
    }

    func testLeftMouseUpStillOpensComponentPanelForProgrammaticFallback() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .componentPanel)
    }

    func testRightMouseDownOpensFeaturePanelImmediately() {
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .featurePanel)
    }

    func testRightMouseUpStillOpensFeaturePanelForProgrammaticFallback() {
        let event = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .featurePanel)
    }

    func testControlClickOpensFeaturePanel() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .featurePanel)
    }

    // MARK: - Option+left (macOS 27 beta right-click reachability channel)

    func testOptionLeftMouseUpOpensFeaturePanel() {
        // On the macOS 27 single-window menu bar host right mouse events are
        // never routed to third-party items, so Option+left must carry the
        // secondary (feature panel) semantics; the action arrives as mouseUp.
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .featurePanel)
    }

    func testOptionLeftMouseDownOpensFeaturePanelOnLegacyHosts() {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )

        XCTAssertEqual(MenuBarStatusItemInvocation.invocation(for: event), .featurePanel)
    }

    // MARK: - Swapped click behavior

    private func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    }

    func testSwappedLeftClickOpensFeaturePanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: mouseEvent(.leftMouseDown), swapped: true),
            .featurePanel
        )
    }

    func testSwappedRightClickOpensComponentPanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: mouseEvent(.rightMouseDown), swapped: true),
            .componentPanel
        )
    }

    func testSwappedControlClickFollowsSecondaryAndOpensComponentPanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: mouseEvent(.leftMouseUp, modifiers: [.control]), swapped: true),
            .componentPanel
        )
    }

    func testSwappedNilEventOpensFeaturePanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: nil, swapped: true),
            .featurePanel
        )
    }

    func testSwappedOptionLeftClickFollowsSecondaryAndOpensComponentPanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: mouseEvent(.leftMouseUp, modifiers: [.option]), swapped: true),
            .componentPanel
        )
    }

    func testClickBehaviorPreferenceDefaultsToStandard() {
        let suite = "MenuBarClickBehaviorPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(MenuBarClickBehaviorPreference.current(defaults), .standard)
        XCTAssertFalse(MenuBarClickBehaviorPreference.current(defaults).isSwapped)

        defaults.set(MenuBarClickBehaviorPreference.swapped.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
        XCTAssertEqual(MenuBarClickBehaviorPreference.current(defaults), .swapped)
        XCTAssertTrue(MenuBarClickBehaviorPreference.current(defaults).isSwapped)
    }

    // MARK: - Appearance-change refresh dedup

    func testAppearanceRefreshSkipsWhenNameUnchanged() {
        // Theme notification and KVO fallback both fire for one switch; the
        // second delivery sees the already-applied name and must not rebuild
        // the icon image again.
        XCTAssertFalse(
            MenuBarStatusIconAppearanceRefreshPolicy.shouldRefresh(
                currentAppearanceName: .darkAqua,
                lastAppliedAppearanceName: .darkAqua
            )
        )
        XCTAssertFalse(
            MenuBarStatusIconAppearanceRefreshPolicy.shouldRefresh(
                currentAppearanceName: nil,
                lastAppliedAppearanceName: nil
            )
        )
    }

    func testAppearanceRefreshRunsWhenNameChangesOrWasNeverApplied() {
        XCTAssertTrue(
            MenuBarStatusIconAppearanceRefreshPolicy.shouldRefresh(
                currentAppearanceName: .aqua,
                lastAppliedAppearanceName: .darkAqua
            )
        )
        XCTAssertTrue(
            MenuBarStatusIconAppearanceRefreshPolicy.shouldRefresh(
                currentAppearanceName: .darkAqua,
                lastAppliedAppearanceName: nil
            )
        )
        XCTAssertTrue(
            MenuBarStatusIconAppearanceRefreshPolicy.shouldRefresh(
                currentAppearanceName: nil,
                lastAppliedAppearanceName: .darkAqua
            )
        )
    }
}
