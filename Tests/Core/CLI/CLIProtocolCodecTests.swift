import XCTest
import MacToolsPluginKit
@testable import MacTools

final class CLIProtocolCodecTests: XCTestCase {
    func testNegotiationRequiresThreeWayOverlapWhenHostIsRegistered() {
        XCTAssertEqual(
            CLIProtocolNegotiator.selectedVersion(
                clientMinimum: 1,
                clientMaximum: 3,
                brokerMinimum: 1,
                brokerMaximum: 2,
                hostMinimum: 1,
                hostMaximum: 1
            ),
            1
        )
        XCTAssertNil(CLIProtocolNegotiator.selectedVersion(
            clientMinimum: 2,
            clientMaximum: 3,
            brokerMinimum: 1,
            brokerMaximum: 2,
            hostMinimum: 1,
            hostMaximum: 1
        ))
    }

    func testTimestampsUseFractionalSeconds() {
        XCTAssertEqual(
            CLIProtocolCodec.timestamp(Date(timeIntervalSince1970: 0.123)),
            "1970-01-01T00:00:00.123Z"
        )
    }

    func testRequestRoundTripAndUnknownTopLevelKeyRejection() throws {
        let request = CLIActionListRequest(runnableOnly: true, continuationToken: nil)
        let data = try CLIProtocolCodec.encodeRequest(request)
        XCTAssertEqual(
            try CLIProtocolCodec.decodeRequest(
                CLIActionListRequest.self,
                from: data,
                allowedKeys: ["runnableOnly", "continuationToken"]
            ),
            request
        )

        let unknown = Data(#"{"runnableOnly":true,"future":1}"#.utf8)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIActionListRequest.self,
            from: unknown,
            allowedKeys: ["runnableOnly"]
        ))

        let duplicate = Data(#"{"runnableOnly":true,"runnableOnly":false}"#.utf8)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIActionListRequest.self,
            from: duplicate,
            allowedKeys: ["runnableOnly"]
        )) { error in
            XCTAssertEqual(error as? CLIProtocolCodecError, .duplicateFields(["runnableOnly"]))
        }
    }

    func testInvocationContextEnvironmentRequiresCompleteBoundedValues() throws {
        let chainID = UUID()
        XCTAssertEqual(
            try CLIInvocationContext.inherited(environment: [
                CLIInvocationContext.chainEnvironmentKey: chainID.uuidString,
                CLIInvocationContext.depthEnvironmentKey: "1",
            ]),
            CLIInvocationContext(chainID: chainID, depth: 1)
        )
        XCTAssertNil(try CLIInvocationContext.inherited(environment: [:]))
        XCTAssertThrowsError(try CLIInvocationContext.inherited(environment: [
            CLIInvocationContext.chainEnvironmentKey: chainID.uuidString,
        ]))
        XCTAssertThrowsError(try CLIInvocationContext.inherited(environment: [
            CLIInvocationContext.chainEnvironmentKey: chainID.uuidString,
            CLIInvocationContext.depthEnvironmentKey: "2",
        ]))
    }

    func testRequestEnvelopeRoundTripPreservesBrokerInvocationContext() throws {
        let request = CLIRequestEnvelope(
            protocolVersion: 1,
            requestID: UUID(),
            operation: .actionsRun,
            sentAt: .now,
            invocationContext: CLIInvocationContext(chainID: UUID(), depth: 0),
            payload: nil
        )

        let data = try CLIProtocolCodec.encodeRequest(request)
        let decoded = try CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: data,
            allowedKeys: [
                "protocolVersion", "requestID", "operation", "sentAt",
                "invocationContext", "payload",
            ]
        )

        XCTAssertEqual(decoded.protocolVersion, request.protocolVersion)
        XCTAssertEqual(decoded.requestID, request.requestID)
        XCTAssertEqual(decoded.operation, request.operation)
        XCTAssertEqual(decoded.invocationContext, request.invocationContext)
        XCTAssertEqual(decoded.payload, request.payload)
        XCTAssertEqual(
            decoded.sentAt.timeIntervalSince1970,
            request.sentAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testVersionOneDraftAcceptsRequestShapeFromBeforeInvocationContext() throws {
        let requestID = UUID()
        let data = Data("""
        {
          "protocolVersion": 1,
          "requestID": "\(requestID.uuidString)",
          "operation": "doctor",
          "sentAt": "2026-08-23T17:00:00.000Z"
        }
        """.utf8)

        let request = try CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: data,
            allowedKeys: [
                "protocolVersion", "requestID", "operation", "sentAt",
                "invocationContext", "payload",
            ]
        )

        XCTAssertEqual(request.requestID, requestID)
        XCTAssertEqual(request.operation, .doctor)
        XCTAssertNil(request.invocationContext)
        XCTAssertNil(request.payload)
    }

    func testRejectsOversizedRequestsAndNonFiniteValues() throws {
        let oversized = Data(repeating: 0x20, count: CLIProtocolVersion.maximumRequestBytes + 1)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIActionListRequest.self,
            from: oversized,
            allowedKeys: ["runnableOnly"]
        ))
        XCTAssertThrowsError(try CLIProtocolCodec.encodeRequest(
            ["value": CLIParameterValue.double(.infinity)]
        ))
    }

    func testExecutionSourceAndExposureSurfaceAreForwardCompatible() throws {
        let source = ActionExecutionSource(rawValue: "future-source")
        let encoded = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(ActionExecutionSource.self, from: encoded), source)
        XCTAssertEqual(ActionExecutionSource.cli.rawValue, "cli")
        XCTAssertEqual(ActionExposureSurface.cli.rawValue, "cli")
    }

    func testReplacingOperationPreservesFailureDetails() {
        let request = CLIRequestEnvelope(
            protocolVersion: 1,
            requestID: UUID(),
            operation: .actionsDescribe,
            sentAt: .now,
            payload: nil
        )
        let response = CLIResponseEnvelope.failure(
            request: request,
            outcome: .unknownTarget,
            category: "unknownAction",
            message: "The requested action was not found."
        )

        let replaced = response.replacingOperation(.actionsRun)

        XCTAssertEqual(replaced.operation, .actionsRun)
        XCTAssertEqual(replaced.requestID, response.requestID)
        XCTAssertEqual(replaced.outcome, response.outcome)
        XCTAssertEqual(replaced.rejection, response.rejection)
        XCTAssertEqual(replaced.message, response.message)
    }
}
