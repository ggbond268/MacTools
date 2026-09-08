import XCTest
@testable import MacTools

@MainActor
final class PluginUninstallConfirmationSessionTests: XCTestCase {
    func testConfirmationIsEnabledAtTheStartOfASettingsSession() {
        let session = PluginUninstallConfirmationSession()

        XCTAssertTrue(session.shouldConfirmUninstall)
        XCTAssertFalse(session.isConfirmationPaused)
    }

    func testPausingConfirmationOnlyChangesTheCurrentSessionObject() {
        let session = PluginUninstallConfirmationSession()

        session.pauseConfirmation()

        XCTAssertFalse(session.shouldConfirmUninstall)
        XCTAssertTrue(session.isConfirmationPaused)
        XCTAssertTrue(PluginUninstallConfirmationSession().shouldConfirmUninstall)
    }

    func testResumingConfirmationRestoresTheSafeguard() {
        let session = PluginUninstallConfirmationSession()
        session.pauseConfirmation()

        session.resumeConfirmation()

        XCTAssertTrue(session.shouldConfirmUninstall)
        XCTAssertFalse(session.isConfirmationPaused)
    }

    func testPrivateDataRemovalAlwaysRequiresConfirmation() {
        let session = PluginUninstallConfirmationSession()
        session.pauseConfirmation()

        XCTAssertFalse(session.shouldConfirmUninstall(removesData: false))
        XCTAssertTrue(session.shouldConfirmUninstall(removesData: true))
    }
}
