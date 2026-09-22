import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarPanelMenuPresenterTests: XCTestCase {
    func testFirstRequestWaitsForActivationAndOpensOnlyOnce() async {
        let center = NotificationCenter()
        var isActive = false
        var activationRequests = 0
        var presentations = 0
        let presenter = MenuBarPanelMenuPresenter(
            notificationCenter: center, workspaceCenter: NotificationCenter(),
            isApplicationActive: { isActive }, activateApplication: { activationRequests += 1 })

        presenter.requestPresentation(isValid: { true }) { presentations += 1 }
        await drainMainQueue()
        XCTAssertEqual(activationRequests, 1)
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(presenter.isPresenting)

        isActive = true
        for _ in 0..<2 { center.post(name: NSApplication.didBecomeActiveNotification, object: nil) }
        await drainMainQueue()
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(presenter.isPresenting)

        presenter.requestPresentation(isValid: { true }) { presentations += 1 }
        await drainMainQueue()
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(activationRequests, 1)
    }

    func testCancelledOrHiddenOwnerDoesNotOpenAfterActivation() async {
        for cancelsRequest in [true, false] {
            let center = NotificationCenter()
            var isActive = false
            var isVisible = true
            var presentations = 0
            let presenter = MenuBarPanelMenuPresenter(
                notificationCenter: center, workspaceCenter: NotificationCenter(),
                isApplicationActive: { isActive }, activateApplication: {})
            presenter.requestPresentation(isValid: { isVisible }) { presentations += 1 }
            if cancelsRequest { presenter.cancel() } else { isVisible = false }
            isActive = true
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await drainMainQueue()
            XCTAssertEqual(presentations, 0)
            XCTAssertFalse(presenter.isPresenting)
        }
    }

    func testNewRequestReplacesQueuedPresentation() async {
        let presenter = MenuBarPanelMenuPresenter(
            notificationCenter: NotificationCenter(), workspaceCenter: NotificationCenter(),
            isApplicationActive: { true }, activateApplication: { XCTFail("Already active") })
        var selections: [String] = []
        presenter.requestPresentation(isValid: { true }) { selections.append("old") }
        presenter.requestPresentation(isValid: { true }) { selections.append("current") }
        await drainMainQueue()
        XCTAssertEqual(selections, ["current"])
        XCTAssertFalse(presenter.isPresenting)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
