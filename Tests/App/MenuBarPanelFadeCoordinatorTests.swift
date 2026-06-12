import XCTest
@testable import MacTools

/// Headless tests for the fade-out state machine that backs the menu bar
/// panel closing animation. The AppKit animation itself is not exercised
/// here; these lock the cancellation/reopen rules that keep the reused
/// popover window from being left transparent or double-closed.
@MainActor
final class MenuBarPanelFadeCoordinatorTests: XCTestCase {
    func testBeginFadeOutReturnsTokenAndMarksFading() {
        let coordinator = MenuBarPanelFadeCoordinator()

        let token = coordinator.beginFadeOut()

        XCTAssertNotNil(token)
        XCTAssertTrue(coordinator.isFadingOut)
    }

    func testSecondCloseDuringFadeIsIgnored() {
        let coordinator = MenuBarPanelFadeCoordinator()
        let firstToken = coordinator.beginFadeOut()

        XCTAssertNil(coordinator.beginFadeOut())

        // The first fade keeps ownership and still finishes the close.
        XCTAssertTrue(coordinator.finishFadeOut(token: firstToken!))
    }

    func testFinishFadeOutWithCurrentTokenFinishesExactlyOnce() {
        let coordinator = MenuBarPanelFadeCoordinator()
        let token = coordinator.beginFadeOut()!

        XCTAssertTrue(coordinator.finishFadeOut(token: token))
        XCTAssertFalse(coordinator.isFadingOut)
        // A duplicate completion (e.g. delegate + animation racing) must not
        // close again.
        XCTAssertFalse(coordinator.finishFadeOut(token: token))
    }

    func testReopenDuringFadeCancelsAndStaleCompletionDoesNotClose() {
        let coordinator = MenuBarPanelFadeCoordinator()
        let staleToken = coordinator.beginFadeOut()!

        // Reopen while the fade is running: caller must restore alpha and
        // finish the pending close immediately.
        XCTAssertTrue(coordinator.prepareForPresentation())
        XCTAssertFalse(coordinator.isFadingOut)

        // The original animation completion later fires with a stale token
        // and must be a no-op.
        XCTAssertFalse(coordinator.finishFadeOut(token: staleToken))
    }

    func testPrepareForPresentationWithoutFadeReportsNoCancellation() {
        let coordinator = MenuBarPanelFadeCoordinator()

        XCTAssertFalse(coordinator.prepareForPresentation())
        XCTAssertFalse(coordinator.isFadingOut)
    }

    func testCloseAfterCancelledFadeUsesFreshToken() {
        let coordinator = MenuBarPanelFadeCoordinator()
        let staleToken = coordinator.beginFadeOut()!
        _ = coordinator.prepareForPresentation()

        let freshToken = coordinator.beginFadeOut()

        XCTAssertNotNil(freshToken)
        XCTAssertNotEqual(freshToken, staleToken)
        XCTAssertFalse(coordinator.finishFadeOut(token: staleToken))
        XCTAssertTrue(coordinator.finishFadeOut(token: freshToken!))
    }

    func testExternalCloseInvalidatesInFlightFadeWithoutSticking() {
        let coordinator = MenuBarPanelFadeCoordinator()
        let staleToken = coordinator.beginFadeOut()!

        // The popover closed through some other path (e.g. AppKit teardown)
        // while the fade was still running.
        coordinator.notePopoverClosed()

        XCTAssertFalse(coordinator.isFadingOut)
        XCTAssertFalse(coordinator.finishFadeOut(token: staleToken))
        // The coordinator must not be stuck: the next close fades normally.
        XCTAssertNotNil(coordinator.beginFadeOut())
    }
}
