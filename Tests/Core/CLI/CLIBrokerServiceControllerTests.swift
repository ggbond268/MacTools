import Combine
import ServiceManagement
import XCTest
@testable import MacTools

@MainActor
final class CLIBrokerServiceControllerTests: XCTestCase {
    func testRegistrationIsExplicitAndRecordsCurrentFingerprint() {
        let service = FakeCLIBrokerService(status: .notRegistered)
        let store = FakeCLIBrokerRegistrationStore()
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.reconcileRegisteredService())
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertTrue(controller.ensureRegistered())
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(store.enabledIntent, true)
        XCTAssertEqual(store.registeredFingerprint, "current")
        XCTAssertEqual(controller.status, .enabled)
    }

    func testExplicitDisableSurvivesFailureAndRetriesOnReconcile() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.unregisterError = FakeServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "current",
            enabledIntent: true
        )
        var controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.unregister())
        XCTAssertEqual(store.enabledIntent, false)
        XCTAssertEqual(controller.status, .enabled)

        service.unregisterError = nil
        controller = makeController(service: service, store: store)
        XCTAssertTrue(controller.reconcileRegisteredService())
        XCTAssertEqual(service.unregisterCallCount, 2)
        XCTAssertNil(store.registeredFingerprint)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testUpgradeReplacesEnabledRegistration() {
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
    }

    func testUpgradeFailurePreservesIntentForLaterRetry() {
        let service = FakeCLIBrokerService(status: .enabled)
        service.registerError = FakeServiceError.refused
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "old",
            enabledIntent: true
        )
        var controller = makeController(service: service, store: store)

        XCTAssertFalse(controller.reconcileRegisteredService())
        XCTAssertEqual(store.enabledIntent, true)
        XCTAssertEqual(controller.status, .registrationFailed)

        service.registerError = nil
        controller = makeController(service: service, store: store)
        XCTAssertTrue(controller.reconcileRegisteredService())
        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertEqual(store.registeredFingerprint, "current")
    }

    func testRequiresApprovalCountsAsRegistered() {
        let service = FakeCLIBrokerService(status: .requiresApproval)
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "current",
            enabledIntent: true
        )
        let controller = makeController(service: service, store: store)

        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.reconcileRegisteredService())
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testApplicationActivationPublishesExternalApprovalWithoutRestart() {
        let service = FakeCLIBrokerService(status: .requiresApproval)
        let store = FakeCLIBrokerRegistrationStore(
            registeredFingerprint: "current",
            enabledIntent: true
        )
        let controller = makeController(service: service, store: store)
        var publishedStatuses: [CLIBrokerServiceController.ServiceStatus] = []
        let observation = controller.$status.dropFirst().sink {
            publishedStatuses.append($0)
        }

        service.status = .enabled

        XCTAssertTrue(controller.applicationDidBecomeActive())
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(publishedStatuses, [.enabled])
        withExtendedLifetime(observation) {}
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

    init(registeredFingerprint: String? = nil, enabledIntent: Bool? = nil) {
        self.registeredFingerprint = registeredFingerprint
        self.enabledIntent = enabledIntent
    }
}

private enum FakeServiceError: Error {
    case refused
}
