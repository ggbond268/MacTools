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

    func testLiveOptionFlagMakesStrippedEventSecondary() {
        // Rehosted menu bar reality: the forwarded action event carries no
        // modifiers even for a physical Option-click; the caller-sampled
        // live keyboard state must carry the intent instead.
        let strippedEvent = NSEvent.mouseEvent(
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

        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: strippedEvent, liveModifierFlags: [.option]),
            .featurePanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: strippedEvent, liveModifierFlags: [.control]),
            .featurePanel
        )
        // Non-secondary live modifiers must not flip the invocation.
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: strippedEvent, liveModifierFlags: [.shift]),
            .componentPanel
        )
    }

    func testLiveFlagsAreIgnoredForProgrammaticNilEvent() {
        // A programmatic invocation (no event) stays primary even if the
        // user happens to be holding Option at that moment.
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocation(for: nil, liveModifierFlags: [.option]),
            .componentPanel
        )
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

    // MARK: - Expanded-interface session invocation (macOS 27, eventless)

    // didBegin carries no NSEvent, so the resolution is driven purely by the
    // swapped preference and the live keyboard modifier state. Full
    // combination coverage: {none, shift, control, option} x {standard,
    // swapped}.

    func testExpandedSessionNoModifiersOpensPrimaryPanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: false,
                liveModifierFlags: []
            ),
            .componentPanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: true,
                liveModifierFlags: []
            ),
            .featurePanel
        )
    }

    func testExpandedSessionShiftStaysPrimary() {
        // Shift is not a secondary modifier and must not flip the invocation.
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: false,
                liveModifierFlags: [.shift]
            ),
            .componentPanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: true,
                liveModifierFlags: [.shift]
            ),
            .featurePanel
        )
    }

    func testExpandedSessionControlOpensSecondaryPanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: false,
                liveModifierFlags: [.control]
            ),
            .featurePanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: true,
                liveModifierFlags: [.control]
            ),
            .componentPanel
        )
    }

    func testExpandedSessionOptionOpensSecondaryPanel() {
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: false,
                liveModifierFlags: [.option]
            ),
            .featurePanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: true,
                liveModifierFlags: [.option]
            ),
            .componentPanel
        )
    }

    func testExpandedSessionSecondaryModifierWinsWhenCombinedWithShift() {
        // A non-secondary modifier held alongside a secondary one must not
        // mask the secondary intent.
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: false,
                liveModifierFlags: [.option, .shift]
            ),
            .featurePanel
        )
        XCTAssertEqual(
            MenuBarStatusItemInvocation.invocationForExpandedSession(
                swapped: false,
                liveModifierFlags: [.control, .option]
            ),
            .featurePanel
        )
    }

    // MARK: - Replaced-session cancel sequence (controller recovery contract)

    @MainActor
    func testReplacedSessionCancelSequenceKeepsNewSessionTracked() {
        // Mirrors handleExpandedSessionBegin under the COMPOSED takeover
        // semantics: sessionDidBegin(new) arms a one-shot expectation that
        // swallows the synchronous, session-LESS didEnd produced by
        // cancelling the replaced session — the freshly stored NEW session
        // survives untouched and no dismissal fires. The controller's
        // follow-up re-begin of the identical session is then a harmless
        // no-op that must NOT re-arm the expectation.
        let coordinator = MenuBarExpandedSessionCoordinator()
        let staleSession = NSObject()
        let newSession = NSObject()
        _ = coordinator.sessionDidBegin(staleSession)

        // didBegin for the new session while the stale one is still tracked.
        let replaced = coordinator.sessionDidBegin(newSession)
        XCTAssertTrue(replaced === staleSession)

        // cancel(replaced) → host fires didEnd synchronously; the armed
        // expectation absorbs it: no dismissal, new session stays tracked.
        var dismissCount = 0
        coordinator.sessionDidEnd { dismissCount += 1 }
        XCTAssertEqual(dismissCount, 0)
        XCTAssertTrue(coordinator.activeSession === newSession)

        // Controller recovery step (kept for host-ordering drift): identical
        // re-begin is a no-op returning nothing to cancel.
        XCTAssertNil(coordinator.sessionDidBegin(newSession))
        XCTAssertTrue(coordinator.activeSession === newSession)

        // The expectation was consumed exactly once: a later genuine didEnd
        // must dismiss normally instead of being swallowed.
        coordinator.sessionDidEnd { dismissCount += 1 }
        XCTAssertEqual(dismissCount, 1)
        XCTAssertNil(coordinator.activeSession)

        // And a fresh session still closes through cancel, never
        // directDismiss (which would leak the host-side session).
        let thirdSession = NSObject()
        XCTAssertNil(coordinator.sessionDidBegin(thirdSession))
        var cancelledSessions: [NSObject] = []
        coordinator.requestClose(
            cancel: { cancelledSessions.append($0) },
            directDismiss: {
                XCTFail("an active session must close via cancel; directDismiss would leak it host-side")
            }
        )
        XCTAssertEqual(cancelledSessions.count, 1)
        XCTAssertTrue(cancelledSessions.first === thirdSession)
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
