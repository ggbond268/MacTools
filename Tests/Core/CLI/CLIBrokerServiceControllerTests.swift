import ServiceManagement
import XCTest
@testable import MacTools

@MainActor
final class CLIBrokerServiceControllerTests: XCTestCase {
    func testUnregisterFailureRemainsEnabledAndReportsFailure() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.unregisterError = FakeCLIBrokerServiceError.refused
        let controller = CLIBrokerServiceController(service: service)

        XCTAssertFalse(controller.unregister())
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testSuccessfulUnregisterReportsNotRegistered() {
        let service = FakeCLIBrokerService(status: .enabled)
        let controller = CLIBrokerServiceController(service: service)

        XCTAssertTrue(controller.unregister())
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNil(controller.lastError)
    }

    func testRegistrationFailureReportsFailure() {
        let service = FakeCLIBrokerService(status: .notRegistered)
        service.registerError = FakeCLIBrokerServiceError.refused
        let controller = CLIBrokerServiceController(service: service)

        XCTAssertFalse(controller.ensureRegistered())
        XCTAssertEqual(controller.status, .registrationFailed)
        XCTAssertNotNil(controller.lastError)
    }
}

@MainActor
private final class FakeCLIBrokerService: CLIBrokerServicing {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private enum FakeCLIBrokerServiceError: Error {
    case refused
}
