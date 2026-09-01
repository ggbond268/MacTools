import CoreServices
import XCTest
@testable import SystemPowerPlugin

final class SystemPowerControllerTests: XCTestCase {
    func testLoginWindowEventMappingUsesConfirmationDialogsForDestructiveActions() {
        XCTAssertNil(SystemPowerController.loginWindowEventID(for: .sleep))
        XCTAssertEqual(
            SystemPowerController.loginWindowEventID(for: .logOut),
            AEEventID(kAELogOut)
        )
        XCTAssertEqual(
            SystemPowerController.loginWindowEventID(for: .restart),
            AEEventID(kAEShowRestartDialog)
        )
        XCTAssertEqual(
            SystemPowerController.loginWindowEventID(for: .shutDown),
            AEEventID(kAEShowShutdownDialog)
        )
    }

    func testDestructiveActionMappingDoesNotUseImmediateEvents() {
        XCTAssertNotEqual(
            SystemPowerController.loginWindowEventID(for: .restart),
            AEEventID(kAERestart)
        )
        XCTAssertNotEqual(
            SystemPowerController.loginWindowEventID(for: .shutDown),
            AEEventID(kAEShutDown)
        )
    }
}
