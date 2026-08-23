import AppKit
import Foundation

enum CLIBrokerClientError: Error {
    case unavailable(String)
    case invalidResponse
    case timedOut
    case protocolIncompatible
    case hostDiscovery(CLIHostLocationError)
    case hostLaunchFailed(message: String, applicationURL: URL)
    case backgroundItemApprovalRequired(applicationURL: URL)
}

struct CLIHostFailureDiagnostic {
    let category: String
    let message: String
    let applicationURL: URL?
    let signatureAccepted: Bool
    let guidance: String
}

extension CLIBrokerClientError {
    var hostFailureDiagnostic: CLIHostFailureDiagnostic? {
        switch self {
        case let .hostDiscovery(error):
            let signatureAccepted: Bool
            switch error {
            case .versionIncompatible: signatureAccepted = true
            case .notFound, .teamMismatch, .roleMismatch, .invalidSignature:
                signatureAccepted = false
            }
            return CLIHostFailureDiagnostic(
                category: error.category,
                message: error.message,
                applicationURL: error.candidateURL,
                signatureAccepted: signatureAccepted,
                guidance: "Install the matching MacTools app release, then retry."
            )
        case let .hostLaunchFailed(message, applicationURL):
            return CLIHostFailureDiagnostic(
                category: "hostLaunchFailed",
                message: message,
                applicationURL: applicationURL,
                signatureAccepted: true,
                guidance: "Open MacTools manually, then retry."
            )
        case let .backgroundItemApprovalRequired(applicationURL):
            return CLIHostFailureDiagnostic(
                category: "brokerApprovalRequired",
                message: "The MacTools broker did not become available.",
                applicationURL: applicationURL,
                signatureAccepted: true,
                guidance: "Open System Settings > General > Login Items & Extensions and allow the MacTools background item, then retry."
            )
        case .unavailable, .invalidResponse, .timedOut, .protocolIncompatible:
            return nil
        }
    }
}

final class CLIBrokerClient: @unchecked Sendable {
    private let identityValidator = CLIPeerIdentityValidator()
    private let hostLocator: CLIHostLocator
    private let hostLauncher: CLIHostApplicationLauncher
    private var connection: NSXPCConnection?
    private var negotiatedProtocolVersion: Int?
    private var selectedHostApplicationURL: URL?

    init(
        hostLocator: CLIHostLocator = CLIHostLocator(),
        hostLauncher: CLIHostApplicationLauncher = CLIHostApplicationLauncher()
    ) {
        self.hostLocator = hostLocator
        self.hostLauncher = hostLauncher
    }

    deinit {
        connection?.invalidate()
    }

