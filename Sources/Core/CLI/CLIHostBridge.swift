import Combine
import Foundation
import MacToolsCLIProtocol

@MainActor
final class CLIHostBridge: NSObject, CLIHostXPCProtocol {
    private let serviceController: CLIBrokerServiceController
    private let identityValidator = CLIPeerIdentityValidator()
    nonisolated private let callerIsBroker: @Sendable () -> Bool
    nonisolated private let requestState = CLIHostRequestState()
    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff = CLIReconnectBackoff()
    private var connectionGeneration = CLIConnectionGeneration()
    private var localIdentityCache = CLILocalPeerIdentityCache()
    private var serviceStatusObservation: AnyCancellable?
    private var isStarted = false
    private lazy var callbackRelay = CLIHostBridgeCallbackRelay(
        reconnect: { @MainActor [weak self] generation in
            guard self?.connectionGeneration.isCurrent(generation) == true else { return }
            self?.scheduleReconnect()
        },
        registered: { @MainActor [weak self] generation in
            guard self?.connectionGeneration.isCurrent(generation) == true else { return }
            self?.reconnectBackoff.reset()
        }
    )

    init(
        serviceController: CLIBrokerServiceController = .shared,
        callerIsBroker: @escaping @Sendable () -> Bool = {
            guard let connection = NSXPCConnection.current() else { return false }
            return CLIPeerIdentityValidator().accepts(connection, as: .broker)
        }
    ) {
        self.serviceController = serviceController
        self.callerIsBroker = callerIsBroker
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
        reconnectBackoff.reset()
        serviceController.reconcileRegisteredService()
        serviceStatusDidChange(serviceController.status)
    }

    func stop() {
        isStarted = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectBackoff.reset()
        _ = connectionGeneration.advance()
        connection?.invalidate()
        connection = nil
    }

    nonisolated func handle(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        let reply = CLIHostReply(reply)
        guard callerIsBroker() else {
            reply.call(Data())
            return
        }
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
        guard requestState.begin(request.requestID) else {
            reply.call(Self.encodedFailure(
                request: request,
                outcome: .cancelled,
                category: "cancelled",
                message: "The request was cancelled.",
                startedAt: .now
            ))
            return
        }
        Task { @MainActor in
            defer { requestState.finish(request.requestID) }
            let response: Data
            if requestState.isCancelled(request.requestID) {
                response = Self.encodedFailure(
                    request: request,
                    outcome: .cancelled,
                    category: "cancelled",
                    message: "The request was cancelled.",
                    startedAt: .now
                )
            } else {
                response = Self.response(to: request)
            }
            reply.call(response)
        }
    }

    nonisolated func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        guard callerIsBroker() else {
            reply(false)
            return
        }
        reply(requestState.cancel(requestID))
    }

    private static func response(to request: CLIRequestEnvelope) -> Data {
        let startedAt = Date()
        guard request.operation == .doctor,
              request.payload == nil,
              (CLIProtocolVersion.minimum...CLIProtocolVersion.current)
                .contains(request.protocolVersion) else {
            return encodedFailure(
                request: request,
                outcome: .protocolIncompatible,
                category: "protocolIncompatible",
                message: "The CLI protocol version or operation is not supported.",
                startedAt: startedAt
            )
        }
        let record = CLIDoctorRecord(
            hostVersion: AppMetadata.shortVersion ?? "unknown",
            hostBuild: AppMetadata.buildNumber ?? "unknown",
            protocolVersion: request.protocolVersion,
            brokerServiceStatus: CLIBrokerServiceController.shared.status.rawValue
        )
        do {
            let payload = try CLIProtocolCodec.encodeResponse(record)
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                operation: request.operation,
                startedAt: startedAt,
                finishedAt: .now,
                outcome: .completed,
                message: nil,
                rejection: nil,
                payload: payload
            ))
        } catch {
            return encodedFailure(
                request: request,
                outcome: .hostUnavailable,
                category: "responseEncodingFailed",
                message: "MacTools could not encode the doctor response.",
                startedAt: startedAt
            )
        }
    }

    private nonisolated static func encodedFailure(
        request: CLIRequestEnvelope,
        outcome: CLIOutcome,
        category: String,
        message: String,
        startedAt: Date
    ) -> Data {
        (try? CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
            request: request,
            outcome: outcome,
            category: category,
            message: message,
            startedAt: startedAt
        ))) ?? Data()
    }

    private func connect() {
        guard isStarted, serviceController.status == .enabled else { return }
        connection?.invalidate()
        let generation = connectionGeneration.advance()
        let connection = NSXPCConnection(
            machServiceName: CLIServiceConfiguration.serviceName(
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: CLIHostXPCProtocol.self)
        connection.exportedObject = self
        guard let currentIdentity = localIdentityCache.resolve(
            using: identityValidator.currentIdentity
        ), identityValidator.configure(
            connection,
            toRequire: .broker,
            currentIdentity: currentIdentity
        ) else {
            scheduleReconnect()
            return
        }
        connection.invalidationHandler = callbackRelay.makeReconnectHandler(for: generation)
        connection.interruptionHandler = callbackRelay.makeReconnectHandler(for: generation)
        connection.activate()
        self.connection = connection

        guard let broker = connection.remoteObjectProxyWithErrorHandler(
            callbackRelay.makeReconnectErrorHandler(for: generation)
        ) as? CLIBrokerXPCProtocol else {
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
            withReply: callbackRelay.makeRegistrationReplyHandler(
                for: connection,
                generation: generation
            )
        )
    }

    private func scheduleReconnect() {
        guard isStarted, reconnectTask == nil else { return }
        let delay = reconnectBackoff.nextDelay()
        _ = connectionGeneration.advance()
        connection?.invalidate()
        connection = nil
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
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
        case .enabled:
            if connection == nil { connect() }
        case .requiresApproval, .notRegistered, .notFound, .registrationFailed:
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectBackoff.reset()
            _ = connectionGeneration.advance()
            connection?.invalidate()
            connection = nil
        }
    }
}

