import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

final class WindowSwitcherNotificationRegistrationTests: XCTestCase {
    func testTransientFailureRetriesWithBackoffAndStopsAfterSuccess() {
        var registration = WindowSwitcherNotificationRegistration()
        var calls = 0
        registration.attempt(at: 0) { calls += 1; return .cannotComplete }
        registration.attempt(at: 0.5) { calls += 1; return .success }
        XCTAssertFalse(registration.isRegistered)
        XCTAssertEqual(calls, 1)
        registration.attempt(at: 1) { calls += 1; return .cannotComplete }
        registration.attempt(at: 2) { calls += 1; return .success }
        XCTAssertEqual(calls, 2)
        registration.attempt(at: 3) { calls += 1; return .notificationAlreadyRegistered }
        registration.attempt(at: 100) { calls += 1; return .failure }
        XCTAssertTrue(registration.isRegistered)
        XCTAssertEqual(calls, 3)
    }

    func testUnsupportedNotificationDoesNotRetryOnEveryScan() {
        var registration = WindowSwitcherNotificationRegistration()
        registration.attempt(at: 0) { .notificationUnsupported }
        registration.attempt(at: 100) { XCTFail("Unsupported notifications need reconciliation, not repeated registration"); return .success }
        XCTAssertTrue(registration.isUnsupported)
        XCTAssertFalse(registration.isRegistered)
    }

    func testInvalidObserverRequiresReplacementInsteadOfSuccessfulRegistration() {
        var registration = WindowSwitcherNotificationRegistration()
        registration.attempt(at: 0) { .invalidUIElementObserver }
        XCTAssertTrue(registration.requiresObserverReset)
        XCTAssertFalse(registration.isRegistered)
    }

    func testWindowGeometryAndLifecycleChangesRequestWindowRecords() {
        for name in [kAXMovedNotification, kAXResizedNotification, kAXWindowCreatedNotification,
                     kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            XCTAssertTrue(WindowSwitcherProcessEvent.Kind(notification: name).requiresWindowRecords)
        }
        for name in [kAXTitleChangedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            XCTAssertFalse(WindowSwitcherProcessEvent.Kind(notification: name).requiresWindowRecords)
        }
    }
}
