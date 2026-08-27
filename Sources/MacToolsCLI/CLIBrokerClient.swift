import Foundation
import MacToolsCLIProtocol

enum CLIBrokerClientError: Error {
    case unavailable(String)
    case timedOut
    case protocolIncompatible
    case invalidPeerResponse
}

final class CLIBrokerClient: @unchecked Sendable {
    private let identityValidator = CLIPeerIdentityValidator()
    private let requestCleanupPolicy = CLIRequestCleanupPolicy(budget: .milliseconds(250))
    private let connectionLifecyclePolicy = CLIConnectionLifecyclePolicy()
    private var connection: NSXPCConnection?
    private var negotiatedProtocolVersion: Int?

    deinit {
        connection?.invalidate()
    }

    func prepareHost(deadline: CLIStartupDeadline) async throws -> CLIHandshakeResponse {
        try await connectionLifecyclePolicy.preserveConnectionOnSuccess(
            operation: { [self] in
                try await prepareHostConnection(deadline: deadline)
            },
            invalidate: { [self] in invalidateConnection() }
        )
    }

    private func prepareHostConnection(
        deadline: CLIStartupDeadline
    ) async throws -> CLIHandshakeResponse {
        var lastMessage = "The MacTools command-line broker is unavailable."
        while let handshakeDeadline = deadline.cappedInstant(upTo: .seconds(1)) {
            do {
                let response = try await connectAndHandshake(
                    deadline: handshakeDeadline,
                    launchHostIfNeeded: true
                )
                guard let selected = response.selectedProtocolVersion else {
                    throw CLIBrokerClientError.protocolIncompatible
                }
                try validate(handshake: response)
                if response.hostReady {
                    negotiatedProtocolVersion = selected
                    return response
                }
                lastMessage = response.message ?? "MacTools is starting."
            } catch CLIBrokerClientError.protocolIncompatible {
                throw CLIBrokerClientError.protocolIncompatible
            } catch CLIBrokerClientError.invalidPeerResponse {
                throw CLIBrokerClientError.invalidPeerResponse
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastMessage = "The MacTools command-line broker is unavailable."
            }
            guard let retryDeadline = deadline.cappedInstant(upTo: .milliseconds(200)) else {
                break
            }
            try await ContinuousClock().sleep(until: retryDeadline)
        }
        throw CLIBrokerClientError.unavailable(
            "\(lastMessage) Enable Command Line in MacTools Settings and allow its background item."
        )
    }

    func handshakeWithoutHostLaunch() async throws -> CLIHandshakeResponse {
        let deadline = CLIStartupDeadline(timeout: .seconds(1))
        return try await connectAndHandshake(
            deadline: deadline.instant,
            launchHostIfNeeded: false
        )
    }

