import Foundation
import MacToolsCLIProtocol
import XCTest
@testable import MacTools

final class CLIDiscoveryProtocolTests: XCTestCase {
    func testVersionNegotiationKeepsV1DiagnosticsAndRequiresV2Discovery() {
        XCTAssertEqual(CLIProtocolNegotiator.selectedVersion(clientMinimum: 1, clientMaximum: 2,
                                                             hostMinimum: 1, hostMaximum: 1), 1)
        XCTAssertEqual(CLIProtocolNegotiator.selectedVersion(clientMinimum: 1, clientMaximum: 1), 1)
        XCTAssertEqual(CLIOperation.doctor.minimumProtocolVersion, 1)
        XCTAssertEqual(CLIOperation.actionsList.minimumProtocolVersion, 2)
    }

    func testStrictShapesRejectUnknownDuplicateAndMalformedNestedFields() throws {
        let examples = [
            #"{"pageSize":1,"cursor":null,"unknown":null}"#,
            #"{"pageSize":1,"pageSize":2}"#,
            #"{"pageSize":1,"parameters":{"secret":"hidden"}}"#,
        ]
        for json in examples {
            XCTAssertThrowsError(try CLIDiscoveryValidation.decode(CLIActionListRequest.self, from: Data(json.utf8)))
        }
        let action = description()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CLIProtocolCodec.encodeResponse(action)) as? [String: Any])
        var parameters = try XCTUnwrap(object["parameters"] as? [[String: Any]])
        parameters[0]["default"] = "private"
        object["parameters"] = parameters
        XCTAssertThrowsError(try CLIDiscoveryValidation.decode(CLIActionDescription.self,
                                                              from: JSONSerialization.data(withJSONObject: object)))
        parameters[0].removeValue(forKey: "default")
        parameters[0]["kind"] = "unexpected"
        object["parameters"] = parameters
        XCTAssertThrowsError(try CLIDiscoveryValidation.decode(CLIActionDescription.self,
                                                              from: JSONSerialization.data(withJSONObject: object)))
        let deep = "{\"a\":" + String(repeating: "[", count: 100) + "0" + String(repeating: "]", count: 100) + "}"
        XCTAssertThrowsError(try CLIProtocolCodec.rejectDuplicateFieldsRecursively(in: Data(deep.utf8)))
    }

    func testPageAndReferenceSemanticValidation() throws {
        let generation = String(repeating: "a", count: 64)
        let items = [CLIActionSummary(id: "test/a", title: "A")]
        try CLIDiscoveryValidation.validate(CLIActionPage(actions: items, generation: generation,
                                                        nextCursor: "\(generation).1"), request: .init(pageSize: 1))
        for size in [0, 101, -1] { XCTAssertThrowsError(try CLIDiscoveryValidation.validate(CLIActionListRequest(pageSize: size))) }
        for id in ["../x", "a/b/c", "a/", "a/b@bad", "a/b\n"] {
            XCTAssertFalse(CLIDiscoveryValidation.validID(id))
        }
        for page in [
            CLIActionPage(actions: items + items, generation: generation, nextCursor: nil),
            CLIActionPage(actions: items, generation: generation, nextCursor: "\(generation).2"),
            CLIActionPage(actions: [], generation: generation, nextCursor: "\(generation).1"),
            CLIActionPage(actions: items, generation: "invalid", nextCursor: nil),
        ] { XCTAssertThrowsError(try CLIDiscoveryValidation.validate(page, request: .init(pageSize: 1))) }
        XCTAssertThrowsError(try CLIDiscoveryValidation.validate(description(), id: "test/other"))
        let duplicate = CLIActionDescription(id: "test/a", title: "A", description: "", parameterSchemaVersion: 1,
                                            parameters: description().parameters + description().parameters)
        XCTAssertThrowsError(try CLIDiscoveryValidation.validate(duplicate, id: duplicate.id))
        XCTAssertThrowsError(try CLIDiscoveryValidation.validate(
            CLIActionAvailability(id: "test/a", available: true, reason: .providerUnavailable), id: "test/a"))
    }

    func testTerminalPageCannotExceedCatalogLimit() throws {
        let generation = String(repeating: "a", count: 64)
        let request = CLIActionListRequest(pageSize: 2,
            cursor: "\(generation).\(CLIDiscoveryLimits.maximumCatalogSize - 1)")
        let items = [CLIActionSummary(id: "test/a", title: "A"), CLIActionSummary(id: "test/b", title: "B")]
        try CLIDiscoveryValidation.validate(CLIActionPage(actions: [items[0]], generation: generation,
                                                        nextCursor: nil), request: request)
        let overflow = CLIActionPage(actions: items, generation: generation, nextCursor: nil)
        XCTAssertThrowsError(try CLIDiscoveryValidation.validate(overflow, request: request))
        let response = envelope(operation: .actionsList, payload: try CLIProtocolCodec.encodeResponse(overflow))
        let payload = try CLIProtocolCodec.encodeRequest(request)
        for json in [false, true] {
            XCTAssertThrowsError(try CLIOutput().renderDiscovery(response, requestPayload: payload, json: json))
        }
    }

    func testHumanAndJSONRenderersValidateBeforeOutput() throws {
        let request = try CLIProtocolCodec.encodeRequest(CLIActionTargetRequest(id: "test/a"))
        let payload = try CLIProtocolCodec.encodeResponse(description())
        let response = envelope(operation: .actionsDescribe, payload: payload)
        let human = try CLIOutput().renderDiscovery(response, requestPayload: request, json: false)
        XCTAssertTrue(human.contains("Execution: not supported"))
        let json = try CLIOutput().renderDiscovery(response, requestPayload: request, json: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["command"] as? String, "actions.describe")
        XCTAssertEqual((object["data"] as? [String: Any])?["executionSupported"] as? Bool, false)
        XCTAssertThrowsError(try CLIOutput().renderDiscovery(response,
            requestPayload: CLIProtocolCodec.encodeRequest(CLIActionTargetRequest(id: "test/wrong")), json: true))
        let availability = CLIActionAvailability(id: "test/a", available: false, reason: .providerUnavailable)
        let rendered = try CLIOutput().renderDiscovery(envelope(operation: .actionsAvailability,
            payload: CLIProtocolCodec.encodeResponse(availability)), requestPayload: request, json: false)
        XCTAssertTrue(rendered.contains("currently unavailable"))
    }

    func testResponseOutcomeAndTimestampSemantics() throws {
        let request = CLIRequestEnvelope(protocolVersion: 2, requestID: UUID(), operation: .actionsDescribe,
                                         sentAt: .now, payload: nil)
        for response in [
            CLIResponseEnvelope(protocolVersion: 2, requestID: request.requestID, operation: .actionsDescribe,
                                startedAt: .now, finishedAt: .distantPast, outcome: .completed,
                                message: nil, rejection: nil, payload: Data()),
            CLIResponseEnvelope(protocolVersion: 2, requestID: request.requestID, operation: .actionsDescribe,
                                startedAt: .distantPast, finishedAt: .now, outcome: .unknownTarget,
                                message: nil, rejection: nil, payload: Data()),
        ] { XCTAssertThrowsError(try CLIProtocolSemanticValidator.validate(response: response, matching: request)) }
    }

    private func description() -> CLIActionDescription {
        CLIActionDescription(id: "test/a", title: "A", description: "Description", parameterSchemaVersion: 1,
            parameters: [CLIActionParameter(id: "enabled", kind: .boolean, isRequired: true,
                                             privacy: .publicValue, portability: .portable)])
    }

    private func envelope(operation: CLIOperation, payload: Data) -> CLIResponseEnvelope {
        CLIResponseEnvelope(protocolVersion: 2, requestID: UUID(), operation: operation,
                            startedAt: .distantPast, finishedAt: .now, outcome: .completed,
                            message: nil, rejection: nil, payload: payload)
    }
}
