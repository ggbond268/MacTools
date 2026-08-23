import ServiceManagement
import XCTest
@testable import MacTools

@MainActor
final class CLIBrokerServiceControllerTests: XCTestCase {
    func testUnregisterFailureRemainsEnabledAndReportsFailure() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.unregisterError = FakeCLIBrokerServiceError.refused
        let controller = makeController(service: service, registeredFingerprint: "current")

        XCTAssertFalse(controller.unregister())
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNotNil(controller.lastError)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testSuccessfulUnregisterReportsNotRegistered() {
        let service = FakeCLIBrokerService(status: .enabled)
        let controller = makeController(service: service, registeredFingerprint: "current")

        XCTAssertTrue(controller.unregister())
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNil(controller.lastError)
    }

    func testRegistrationFailureReportsFailure() {
        let service = FakeCLIBrokerService(status: .notRegistered)
        service.registerError = FakeCLIBrokerServiceError.refused
        let controller = makeController(service: service)

        XCTAssertFalse(controller.ensureRegistered())
        XCTAssertEqual(controller.status, .registrationFailed)
        XCTAssertNotNil(controller.lastError)
    }

    func testSuccessfulRegistrationRecordsCurrentFingerprint() {
        let service = FakeCLIBrokerService(status: .notRegistered)
        let store = FakeCLIBrokerRegistrationStore(registeredFingerprint: nil)
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.ensureRegistered())

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(store.registeredFingerprint, "current")
        XCTAssertEqual(controller.status, .enabled)
    }

    func testReconcileCyclesRegisteredServiceAfterAppUpgrade() {
        let service = FakeCLIBrokerService(status: .enabled)
        let store = FakeCLIBrokerRegistrationStore(registeredFingerprint: "old")
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(store.registeredFingerprint, "current")
        XCTAssertEqual(controller.status, .enabled)
    }

    func testReconcileKeepsCurrentRegisteredServiceRunning() {
        let service = FakeCLIBrokerService(status: .enabled)
        let controller = makeController(service: service, registeredFingerprint: "current")

        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testReconcileDoesNotEnableAnUnregisteredService() {
        let service = FakeCLIBrokerService(status: .notRegistered)
        let controller = makeController(service: service, registeredFingerprint: "old")

        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testReconcileReportsReregistrationFailure() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.registerError = FakeCLIBrokerServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(registeredFingerprint: "old")
        let controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertNil(store.registeredFingerprint)
        XCTAssertEqual(controller.status, .registrationFailed)
        XCTAssertNotNil(controller.lastError)
    }

    func testReconcilePreservesOldFingerprintWhenUnregisterFails() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.unregisterError = FakeCLIBrokerServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(registeredFingerprint: "old")
        let controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(store.registeredFingerprint, "old")
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNotNil(controller.lastError)
    }

    private func makeController(
        service: FakeCLIBrokerService,
        registeredFingerprint: String? = nil
    ) -> CLIBrokerServiceController {
        makeController(
            service: service,
            store: FakeCLIBrokerRegistrationStore(
                registeredFingerprint: registeredFingerprint
            )
        )
    }

    private func makeController(
        service: FakeCLIBrokerService,
        store: FakeCLIBrokerRegistrationStore
    ) -> CLIBrokerServiceController {
        CLIBrokerServiceController(
            service: service,
            registrationStore: store,
            currentRegistrationFingerprint: { "current" }
        )
    }
}

@MainActor
private final class FakeCLIBrokerService: CLIBrokerServicing {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

@MainActor
private final class FakeCLIBrokerRegistrationStore: CLIBrokerRegistrationStoring {
    var registeredFingerprint: String?

    init(registeredFingerprint: String?) {
        self.registeredFingerprint = registeredFingerprint
    }
}

private enum FakeCLIBrokerServiceError: Error {
    case refused
}