struct CLIReconnectBackoff {
    private static let maximumExponent = 5
    private(set) var failureCount = 0

    mutating func nextDelay() -> Duration {
        let exponent = min(failureCount, Self.maximumExponent)
        failureCount += 1
        return .seconds(min(1 << exponent, 30))
    }

    mutating func reset() {
        failureCount = 0
    }
}

struct CLIConnectionGeneration {
    private(set) var current = 0

    mutating func advance() -> Int {
        current &+= 1
        return current
    }

    func isCurrent(_ candidate: Int) -> Bool {
        candidate == current
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

final class CLIHostRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = Set<UUID>()
    private var cancelled = Set<UUID>()

    func begin(_ requestID: UUID) -> Bool {
        lock.withLock {
            guard active.count < CLIProtocolVersion.maximumInFlightRequestsGlobally,
                  !active.contains(requestID) else { return false }
            active.insert(requestID)
            return true
        }
    }

    func cancel(_ requestID: UUID) -> Bool {
        lock.withLock {
            guard active.contains(requestID) else { return false }
            cancelled.insert(requestID)
            return true
        }
    }

    func isCancelled(_ requestID: UUID) -> Bool {
        lock.withLock { cancelled.contains(requestID) }
    }

    func finish(_ requestID: UUID) {
        lock.withLock {
            active.remove(requestID)
            cancelled.remove(requestID)
        }
    }
}

final class CLIHostBridgeCallbackRelay: @unchecked Sendable {
    private let reconnect: @MainActor @Sendable (Int) -> Void
    private let registered: @MainActor @Sendable (Int) -> Void
    private let connectionIsBroker: @Sendable (NSXPCConnection) -> Bool

    init(
        reconnect: @escaping @MainActor @Sendable (Int) -> Void,
        registered: @escaping @MainActor @Sendable (Int) -> Void = { _ in },
        connectionIsBroker: @escaping @Sendable (NSXPCConnection) -> Bool = {
            CLIPeerIdentityValidator().accepts($0, as: .broker)
        }
    ) {
        self.reconnect = reconnect
        self.registered = registered
        self.connectionIsBroker = connectionIsBroker
    }

    nonisolated func makeReconnectHandler(for generation: Int) -> @Sendable () -> Void {
        { [weak self] in self?.requestReconnect(generation: generation) }
    }

    nonisolated func makeReconnectErrorHandler(
        for generation: Int
    ) -> @Sendable (Error) -> Void {
        { [weak self] _ in self?.requestReconnect(generation: generation) }
    }

    nonisolated func makeRegistrationReplyHandler(
        for connection: NSXPCConnection,
        generation: Int
    ) -> @Sendable (Data) -> Void {
        let reference = CLIHostXPCConnectionReference(connection)
        return { [weak self, reference, connectionIsBroker] response in
            guard let connection = reference.connection,
                  connectionIsBroker(connection),
                  let handshake = try? CLIProtocolCodec.decodeResponse(
                    CLIHandshakeResponse.self,
                    from: response,
                    allowedKeys: [
                        "selectedProtocolVersion", "brokerVersion", "brokerBuild",
                        "hostVersion", "hostBuild", "hostReady", "message",
                    ]
                  ),
                  (try? CLIProtocolSemanticValidator.validate(handshake: handshake)) != nil
            else {
                self?.requestReconnect(generation: generation)
                return
            }
            if handshake.hostReady {
                guard handshake.selectedProtocolVersion != nil else {
                    self?.requestReconnect(generation: generation)
                    return
                }
            } else if handshake.hostVersion == nil {
                self?.requestReconnect(generation: generation)
                return
            }
            self?.requestRegistered(generation: generation)
        }
    }

    nonisolated func requestReconnect(generation: Int) {
        let reconnect = reconnect
        Task { @MainActor in reconnect(generation) }
    }

    nonisolated func requestRegistered(generation: Int) {
        let registered = registered
        Task { @MainActor in registered(generation) }
    }
}

private final class CLIHostXPCConnectionReference: @unchecked Sendable {
    weak var connection: NSXPCConnection?

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
