import AppKit
import XCTest
@testable import MacTools

// The expanded-interface bridge is wired entirely through runtime selector
// strings (26.5 SDK, no macOS 27 symbols), so there is no compiler safety
// net: a single wrong character means the host silently never calls back.
// These tests are the only line of defense — they pin every selector literal
// and exercise the callbacks through real ObjC dispatch.
@MainActor
final class MenuBarStatusItemExpandedInterfaceTests: XCTestCase {
    private typealias Adapter = MenuBarStatusItemExpandedInterfaceAdapter

    // MARK: Selector pinning

    func testSelectorConstantsMatchProbedLiterals() {
        XCTAssertEqual(Adapter.delegateSetterSelectorName, "setExpandedInterfaceDelegate:")
        XCTAssertEqual(Adapter.delegateGetterKey, "expandedInterfaceDelegate")
        XCTAssertEqual(Adapter.sessionGetterSelectorName, "expandedInterfaceSession")
        XCTAssertEqual(Adapter.sessionDidBeginSelectorName, "statusItem:didBeginExpandedInterfaceSession:")
        XCTAssertEqual(Adapter.sessionDidEndSelectorName, "statusItemDidEndExpandedInterfaceSession:animated:")
        XCTAssertEqual(Adapter.sessionCancelSelectorName, "cancel")
    }

    func testAdapterRespondsToCallbackSelectorConstants() {
        let adapter = Adapter()
        XCTAssertTrue(adapter.responds(to: NSSelectorFromString(Adapter.sessionDidBeginSelectorName)))
        XCTAssertTrue(adapter.responds(to: NSSelectorFromString(Adapter.sessionDidEndSelectorName)))
        XCTAssertTrue(Adapter.instancesRespond(to: NSSelectorFromString(Adapter.sessionDidBeginSelectorName)))
        XCTAssertTrue(Adapter.instancesRespond(to: NSSelectorFromString(Adapter.sessionDidEndSelectorName)))
    }

    func testAdapterRespondsToLiteralCallbackSelectors() {
        // Literal probes so an edit to the constants cannot mask drift away
        // from the device-verified selector strings.
        let adapter = Adapter()
        XCTAssertTrue(adapter.responds(to: NSSelectorFromString("statusItem:didBeginExpandedInterfaceSession:")))
        XCTAssertTrue(adapter.responds(to: NSSelectorFromString("statusItemDidEndExpandedInterfaceSession:animated:")))
    }

    // MARK: Callback forwarding through real ObjC dispatch

    func testDidBeginCallbackForwardsSameSessionObject() {
        let adapter = Adapter()
        var receivedSessions: [NSObject] = []
        adapter.onSessionBegin = { receivedSessions.append($0) }

        // Removed from the bar immediately: no assertion depends on the item
        // being installed, and an early removal cannot leak menu bar residue
        // even if the test process dies mid-test.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSStatusBar.system.removeStatusItem(item)
        let session = NSObject()

        _ = adapter.perform(
            NSSelectorFromString(Adapter.sessionDidBeginSelectorName),
            with: item,
            with: session
        )

        XCTAssertEqual(receivedSessions.count, 1)
        XCTAssertTrue(receivedSessions.first === session)
    }

