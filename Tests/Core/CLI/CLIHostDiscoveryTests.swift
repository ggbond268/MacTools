import Foundation
import MacToolsCLIProtocol
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class CLIHostDiscoveryTests: XCTestCase {
    private let owner = NSObject()

    func testDiscoveryWaitsForRegistryAndV1DoctorStillWorks() async throws {
        let discovery = CLIActionDiscovery(registry: ActionRegistry())
        let bridge = CLIHostBridge(discovery: discovery, readinessTimeout: .milliseconds(200), callerIsBroker: { true })
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            discovery.markReady()
        }
        let page = try await response(bridge, operation: .actionsList,
                                     payload: CLIProtocolCodec.encodeRequest(CLIActionListRequest()))
        XCTAssertEqual(page.outcome, .completed)
        let doctor = try await response(bridge, operation: .doctor, version: 1, payload: nil)
        XCTAssertEqual(doctor.outcome, .completed)
        let old = try await response(bridge, operation: .actionsList, version: 1,
                                    payload: CLIProtocolCodec.encodeRequest(CLIActionListRequest()))
        XCTAssertEqual(old.outcome, .protocolIncompatible)
    }

    func testNotReadyInvalidInputAndUnknownTargetRemainDistinct() async throws {
        let discovery = CLIActionDiscovery(registry: ActionRegistry())
        let bridge = CLIHostBridge(discovery: discovery, readinessTimeout: .zero, callerIsBroker: { true })
        let pending = try await response(bridge, operation: .actionsList,
                                        payload: CLIProtocolCodec.encodeRequest(CLIActionListRequest()))
        XCTAssertEqual(pending.rejection?.category, "registryNotReady")
        let malformed = try await response(bridge, operation: .actionsList, payload: Data("{}".utf8))
        XCTAssertEqual(malformed.outcome, .invalidInput)
        discovery.markReady()
        let missing = try await response(bridge, operation: .actionsDescribe,
                                        payload: CLIProtocolCodec.encodeRequest(CLIActionTargetRequest(id: "test/missing")))
        XCTAssertEqual(missing.outcome, .unknownTarget)
    }

    func testReadinessWaitHonorsCancellation() async throws {
        let discovery = CLIActionDiscovery(registry: ActionRegistry())
        let bridge = CLIHostBridge(discovery: discovery, callerIsBroker: { true })
        let id = UUID()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            bridge.cancel(id) { _ in }
        }
        let result = try await response(bridge, operation: .actionsList, id: id,
                                       payload: CLIProtocolCodec.encodeRequest(CLIActionListRequest()))
        XCTAssertEqual(result.outcome, .cancelled)
    }

    func testRunTimeoutIncludesRegistryReadinessWait() async throws {
        let discovery = CLIActionDiscovery(registry: ActionRegistry())
        let bridge = CLIHostBridge(
            discovery: discovery,
            readinessTimeout: .seconds(5),
            callerIsBroker: { true }
        )
        let result = try await response(
            bridge,
            operation: .actionsRun,
            version: 3,
            payload: CLIProtocolCodec.encodeRequest(
                CLIActionRunRequest(id: "test/run", timeoutSeconds: 1)
            )
        )
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.rejection?.category, "executionTimedOut")
    }

    func testV3RunReturnsValidatedResultAndV2RejectsBeforeExecution() async throws {
        let registry = ActionRegistry()
        var executions = 0
        let definition = actionDefinition()
        install(definition, in: registry) { _ in
            executions += 1
            return .success(ActionExecutionHandle { .succeeded(message: "Done") })
        }
        let discovery = CLIActionDiscovery(registry: registry)
        discovery.markReady()
        let bridge = CLIHostBridge(
            discovery: discovery,
            runner: CLIActionRunner(discovery: discovery, executor: ActionExecutor(registry: registry)),
            callerIsBroker: { true }
        )
        let request = CLIActionRunRequest(id: definition.key.id, timeoutSeconds: 2)
        let payload = try CLIProtocolCodec.encodeRequest(request)
        let completed = try await response(bridge, operation: .actionsRun, version: 3, payload: payload)
        XCTAssertEqual(completed.outcome, .completed)
        let result = try CLIExecutionValidation.decode(
            CLIActionRunResult.self,
            from: try XCTUnwrap(completed.payload)
        )
        try CLIExecutionValidation.validate(result, request: request)
        XCTAssertEqual(executions, 1)

        let old = try await response(bridge, operation: .actionsRun, version: 2, payload: payload)
        XCTAssertEqual(old.outcome, .protocolIncompatible)
        XCTAssertEqual(executions, 1)
    }

    func testDescribeMasksV3ExecutionCapabilityFromV2Clients() async throws {
        let registry = ActionRegistry()
        let definition = actionDefinition()
        install(definition, in: registry) { _ in
            .success(ActionExecutionHandle { .succeeded() })
        }
        let discovery = CLIActionDiscovery(registry: registry)
        discovery.markReady()
        let bridge = CLIHostBridge(discovery: discovery, callerIsBroker: { true })
        let request = CLIActionTargetRequest(id: definition.key.id)
        let payload = try CLIProtocolCodec.encodeRequest(request)

        let v2 = try await response(bridge, operation: .actionsDescribe, version: 2, payload: payload)
        let v2Description = try CLIDiscoveryValidation.decode(
            CLIActionDescription.self,
            from: try XCTUnwrap(v2.payload)
        )
        try CLIDiscoveryValidation.validate(v2Description, id: request.id)
        XCTAssertFalse(v2Description.executionSupported)

        let v3 = try await response(bridge, operation: .actionsDescribe, version: 3, payload: payload)
        let v3Description = try CLIDiscoveryValidation.decode(
            CLIActionDescription.self,
            from: try XCTUnwrap(v3.payload)
        )
        try CLIDiscoveryValidation.validate(v3Description, id: request.id)
        XCTAssertTrue(v3Description.executionSupported)
    }

    func testRunCancellationReachesExecutionHandle() async throws {
        let registry = ActionRegistry()
        var didCancel = false
        let definition = actionDefinition()
        install(definition, in: registry) { _ in
            .success(ActionExecutionHandle(operation: {
                try? await Task.sleep(for: .seconds(10))
                return .succeeded()
            }, cancel: { didCancel = true }))
        }
        let discovery = CLIActionDiscovery(registry: registry)
        discovery.markReady()
        let bridge = CLIHostBridge(
            discovery: discovery,
            runner: CLIActionRunner(discovery: discovery, executor: ActionExecutor(registry: registry)),
            callerIsBroker: { true }
        )
        let id = UUID()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            bridge.cancel(id) { _ in }
        }
        let result = try await response(
            bridge,
            operation: .actionsRun,
            version: 3,
            id: id,
            payload: CLIProtocolCodec.encodeRequest(CLIActionRunRequest(id: definition.key.id))
        )
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(didCancel)
    }

    private func response(_ bridge: CLIHostBridge, operation: CLIOperation, version: Int = 2,
                          id: UUID = UUID(), payload: Data?) async throws -> CLIResponseEnvelope {
        let request = CLIRequestEnvelope(protocolVersion: version, requestID: id, operation: operation,
                                         sentAt: .now, payload: payload)
        let encoded = try CLIProtocolCodec.encodeRequest(request)
        let data = await withCheckedContinuation { continuation in
            bridge.handle(encoded) { continuation.resume(returning: $0) }
        }
        let response = try CLIProtocolCodec.decodeResponse(CLIResponseEnvelope.self, from: data)
        try CLIProtocolSemanticValidator.validate(response: response, matching: request)
        return response
    }

    private func actionDefinition() -> ActionDefinition {
        ActionDefinition(
            key: .init(providerID: "test", actionID: "run"),
            title: "Run",
            description: "",
            systemImage: "bolt",
            capabilities: [.background, .automatic]
        )
    }

    private func install(
        _ definition: ActionDefinition,
        in registry: ActionRegistry,
        begin: @escaping (ActionInvocation) -> Result<ActionExecutionHandle, ActionRegistryError>
    ) {
        registry.synchronize([ActionProviderRegistration(
            providerID: definition.key.providerID,
            identity: ObjectIdentifier(owner),
            definitions: [definition],
            catalogEntries: [ActionCatalogEntry(reference: .init(key: definition.key), title: definition.title)],
            availability: { _ in .available },
            exposurePolicy: { _, _ in .automatic },
            migrate: { _, _ in nil },
            begin: begin
        )])
    }
}
