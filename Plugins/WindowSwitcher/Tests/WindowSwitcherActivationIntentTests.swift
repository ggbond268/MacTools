import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherActivationIntentTests: XCTestCase {
    private func activateCurrentApp(in center: NotificationCenter) {
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
    }

    func testSwitchAwayAndBackDuringValidationPreventsActivation() async {
        let center = NotificationCenter()
        let intent = WindowSwitcherActivationIntent(targetPID: -2, notificationCenter: center, foregroundPID: { -1 })
        defer { intent.finish() }
        var resume: CheckedContinuation<Void, Never>?
        let operation = Task {
            await withCheckedContinuation { resume = $0 }
            return await WindowSwitcherApplicationActivation.prepare(
                state: { .init(isHidden: true, isFrontmost: false) },
                request: { _ in XCTFail("Superseded selection must not unhide or activate") },
                fallbackRequest: { XCTFail("Superseded selection must not use fallback") },
                shouldContinue: { intent.shouldContinue() })
        }
        while resume == nil { await Task.yield() }
        // The notification records leaving, even though the sampled foreground
        // has already returned to the starting app when validation completes.
        activateCurrentApp(in: center)
        resume?.resume()
        let result = await operation.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(intent.cancellation.isCancelled)
    }

    func testForegroundRecheckCatchesChangeBeforeNotification() {
        var foreground: pid_t? = -1
        let intent = WindowSwitcherActivationIntent(targetPID: -2, notificationCenter: NotificationCenter(), foregroundPID: { foreground })
        defer { intent.finish() }
        foreground = -3
        XCTAssertFalse(intent.shouldContinue())
        foreground = -1
        XCTAssertFalse(intent.shouldContinue(), "Cancellation must remain sticky")
    }

    func testExpectedHandoffIsAllowedButReturningToOriginAfterTargetCancels() {
        let center = NotificationCenter()
        var foreground: pid_t? = -1
        let intent = WindowSwitcherActivationIntent(targetPID: NSRunningApplication.current.processIdentifier,
            notificationCenter: center, foregroundPID: { foreground })
        defer { intent.finish() }
        XCTAssertTrue(intent.shouldContinue())
        foreground = nil
        XCTAssertTrue(intent.shouldContinue(), "An unknown foreground during handoff is not a new app")
        foreground = NSRunningApplication.current.processIdentifier
        activateCurrentApp(in: center)
        XCTAssertTrue(intent.shouldContinue())
        foreground = -1
        XCTAssertFalse(intent.shouldContinue())
    }

    func testFinishRemovesObserver() {
        let center = NotificationCenter()
        let intent = WindowSwitcherActivationIntent(targetPID: -2, notificationCenter: center, foregroundPID: { -1 })
        intent.finish()
        activateCurrentApp(in: center)
        XCTAssertTrue(intent.shouldContinue())
    }

    func testObserverDoesNotRetainIntent() {
        let center = NotificationCenter()
        var intent: WindowSwitcherActivationIntent? = WindowSwitcherActivationIntent(targetPID: -2,
            notificationCenter: center, foregroundPID: { -1 })
        weak var reference = intent
        intent = nil
        XCTAssertNil(reference)
        activateCurrentApp(in: center)
    }

    func testTaskCancellationPropagatesToWorkerToken() async {
        let intent = WindowSwitcherActivationIntent(targetPID: -2, notificationCenter: NotificationCenter(), foregroundPID: { -1 })
        defer { intent.finish() }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return intent.shouldContinue()
        }
        let result = await operation.value
        XCTAssertFalse(result)
        XCTAssertTrue(intent.cancellation.isCancelled)
    }
}
