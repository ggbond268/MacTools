import Foundation
import MacToolsCLIProtocol
import XCTest
@testable import MacTools

@MainActor
final class CLIHostDiscoveryTests: XCTestCase {
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
}
