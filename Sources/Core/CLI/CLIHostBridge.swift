import Combine
import Foundation
import MacToolsCLIProtocol

@MainActor
final class CLIHostBridge: NSObject, CLIHostXPCProtocol {
    private let serviceController: CLIBrokerServiceController
    private let discovery: CLIActionDiscovery?
    private let runner: CLIActionRunner?
    private let readinessTimeout: Duration
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
        discovery: CLIActionDiscovery? = nil,
        runner: CLIActionRunner? = nil,
        readinessTimeout: Duration = .seconds(8),
        callerIsBroker: @escaping @Sendable () -> Bool = {
            guard let connection = NSXPCConnection.current() else { return false }
            return CLIPeerIdentityValidator().accepts(connection, as: .broker)
        }
    ) {
        self.serviceController = serviceController
        self.discovery = discovery
        self.runner = runner
        self.readinessTimeout = readinessTimeout
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
        let task = Task { @MainActor in
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
                response = await self.response(to: request)
            }
            reply.call(response)
        }
        requestState.installCancellationHandler(request.requestID) { task.cancel() }
    }

    nonisolated func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        guard callerIsBroker() else {
            reply(false)
            return
        }
        reply(requestState.cancel(requestID))
    }

    private func response(to request: CLIRequestEnvelope) async -> Data {
        let startedAt = Date()
        guard request.protocolVersion >= request.operation.minimumProtocolVersion,
              (CLIProtocolVersion.minimum...CLIProtocolVersion.current)
                .contains(request.protocolVersion) else {
            return Self.encodedFailure(
                request: request,
                outcome: .protocolIncompatible,
                category: "protocolIncompatible",
                message: "The CLI protocol version or operation is not supported.",
                startedAt: startedAt
            )
        }
        do {
            let payload: Data
            if request.operation == .doctor {
                guard request.payload == nil else { throw CLIProtocolCodecError.invalidObject }
                payload = try CLIProtocolCodec.encodeResponse(CLIDoctorRecord(
                    hostVersion: AppMetadata.shortVersion ?? "unknown",
                    hostBuild: AppMetadata.buildNumber ?? "unknown",
                    protocolVersion: request.protocolVersion,
                    brokerServiceStatus: serviceController.status.rawValue
                ))
            } else {
                guard let data = request.payload else { throw CLIProtocolCodecError.invalidObject }
                // Validate before waiting; malformed requests must not consume the readiness budget.
                let runRequest: CLIActionRunRequest?
                if request.operation == .actionsList {
                    try CLIDiscoveryValidation.validate(CLIDiscoveryValidation.decode(CLIActionListRequest.self, from: data))
                    runRequest = nil
                } else if request.operation == .actionsRun {
                    let decoded = try CLIExecutionValidation.decode(CLIActionRunRequest.self, from: data)
                    try CLIExecutionValidation.validate(decoded)
                    runRequest = decoded
                } else {
                    try CLIDiscoveryValidation.validate(CLIDiscoveryValidation.decode(CLIActionTargetRequest.self, from: data))
                    runRequest = nil
                }
                guard let discovery else { throw CLIActionDiscoveryError.notReady }
                let executionDeadline = runRequest.map {
                    ContinuousClock.now.advanced(by: .seconds($0.timeoutSeconds))
                }
                let ordinaryReadinessDeadline = ContinuousClock.now.advanced(by: readinessTimeout)
                let readinessDeadline = executionDeadline.map {
                    min(ordinaryReadinessDeadline, $0)
                } ?? ordinaryReadinessDeadline
                while !discovery.isReady && ContinuousClock.now < readinessDeadline {
                    guard !requestState.isCancelled(request.requestID) else { throw CancellationError() }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !requestState.isCancelled(request.requestID) else { throw CancellationError() }
                if !discovery.isReady,
                   let executionDeadline,
                   ContinuousClock.now >= executionDeadline {
                    throw CLIActionRunError.timedOut
                }
                switch request.operation {
                case .actionsList:
                    payload = try CLIProtocolCodec.encodeResponse(discovery.list(
                        CLIDiscoveryValidation.decode(CLIActionListRequest.self, from: data)))
                case .actionsDescribe:
                    let description = try discovery.describe(
                        CLIDiscoveryValidation.decode(CLIActionTargetRequest.self, from: data))
                    if request.protocolVersion >= 3 {
                        payload = try CLIProtocolCodec.encodeResponse(description)
                    } else {
                        payload = try CLIProtocolCodec.encodeResponse(CLIActionDescription(
                            id: description.id,
                            title: description.title,
                            description: description.description,
                            parameterSchemaVersion: description.parameterSchemaVersion,
                            parameters: description.parameters,
                            executionSupported: false
                        ))
                    }
                case .actionsAvailability:
                    payload = try CLIProtocolCodec.encodeResponse(discovery.availability(
                        CLIDiscoveryValidation.decode(CLIActionTargetRequest.self, from: data)))
                case .actionsRun:
                    guard let runner, let runRequest, let executionDeadline else {
                        throw CLIActionDiscoveryError.notReady
                    }
                    payload = try CLIProtocolCodec.encodeResponse(try await runner.run(
                        runRequest,
                        deadline: executionDeadline
                    ))
                case .doctor:
                    throw CLIProtocolCodecError.invalidObject
                }
            }
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
            let failure: (CLIOutcome, String, String)
            switch error {
            case is CancellationError:
                failure = (.cancelled, "cancelled", "The request was cancelled.")
            case CLIActionDiscoveryError.notReady:
                failure = (.hostUnavailable, "registryNotReady", "The action registry is not ready. Try again after MacTools finishes starting.")
            case CLIActionDiscoveryError.unknownTarget:
                failure = (.unknownTarget, "unknownAction", "The requested action is not discoverable.")
            case CLIActionDiscoveryError.executionUnsupported:
                failure = (.invalidInput, "executionUnsupported", "The requested action is not parameterless and executable from the CLI.")
            case CLIActionDiscoveryError.unavailable, CLIActionRunError.unavailable:
                failure = (.unavailable, "actionUnavailable", "The requested action is currently unavailable.")
            case CLIActionRunError.busy:
                failure = (.unavailable, "actionBusy", "The requested action is already running.")
            case CLIActionRunError.timedOut:
                failure = (.timedOut, "executionTimedOut", "The action exceeded the requested timeout and was cancelled.")
            case CLIActionRunError.failed:
                failure = (.actionFailed, "actionFailed", "The action failed.")
            case CLIActionRunError.eligibilityChanged:
                failure = (.invalidInput, "eligibilityChanged", "The action is no longer eligible for CLI execution.")
            case CLIActionDiscoveryError.staleCursor:
                failure = (.invalidInput, "staleCursor", "The catalog changed. Restart actions list without a cursor.")
            case CLIActionDiscoveryError.catalogTooLarge, CLIProtocolCodecError.responseTooLarge:
                failure = (.hostUnavailable, "catalogLimitExceeded", "The action catalog exceeds the discovery limits.")
            default:
                failure = (.invalidInput, "invalidRequest", "The discovery request is invalid.")
            }
            return Self.encodedFailure(request: request, outcome: failure.0, category: failure.1,
                                       message: failure.2, startedAt: startedAt)
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
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    func begin(_ requestID: UUID) -> Bool {
        lock.withLock {
            guard active.count < CLIProtocolVersion.maximumInFlightRequestsGlobally,
                  !active.contains(requestID) else { return false }
            active.insert(requestID)
            return true
        }
    }

    func cancel(_ requestID: UUID) -> Bool {
        var handler: (@Sendable () -> Void)?
        let accepted = lock.withLock {
            guard active.contains(requestID) else { return false }
            if cancelled.insert(requestID).inserted {
                handler = cancellationHandlers[requestID]
            }
            return true
        }
        guard accepted else { return false }
        handler?()
        return true
    }

    func installCancellationHandler(
        _ requestID: UUID,
        handler: @escaping @Sendable () -> Void
    ) {
        let invoke = lock.withLock {
            guard active.contains(requestID) else { return false }
            cancellationHandlers[requestID] = handler
            return cancelled.contains(requestID)
        }
        if invoke { handler() }
    }

    func isCancelled(_ requestID: UUID) -> Bool {
        lock.withLock { cancelled.contains(requestID) }
    }

    func finish(_ requestID: UUID) {
        lock.withLock {
            active.remove(requestID)
            cancelled.remove(requestID)
            cancellationHandlers.removeValue(forKey: requestID)
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
