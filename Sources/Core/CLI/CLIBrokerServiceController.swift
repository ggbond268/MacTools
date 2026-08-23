import Foundation
import ServiceManagement

@MainActor
protocol CLIBrokerServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
private final class SystemCLIBrokerService: CLIBrokerServicing {
    private let service: SMAppService

    init(service: SMAppService) {
        self.service = service
    }

    var status: SMAppService.Status { service.status }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

@MainActor
final class CLIBrokerServiceController: ObservableObject {
    static let shared = CLIBrokerServiceController()

    enum ServiceStatus: String {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case registrationFailed
    }

    @Published private(set) var status: ServiceStatus = .notRegistered
    @Published private(set) var lastError: String?

    private let service: any CLIBrokerServicing

    var isRegistered: Bool {
        service.status == .enabled || service.status == .requiresApproval
    }

    init(service: (any CLIBrokerServicing)? = nil) {
        self.service = service ?? SystemCLIBrokerService(
            service: .agent(plistName: CLIServiceConfiguration.launchAgentPlistName)
        )
        refresh()
    }

    @discardableResult
    func ensureRegistered() -> Bool {
        refresh()
        guard service.status == .notRegistered || service.status == .notFound else {
            return service.status == .enabled || service.status == .requiresApproval
        }
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        return service.status == .enabled || service.status == .requiresApproval
    }

    @discardableResult
    func unregister() -> Bool {
        if service.status == .notRegistered || service.status == .notFound {
            lastError = nil
            refresh()
            return true
        }
        do {
            try service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        return service.status == .notRegistered || service.status == .notFound
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refresh() {
        switch service.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notRegistered: status = lastError == nil ? .notRegistered : .registrationFailed
        case .notFound: status = .notFound
        @unknown default: status = .registrationFailed
        }
    }
}
