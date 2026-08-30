import Foundation
import MacToolsCLIProtocol

struct CLIOutput {
    func renderDiscovery(_ response: CLIResponseEnvelope, requestPayload: Data, json: Bool) throws -> String {
        guard response.outcome == .completed, let payload = response.payload,
              response.protocolVersion.map({ $0 >= 2 }) == true else {
            throw CLIProtocolSemanticError.invalidResponse
        }
        let human: String
        switch response.operation {
        case .actionsList:
            let request = try CLIDiscoveryValidation.decode(CLIActionListRequest.self, from: requestPayload)
            let page = try CLIDiscoveryValidation.decode(CLIActionPage.self, from: payload)
            try CLIDiscoveryValidation.validate(page, request: request)
            var lines = page.actions.map { "\($0.id)  \($0.title)" }
            if lines.isEmpty { lines.append("No discoverable actions.") }
            if let cursor = page.nextCursor { lines.append("Next page: mactools actions list --cursor \(cursor)") }
            human = lines.joined(separator: "\n")
        case .actionsDescribe:
            let request = try CLIDiscoveryValidation.decode(CLIActionTargetRequest.self, from: requestPayload)
            let action = try CLIDiscoveryValidation.decode(CLIActionDescription.self, from: payload)
            try CLIDiscoveryValidation.validate(action, id: request.id)
            var lines = ["\(action.id)  \(action.title)", action.description,
                         "Parameter schema: \(action.parameterSchemaVersion)", "Execution: not supported"]
            lines += action.parameters.map { "  \($0.id): \($0.kind.rawValue) (\($0.isRequired ? "required" : "optional"), \($0.privacy.rawValue), \($0.portability.rawValue))" }
            human = lines.joined(separator: "\n")
        case .actionsAvailability:
            let request = try CLIDiscoveryValidation.decode(CLIActionTargetRequest.self, from: requestPayload)
            let availability = try CLIDiscoveryValidation.decode(CLIActionAvailability.self, from: payload)
            try CLIDiscoveryValidation.validate(availability, id: request.id)
            human = "\(availability.id)\nCLI eligibility: eligible\nAvailability: \(availability.available ? "available" : "currently unavailable in MacTools")"
        case .doctor:
            throw CLIProtocolSemanticError.invalidResponse
        }
        return json ? try envelopeJSON(response, data: JSONSerialization.jsonObject(with: payload)) : human
    }

    func renderVersion(
        cli: (version: String, build: String),
        handshake: CLIHandshakeResponse?,
        json: Bool
    ) throws -> String {
        if !json {
            var lines = ["mactools \(cli.version) (\(cli.build))"]
            if let handshake {
                lines.append("broker \(handshake.brokerVersion) (\(handshake.brokerBuild))")
                if let version = handshake.hostVersion, let build = handshake.hostBuild {
                    lines.append("host \(version) (\(build))")
                }
                if let selected = handshake.selectedProtocolVersion {
                    lines.append("protocol \(selected)")
                }
            }
            return lines.joined(separator: "\n")
        }
        return try localJSON(
            command: "version",
            outcome: .completed,
            message: nil,
            rejectionCategory: nil,
            protocolVersion: handshake?.selectedProtocolVersion,
            data: [
                "cliVersion": cli.version,
                "cliBuild": cli.build,
                "brokerVersion": handshake?.brokerVersion as Any? ?? NSNull(),
                "brokerBuild": handshake?.brokerBuild as Any? ?? NSNull(),
                "hostVersion": handshake?.hostVersion as Any? ?? NSNull(),
                "hostBuild": handshake?.hostBuild as Any? ?? NSNull(),
            ]
        )
    }

    func renderDoctor(
        _ response: CLIResponseEnvelope,
        handshake: CLIHandshakeResponse,
        json: Bool
    ) throws -> String {
        guard let payload = response.payload else {
            return try renderFailure(response, json: json)
        }
        let record = try CLIProtocolCodec.decodeResponse(
            CLIDoctorRecord.self,
            from: payload,
            allowedKeys: [
                "hostVersion", "hostBuild", "protocolVersion", "brokerServiceStatus",
            ]
        )
        try CLIProtocolSemanticValidator.validate(
            doctorRecord: record,
            response: response,
            handshake: handshake
        )
        if !json {
            return [
                "MacTools \(record.hostVersion) (\(record.hostBuild))",
                "Broker \(handshake.brokerVersion) (\(handshake.brokerBuild))",
                "Protocol: \(record.protocolVersion)",
                "Broker service: \(record.brokerServiceStatus)",
            ].joined(separator: "\n")
        }
        return try envelopeJSON(response, data: [
            "hostVersion": record.hostVersion,
            "hostBuild": record.hostBuild,
            "brokerVersion": handshake.brokerVersion,
            "brokerBuild": handshake.brokerBuild,
            "brokerServiceStatus": record.brokerServiceStatus,
        ])
    }

    func renderFailure(_ response: CLIResponseEnvelope, json: Bool) throws -> String {
        if !json { return response.message ?? "MacTools is unavailable." }
        return try envelopeJSON(response, data: NSNull())
    }

    func localFailure(
        command: String,
        outcome: CLIOutcome,
        category: String,
        message: String,
        json: Bool
    ) -> String {
        guard json else { return message }
        return (try? localJSON(
            command: command,
            outcome: outcome,
            message: message,
            rejectionCategory: category,
            protocolVersion: nil,
            data: NSNull()
        )) ?? message
    }

    private func envelopeJSON(_ response: CLIResponseEnvelope, data: Any) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": response.schemaVersion,
            "protocolVersion": response.protocolVersion as Any? ?? NSNull(),
            "requestID": response.requestID.uuidString.uppercased(),
            "command": response.operation.rawValue,
            "invocationSource": "cli",
            "startedAt": CLIProtocolCodec.timestamp(response.startedAt),
            "finishedAt": CLIProtocolCodec.timestamp(response.finishedAt),
            "outcome": response.outcome.rawValue,
            "message": response.message as Any? ?? NSNull(),
            "data": data,
        ]
        if let rejection = response.rejection {
            object["rejection"] = [
                "category": rejection.category,
                "message": rejection.message as Any? ?? NSNull(),
            ]
        } else {
            object["rejection"] = NSNull()
        }
        return try jsonString(object)
    }

    private func localJSON(
        command: String,
        outcome: CLIOutcome,
        message: String?,
        rejectionCategory: String?,
        protocolVersion: Int?,
        data: Any
    ) throws -> String {
        let now = Date()
        var object: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": protocolVersion as Any? ?? NSNull(),
            "requestID": UUID().uuidString.uppercased(),
            "command": command,
            "invocationSource": "cli",
            "startedAt": CLIProtocolCodec.timestamp(now),
            "finishedAt": CLIProtocolCodec.timestamp(now),
            "outcome": outcome.rawValue,
            "message": message as Any? ?? NSNull(),
            "data": data,
        ]
        object["rejection"] = rejectionCategory.map {
            ["category": $0, "message": message as Any? ?? NSNull()] as [String: Any]
        } ?? NSNull()
        return try jsonString(object)
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw CLIProtocolCodecError.encodingFailed
        }
        return value
    }
}
