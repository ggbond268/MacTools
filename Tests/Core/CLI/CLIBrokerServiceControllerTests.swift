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
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "old",
            enabledIntent: true
        )
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
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "old",
            enabledIntent: false
        )
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(store.enabledIntent, false)
    }

    func testReconcileReportsReregistrationFailure() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.registerError = FakeCLIBrokerServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "old",
            enabledIntent: true
        )
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
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "old",
            enabledIntent: true
        )
        let controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(store.registeredFingerprint, "old")
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNotNil(controller.lastError)
    }

    func testReconcileRetriesRegistrationAfterReplacementFailure() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.registerError = FakeCLIBrokerServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "old",
            enabledIntent: true
        )
        var controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.reconcileRegisteredService())
        XCTAssertEqual(service.status, .notRegistered)
        XCTAssertEqual(store.enabledIntent, true)

        service.registerError = nil
        controller = makeController(service: service, store: store)
        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertEqual(store.registeredFingerprint, "current")
        XCTAssertEqual(store.enabledIntent, true)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testLegacyRegisteredServiceMigratesToEnabledIntent() {
        let service = FakeCLIBrokerService(status: .enabled)
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "current",
            enabledIntent: nil
        )
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(store.enabledIntent, true)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testLegacyUnregisteredServiceRemainsDisabledWithoutIntent() {
        let service = FakeCLIBrokerService(status: .notRegistered)
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: nil,
            enabledIntent: nil
        )
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertNil(store.enabledIntent)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testReconcileRetriesExplicitDisableAfterUnregisterFailure() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.unregisterError = FakeCLIBrokerServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "current",
            enabledIntent: true
        )
        var controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.unregister())
        XCTAssertEqual(store.enabledIntent, false)

        service.unregisterError = nil
        controller = makeController(service: service, store: store)
        XCTAssertTrue(controller.reconcileRegisteredService())

        XCTAssertEqual(service.unregisterCallCount, 2)
        XCTAssertEqual(store.registeredFingerprint, nil)
        XCTAssertEqual(store.enabledIntent, false)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    private func makeController(
        service: FakeCLIBrokerService,
        registeredFingerprint: String? = nil
    ) -> CLIBrokerServiceController {
        makeController(
            service: service,
            store: FakeCLIBrokerRegistrationStore(
                registeredFingerprint: registeredFingerprint,
                enabledIntent: service.status == .enabled
                    || service.status == .requiresApproval
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
    var enabledIntent: Bool?

    init(registeredFingerprint: String?, enabledIntent: Bool? = nil) {
        self.registeredFingerprint = registeredFingerprint
        self.enabledIntent = enabledIntent
    }
}

private enum FakeCLIBrokerServiceError: Error {
    case refused
}
