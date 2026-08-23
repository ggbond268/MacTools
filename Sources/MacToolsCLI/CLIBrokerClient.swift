import AppKit
import Foundation

enum CLIBrokerClientError: Error {
    case unavailable(String)
    case timedOut
    case replyTimedOut
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
        case .unavailable, .timedOut, .replyTimedOut, .protocolIncompatible,
             .peerContractInvalid:
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
        let deadline = CLIStartupDeadline(duration: .seconds(10))
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
        while !deadline.isExpired {
            do {
                let remaining = deadline.remainingTimeInterval
                guard remaining > 0 else { break }
                let response = try await connectAndHandshake(
                    timeout: min(1.5, remaining)
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
            throw CLIBrokerClientError.replyTimedOut
        }
        guard !responseData.isEmpty else { throw CLIBrokerClientError.peerContractInvalid }
        let response: CLIResponseEnvelope
        do {
            try CLIResponsePayloadValidator.validateEnvelope(responseData)
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
        do {
            try CLIResponsePayloadValidator.validate(response)
        } catch {
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
        case "missingPayload":
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
                payload: nil
            ))
        case "schemaInvalidPayload":
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
                payload: Data("{}".utf8)
            ))
        case "nestedUnknownPayload":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(operation: request.operation, mutation: .unknown)
            )
        case "nestedDuplicatePayload":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(operation: request.operation, mutation: .duplicate)
            )
        case "validDiscoveryPayload":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(operation: request.operation, mutation: .none)
            )
        case "invalidOutcome":
            return try testResponseData(
                request: request,
                payload: nil,
                outcome: .timedOut
            )
        case "missingFinishedAt":
            return try testResponseData(
                request: request,
                payload: testDoctorPayload(),
                finishedAt: nil
            )
        case "unexpectedActionReference":
            return try testResponseData(
                request: request,
                payload: testDoctorPayload(),
                actionReference: testActionReference
            )
        case "validActionTimeout":
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
                request: request,
                outcome: .timedOut,
                category: "executionTimedOut",
                message: "The action timed out.",
                actionReference: testActionReference
            ))
        case "oversizedPage":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(
                    operation: request.operation,
                    mutation: .none,
                    recordCount: CLIProtocolVersion.maximumPageSize + 1
                )
            )
        case "duplicateParameterDefinitions":
            let parameter = testParameter(id: "value")
            return try testResponseData(
                request: request,
                payload: CLIProtocolCodec.encodeResponse(
                    testActionRecord(parameters: [parameter, parameter])
                )
            )
        case "invalidParameterID":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(
                    operation: request.operation,
                    mutation: .none,
                    parameters: [testParameter(id: "invalid id")]
                )
            )
        case "invalidParameterKind":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(
                    operation: request.operation,
                    mutation: .none,
                    parameters: [testParameter(id: "value", kind: "object")]
                )
            )
        case "invalidParameterPrivacy":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(
                    operation: request.operation,
                    mutation: .none,
                    parameters: [testParameter(id: "value", privacy: "secret")]
                )
            )
        case "invalidParameterPortability":
            return try testResponseData(
                request: request,
                payload: testDiscoveryPayload(
                    operation: request.operation,
                    mutation: .none,
                    parameters: [testParameter(id: "value", portability: "remote")]
                )
            )
        case "validStartedPayload":
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope(
                schemaVersion: 1,
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                operation: request.operation,
                actionReference: testActionReference,
                startedAt: .now,
                finishedAt: nil,
                outcome: .started,
                message: "Action started.",
                rejection: nil,
                payload: try CLIProtocolCodec.encodeResponse(["accepted": true])
            ))
        case "validFailure":
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
                request: request,
                outcome: .failed,
                category: "fixtureFailure",
                message: "Fixture failed."
            ))
        case "timeout":
            throw CLIBrokerClientError.timedOut
        default:
            return nil
        }
    }

    private func testResponseData(
        request: CLIRequestEnvelope,
        payload: Data?,
        actionReference: CLIActionReference? = nil,
        finishedAt: Date? = .now,
        outcome: CLIOutcome = .completed
    ) throws -> Data {
        try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope(
            schemaVersion: 1,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            operation: request.operation,
            actionReference: actionReference,
            startedAt: .now,
            finishedAt: finishedAt,
            outcome: outcome,
            message: nil,
            rejection: nil,
            payload: payload
        ))
    }

    private enum TestPayloadMutation: Equatable {
        case none
        case unknown
        case duplicate
    }

    private func testDiscoveryPayload(
        operation: CLIOperation,
        mutation: TestPayloadMutation,
        recordCount: Int = 1,
        parameters: [CLIActionParameter] = []
    ) throws -> Data {
        let payload: Data
        let duplicateField: String
        switch operation {
        case .actionsList:
            payload = try CLIProtocolCodec.encodeResponse(CLIPage(
                records: Array(
                    repeating: testActionRecord(parameters: parameters),
                    count: recordCount
                ),
                continuationToken: nil
            ))
            duplicateField = #""title":"Fixture action""#
        case .workflowsList:
            let record = CLIWorkflowRecord(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    name: "Fixture workflow",
                    isEnabled: true,
                    stepCount: 1,
                    actionReference: CLIActionReference(
                        key: CLIActionKey(providerID: "fixture", actionID: "action"),
                        schemaVersion: 1
                    ),
                    availability: CLIAvailabilityRecord(isAvailable: true, reason: nil)
                )
            payload = try CLIProtocolCodec.encodeResponse(CLIPage(
                records: Array(repeating: record, count: recordCount),
                continuationToken: nil
            ))
            duplicateField = #""name":"Fixture workflow""#
        case .pluginsList:
            let record = CLIPluginRecord(
                    id: "fixture",
                    title: "Fixture plugin",
                    summary: nil,
                    version: "1.0.0",
                    state: "active",
                    diagnostic: nil,
                    requiresRestart: false,
                    permissions: [CLIPluginPermissionRecord(
                        id: "fixture.permission",
                        title: "Fixture permission",
                        isGranted: true,
                        status: "granted"
                    )],
                    publishedActionCount: 1
                )
            payload = try CLIProtocolCodec.encodeResponse(CLIPage(
                records: Array(repeating: record, count: recordCount),
                continuationToken: nil
            ))
            duplicateField = #""title":"Fixture plugin""#
        default:
            return Data("{}".utf8)
        }

        if mutation == .duplicate {
            guard var string = String(data: payload, encoding: .utf8),
                  let range = string.range(of: duplicateField) else {
                throw CLIProtocolCodecError.encodingFailed
            }
            let key = duplicateField.prefix { $0 != ":" }
            string.replaceSubrange(range, with: "\(key):\"duplicate\",\(duplicateField)")
            return Data(string.utf8)
        }

        if mutation == .none { return payload }

        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              var records = object["records"] as? [[String: Any]],
              !records.isEmpty else {
            throw CLIProtocolCodecError.encodingFailed
        }
        records[0]["injected"] = true
        object["records"] = records
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private var testActionReference: CLIActionReference {
        CLIActionReference(
            key: CLIActionKey(providerID: "fixture", actionID: "action"),
            schemaVersion: 1
        )
    }

    private func testActionRecord(
        parameters: [CLIActionParameter] = []
    ) -> CLIActionRecord {
        CLIActionRecord(
            reference: testActionReference,
            title: "Fixture action",
            subtitle: nil,
            description: "Fixture",
            systemImage: "hammer",
            parameters: parameters,
            availability: CLIAvailabilityRecord(isAvailable: true, reason: nil),
            cliEligibility: CLIAvailabilityRecord(isAvailable: true, reason: nil),
            capabilities: [],
            externalInvocationPolicy: "automatic"
        )
    }

    private func testParameter(
        id: String,
        kind: String = "string",
        privacy: String = "publicValue",
        portability: String = "portable"
    ) -> CLIActionParameter {
        CLIActionParameter(
            id: id,
            title: id,
            kind: kind,
            isRequired: true,
            privacy: privacy,
            portability: portability
        )
    }

    private func testDoctorPayload() throws -> Data {
        try CLIProtocolCodec.encodeResponse(CLIDoctorRecord(
            hostVersion: "1.0.0",
            hostBuild: "1",
            protocolVersion: CLIProtocolVersion.current,
            actionCount: 1,
            workflowCount: 1,
            pluginCount: 1,
            brokerServiceStatus: "ready"
        ))
    }
#endif

    private func launchHost(deadline: CLIStartupDeadline) async throws -> URL {
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

    private func waitBeforeRetry(deadline: CLIStartupDeadline) async throws {
        try await deadline.sleep(upTo: .milliseconds(200))
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

private enum CLIResponsePayloadValidator {
    private struct StartedPayload: Decodable, Equatable {
        let accepted: Bool
    }

    private static let commonOutcomes: Set<CLIOutcome> = [
        .completed, .cancelled, .invalidInput, .hostUnavailable, .protocolIncompatible,
    ]
    private static let actionTargetOperations: Set<CLIOperation> = [
        .actionsDescribe, .actionsAvailability, .actionsRun, .workflowsRun,
    ]
    private static let parameterKinds: Set<String> = [
        "string", "integer", "double", "boolean",
    ]
    private static let parameterPrivacyValues: Set<String> = [
        "publicValue", "sensitive",
    ]
    private static let parameterPortabilityValues: Set<String> = [
        "portable", "localOnly",
    ]

    static func validate(_ response: CLIResponseEnvelope) throws {
        try validateEnvelopeSemantics(response)

        if response.outcome == .started {
            guard response.operation == .actionsRun || response.operation == .workflowsRun,
                  let payload = response.payload else {
                throw CLIProtocolCodecError.invalidObject
            }
            let value = try CLIProtocolCodec.decodeResponse(
                StartedPayload.self,
                from: payload
            )
            try CLIResponseJSONSchema.started.validate(payload)
            guard value.accepted else { throw CLIProtocolCodecError.invalidObject }
            return
        }

        guard response.outcome == .completed else {
            guard response.payload == nil else {
                throw CLIProtocolCodecError.invalidObject
            }
            return
        }

        switch response.operation {
        case .doctor:
            _ = try decode(
                CLIDoctorRecord.self,
                response.payload,
                schema: .doctor
            )
        case .actionsList:
            let page = try decode(
                CLIPage<CLIActionRecord>.self,
                response.payload,
                schema: .page(record: .action)
            )
            try validatePage(page)
            try page.records.forEach(validateActionRecord)
        case .actionsDescribe:
            let record = try decode(
                CLIActionRecord.self,
                response.payload,
                schema: .action
            )
            try validateActionRecord(record)
        case .actionsAvailability:
            _ = try decode(
                CLIAvailabilityRecord.self,
                response.payload,
                schema: .availability
            )
        case .workflowsList:
            let page = try decode(
                CLIPage<CLIWorkflowRecord>.self,
                response.payload,
                schema: .page(record: .workflow)
            )
            try validatePage(page)
        case .workflowsDescribe:
            _ = try decode(
                CLIWorkflowRecord.self,
                response.payload,
                schema: .workflow
            )
        case .pluginsList:
            let page = try decode(
                CLIPage<CLIPluginRecord>.self,
                response.payload,
                schema: .page(record: .plugin)
            )
            try validatePage(page)
        case .pluginsDescribe, .pluginsDoctor:
            _ = try decode(
                CLIPluginRecord.self,
                response.payload,
                schema: .plugin
            )
        case .actionsRun, .workflowsRun:
            guard response.payload == nil else {
                throw CLIProtocolCodecError.invalidObject
            }
        }
    }

    static func validateEnvelope(_ data: Data) throws {
        try CLIResponseJSONSchema.envelope.validate(data)
    }

    private static func validateEnvelopeSemantics(
        _ response: CLIResponseEnvelope
    ) throws {
        guard allowedOutcomes(for: response.operation).contains(response.outcome),
              (response.outcome == .started) == (response.finishedAt == nil),
              response.actionReference == nil
                || actionTargetOperations.contains(response.operation) else {
            throw CLIProtocolCodecError.invalidObject
        }
    }

    private static func allowedOutcomes(for operation: CLIOperation) -> Set<CLIOutcome> {
        switch operation {
        case .doctor, .actionsList, .workflowsList, .pluginsList:
            return commonOutcomes
        case .actionsDescribe, .actionsAvailability, .workflowsDescribe,
             .pluginsDescribe, .pluginsDoctor:
            return commonOutcomes.union([.unknownTarget])
        case .actionsRun, .workflowsRun:
            return Set([
                .completed, .started, .cancelled, .unavailable, .confirmationDenied,
                .timedOut, .invalidInput, .unknownTarget, .failed, .hostUnavailable,
                .providerChanged, .protocolIncompatible,
            ])
        }
    }

    private static func validatePage<Record>(_ page: CLIPage<Record>) throws {
        guard page.records.count <= CLIProtocolVersion.maximumPageSize else {
            throw CLIProtocolCodecError.invalidObject
        }
    }

    private static func validateActionRecord(_ record: CLIActionRecord) throws {
        var parameterIDs: Set<String> = []
        for parameter in record.parameters {
            guard isValidIdentifier(parameter.id),
                  parameterIDs.insert(parameter.id).inserted,
                  parameterKinds.contains(parameter.kind),
                  parameterPrivacyValues.contains(parameter.privacy),
                  parameterPortabilityValues.contains(parameter.portability) else {
                throw CLIProtocolCodecError.invalidObject
            }
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
            }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        _ payload: Data?,
        schema: CLIResponseJSONSchema
    ) throws -> T {
        guard let payload else { throw CLIProtocolCodecError.invalidObject }
        try schema.validate(payload)
        return try CLIProtocolCodec.decodeResponse(type, from: payload)
    }
}

private indirect enum CLIResponseJSONSchema: Sendable {
    case scalar
    case array(CLIResponseJSONSchema)
    case object([String: CLIResponseJSONSchema])

    static let envelope: Self = .object([
        "schemaVersion": .scalar,
        "protocolVersion": .scalar,
        "requestID": .scalar,
        "operation": .scalar,
        "actionReference": .actionReference,
        "startedAt": .scalar,
        "finishedAt": .scalar,
        "outcome": .scalar,
        "message": .scalar,
        "rejection": .object([
            "category": .scalar,
            "message": .scalar,
        ]),
        "payload": .scalar,
    ])

    static let started: Self = .object(["accepted": .scalar])

    static let doctor: Self = .object([
        "hostVersion": .scalar,
        "hostBuild": .scalar,
        "protocolVersion": .scalar,
        "actionCount": .scalar,
        "workflowCount": .scalar,
        "pluginCount": .scalar,
        "brokerServiceStatus": .scalar,
    ])

    static let action: Self = .object([
        "reference": .actionReference,
        "title": .scalar,
        "subtitle": .scalar,
        "description": .scalar,
        "systemImage": .scalar,
        "parameters": .array(.object([
            "id": .scalar,
            "title": .scalar,
            "kind": .scalar,
            "isRequired": .scalar,
            "privacy": .scalar,
            "portability": .scalar,
        ])),
        "availability": .availability,
        "cliEligibility": .availability,
        "capabilities": .array(.scalar),
        "externalInvocationPolicy": .scalar,
    ])

    static let availability: Self = .object([
        "isAvailable": .scalar,
        "reason": .scalar,
    ])

    static let workflow: Self = .object([
        "id": .scalar,
        "name": .scalar,
        "isEnabled": .scalar,
        "stepCount": .scalar,
        "actionReference": .actionReference,
        "availability": .availability,
    ])

    static let plugin: Self = .object([
        "id": .scalar,
        "title": .scalar,
        "summary": .scalar,
        "version": .scalar,
        "state": .scalar,
        "diagnostic": .scalar,
        "requiresRestart": .scalar,
        "permissions": .array(.object([
            "id": .scalar,
            "title": .scalar,
            "isGranted": .scalar,
            "status": .scalar,
        ])),
        "publishedActionCount": .scalar,
    ])

    static func page(record: Self) -> Self {
        .object([
            "records": .array(record),
            "continuationToken": .scalar,
        ])
    }

    private static let actionReference: Self = .object([
        "key": .object([
            "providerID": .scalar,
            "actionID": .scalar,
        ]),
        "schemaVersion": .scalar,
    ])

    func validate(_ data: Data) throws {
        try CLIProtocolCodec.rejectDuplicateFieldsRecursively(in: data)
        let value = try JSONSerialization.jsonObject(with: data)
        try validate(value, path: "data")
    }

    private func validate(_ value: Any, path: String) throws {
        switch self {
        case .scalar:
            return
        case let .array(element):
            guard let values = value as? [Any] else {
                throw CLIProtocolCodecError.invalidObject
            }
            for (index, value) in values.enumerated() {
                try element.validate(value, path: "\(path)[\(index)]")
            }
        case let .object(fields):
            if value is NSNull { return }
            guard let object = value as? [String: Any] else {
                throw CLIProtocolCodecError.invalidObject
            }
            let unknown = Set(object.keys).subtracting(fields.keys).sorted()
            guard unknown.isEmpty else {
                throw CLIProtocolCodecError.unknownFields(
                    unknown.map { "\(path).\($0)" }
                )
            }
            for (key, value) in object {
                guard let schema = fields[key] else { continue }
                try schema.validate(value, path: "\(path).\(key)")
            }
        }
    }
}
