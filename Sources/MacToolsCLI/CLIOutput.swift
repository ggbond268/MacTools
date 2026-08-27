import Foundation
import MacToolsCLIProtocol

struct CLIOutput {
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
