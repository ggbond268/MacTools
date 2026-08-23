import Foundation

final class CLIBroker: NSObject, CLIBrokerXPCProtocol, NSXPCListenerDelegate {
    private let identityValidator = CLIPeerIdentityValidator()
    private let lock = NSLock()
    private var hostConnection: NSXPCConnection?
    private var hostRegistration: CLIHostRegistration?
    private var clientConnections: Set<ObjectIdentifier> = []
    private var admissionState = CLIRequestAdmissionState<ObjectIdentifier>()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier == geteuid() else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: CLIHostXPCProtocol.self)
        let identity = ObjectIdentifier(newConnection)
        _ = lock.withLock {
            clientConnections.insert(identity)
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.connectionInvalidated(newConnection)
        }
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.connectionInvalidated(newConnection)
        }
        newConnection.activate()
        return true
    }

    func handshake(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current(),
              identityValidator.accepts(connection, as: .commandLineTool) else {
            reply(encodedHandshake(message: "Client authentication failed."))
            return
        }
        let hello: CLIHandshakeRequest
        do {
            hello = try CLIProtocolCodec.decodeRequest(
                CLIHandshakeRequest.self,
                from: request,
                allowedKeys: [
                    "minimumProtocolVersion",
                    "maximumProtocolVersion",
                    "clientVersion",
                    "clientBuild",
                ]
            )
        } catch {
            reply(encodedHandshake(message: "Invalid handshake."))
            return
        }
        let selected = selectedVersion(
            clientMinimum: hello.minimumProtocolVersion,
            clientMaximum: hello.maximumProtocolVersion,
            hostRegistration: lock.withLock { hostRegistration }
        )
        let state = lock.withLock { (hostConnection != nil, hostRegistration) }
        reply(encodedHandshake(
            selectedVersion: selected,
            hostReady: state.0,
            hostRegistration: state.1,
            message: selected == nil ? "No compatible protocol version." : nil
        ))
    }

    func registerHost(_ registration: Data, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current(),
              identityValidator.accepts(connection, as: .host) else {
            reply(encodedHandshake(message: "Host authentication failed."))
            return
        }
        let decoded: CLIHostRegistration
        do {
            decoded = try CLIProtocolCodec.decodeRequest(
                CLIHostRegistration.self,
                from: registration,
                allowedKeys: [
                    "minimumProtocolVersion",
                    "maximumProtocolVersion",
                    "hostVersion",
                    "hostBuild",
                ]
            )
        } catch {
            reply(encodedHandshake(message: "Invalid host registration."))
            return
        }
        let selected = selectedVersion(
            clientMinimum: decoded.minimumProtocolVersion,
            clientMaximum: decoded.maximumProtocolVersion,
            hostRegistration: decoded
        )
        guard selected != nil else {
            reply(encodedHandshake(message: "No compatible host protocol version."))
            return
        }
        lock.withLock {
            hostConnection = connection
            hostRegistration = decoded
        }
        reply(encodedHandshake(
            selectedVersion: selected,
            hostReady: true,
            hostRegistration: decoded,
            message: nil
        ))
    }

    func send(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current(),
              identityValidator.accepts(connection, as: .commandLineTool) else {
            reply(encodedTransportFailure(request, message: "Client authentication failed."))
            return
        }
        guard request.count <= CLIProtocolVersion.maximumRequestBytes else {
            reply(encodedTransportFailure(request, message: "Request is too large."))
            return
        }
        guard let envelope = try? CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: request,
            allowedKeys: [
                "protocolVersion", "requestID", "operation", "sentAt",
                "invocationContext", "payload",
            ]
        ) else {
            reply(Data())
            return
        }
        let clientID = ObjectIdentifier(connection)
        let admissionRejection = lock.withLock {
            admissionState.admit(
                requestID: envelope.requestID,
                clientID: clientID,
                invocationContext: envelope.invocationContext
            )
        }
        if let admissionRejection {
            reply(encodedAdmissionRejection(envelope, rejection: admissionRejection))
            return
        }
        guard let invocationContext = lock.withLock({
            admissionState.invocationContext(
                requestID: envelope.requestID,
                clientID: clientID
            )
        }), let forwardedRequest = try? CLIProtocolCodec.encodeRequest(
            envelope.replacingInvocationContext(invocationContext)
        ) else {
            lock.withLock {
                admissionState.finish(requestID: envelope.requestID, clientID: clientID)
            }
            reply(encodedTransportFailure(request, message: "The request context is unavailable."))
            return
        }
        let finish = BrokerReplyOnce<Data> { [weak self] response in
            if let self {
                self.lock.withLock {
                    self.admissionState.finish(
                        requestID: envelope.requestID,
                        clientID: clientID
                    )
                }
            }
            reply(response)
        }
        guard let hostConnection = lock.withLock({ self.hostConnection }) else {
            finish.call(encodedTransportFailure(request, message: "MacTools host is not ready."))
            return
        }
        guard let hostRegistration = lock.withLock({ self.hostRegistration }),
              requestVersionIsSupported(envelope.protocolVersion, by: hostRegistration) else {
            finish.call(encodedProtocolIncompatibility(request))
            return
        }
        let proxy = hostConnection.remoteObjectProxyWithErrorHandler { _ in
            finish.call(self.encodedTransportFailure(request, message: "Host transport failed."))
        }
        guard let host = proxy as? CLIHostXPCProtocol else {
            finish.call(encodedTransportFailure(request, message: "Host interface is unavailable."))
            return
        }
        let didBeginForwarding = lock.withLock {
            admissionState.beginForwarding(
                requestID: envelope.requestID,
                clientID: clientID
            )
        }
        if didBeginForwarding {
            // Never invoke an XPC proxy while holding the broker state lock. If cancel
            // overtakes this send, the host's bounded pre-registration relay records it
            // and consumes the request before creating its execution task.
            host.handle(forwardedRequest) { response in
                guard response.count <= CLIProtocolVersion.maximumResponseBytes else {
                    finish.call(self.encodedTransportFailure(
                        request,
                        message: "Host response is too large."
                    ))
                    return
                }
                finish.call(response)
            }
        } else {
            finish.call(encodedAdmissionRejection(
                envelope,
                rejection: .cancelledBeforeAdmission
            ))
        }
    }

    func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current(),
              identityValidator.accepts(connection, as: .commandLineTool) else {
            reply(false)
            return
        }
        let cancellation = lock.withLock {
            admissionState.cancel(
                requestID: requestID,
                clientID: ObjectIdentifier(connection)
            )
        }
        guard let cancellation else {
            reply(false)
            return
        }
        guard cancellation == .forwardToHost else {
            reply(true)
            return
        }
        guard let hostConnection = lock.withLock({ self.hostConnection }) else {
            reply(false)
            return
        }
        let proxy = hostConnection.remoteObjectProxyWithErrorHandler { _ in reply(false) }
        guard let host = proxy as? CLIHostXPCProtocol else {
            reply(false)
            return
        }
        host.cancel(requestID, withReply: reply)
    }

    private func connectionInvalidated(_ connection: NSXPCConnection) {
        let cancelledRequestIDs = lock.withLock { () -> [UUID] in
            clientConnections.remove(ObjectIdentifier(connection))
            let requestIDs = admissionState.removeRequests(
                clientID: ObjectIdentifier(connection)
            )
            if hostConnection === connection {
                hostConnection = nil
                hostRegistration = nil
            }
            return requestIDs
        }
        guard !cancelledRequestIDs.isEmpty,
              let hostConnection = lock.withLock({ self.hostConnection }),
              let host = hostConnection.remoteObjectProxy as? CLIHostXPCProtocol else { return }
        cancelledRequestIDs.forEach { host.cancel($0) { _ in } }
    }

    private func selectedVersion(
        clientMinimum: Int,
        clientMaximum: Int,
        hostRegistration: CLIHostRegistration?
    ) -> Int? {
        CLIProtocolNegotiator.selectedVersion(
            clientMinimum: clientMinimum,
            clientMaximum: clientMaximum,
            hostMinimum: hostRegistration?.minimumProtocolVersion,
            hostMaximum: hostRegistration?.maximumProtocolVersion
        )
    }

    private func requestVersionIsSupported(
        _ version: Int,
        by registration: CLIHostRegistration
    ) -> Bool {
        (CLIProtocolVersion.minimum...CLIProtocolVersion.current).contains(version)
            && (registration.minimumProtocolVersion...registration.maximumProtocolVersion).contains(version)
    }

    private func encodedProtocolIncompatibility(_ requestData: Data) -> Data {
        guard let request = try? CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: requestData,
            allowedKeys: [
                "protocolVersion", "requestID", "operation", "sentAt",
                "invocationContext", "payload",
            ]
        ) else { return Data() }
        return (try? CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
            request: request,
            outcome: .protocolIncompatible,
            category: "protocolIncompatible",
            message: "The registered host does not support this protocol version."
        ))) ?? Data()
    }

    private func encodedHandshake(
        selectedVersion: Int? = nil,
        hostReady: Bool = false,
        hostRegistration: CLIHostRegistration? = nil,
        message: String?
    ) -> Data {
        let info = CLIServiceConfiguration.executableInfoDictionary()
        let response = CLIHandshakeResponse(
            selectedProtocolVersion: selectedVersion,
            brokerVersion: info["CFBundleShortVersionString"] as? String
                ?? hostRegistration?.hostVersion
                ?? "unknown",
            brokerBuild: info["CFBundleVersion"] as? String
                ?? hostRegistration?.hostBuild
                ?? "unknown",
            hostVersion: hostRegistration?.hostVersion,
            hostBuild: hostRegistration?.hostBuild,
            hostReady: hostReady,
            message: message
        )
        return (try? CLIProtocolCodec.encodeResponse(response)) ?? Data()
    }

    private func encodedTransportFailure(_ requestData: Data, message: String) -> Data {
        guard let request = try? CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: requestData,
            allowedKeys: [
                "protocolVersion", "requestID", "operation", "sentAt",
                "invocationContext", "payload",
            ]
        ) else { return Data() }
        return (try? CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
            request: request,
            outcome: .hostUnavailable,
            category: "hostTransportFailure",
            message: message
        ))) ?? Data()
    }

    private func encodedAdmissionRejection(
        _ request: CLIRequestEnvelope,
        rejection: CLIRequestAdmissionState<ObjectIdentifier>.Rejection
    ) -> Data {
        let outcome: CLIOutcome
        let category: String
        let message: String
        switch rejection {
        case .duplicateRequestID:
            outcome = .hostUnavailable
            category = "duplicateRequestID"
            message = "The request identifier is already active."
        case .globalCapacity:
            outcome = .hostUnavailable
            category = "globalCapacity"
            message = "The broker request limit has been reached."
        case .clientCapacity:
            outcome = .hostUnavailable
            category = "clientCapacity"
            message = "The client request limit has been reached."
        case .recursiveInvocation:
            outcome = .invalidInput
            category = "recursiveInvocation"
            message = "Recursive CLI invocation is not allowed."
        case .invalidInvocationContext:
            outcome = .invalidInput
            category = "invalidInvocationContext"
            message = "The CLI invocation context is invalid."
        case .cancelledBeforeAdmission:
            outcome = .cancelled
            category = "cancelled"
            message = "The request was cancelled."
        }
        return (try? CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
            request: request,
            outcome: outcome,
            category: category,
            message: message
        ))) ?? Data()
    }
}

private final class BrokerReplyOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Value) -> Void)?

    init(_ reply: @escaping (Value) -> Void) {
        self.reply = reply
    }

    func call(_ value: Value) {
        let reply = lock.withLock { () -> ((Value) -> Void)? in
            defer { self.reply = nil }
            return self.reply
        }
        reply?(value)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