    func prepareHost(launchIfNeeded: Bool = true) async throws -> CLIHandshakeResponse {
        let deadline = Date().addingTimeInterval(10)
#if DEBUG
        let launchIfNeeded = launchIfNeeded
            && ProcessInfo.processInfo.environment[
                CLIServiceConfiguration.testDisableHostLaunchEnvironmentKey
            ] != "1"
#endif
        var didLaunch = false
        var didContactBroker = false
        var lastMessage = "The MacTools broker is unavailable."
        repeat {
            do {
                let response = try await connectAndHandshake(timeout: 1.5)
                didContactBroker = true
                let version = cliVersion()
                let brokerMatches = response.brokerVersion == version.version
                    && response.brokerBuild == version.build
                let hostMatches: Bool
                if let hostVersion = response.hostVersion, let hostBuild = response.hostBuild {
                    hostMatches = hostVersion == version.version && hostBuild == version.build
                } else {
                    hostMatches = !response.hostReady
                }
                guard brokerMatches, hostMatches else {
                    let found = [
                        "broker \(response.brokerVersion) (\(response.brokerBuild))",
                        response.hostVersion.map {
                            "host \($0) (\(response.hostBuild ?? "unknown"))"
                        },
                    ].compactMap { $0 }
                    throw CLIBrokerClientError.hostDiscovery(.versionIncompatible(
                        expected: "\(version.version) (\(version.build))",
                        found: found,
                        candidate: selectedHostApplicationURL
                    ))
                }
                guard let selectedVersion = response.selectedProtocolVersion else {
                    throw CLIBrokerClientError.protocolIncompatible
                }
                negotiatedProtocolVersion = selectedVersion
                if response.hostReady { return response }
                lastMessage = response.message ?? "MacTools is starting."
            } catch CLIBrokerClientError.protocolIncompatible {
                throw CLIBrokerClientError.protocolIncompatible
            } catch let error as CLIBrokerClientError where error.hostFailureDiagnostic != nil {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastMessage = "The MacTools broker is unavailable."
            }
            if launchIfNeeded, !didLaunch {
                selectedHostApplicationURL = try await launchHost(
                    timeout: deadline.timeIntervalSinceNow
                )
                didLaunch = true
            }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        if let selectedHostApplicationURL, !didContactBroker {
            throw CLIBrokerClientError.backgroundItemApprovalRequired(
                applicationURL: selectedHostApplicationURL
            )
        }
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
        let sendState = CLIRequestSendState()
        if connection == nil || negotiatedProtocolVersion == nil {
            _ = try await prepareHost()
        }
        let request = CLIRequestEnvelope(
            protocolVersion: negotiatedProtocolVersion ?? CLIProtocolVersion.current,
            requestID: requestID,
            operation: operation,
            sentAt: .now,
            invocationContext: try CLIInvocationContext.inherited(),
            payload: payload
        )
        let data = try CLIProtocolCodec.encodeRequest(request)
        let responseData: Data
        do {
            responseData = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await awaitReply(timeout: 86_460) { completion in
                    guard sendState.beginSending() else {
                        completion(.failure(CancellationError()))
                        return
                    }
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
            } onCancel: {
                sendState.cancel()
            }
        } catch is CancellationError {
            // Make the state transition explicit before observing it. The cancellation
            // handlers can resume this task from different executor hops.
            sendState.cancel()
            if sendState.takeCancellationToForward() {
                let cancellationTask = Task.detached { [weak self] in
                    await self?.cancel(requestID: requestID) ?? false
                }
                _ = await cancellationTask.value
            }
            throw CancellationError()
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
        let connection = NSXPCConnection(machServiceName: CLIServiceConfiguration.runtimeCLIServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        guard identityValidator.configure(connection, toRequire: .broker) else {
            throw CLIBrokerClientError.unavailable("The broker identity could not be verified.")
        }
        connection.activate()
        self.connection = connection
        let hello = CLIHandshakeRequest(
            minimumProtocolVersion: CLIProtocolVersion.minimum,
            maximumProtocolVersion: CLIProtocolVersion.current,
            clientVersion: cliVersion().version,
            clientBuild: cliVersion().build
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
        try Task.checkCancellation()
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
        return try await withTaskCancellationHandler {
            for await result in stream {
                timeoutTask.cancel()
                try Task.checkCancellation()
                return try result.get()
            }
            throw CLIBrokerClientError.invalidResponse
        } onCancel: {
            continuation.yield(.failure(CancellationError()))
            continuation.finish()
        }
    }

    private func launchHost(timeout: TimeInterval) async throws -> URL {
        let applicationURL: URL
        do {
            let version = cliVersion()
            applicationURL = try hostLocator.locate(
                bundleIdentifier: hostBundleIdentifier(),
                version: version.version,
                build: version.build
            )
        } catch let error as CLIHostLocationError {
            throw CLIBrokerClientError.hostDiscovery(error)
        }
        do {
            try await hostLauncher.launch(
                applicationURL: applicationURL,
                timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIBrokerClientError.hostLaunchFailed(
                message: error.localizedDescription,
                applicationURL: applicationURL
            )
        }
        return applicationURL
    }

    func cliVersion() -> (version: String, build: String) {
        let info = CLIServiceConfiguration.executableInfoDictionary()
        return (
            info["CFBundleShortVersionString"] as? String ?? "unknown",
            info["CFBundleVersion"] as? String ?? "unknown"
        )
    }

    func installedHostApplicationURL() -> URL? {
        if let selectedHostApplicationURL { return selectedHostApplicationURL }
        let version = cliVersion()
        return try? hostLocator.locate(
            bundleIdentifier: hostBundleIdentifier(),
            version: version.version,
            build: version.build
        )
    }

    private func hostBundleIdentifier() -> String {
        CLIServiceConfiguration.hostBundleIdentifier(
            for: CLIServiceConfiguration.executableInfoDictionary()["CFBundleIdentifier"]
                as? String ?? "app.ggbond.MacTools.cli"
        )
    }
}