    func testDidEndCallbackForwardsAnimatedFlag() {
        // `perform(_:with:with:)` cannot carry a BOOL argument, so the
        // selector is dispatched through its IMP with the correct C signature.
        typealias DidEndFunction = @convention(c) (NSObject, Selector, NSStatusItem, ObjCBool) -> Void

        let adapter = Adapter()
        var receivedAnimated: [Bool] = []
        adapter.onSessionEnd = { receivedAnimated.append($0) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSStatusBar.system.removeStatusItem(item)

        let selector = NSSelectorFromString(Adapter.sessionDidEndSelectorName)
        let implementation: IMP = adapter.method(for: selector)
        let callback = unsafeBitCast(implementation, to: DidEndFunction.self)
        callback(adapter, selector, item, ObjCBool(true))
        callback(adapter, selector, item, ObjCBool(false))

        XCTAssertEqual(receivedAnimated, [true, false])
    }

    // MARK: cancel(session:)

    func testCancelOnNonRespondingSessionDoesNotCrash() {
        let session = NSObject()
        // Precondition of the guard branch: a plain NSObject must not
        // respond to the cancel selector.
        XCTAssertFalse(session.responds(to: NSSelectorFromString(Adapter.sessionCancelSelectorName)))

        // Returning without an ObjC exception is the assertion; the error
        // log path cannot be injected here.
        Adapter.cancel(session: session)
    }

    func testCancelInvokesCancelExactlyOnceOnRespondingSession() {
        let session = RecordingCancellableSession()
        Adapter.cancel(session: session)
        XCTAssertEqual(session.cancelCount, 1)
    }

    // MARK: Live runtime attach/detach

    func testIsSupportedMatchesSetterSelectorProbe() {
        // On macOS <= 26 both sides are false, so this passes vacuously; the
        // selector-constants test is the real pin there. It only gains
        // discriminating power on a 27 runtime, where the setter exists.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSStatusBar.system.removeStatusItem(item)

        XCTAssertEqual(
            Adapter.isSupported(by: item),
            item.responds(to: NSSelectorFromString("setExpandedInterfaceDelegate:"))
        )
    }

    func testAttachVerifiesReadBackAndDetachClearsDelegate() throws {
        // The delegate property lives on the item object, not on its bar
        // installation, so attach/read-back works after immediate removal.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        NSStatusBar.system.removeStatusItem(item)

        guard Adapter.isSupported(by: item) else {
            throw XCTSkip(
                "expandedInterfaceDelegate is not present on this macOS; the <=26 path is isSupported == false"
            )
        }

        let adapter = Adapter()
        XCTAssertTrue(adapter.attach(to: item))

        // Independent read-back of the exact weak property the host consults.
        XCTAssertTrue(item.responds(to: NSSelectorFromString(Adapter.delegateGetterKey)))
        XCTAssertTrue((item.value(forKey: Adapter.delegateGetterKey) as? NSObject) === adapter)

        adapter.detach(from: item)
        XCTAssertNil(item.value(forKey: Adapter.delegateGetterKey))
    }

    func testAttachRollsBackDelegateOnReadBackMismatch() {
        // Models a host that wraps/proxies the delegate so the read-back is
        // a different object. A false return must leave the delegate cleared:
        // an attached delegate replaces the action channel, so failing
        // without rollback would strand the status item with neither route.
        // The fake's overrides make this deterministic on every macOS
        // version (the selectors exist via the subclass even on <= 26).
        let item = ReadBackMismatchStatusItem()
        let adapter = Adapter()

        XCTAssertFalse(adapter.attach(to: item))

        XCTAssertEqual(item.recordedDelegateWrites.count, 2)
        XCTAssertTrue(item.recordedDelegateWrites[0] === adapter)
        XCTAssertNil(item.recordedDelegateWrites[1])
    }

    // MARK: Coordinator state machine

    func testSessionDidBeginStoresSessionAndReplacesNothing() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        let session = NSObject()

        XCTAssertNil(coordinator.sessionDidBegin(session))
        XCTAssertTrue(coordinator.activeSession === session)
        XCTAssertFalse(coordinator.isHandlingSessionEnd)
    }

    func testDoubleBeginReturnsReplacedSessionAndStoresNewOne() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        let first = NSObject()
        let second = NSObject()

        XCTAssertNil(coordinator.sessionDidBegin(first))
        let replaced = coordinator.sessionDidBegin(second)

