import AppKit
import Foundation
import MacToolsCLIProtocol

final class CLIBroker: NSObject, CLIBrokerXPCProtocol, NSXPCListenerDelegate {
    private let identityValidator = CLIPeerIdentityValidator()
    private let hostLauncher: CLIBrokerHostLauncher
    private let lock = NSLock()
    private var hostConnection: NSXPCConnection?
    private var hostRegistration: CLIHostRegistration?
    private var requestAdmissionState = CLIRequestAdmissionState()

    init(hostLauncher: CLIBrokerHostLauncher = CLIBrokerHostLauncher()) {
        self.hostLauncher = hostLauncher
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.effectiveUserIdentifier == geteuid() else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.remoteObjectInterface = NSXPCInterface(with: CLIHostXPCProtocol.self)
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
                    "minimumProtocolVersion", "maximumProtocolVersion",
                    "clientVersion", "clientBuild", "launchHostIfNeeded",
                ]
            )
        } catch {
            reply(encodedHandshake(message: "Invalid handshake."))
            return
        }
        guard hello.minimumProtocolVersion <= hello.maximumProtocolVersion,
              !hello.clientVersion.isEmpty,
              !hello.clientBuild.isEmpty else {
            reply(encodedHandshake(message: "Invalid handshake."))
            return
        }
        let state = lock.withLock { (hostConnection != nil, hostRegistration) }
        let selected = CLIProtocolNegotiator.selectedVersion(
            clientMinimum: hello.minimumProtocolVersion,
            clientMaximum: hello.maximumProtocolVersion,
            hostMinimum: state.1?.minimumProtocolVersion,
            hostMaximum: state.1?.maximumProtocolVersion
        )
        let hostReady = state.0 && state.1 != nil && selected != nil
        if state.1 == nil, hello.launchHostIfNeeded {
            hostLauncher.launchIfNeeded()
        }
        reply(encodedHandshake(
            selectedVersion: selected,
            hostReady: hostReady,
            hostRegistration: state.1,
            message: hostReady
                ? nil
                : state.1 != nil && selected == nil
                    ? "No compatible protocol version."
                    : hostLauncher.statusMessage(default: "MacTools is starting.")
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
                    "minimumProtocolVersion", "maximumProtocolVersion",
                    "hostVersion", "hostBuild",
                ]
            )
        } catch {
            reply(encodedHandshake(message: "Invalid host registration."))
            return
        }
        guard decoded.minimumProtocolVersion <= decoded.maximumProtocolVersion,
              !decoded.hostVersion.isEmpty,
              !decoded.hostBuild.isEmpty else {
            reply(encodedHandshake(message: "Invalid host registration."))
            return
        }
        let selected = CLIProtocolNegotiator.selectedVersion(
            clientMinimum: CLIProtocolVersion.minimum,
            clientMaximum: CLIProtocolVersion.current,
            hostMinimum: decoded.minimumProtocolVersion,
            hostMaximum: decoded.maximumProtocolVersion
        )
        lock.withLock {
            hostConnection = connection
            hostRegistration = decoded
        }
        hostLauncher.hostBecameReady()
        reply(encodedHandshake(
            selectedVersion: selected,
            hostReady: selected != nil,
            hostRegistration: decoded,
            message: selected == nil ? "No compatible host protocol version." : nil
        ))
    }

    func send(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let connection = NSXPCConnection.current(),
              identityValidator.accepts(connection, as: .commandLineTool) else {
            reply(encodedTransportFailure(request, message: "Client authentication failed."))
            return
        }
        let envelope: CLIRequestEnvelope
        do {
            envelope = try CLIProtocolCodec.decodeRequest(
                CLIRequestEnvelope.self,
                from: request,
                allowedKeys: ["protocolVersion", "requestID", "operation", "sentAt", "payload"]
            )
        } catch {
            reply(Data())
            return
        }
        let clientID = ObjectIdentifier(connection)
        guard admit(requestID: envelope.requestID, clientID: clientID) else {
            reply(encodedTransportFailure(request, message: "The broker request limit has been reached."))
            return
        }
        let finish = CLIBrokerReplyOnce<Data> { [weak self] response in
            self?.finish(requestID: envelope.requestID, clientID: clientID)
            reply(response)
        }
        let state = lock.withLock { (hostConnection, hostRegistration) }
        guard let hostConnection = state.0, let registration = state.1 else {
            hostLauncher.launchIfNeeded()
            finish.call(encodedTransportFailure(request, message: "MacTools host is not ready."))
            return
        }
        guard (registration.minimumProtocolVersion...registration.maximumProtocolVersion)
            .contains(envelope.protocolVersion),
              (CLIProtocolVersion.minimum...CLIProtocolVersion.current)
                .contains(envelope.protocolVersion) else {
            finish.call(encodedProtocolIncompatibility(request))
            return
        }
        guard let host = hostConnection.remoteObjectProxyWithErrorHandler({ _ in
            finish.call(self.encodedTransportFailure(request, message: "Host transport failed."))
        }) as? CLIHostXPCProtocol else {
            finish.call(encodedTransportFailure(request, message: "Host interface is unavailable."))
            return
        }
        host.handle(request) { response in
            guard response.count <= CLIProtocolVersion.maximumResponseBytes else {
                finish.call(self.encodedTransportFailure(request, message: "Host response is too large."))
                return
            }
            finish.call(response)
        }
    }

    func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current(),
              identityValidator.accepts(connection, as: .commandLineTool) else {
            reply(false)
            return
        }
        let clientID = ObjectIdentifier(connection)
        guard lock.withLock({ requestAdmissionState.contains(
            requestID: requestID,
            clientID: clientID
        ) }),
              let hostConnection = lock.withLock({ self.hostConnection }),
              let host = hostConnection.remoteObjectProxy as? CLIHostXPCProtocol else {
            reply(false)
            return
        }
        host.cancel(requestID, withReply: reply)
    }

    private func admit(requestID: UUID, clientID: ObjectIdentifier) -> Bool {
        lock.withLock {
            requestAdmissionState.admit(requestID: requestID, clientID: clientID)
        }
    }

    private func finish(requestID: UUID, clientID: ObjectIdentifier) {
        lock.withLock {
            requestAdmissionState.finish(requestID: requestID, clientID: clientID)
        }
    }

    private func connectionInvalidated(_ connection: NSXPCConnection) {
        let requestIDs = lock.withLock { () -> [UUID] in
            let clientID = ObjectIdentifier(connection)
            let requests = requestAdmissionState.removeAll(clientID: clientID)
            if hostConnection === connection {
                hostConnection = nil
                hostRegistration = nil
            }
            return requests
        }
        guard !requestIDs.isEmpty,
              let host = lock.withLock({ hostConnection })?.remoteObjectProxy
                as? CLIHostXPCProtocol else { return }
        requestIDs.forEach { host.cancel($0) { _ in } }
    }

    private func encodedHandshake(
        selectedVersion: Int? = nil,
        hostReady: Bool = false,
        hostRegistration: CLIHostRegistration? = nil,
        message: String?
    ) -> Data {
        let info = CLIServiceConfiguration.executableInfoDictionary()
        return (try? CLIProtocolCodec.encodeResponse(CLIHandshakeResponse(
            selectedProtocolVersion: selectedVersion,
            brokerVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            brokerBuild: info["CFBundleVersion"] as? String ?? "unknown",
            hostVersion: hostRegistration?.hostVersion,
            hostBuild: hostRegistration?.hostBuild,
            hostReady: hostReady,
            message: message
        ))) ?? Data()
    }

    private func encodedProtocolIncompatibility(_ requestData: Data) -> Data {
        encodedFailure(
            requestData,
            outcome: .protocolIncompatible,
            category: "protocolIncompatible",
            message: "The registered host does not support this protocol version."
        )
    }

    private func encodedTransportFailure(_ requestData: Data, message: String) -> Data {
        encodedFailure(
            requestData,
            outcome: .hostUnavailable,
            category: "hostTransportFailure",
            message: message
        )
    }

    private func encodedFailure(
        _ requestData: Data,
        outcome: CLIOutcome,
        category: String,
        message: String
    ) -> Data {
        guard let request = try? CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: requestData,
            allowedKeys: ["protocolVersion", "requestID", "operation", "sentAt", "payload"]
        ) else { return Data() }
        return (try? CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
            request: request,
            outcome: outcome,
            category: category,
            message: message
        ))) ?? Data()
    }
}

