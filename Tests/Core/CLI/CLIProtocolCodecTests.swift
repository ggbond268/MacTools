import MacToolsCLIProtocol
import XCTest

final class CLIProtocolCodecTests: XCTestCase {
    func testNegotiationUsesProtocolRangesOnly() {
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
        XCTAssertNil(CLIProtocolNegotiator.selectedVersion(
            clientMinimum: 1,
            clientMaximum: 1,
            hostMinimum: 1,
            hostMaximum: nil
        ))
    }

    func testTimestampsRequireAndEmitFractionalSeconds() throws {
        XCTAssertEqual(
            CLIProtocolCodec.timestamp(Date(timeIntervalSince1970: 0.123)),
            "1970-01-01T00:00:00.123Z"
        )
        let requestID = UUID()
        let missingFraction = Data("""
        {
          "protocolVersion": 1,
          "requestID": "\(requestID.uuidString)",
          "operation": "doctor",
          "sentAt": "2026-08-24T12:00:00Z"
        }
        """.utf8)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: missingFraction,
            allowedKeys: ["protocolVersion", "requestID", "operation", "sentAt", "payload"]
        ))
    }

    func testStrictShapeRejectsUnknownAndDuplicateFields() {
        let requestID = UUID()
        let unknown = Data("""
        {"protocolVersion":1,"requestID":"\(requestID)","operation":"doctor",\
        "sentAt":"2026-08-24T12:00:00.000Z","future":true}
        """.utf8)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIRequestEnvelope.self,
            from: unknown,
            allowedKeys: ["protocolVersion", "requestID", "operation", "sentAt", "payload"]
        ))

        let nestedDuplicate = Data(#"{"rejection":{"category":"a","category":"b"}}"#.utf8)
        XCTAssertThrowsError(
            try CLIProtocolCodec.validateResponseEnvelopeShape(in: nestedDuplicate)
        )
        let nestedUnknown = Data(#"{"rejection":{"category":"a","future":true}}"#.utf8)
        XCTAssertThrowsError(
            try CLIProtocolCodec.validateResponseEnvelopeShape(in: nestedUnknown)
        )
    }

    func testSizeLimitsAreEnforced() {
        let oversizedRequest = Data(
            repeating: 0x20,
            count: CLIProtocolVersion.maximumRequestBytes + 1
        )
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIHandshakeRequest.self,
            from: oversizedRequest
        ))
        let oversizedResponse = Data(
            repeating: 0x20,
            count: CLIProtocolVersion.maximumResponseBytes + 1
        )
        XCTAssertThrowsError(try CLIProtocolCodec.decodeResponse(
            CLIHandshakeResponse.self,
            from: oversizedResponse
        ))
    }

    func testHandshakeSemanticValidationAllowsDifferentProductVersions() throws {
        XCTAssertNoThrow(try CLIProtocolSemanticValidator.validate(handshake: CLIHandshakeResponse(
            selectedProtocolVersion: 1,
            brokerVersion: "99.0",
            brokerBuild: "999",
            hostVersion: "1.2.3",
            hostBuild: "123",
            hostReady: true,
            message: nil
        )))
        XCTAssertThrowsError(try CLIProtocolSemanticValidator.validate(handshake: CLIHandshakeResponse(
            selectedProtocolVersion: 1,
            brokerVersion: "1",
            brokerBuild: "1",
            hostVersion: "1",
            hostBuild: nil,
            hostReady: true,
            message: nil
        )))
        XCTAssertThrowsError(try CLIProtocolSemanticValidator.validate(handshake: CLIHandshakeResponse(
            selectedProtocolVersion: 1,
            brokerVersion: "1",
            brokerBuild: "1",
            hostVersion: "1",
            hostBuild: "1",
            hostReady: false,
            message: "not ready"
        )))
        XCTAssertNoThrow(try CLIProtocolSemanticValidator.validate(handshake: CLIHandshakeResponse(
            selectedProtocolVersion: nil,
            brokerVersion: "99.0",
            brokerBuild: "999",
            hostVersion: "1.2.3",
            hostBuild: "123",
            hostReady: false,
            message: "No compatible protocol version."
        )))
    }

    func testResponseSemanticValidationRejectsInvalidCombinations() throws {
        let request = CLIRequestEnvelope(
            protocolVersion: 1,
            requestID: UUID(),
            operation: .doctor,
            sentAt: .now,
            payload: nil
        )
        let validPayload = try CLIProtocolCodec.encodeResponse(CLIDoctorRecord(
            hostVersion: "1",
            hostBuild: "1",
            protocolVersion: 1,
            brokerServiceStatus: "enabled"
        ))
        let valid = CLIResponseEnvelope(
            protocolVersion: 1,
            requestID: request.requestID,
            operation: .doctor,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            outcome: .completed,
            message: nil,
            rejection: nil,
            payload: validPayload
        )
        XCTAssertNoThrow(
            try CLIProtocolSemanticValidator.validate(response: valid, matching: request)
        )

        let invalid = CLIResponseEnvelope(
            protocolVersion: 1,
            requestID: request.requestID,
            operation: .doctor,
            startedAt: Date(timeIntervalSince1970: 2),
            finishedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed,
            message: "unexpected",
            rejection: CLIRejection(category: "unexpected", message: "unexpected"),
            payload: validPayload
        )
        XCTAssertThrowsError(
            try CLIProtocolSemanticValidator.validate(response: invalid, matching: request)
        )
    }
}
