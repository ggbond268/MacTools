import Foundation

@MainActor
final class CLIHostBridge: NSObject, CLIHostXPCProtocol {
    private let router: CLIHostRequestRouter
    private let serviceController: CLIBrokerServiceController
    private let identityValidator = CLIPeerIdentityValidator()
    private var connection: NSXPCConnection?
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTask: Task<Void, Never>?

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
    }

    func start() {
        serviceController.ensureRegistered()
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
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
                    allowedKeys: ["protocolVersion", "requestID", "operation", "sentAt", "payload"]
                )
            } catch {
                reply.call(Data())
                return
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { reply.call(Data()); return }
                let response = await router.handle(request)
                let data = (try? CLIProtocolCodec.encodeResponse(response)) ?? Data()
                requestTasks[request.requestID] = nil
                reply.call(data)
            }
            requestTasks[request.requestID] = task
        }
    }

    nonisolated func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        let reply = CLIHostReply(reply)
        Task { @MainActor [weak self] in
            guard let task = self?.requestTasks[requestID] else {
                reply.call(false)
                return
            }
            task.cancel()
            reply.call(true)
        }
    }

    private func connect() {
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
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.scheduleReconnect() }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.scheduleReconnect() }
        }
        connection.activate()
        self.connection = connection

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.scheduleReconnect() }
        }
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
        broker.registerHost(data) { [weak self] response in
            guard self?.identityValidator.accepts(connection, as: .broker) == true,
                  (try? CLIProtocolCodec.decodeResponse(
                CLIHandshakeResponse.self,
                from: response,
                allowedKeys: [
                    "selectedProtocolVersion", "brokerVersion", "brokerBuild", "hostVersion",
                    "hostBuild", "hostReady", "message",
                ]
            ))?.hostReady == true else {
                Task { @MainActor in self?.scheduleReconnect() }
                return
            }
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        connection = nil
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect()
        }
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
