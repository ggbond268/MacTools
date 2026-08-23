import AppKit
import Foundation

enum CLIBrokerClientError: Error {
    case unavailable(String)
    case timedOut
    case protocolIncompatible
    case peerContractInvalid
    case hostDiscovery(CLIHostLocationError)
    case hostDiscoveryTimedOut
    case brokerVersionIncompatible(expected: String, found: String, applicationURL: URL?)
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
        case .hostDiscoveryTimedOut:
            return CLIHostFailureDiagnostic(
                category: "hostDiscoveryTimedOut",
                message: CLIHostDiscoveryError.timedOut.localizedDescription,
                applicationURL: nil,
                signatureAccepted: false,
                guidance: "Remove unavailable MacTools copies or volumes, then retry."
            )
        case let .brokerVersionIncompatible(expected, found, applicationURL):
            return CLIHostFailureDiagnostic(
                category: "brokerVersionIncompatible",
                message: "The running broker is \(found); expected \(expected).",
                applicationURL: applicationURL,
                signatureAccepted: true,
                guidance: "Open the matching MacTools app once to refresh its background item."
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
        case .unavailable, .timedOut, .protocolIncompatible, .peerContractInvalid:
            return nil
        }
    }
}

final class CLIBrokerClient: @unchecked Sendable {
    private let identityValidator = CLIPeerIdentityValidator()
    private let hostDiscovery: CLIHostDiscovery
    private let hostLauncher: CLIHostApplicationLauncher
    private var connection: NSXPCConnection?
    private var negotiatedProtocolVersion: Int?
    private var selectedHostApplicationURL: URL?

    init(
        hostLocator: CLIHostLocator = CLIHostLocator(),
        hostDiscovery: CLIHostDiscovery? = nil,
        hostLauncher: CLIHostApplicationLauncher = CLIHostApplicationLauncher()
    ) {
        self.hostDiscovery = hostDiscovery ?? CLIHostDiscovery(locator: hostLocator)
        self.hostLauncher = hostLauncher
    }

    deinit {
        connection?.invalidate()
    }

    func prepareHost(launchIfNeeded: Bool = true) async throws -> CLIHandshakeResponse {
#if DEBUG
        if ProcessInfo.processInfo.environment[
            CLIServiceConfiguration.testPeerResponseEnvironmentKey
        ] != nil {
            negotiatedProtocolVersion = CLIProtocolVersion.current
            return CLIHandshakeResponse(
                selectedProtocolVersion: CLIProtocolVersion.current,
                brokerVersion: cliVersion().version,
                brokerBuild: cliVersion().build,
                hostVersion: cliVersion().version,
                hostBuild: cliVersion().build,
                hostReady: true,
                message: nil
            )
        }
#endif
        let deadline = Date().addingTimeInterval(10)
#if DEBUG
        let launchIfNeeded = launchIfNeeded
            && ProcessInfo.processInfo.environment[
                CLIServiceConfiguration.testDisableHostLaunchEnvironmentKey
            ] != "1"
#endif
        var didLaunch = false
        var didContactBroker = false
        var lastVersionMismatch: CLIBrokerClientError?
        var lastMessage = "The MacTools broker is unavailable."
        while Date() < deadline {
            do {
                let response = try await connectAndHandshake(
                    timeout: min(1.5, max(0.01, deadline.timeIntervalSinceNow))
                )
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
                let recoveryDecision = CLIHostRecoveryPolicy.decision(
                    brokerMatches: brokerMatches,
                    hostMatches: hostMatches,
                    launchAllowed: launchIfNeeded,
                    didLaunch: didLaunch
                )
                switch recoveryDecision {
                case .continueHandshake:
                    break
                case .launchExactHost:
                    selectedHostApplicationURL = try await launchHost(deadline: deadline)
                    lastVersionMismatch = versionMismatchError(
                        response: response,
                        expectedVersion: version
                    )
                    didLaunch = true
                    connection?.invalidate()
                    connection = nil
                    negotiatedProtocolVersion = nil
                    try await waitBeforeRetry(deadline: deadline)
                    continue
                case .waitForReplacement:
                    lastVersionMismatch = versionMismatchError(
                        response: response,
                        expectedVersion: version
                    )
                    connection?.invalidate()
                    connection = nil
                    negotiatedProtocolVersion = nil
                    try await waitBeforeRetry(deadline: deadline)
                    continue
                case .rejectBrokerVersion:
                    throw CLIBrokerClientError.brokerVersionIncompatible(
                        expected: "\(version.version) (\(version.build))",
                        found: "\(response.brokerVersion) (\(response.brokerBuild))",
                        applicationURL: selectedHostApplicationURL
                    )
                case .rejectHostVersion:
                    let found = response.hostVersion.map {
                        ["host \($0) (\(response.hostBuild ?? "unknown"))"]
                    } ?? ["host unknown"]
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
            } catch CLIBrokerClientError.peerContractInvalid {
                throw CLIBrokerClientError.peerContractInvalid
            } catch let error as CLIBrokerClientError where error.hostFailureDiagnostic != nil {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastMessage = "The MacTools broker is unavailable."
            }
            if launchIfNeeded, !didLaunch {
                selectedHostApplicationURL = try await launchHost(deadline: deadline)
                didLaunch = true
            }
            try await waitBeforeRetry(deadline: deadline)
        }
        if let lastVersionMismatch {
            throw lastVersionMismatch
        }
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
            responseData = try await receiveResponseData(
                request: request,
                encodedRequest: data,
                sendState: sendState
            )
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
        } catch CLIBrokerClientError.timedOut {
            throw CLIBrokerClientError.unavailable(
                "Timed out waiting for the broker reply; delivery state is unknown."
            )
        }
        guard !responseData.isEmpty else { throw CLIBrokerClientError.peerContractInvalid }
        let response: CLIResponseEnvelope
        do {
            response = try CLIProtocolCodec.decodeResponse(
                CLIResponseEnvelope.self,
                from: responseData,
                allowedKeys: [
                    "schemaVersion", "protocolVersion", "requestID", "operation",
                    "actionReference", "startedAt", "finishedAt", "outcome", "message",
                    "rejection", "payload",
                ]
            )
        } catch {
            throw CLIBrokerClientError.peerContractInvalid
        }
        guard response.schemaVersion == 1,
              response.protocolVersion == request.protocolVersion,
              response.requestID == request.requestID,
              response.operation == request.operation else {
            throw CLIBrokerClientError.peerContractInvalid
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
        guard !responseData.isEmpty else { throw CLIBrokerClientError.peerContractInvalid }
        let response: CLIHandshakeResponse
        do {
            response = try CLIProtocolCodec.decodeResponse(
                CLIHandshakeResponse.self,
                from: responseData,
                allowedKeys: [
                    "selectedProtocolVersion", "brokerVersion", "brokerBuild", "hostVersion",
                    "hostBuild", "hostReady", "message",
                ]
            )
        } catch {
            throw CLIBrokerClientError.peerContractInvalid
        }
        if let selectedProtocolVersion = response.selectedProtocolVersion,
           !(CLIProtocolVersion.minimum...CLIProtocolVersion.current).contains(
               selectedProtocolVersion
           ) {
            throw CLIBrokerClientError.peerContractInvalid
        }
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

    private func receiveResponseData(
        request: CLIRequestEnvelope,
        encodedRequest: Data,
        sendState: CLIRequestSendState
    ) async throws -> Data {
#if DEBUG
        if let fixture = try testPeerResponseData(request: request) {
            return fixture
        }
#endif
        return try await withTaskCancellationHandler {
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
                broker.send(encodedRequest) { completion(.success($0)) }
            }
        } onCancel: {
            sendState.cancel()
        }
    }

#if DEBUG
    private func testPeerResponseData(request: CLIRequestEnvelope) throws -> Data? {
        switch ProcessInfo.processInfo.environment[
            CLIServiceConfiguration.testPeerResponseEnvironmentKey
        ] {
        case "empty":
            return Data()
        case "malformed":
            return Data("{".utf8)
        case "mismatched":
            let mismatched = CLIRequestEnvelope(
                protocolVersion: request.protocolVersion,
                requestID: UUID(),
                operation: request.operation,
                sentAt: request.sentAt,
                invocationContext: request.invocationContext,
                payload: request.payload
            )
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
                request: mismatched,
                outcome: .failed,
                category: "fixture",
                message: "fixture"
            ))
        case "malformedPayload":
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope(
                schemaVersion: 1,
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                operation: request.operation,
                actionReference: nil,
                startedAt: .now,
                finishedAt: .now,
                outcome: .completed,
                message: nil,
                rejection: nil,
                payload: Data("{".utf8)
            ))
        case "timeout":
            throw CLIBrokerClientError.timedOut
        default:
            return nil
        }
    }
