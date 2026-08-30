import Foundation
import MacToolsCLIProtocol
import XCTest
@testable import MacTools

final class CLIDiscoveryProtocolTests: XCTestCase {
    func testVersionNegotiationKeepsV1DiagnosticsV2DiscoveryAndRequiresV3Execution() {
        XCTAssertEqual(CLIProtocolNegotiator.selectedVersion(clientMinimum: 1, clientMaximum: 3,
                                                             hostMinimum: 1, hostMaximum: 1), 1)
        XCTAssertEqual(CLIProtocolNegotiator.selectedVersion(clientMinimum: 1, clientMaximum: 1), 1)
        XCTAssertEqual(CLIOperation.doctor.minimumProtocolVersion, 1)
        XCTAssertEqual(CLIOperation.actionsList.minimumProtocolVersion, 2)
        XCTAssertEqual(CLIOperation.actionsRun.minimumProtocolVersion, 3)
    }

    func testExecutionRequestAndResultValidation() throws {
        let request = CLIActionRunRequest(id: "test/a", timeoutSeconds: 15)
        try CLIExecutionValidation.validate(request)
        for timeout in [0, 301] {
            XCTAssertThrowsError(try CLIExecutionValidation.validate(
                CLIActionRunRequest(id: "test/a", timeoutSeconds: timeout)
            ))
        }
        let result = CLIActionRunResult(id: "test/a", message: "Done")
        try CLIExecutionValidation.validate(result, request: request)
        XCTAssertThrowsError(try CLIExecutionValidation.validate(
            CLIActionRunResult(id: "test/other", message: nil), request: request
        ))
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

    func testExecutionHumanAndJSONRenderersValidateBeforeOutput() throws {
        let request = CLIActionRunRequest(id: "test/a", timeoutSeconds: 3)
        let requestData = try CLIProtocolCodec.encodeRequest(request)
        let result = CLIActionRunResult(id: request.id, message: "Done")
        let response = CLIResponseEnvelope(
            protocolVersion: 3,
            requestID: UUID(),
            operation: .actionsRun,
            startedAt: .distantPast,
            finishedAt: .now,
            outcome: .completed,
            message: nil,
            rejection: nil,
            payload: try CLIProtocolCodec.encodeResponse(result)
        )
        XCTAssertEqual(
            try CLIOutput().renderExecution(response, requestPayload: requestData, json: false),
            "test/a: succeeded — Done"
        )
        let json = try CLIOutput().renderExecution(response, requestPayload: requestData, json: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["command"] as? String, "actions.run")
        XCTAssertEqual((object["data"] as? [String: Any])?["status"] as? String, "succeeded")
        XCTAssertThrowsError(try CLIOutput().renderExecution(
            response,
            requestPayload: CLIProtocolCodec.encodeRequest(CLIActionRunRequest(id: "test/b")),
            json: false
        ))
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

    func testExecutionFailuresAreScopedToRunOperationAndStableCategories() throws {
        let run = CLIRequestEnvelope(
            protocolVersion: 3,
            requestID: UUID(),
            operation: .actionsRun,
            sentAt: .now,
            payload: nil
        )
        for (outcome, category) in [
            (CLIOutcome.unavailable, "actionUnavailable"),
            (.unavailable, "actionBusy"),
            (.actionFailed, "actionFailed"),
            (.timedOut, "executionTimedOut"),
        ] {
            let response = CLIResponseEnvelope.failure(
                request: run,
                outcome: outcome,
                category: category,
                message: "Stable"
            )
            XCTAssertNoThrow(
                try CLIProtocolSemanticValidator.validate(response: response, matching: run)
            )
        }

        let list = CLIRequestEnvelope(
            protocolVersion: 3,
            requestID: UUID(),
            operation: .actionsList,
            sentAt: .now,
            payload: nil
        )
        for (outcome, category) in [
            (CLIOutcome.unavailable, "actionUnavailable"),
            (.actionFailed, "actionFailed"),
            (.timedOut, "executionTimedOut"),
            (.unknownTarget, "unknownAction"),
        ] {
            let response = CLIResponseEnvelope.failure(
                request: list,
                outcome: outcome,
                category: category,
                message: "Malformed"
            )
            XCTAssertThrowsError(
                try CLIProtocolSemanticValidator.validate(response: response, matching: list)
            )
        }
        let wrongCategory = CLIResponseEnvelope.failure(
            request: run,
            outcome: .actionFailed,
            category: "providerSecret",
            message: "Malformed"
        )
        XCTAssertThrowsError(
            try CLIProtocolSemanticValidator.validate(response: wrongCategory, matching: run)
        )

        let doctor = CLIRequestEnvelope(
            protocolVersion: 3,
            requestID: UUID(),
            operation: .doctor,
            sentAt: .now,
            payload: nil
        )
        for category in ["registryNotReady", "catalogLimitExceeded"] {
            let response = CLIResponseEnvelope.failure(
                request: doctor,
                outcome: .hostUnavailable,
                category: category,
                message: "Impossible for doctor"
            )
            XCTAssertThrowsError(
                try CLIProtocolSemanticValidator.validate(response: response, matching: doctor)
            )
        }
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