    func sendDoctor(
        requestID: UUID = UUID(),
        deadline: CLIStartupDeadline
    ) async throws -> CLIResponseEnvelope {
        guard let version = negotiatedProtocolVersion else {
            throw CLIBrokerClientError.unavailable("The host handshake has not completed.")
        }
        let request = CLIRequestEnvelope(
            protocolVersion: version,
            requestID: requestID,
            operation: .doctor,
            sentAt: .now,
            payload: nil
        )
        let data = try CLIProtocolCodec.encodeRequest(request)
        let responseData: Data
        guard let responseDeadline = requestCleanupPolicy.responseDeadline(
            within: deadline,
            maximumWait: .seconds(10)
        ) else {
            invalidateConnection()
            throw CLIBrokerClientError.unavailable(
                "Timed out waiting for the broker reply; delivery state is unknown."
            )
        }
        do {
            responseData = try await awaitReply(deadline: responseDeadline) { completion in
                guard let broker = self.brokerProxy(errorHandler: { _ in
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
        } catch is CancellationError {
            await Task.detached { [self] in
                await cleanup(requestID: requestID, deadline: deadline)
            }.value
            throw CancellationError()
        } catch CLIBrokerClientError.timedOut {
            await cleanup(requestID: requestID, deadline: deadline)
            throw CLIBrokerClientError.unavailable(
                "Timed out waiting for the broker reply; delivery state is unknown."
            )
        }
        let response = try decodeResponse(responseData)
        do {
            try CLIProtocolSemanticValidator.validate(response: response, matching: request)
        } catch {
            throw CLIBrokerClientError.invalidPeerResponse
        }
        return response
    }

    func version() -> (version: String, build: String) {
        let info = CLIServiceConfiguration.executableInfoDictionary()
        return (
            info["CFBundleShortVersionString"] as? String ?? "unknown",
            info["CFBundleVersion"] as? String ?? "unknown"
        )
    }

    private func connectAndHandshake(
        deadline: ContinuousClock.Instant,
        launchHostIfNeeded: Bool
    ) async throws -> CLIHandshakeResponse {
        connection?.invalidate()
        negotiatedProtocolVersion = nil
        let connection = NSXPCConnection(
            machServiceName: CLIServiceConfiguration.runtimeCLIServiceName
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        guard identityValidator.configure(connection, toRequire: .broker) else {
            throw CLIBrokerClientError.unavailable("The broker identity could not be verified.")
        }
        connection.activate()
        self.connection = connection
        let version = version()
        let request = try CLIProtocolCodec.encodeRequest(CLIHandshakeRequest(
            minimumProtocolVersion: CLIProtocolVersion.minimum,
            maximumProtocolVersion: CLIProtocolVersion.current,
            clientVersion: version.version,
            clientBuild: version.build,
            launchHostIfNeeded: launchHostIfNeeded
        ))
        let responseData: Data = try await awaitReply(deadline: deadline) { completion in
            guard let broker = self.brokerProxy(errorHandler: { _ in
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
        let response: CLIHandshakeResponse
        do {
            response = try CLIProtocolCodec.decodeResponse(
                CLIHandshakeResponse.self,
                from: responseData,
                allowedKeys: [
                    "selectedProtocolVersion", "brokerVersion", "brokerBuild",
                    "hostVersion", "hostBuild", "hostReady", "message",
                ]
            )
        } catch {
            throw CLIBrokerClientError.invalidPeerResponse
        }
        try validate(handshake: response)
        return response
    }

    private func validate(handshake: CLIHandshakeResponse) throws {
        do {
            try CLIProtocolSemanticValidator.validate(handshake: handshake)
        } catch {
            throw CLIBrokerClientError.invalidPeerResponse
        }
    }

    private func decodeResponse(_ data: Data) throws -> CLIResponseEnvelope {
        do {
            try CLIProtocolCodec.validateResponseEnvelopeShape(in: data)
            return try CLIProtocolCodec.decodeResponse(
                CLIResponseEnvelope.self,
                from: data,
                allowedKeys: [
                    "schemaVersion", "protocolVersion", "requestID", "operation",
                    "startedAt", "finishedAt", "outcome", "message", "rejection", "payload",
                ]
            )
        } catch {
            throw CLIBrokerClientError.invalidPeerResponse
        }
    }

    private func cleanup(requestID: UUID, deadline: CLIStartupDeadline) async {
        await requestCleanupPolicy.performCleanup(
            within: deadline,
            cancel: { [self] cleanupDeadline in
                await cancel(requestID: requestID, deadline: cleanupDeadline)
            },
            invalidate: { [self] in invalidateConnection() }
        )
    }

    private func cancel(
        requestID: UUID,
        deadline: ContinuousClock.Instant
    ) async {
        let _: Bool? = try? await awaitReply(deadline: deadline) { completion in
            guard let broker = self.brokerProxy(errorHandler: { _ in
                completion(.success(false))
            }) else {
                completion(.success(false))
                return
            }
            broker.cancel(requestID) { completion(.success($0)) }
        }
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
        negotiatedProtocolVersion = nil
    }

    private func brokerProxy(
        errorHandler: ((Error) -> Void)?
    ) -> CLIBrokerXPCProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            errorHandler?(error)
        } as? CLIBrokerXPCProtocol
    }

    private func awaitReply<T: Sendable>(
        deadline: ContinuousClock.Instant,
        start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncStream.makeStream(of: Result<T, Error>.self)
        start { result in
            continuation.yield(result)
            continuation.finish()
        }
        let timeoutTask = Task {
            try? await ContinuousClock().sleep(until: deadline)
            guard !Task.isCancelled else { return }
            continuation.yield(.failure(CLIBrokerClientError.timedOut))
            continuation.finish()
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            for await result in stream {
                try Task.checkCancellation()
                return try result.get()
            }
            try Task.checkCancellation()
            throw CLIBrokerClientError.unavailable("The broker reply ended unexpectedly.")
        } onCancel: {
            continuation.yield(.failure(CancellationError()))
            continuation.finish()
        }
    }
}
