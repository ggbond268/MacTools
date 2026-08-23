import Combine
import Foundation

@MainActor
final class CLIHostBridge: NSObject, CLIHostXPCProtocol {
    private let router: CLIHostRequestRouter
    private let serviceController: CLIBrokerServiceController
    private let identityValidator = CLIPeerIdentityValidator()
    private var connection: NSXPCConnection?
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellationState = CLIHostCancellationRelayState()
    private var reconnectTask: Task<Void, Never>?
    private var serviceStatusObservation: AnyCancellable?
    private var isStarted = false
    private lazy var callbackRelay = CLIHostBridgeCallbackRelay { @MainActor [weak self] in
        self?.scheduleReconnect()
    }

    init(
        pluginHost: PluginHost,
        serviceController: CLIBrokerServiceController = .shared
    ) {
        self.serviceController = serviceController
        self.router = CLIHostRequestRouter(
            pluginHost: pluginHost,
            serviceStatus: { serviceController.status.rawValue }
        )
        super.init()
        serviceStatusObservation = serviceController.$status
            .removeDuplicates()
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.serviceStatusDidChange(status)
                }
            }
    }

    func start() {
        isStarted = true
        serviceController.reconcileRegisteredService()
        serviceStatusDidChange(serviceController.status)
    }

    func stop() {
        isStarted = false
        reconnectTask?.cancel()
        reconnectTask = nil
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        cancellationState.reset()
        connection?.invalidate()
        connection = nil
    }

    nonisolated func handle(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        let reply = CLIHostReply(reply)
        Task { @MainActor [weak self] in
            guard let self else { reply.call(Data()); return }
            let request: CLIRequestEnvelope
            do {
                request = try CLIProtocolCodec.decodeRequest(
                    CLIRequestEnvelope.self,
                    from: requestData,
                    allowedKeys: [
                        "protocolVersion", "requestID", "operation", "sentAt",
                        "invocationContext", "payload",
                    ]
                )
            } catch {
                reply.call(Data())
                return
            }
            guard cancellationState.shouldBeginHandling(request.requestID) else {
                cancellationState.markCompleted(request.requestID)
                let response = CLIResponseEnvelope.failure(
                    request: request,
                    outcome: .cancelled,
                    category: "cancelled",
                    message: "The request was cancelled."
                )
                reply.call((try? CLIProtocolCodec.encodeResponse(response)) ?? Data())
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { reply.call(Data()); return }
                let response = await router.handle(request)
                let data = (try? CLIProtocolCodec.encodeResponse(response)) ?? Data()
                requestTasks[request.requestID] = nil
                cancellationState.markCompleted(request.requestID)
                reply.call(data)
            }
            requestTasks[request.requestID] = task
        }
    }

    nonisolated func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        let reply = CLIHostReply(reply)
        Task { @MainActor [weak self] in
            guard let self else {
                reply.call(false)
                return
            }
            let task = requestTasks[requestID]
            switch cancellationState.cancellationDisposition(
                requestID: requestID,
                hasActiveTask: task != nil
            ) {
            case .cancelActive:
                task?.cancel()
                reply.call(true)
            case .recordedBeforeRegistration:
                reply.call(true)
            case .alreadyCompleted, .capacityExceeded:
                reply.call(false)
            }
        }
    }

    private func connect() {
        guard isStarted, serviceController.status != .notRegistered,
              serviceController.status != .notFound,
              serviceController.status != .registrationFailed else {
            return
        }
        connection?.invalidate()
        let connection = NSXPCConnection(
            machServiceName: CLIServiceConfiguration.serviceName(
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: CLIHostXPCProtocol.self)
        connection.exportedObject = self
        guard identityValidator.configure(connection, toRequire: .broker) else {
            serviceController.refresh()
            return
        }
        connection.invalidationHandler = callbackRelay.makeReconnectHandler()
        connection.interruptionHandler = callbackRelay.makeReconnectHandler()
        connection.activate()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler(
            callbackRelay.makeReconnectErrorHandler()
        )
        guard let broker = proxy as? CLIBrokerXPCProtocol else {
            scheduleReconnect()
            return
        }
        let registration = CLIHostRegistration(
            minimumProtocolVersion: CLIProtocolVersion.minimum,
            maximumProtocolVersion: CLIProtocolVersion.current,
            hostVersion: AppMetadata.shortVersion ?? "unknown",
            hostBuild: AppMetadata.buildNumber ?? "unknown"
        )
        guard let data = try? CLIProtocolCodec.encodeRequest(registration) else { return }
        broker.registerHost(
            data,
            withReply: callbackRelay.makeRegistrationReplyHandler(for: connection)
        )
    }

    private func scheduleReconnect() {
        guard isStarted, reconnectTask == nil else { return }
        connection = nil
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        cancellationState.reset()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect()
        }
    }

    private func serviceStatusDidChange(
        _ status: CLIBrokerServiceController.ServiceStatus
    ) {
        guard isStarted else { return }
        switch status {
        case .enabled, .requiresApproval:
            if connection == nil {
                connect()
            }
        case .notRegistered, .notFound, .registrationFailed:
            reconnectTask?.cancel()
            reconnectTask = nil
            connection?.invalidate()
            connection = nil
        }
    }
}

/// Keeps callbacks invoked by NSXPCConnection nonisolated, then explicitly hops UI state back to
/// the main actor. Foundation does not annotate these callback parameters as `@Sendable`, so a
/// closure created directly inside `CLIHostBridge.connect()` inherits `@MainActor` and traps when
/// XPC invokes it on its private reply queue.
final class CLIHostBridgeCallbackRelay: @unchecked Sendable {
    private let reconnect: @MainActor @Sendable () -> Void

    init(reconnect: @escaping @MainActor @Sendable () -> Void) {
        self.reconnect = reconnect
    }

    nonisolated func makeReconnectHandler() -> @Sendable () -> Void {
        { [weak self] in self?.requestReconnect() }
    }

    nonisolated func makeReconnectErrorHandler() -> @Sendable (Error) -> Void {
        { [weak self] _ in self?.requestReconnect() }
    }

    nonisolated func makeRegistrationReplyHandler(
        for connection: NSXPCConnection
    ) -> @Sendable (Data) -> Void {
        let connectionReference = CLIHostXPCConnectionReference(connection)
        return { [weak self, connectionReference] response in
            guard let connection = connectionReference.connection,
                  CLIPeerIdentityValidator().accepts(connection, as: .broker),
                  (try? CLIProtocolCodec.decodeResponse(
                    CLIHandshakeResponse.self,
                    from: response,
                    allowedKeys: [
                        "selectedProtocolVersion", "brokerVersion", "brokerBuild", "hostVersion",
                        "hostBuild", "hostReady", "message",
                    ]
                  ))?.hostReady == true else {
                self?.requestReconnect()
                return
            }
        }
    }

    nonisolated func requestReconnect() {
        let reconnect = reconnect
        Task { @MainActor in reconnect() }
    }
}

private final class CLIHostXPCConnectionReference: @unchecked Sendable {
    weak var connection: NSXPCConnection?

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private final class CLIHostReply<Value>: @unchecked Sendable {
    private let closure: (Value) -> Void

    init(_ closure: @escaping (Value) -> Void) {
        self.closure = closure
    }

    func call(_ value: Value) {
        closure(value)
    }
}