final class CLIBrokerHostLauncher: @unchecked Sendable {
    private let lock = NSLock()
    private var isLaunching = false
    private var lastAttempt = Date.distantPast
    private var lastMessage: String?

    func launchIfNeeded() {
        let shouldLaunch = lock.withLock { () -> Bool in
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            guard timeSinceLastAttempt >= 1,
                  !isLaunching || timeSinceLastAttempt >= 10 else { return false }
            isLaunching = true
            lastAttempt = .now
            lastMessage = nil
            return true
        }
        guard shouldLaunch else { return }
        guard let applicationURL = CLIServiceConfiguration.containingApplicationURL(),
              CLIPeerIdentityValidator().acceptsApplication(at: applicationURL, as: .host) else {
            finishAttempt(message: "The broker could not verify its containing MacTools app.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) {
            [weak self] application, error in
            if let error {
                self?.finishAttempt(message: "MacTools launch failed: \(error.localizedDescription)")
            } else if application == nil {
                self?.finishAttempt(message: "Launch Services did not return MacTools.")
            }
        }
    }

    func hostBecameReady() {
        lock.withLock {
            isLaunching = false
            lastMessage = nil
        }
    }

    func statusMessage(default defaultMessage: String) -> String {
        lock.withLock { lastMessage ?? defaultMessage }
    }

    private func finishAttempt(message: String) {
        lock.withLock {
            isLaunching = false
            lastMessage = message
        }
    }
}

private final class CLIBrokerReplyOnce<Value>: @unchecked Sendable {
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
