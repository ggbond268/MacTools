import Foundation
import ServiceManagement

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

    private let service: SMAppService

    init(service: SMAppService = .agent(plistName: CLIServiceConfiguration.launchAgentPlistName)) {
        self.service = service
        refresh()
    }

    func ensureRegistered() {
        refresh()
        guard service.status == .notRegistered || service.status == .notFound else { return }
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func unregister() {
        do {
            try service.unregister()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
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
