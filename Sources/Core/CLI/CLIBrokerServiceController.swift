import Foundation
import ServiceManagement

@MainActor
protocol CLIBrokerServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
protocol CLIBrokerRegistrationStoring: AnyObject {
    var registeredFingerprint: String? { get set }
    var enabledIntent: Bool? { get set }
}

@MainActor
private final class UserDefaultsCLIBrokerRegistrationStore: CLIBrokerRegistrationStoring {
    private let defaults: UserDefaults
    private let fingerprintKey: String
    private let enabledIntentKey: String

    init(defaults: UserDefaults = .standard, bundleIdentifier: String?) {
        self.defaults = defaults
        let suffix = bundleIdentifier ?? "unknown"
        fingerprintKey = "cli.broker.registered-fingerprint.\(suffix)"
        enabledIntentKey = "cli.broker.enabled-intent.\(suffix)"
    }

    var registeredFingerprint: String? {
        get { defaults.string(forKey: fingerprintKey) }
        set { defaults.set(newValue, forKey: fingerprintKey) }
    }

    var enabledIntent: Bool? {
        get { defaults.object(forKey: enabledIntentKey) as? Bool }
        set {
            if let newValue {
                defaults.set(newValue, forKey: enabledIntentKey)
            } else {
                defaults.removeObject(forKey: enabledIntentKey)
            }
        }
    }
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
    private let registrationStore: any CLIBrokerRegistrationStoring
    private let currentRegistrationFingerprint: () -> String

    var isRegistered: Bool {
        service.status == .enabled || service.status == .requiresApproval
    }

    init(
        service: (any CLIBrokerServicing)? = nil,
        registrationStore: (any CLIBrokerRegistrationStoring)? = nil,
        currentRegistrationFingerprint: (() -> String)? = nil
    ) {
        self.service = service ?? SystemCLIBrokerService(
            service: .agent(plistName: CLIServiceConfiguration.launchAgentPlistName)
        )
        self.registrationStore = registrationStore ?? UserDefaultsCLIBrokerRegistrationStore(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        self.currentRegistrationFingerprint = currentRegistrationFingerprint ?? {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = info["CFBundleVersion"] as? String ?? "unknown"
            let path = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            return "\(path)|\(version)|\(build)"
        }
        refresh()
    }

    @discardableResult
    func ensureRegistered() -> Bool {
        registrationStore.enabledIntent = true
        return reconcileRegisteredService()
    }

    @discardableResult
    func reconcileRegisteredService() -> Bool {
        refresh()
        let enabledIntent: Bool
        if let storedIntent = registrationStore.enabledIntent {
            enabledIntent = storedIntent
        } else if isRegistered {
            registrationStore.enabledIntent = true
            enabledIntent = true
        } else {
            return true
        }

        guard enabledIntent else {
            return unregisterDesiredService()
        }
        guard isRegistered else {
            return registerDesiredService()
        }
        let fingerprint = currentRegistrationFingerprint()
        guard registrationStore.registeredFingerprint != fingerprint else { return true }
        do {
            try service.unregister()
            registrationStore.registeredFingerprint = nil
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if isRegistered, lastError == nil {
            registrationStore.registeredFingerprint = fingerprint
            return true
        }
        return false
    }

    @discardableResult
    func unregister() -> Bool {
        registrationStore.enabledIntent = false
        return unregisterDesiredService()
    }

    private func registerDesiredService() -> Bool {
        guard service.status == .notRegistered || service.status == .notFound else {
            return false
        }
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        if isRegistered {
            registrationStore.registeredFingerprint = currentRegistrationFingerprint()
            return true
        }
        return false
    }

    private func unregisterDesiredService() -> Bool {
        if service.status == .notRegistered || service.status == .notFound {
            registrationStore.registeredFingerprint = nil
            lastError = nil
            refresh()
            return true
        }
        do {
            try service.unregister()
            registrationStore.registeredFingerprint = nil
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

    @discardableResult
    func applicationDidBecomeActive() -> Bool {
        reconcileRegisteredService()
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