#endif

    private func launchHost(deadline: Date) async throws -> URL {
        let applicationURL: URL
        do {
            let version = cliVersion()
            applicationURL = try await hostDiscovery.locate(
                bundleIdentifier: hostBundleIdentifier(),
                version: version.version,
                build: version.build,
                deadline: deadline
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is CLIHostDiscoveryError {
            throw CLIBrokerClientError.hostDiscoveryTimedOut
        } catch let error as CLIHostLocationError {
            throw CLIBrokerClientError.hostDiscovery(error)
        }
        do {
            try await hostLauncher.launch(
                applicationURL: applicationURL,
                deadline: deadline
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

    private func waitBeforeRetry(deadline: Date) async throws {
        let delay = min(0.2, max(0, deadline.timeIntervalSinceNow))
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private func versionMismatchError(
        response: CLIHandshakeResponse,
        expectedVersion: (version: String, build: String)
    ) -> CLIBrokerClientError {
        let expected = "\(expectedVersion.version) (\(expectedVersion.build))"
        let brokerMatches = response.brokerVersion == expectedVersion.version
            && response.brokerBuild == expectedVersion.build
        if !brokerMatches {
            return .brokerVersionIncompatible(
                expected: expected,
                found: "\(response.brokerVersion) (\(response.brokerBuild))",
                applicationURL: selectedHostApplicationURL
            )
        }
        let found = response.hostVersion.map {
            ["host \($0) (\(response.hostBuild ?? "unknown"))"]
        } ?? ["host unknown"]
        return .hostDiscovery(.versionIncompatible(
            expected: expected,
            found: found,
            candidate: selectedHostApplicationURL
        ))
    }

    func cliVersion() -> (version: String, build: String) {
        let info = CLIServiceConfiguration.executableInfoDictionary()
        return (
            info["CFBundleShortVersionString"] as? String ?? "unknown",
            info["CFBundleVersion"] as? String ?? "unknown"
        )
    }

    func installedHostApplicationURL() -> URL? {
        selectedHostApplicationURL
    }

    private func hostBundleIdentifier() -> String {
        CLIServiceConfiguration.hostBundleIdentifier(
            for: CLIServiceConfiguration.executableInfoDictionary()["CFBundleIdentifier"]
                as? String ?? "app.ggbond.MacTools.cli"
        )
    }
}