        XCTAssertTrue(replaced === first)
        XCTAssertTrue(coordinator.activeSession === second)
    }

    func testTakeoverSwallowsSynchronousReplacedSessionEnd() {
        // Production takeover stack: sessionDidBegin returns the replaced
        // session, the caller cancels it, and per the device-verified
        // contract that cancel fires didEnd synchronously on the same stack.
        // That didEnd belongs to the SUPERSEDED session: it must not wipe
        // the just-stored new session or dismiss anything.
        let coordinator = MenuBarExpandedSessionCoordinator()
        let first = NSObject()
        let second = NSObject()

        XCTAssertNil(coordinator.sessionDidBegin(first))
        let replaced = coordinator.sessionDidBegin(second)
        XCTAssertTrue(replaced === first)

        var dismissCount = 0
        // Synchronous didEnd produced by cancelling `replaced`.
        coordinator.sessionDidEnd { dismissCount += 1 }

        XCTAssertEqual(dismissCount, 0)
        XCTAssertTrue(coordinator.activeSession === second)

        // The swallow is one-shot: the next close must cancel the live
        // replacement session, and ITS synchronous didEnd must dismiss.
        var cancelledSessions: [NSObject] = []
        coordinator.requestClose(
            cancel: { session in
                cancelledSessions.append(session)
                coordinator.sessionDidEnd { dismissCount += 1 }
            },
            directDismiss: {
                XCTFail("the live replacement session must be cancelled, not direct-dismissed")
            }
        )

        XCTAssertEqual(cancelledSessions.count, 1)
        XCTAssertTrue(cancelledSessions.first === second)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertFalse(coordinator.isHandlingSessionEnd)
    }

    func testRequestCloseClearsStaleTakeoverExpectation() {
        // If the takeover caller never delivered the replaced session's
        // didEnd (e.g. the session did not respond to cancel), the swallow
        // expectation is stale by the next close request and must not eat
        // that close's own synchronous didEnd.
        let coordinator = MenuBarExpandedSessionCoordinator()
        _ = coordinator.sessionDidBegin(NSObject())
        let second = NSObject()
        _ = coordinator.sessionDidBegin(second)

        var dismissCount = 0
        coordinator.requestClose(
            cancel: { session in
                XCTAssertTrue(session === second)
                coordinator.sessionDidEnd { dismissCount += 1 }
            },
            directDismiss: { XCTFail("a session is active; close must go through cancel") }
        )

        XCTAssertEqual(dismissCount, 1)
        XCTAssertNil(coordinator.activeSession)
    }

    func testRebeginningIdenticalSessionReturnsNilAndKeepsIt() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        let session = NSObject()

        _ = coordinator.sessionDidBegin(session)
        // Returning the identical object would make the caller cancel the
        // session that was just stored.
        XCTAssertNil(coordinator.sessionDidBegin(session))
        XCTAssertTrue(coordinator.activeSession === session)
    }

    func testRequestCloseWithActiveSessionClearsBeforeCancelAndSkipsDirectDismiss() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        let session = NSObject()
        _ = coordinator.sessionDidBegin(session)

        var cancelledSessions: [NSObject] = []
        var directDismissCount = 0
        coordinator.requestClose(
            cancel: { cancelled in
                // cancel() re-enters via didEnd on this same stack in
                // production; the session must already be cleared here.
                XCTAssertNil(coordinator.activeSession)
                cancelledSessions.append(cancelled)
            },
            directDismiss: { directDismissCount += 1 }
        )

        XCTAssertEqual(cancelledSessions.count, 1)
        XCTAssertTrue(cancelledSessions.first === session)
        XCTAssertEqual(directDismissCount, 0)
    }

    func testRequestCloseWithoutSessionCallsDirectDismissOnly() {
        let coordinator = MenuBarExpandedSessionCoordinator()

        var cancelCount = 0
        var directDismissCount = 0
        coordinator.requestClose(
            cancel: { _ in cancelCount += 1 },
            directDismiss: { directDismissCount += 1 }
        )

        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(directDismissCount, 1)
    }

    func testSessionDidEndClearsSessionAndCallsDismissInsideGuard() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        _ = coordinator.sessionDidBegin(NSObject())

        var dismissCount = 0
        coordinator.sessionDidEnd {
            dismissCount += 1
            XCTAssertTrue(coordinator.isHandlingSessionEnd)
            XCTAssertNil(coordinator.activeSession)
        }

        XCTAssertEqual(dismissCount, 1)
        XCTAssertFalse(coordinator.isHandlingSessionEnd)
    }

    func testSessionDidEndReentryGuardPreventsRecursion() {
        let coordinator = MenuBarExpandedSessionCoordinator()
        _ = coordinator.sessionDidBegin(NSObject())

        var dismissCount = 0
        coordinator.sessionDidEnd {
            dismissCount += 1
            coordinator.sessionDidEnd { dismissCount += 1 }
        }

        XCTAssertEqual(dismissCount, 1)
        XCTAssertFalse(coordinator.isHandlingSessionEnd)
    }

    func testCancelSynchronousDidEndSequenceDismissesExactlyOnceAndResetsState() {
        // Production timing: requestClose → cancel(session) → host fires
        // didEnd synchronously on the same call stack → sessionDidEnd.
        let coordinator = MenuBarExpandedSessionCoordinator()
        let session = NSObject()
        _ = coordinator.sessionDidBegin(session)

        var dismissCount = 0
        coordinator.requestClose(
            cancel: { _ in
                coordinator.sessionDidEnd { dismissCount += 1 }
            },
            directDismiss: { XCTFail("directDismiss must not run while a session is active") }
        )

        XCTAssertEqual(dismissCount, 1)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertFalse(coordinator.isHandlingSessionEnd)

        // Fully reset: the next close request must take the direct path.
        var directDismissCount = 0
        coordinator.requestClose(
            cancel: { _ in XCTFail("no session should be active after the synchronous end sequence") },
            directDismiss: { directDismissCount += 1 }
        )
        XCTAssertEqual(directDismissCount, 1)
    }
}

// MARK: - Test doubles

private final class RecordingCancellableSession: NSObject {
    private(set) var cancelCount = 0

    @objc func cancel() {
        cancelCount += 1
    }
}

/// Plain-initialized NSStatusItem subclass (never installed in a bar, so no
/// menu bar residue) whose delegate getter always disagrees with the setter.
/// On macOS 27 the overrides shadow the real accessors; on <= 26 they ARE the
/// accessors — either way `attach` deterministically hits the read-back
/// mismatch branch.
private final class ReadBackMismatchStatusItem: NSStatusItem {
    private(set) var recordedDelegateWrites: [NSObject?] = []
    private let mismatchedReadBack = NSObject()

    @objc(setExpandedInterfaceDelegate:)
    func recordExpandedInterfaceDelegate(_ delegate: NSObject?) {
        recordedDelegateWrites.append(delegate)
    }

    @objc(expandedInterfaceDelegate)
    func mismatchedExpandedInterfaceDelegate() -> NSObject? {
        mismatchedReadBack
    }
}
