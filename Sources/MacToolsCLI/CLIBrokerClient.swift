import AppKit
import Foundation

enum CLIBrokerClientError: Error {
    case unavailable(String)
    case invalidResponse
    case timedOut
    case protocolIncompatible
}

final class CLIBrokerClient: @unchecked Sendable {
    private let identityValidator = CLIPeerIdentityValidator()
    private var connection: NSXPCConnection?
    private var negotiatedProtocolVersion: Int?

    deinit {
        connection?.invalidate()
    }

    func prepareHost(launchIfNeeded: Bool = true) async throws -> CLIHandshakeResponse {
        let deadline = Date().addingTimeInterval(10)
        var didLaunch = false
        var lastMessage = "The MacTools broker is unavailable."
        repeat {
            do {
                let response = try await connectAndHandshake(timeout: 1.5)
                guard let selectedVersion = response.selectedProtocolVersion else {
                    throw CLIBrokerClientError.protocolIncompatible
                }
                negotiatedProtocolVersion = selectedVersion
                if response.hostReady { return response }
                lastMessage = response.message ?? "MacTools is starting."
            } catch CLIBrokerClientError.protocolIncompatible {
                throw CLIBrokerClientError.protocolIncompatible
            } catch {
                lastMessage = "The MacTools broker is unavailable."
            }
            if launchIfNeeded, !didLaunch {
                try launchHost()
                didLaunch = true
            }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        throw CLIBrokerClientError.unavailable(lastMessage)
    }

    func handshakeWithoutLaunching() async throws -> CLIHandshakeResponse {
        try await connectAndHandshake(timeout: 1)
    }

    func send(
        operation: CLIOperation,
        payload: Data?,
        requestID: UUID = UUID()
    ) async throws -> CLIResponseEnvelope {
        if connection == nil || negotiatedProtocolVersion == nil {
            _ = try await prepareHost()
        }
        let request = CLIRequestEnvelope(
            protocolVersion: negotiatedProtocolVersion ?? CLIProtocolVersion.current,
            requestID: requestID,
            operation: operation,
            sentAt: .now,
            payload: payload
        )
        let data = try CLIProtocolCodec.encodeRequest(request)
        let responseData: Data = try await awaitReply(timeout: 86_460) { completion in
            guard let broker = brokerProxy(errorHandler: { _ in
                completion(.failure(CLIBrokerClientError.unavailable(
                    "The broker or host connection was interrupted."
                )))
            }) else {
                completion(.failure(CLIBrokerClientError.unavailable(
                    "The broker interface is unavailable."
                )))
                return
            }
            broker.send(data) { completion(.success($0)) }
        }
        guard !responseData.isEmpty else { throw CLIBrokerClientError.invalidResponse }
        let response = try CLIProtocolCodec.decodeResponse(
            CLIResponseEnvelope.self,
            from: responseData,
            allowedKeys: [
                "schemaVersion", "protocolVersion", "requestID", "operation",
                "actionReference", "startedAt", "finishedAt", "outcome", "message",
                "rejection", "payload",
            ]
        )
        guard response.schemaVersion == 1,
              response.protocolVersion == request.protocolVersion,
              response.requestID == request.requestID,
              response.operation == request.operation else {
            throw CLIBrokerClientError.invalidResponse
        }
        return response
    }

    func cancel(requestID: UUID) async -> Bool {
        return (try? await awaitReply(timeout: 2) { completion in
            guard let broker = brokerProxy(errorHandler: { _ in
                completion(.failure(CLIBrokerClientError.unavailable(
                    "The broker connection was interrupted."
                )))
            }) else {
                completion(.success(false))
                return
            }
            broker.cancel(requestID) { completion(.success($0)) }
        }) ?? false
    }

    private func connectAndHandshake(timeout: TimeInterval) async throws -> CLIHandshakeResponse {
        connection?.invalidate()
        negotiatedProtocolVersion = nil
        let connection = NSXPCConnection(machServiceName: CLIServiceConfiguration.runtimeServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        guard identityValidator.configure(connection, toRequire: .broker) else {
            throw CLIBrokerClientError.unavailable("The broker identity could not be verified.")
        }
        connection.activate()
        self.connection = connection
        let hello = CLIHandshakeRequest(
            minimumProtocolVersion: CLIProtocolVersion.minimum,
            maximumProtocolVersion: CLIProtocolVersion.current,
            clientVersion: containingAppVersion().version,
            clientBuild: containingAppVersion().build
        )
        let request = try CLIProtocolCodec.encodeRequest(hello)
        let responseData: Data = try await awaitReply(timeout: timeout) { completion in
            guard let broker = brokerProxy(errorHandler: { _ in
                completion(.failure(CLIBrokerClientError.unavailable(
                    "The broker connection was interrupted."
                )))
            }) else {
                completion(.failure(CLIBrokerClientError.unavailable(
                    "The broker interface is unavailable."
                )))
                return
            }
            broker.handshake(request) { completion(.success($0)) }
        }
        guard identityValidator.accepts(connection, as: .broker) else {
            throw CLIBrokerClientError.unavailable("The broker identity could not be verified.")
        }
        guard !responseData.isEmpty else { throw CLIBrokerClientError.invalidResponse }
        let response = try CLIProtocolCodec.decodeResponse(
            CLIHandshakeResponse.self,
            from: responseData,
            allowedKeys: [
                "selectedProtocolVersion", "brokerVersion", "brokerBuild", "hostVersion",
                "hostBuild", "hostReady", "message",
            ]
        )
        negotiatedProtocolVersion = response.selectedProtocolVersion
        return response
    }

    private func brokerProxy(
        errorHandler: ((Error) -> Void)?
    ) -> CLIBrokerXPCProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            errorHandler?(error)
        } as? CLIBrokerXPCProtocol
    }

    private func awaitReply<T: Sendable>(
        timeout: TimeInterval,
        start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let (stream, continuation) = AsyncStream.makeStream(of: Result<T, Error>.self)
        start { result in
            continuation.yield(result)
            continuation.finish()
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            continuation.yield(.failure(CLIBrokerClientError.timedOut))
            continuation.finish()
        }
        for await result in stream {
            timeoutTask.cancel()
            return try result.get()
        }
        throw CLIBrokerClientError.invalidResponse
    }

    private func launchHost() throws {
        let applicationURL: URL
        if let containing = CLIServiceConfiguration.containingApplicationURL() {
            applicationURL = containing
        } else {
            let identifier = hostBundleIdentifier()
            guard let installed = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier
            ) else {
                throw CLIBrokerClientError.unavailable("MacTools is not installed.")
            }
            applicationURL = installed
        }
        guard identityValidator.acceptsApplication(at: applicationURL, as: .host) else {
            throw CLIBrokerClientError.unavailable(
                "The MacTools application signature does not match this CLI."
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { _, error in
            _ = error
        }
    }

    func containingAppVersion() -> (version: String, build: String) {
        let bundle = CLIServiceConfiguration.containingApplicationBundle()
        return (
            bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
    }

    private func hostBundleIdentifier() -> String {
        let identifier = Bundle.main.bundleIdentifier ?? "app.ggbond.MacTools"
        return identifier.hasSuffix(".cli")
            ? String(identifier.dropLast(".cli".count))
            : identifier
    }
}
