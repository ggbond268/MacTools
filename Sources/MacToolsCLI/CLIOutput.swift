import Foundation

struct CLIOutput {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func render(_ response: CLIResponseEnvelope, json: Bool) throws -> String {
        if json { return try jsonOutput(response) }
        if let message = response.message, response.outcome != .completed {
            return message
        }
        guard let payload = response.payload else {
            return response.message ?? humanOutcome(response.outcome)
        }
        switch response.operation {
        case .doctor:
            let value = try decode(CLIDoctorRecord.self, payload)
            return [
                "MacTools \(value.hostVersion) (\(value.hostBuild))",
                "Protocol: \(value.protocolVersion)",
                "Broker: \(value.brokerServiceStatus)",
                "Actions: \(value.actionCount), workflows: \(value.workflowCount), plugins: \(value.pluginCount)",
            ].joined(separator: "\n")
        case .actionsList:
            let page = try decode(CLIPage<CLIActionRecord>.self, payload)
            return (page.records.map { record in
                let marker = record.cliEligibility.isAvailable ? "available" : "unavailable"
                return "\(record.reference.key.id)\t\(record.title)\t\(marker)"
            } + nextPageLine(page.continuationToken)).joined(separator: "\n")
        case .actionsDescribe:
            let record = try decode(CLIActionRecord.self, payload)
            let parameters = record.parameters.map {
                "  \($0.id): \($0.kind)\($0.isRequired ? " (required)" : "") [\($0.privacy)]"
            }
            return ([
                "\(record.reference.key.id) — \(record.title)",
                record.description,
                "Available: \(record.availability.isAvailable ? "yes" : "no")",
                "CLI eligible: \(record.cliEligibility.isAvailable ? "yes" : "no")",
            ] + (parameters.isEmpty ? [] : ["Parameters:"] + parameters)).joined(separator: "\n")
        case .actionsAvailability:
            let record = try decode(CLIAvailabilityRecord.self, payload)
            return record.isAvailable ? "Available" : "Unavailable: \(record.reason ?? "unknown reason")"
        case .workflowsList:
            let page = try decode(CLIPage<CLIWorkflowRecord>.self, payload)
            return (page.records.map {
                "\($0.id.uuidString.lowercased())\t\($0.name)\t\($0.isEnabled ? "enabled" : "disabled")"
            } + nextPageLine(page.continuationToken)).joined(separator: "\n")
        case .workflowsDescribe:
            let workflow = try decode(CLIWorkflowRecord.self, payload)
            return "\(workflow.name)\nID: \(workflow.id.uuidString.lowercased())\nSteps: \(workflow.stepCount)"
        case .pluginsList:
            let page = try decode(CLIPage<CLIPluginRecord>.self, payload)
            return (page.records.map {
                "\($0.id)\t\($0.title)\t\($0.state)"
            } + nextPageLine(page.continuationToken)).joined(separator: "\n")
        case .pluginsDescribe, .pluginsDoctor:
            let plugin = try decode(CLIPluginRecord.self, payload)
            let permissions = plugin.permissions.map {
                "Permission \($0.title): \($0.status)"
            }
            return ([
                "\(plugin.title) (\(plugin.id))",
                "Version: \(plugin.version)",
                "State: \(plugin.state)",
                "Published actions: \(plugin.publishedActionCount)",
            ] + permissions + (plugin.diagnostic.map { ["Diagnostic: \($0)"] } ?? []))
                .joined(separator: "\n")
        case .actionsRun, .workflowsRun:
            return response.message ?? humanOutcome(response.outcome)
        }
    }

    func renderLocal(
        command: String,
        outcome: CLIOutcome,
        message: String?,
        rejectionCategory: String?,
        data: Any = NSNull(),
        protocolVersion: Int? = nil,
        requestID: UUID = UUID(),
        timestamp: Date = .now
    ) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "protocolVersion": protocolVersion.map { $0 as Any } ?? NSNull(),
            "requestID": requestID.uuidString.uppercased(),
            "command": command,
            "invocationSource": "cli",
            "startedAt": CLIProtocolCodec.timestamp(timestamp),
            "finishedAt": CLIProtocolCodec.timestamp(timestamp),
            "outcome": outcome.rawValue,
            "message": message.map { $0 as Any } ?? NSNull(),
            "data": data,
        ]
        if let rejectionCategory {
            object["rejection"] = [
                "category": rejectionCategory,
                "message": message.map { $0 as Any } ?? NSNull(),
            ]
        } else {
            object["rejection"] = NSNull()
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let output = String(data: data, encoding: .utf8) else {
            throw CLIProtocolCodecError.encodingFailed
        }
        return output
    }

    func exitCode(for response: CLIResponseEnvelope) -> CLIExitCode {
        switch response.outcome {
        case .completed, .started: .success
        case .invalidInput: .invalidInput
        case .unknownTarget: .unknownTarget
        case .unavailable: .unavailable
        case .confirmationDenied: .confirmationFailure
        case .failed, .providerChanged: .actionFailure
        case .timedOut: .timeout
        case .cancelled: .cancellation
        case .hostUnavailable: .transportFailure
        case .protocolIncompatible: .protocolIncompatible
        }
    }

    private func jsonOutput(_ response: CLIResponseEnvelope) throws -> String {
        var object: [String: Any] = [
            "schemaVersion": response.schemaVersion,
            "requestID": response.requestID.uuidString.uppercased(),
            "command": response.operation.rawValue,
            "invocationSource": "cli",
            "startedAt": CLIProtocolCodec.timestamp(response.startedAt),
            "outcome": response.outcome.rawValue,
        ]
        object["protocolVersion"] = response.protocolVersion.map { $0 as Any } ?? NSNull()
        if let reference = response.actionReference {
            object["actionReference"] = [
                "providerID": reference.key.providerID,
                "actionID": reference.key.actionID,
                "schemaVersion": reference.schemaVersion,
            ]
        }
        object["finishedAt"] = response.finishedAt.map {
            CLIProtocolCodec.timestamp($0) as Any
        } ?? NSNull()
        object["message"] = response.message.map { $0 as Any } ?? NSNull()
        if let rejection = response.rejection {
            object["rejection"] = [
                "category": rejection.category,
                "message": rejection.message.map { $0 as Any } ?? NSNull(),
            ]
        } else {
            object["rejection"] = NSNull()
        }
        if let payload = response.payload {
            object["data"] = try JSONSerialization.jsonObject(with: payload)
        } else {
            object["data"] = NSNull()
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let output = String(data: data, encoding: .utf8) else {
            throw CLIProtocolCodecError.encodingFailed
        }
        return output
    }

    private func decode<T: Decodable>(_ type: T.Type, _ payload: Data) throws -> T {
        try CLIProtocolCodec.decodeResponse(type, from: payload)
    }

    private func humanOutcome(_ outcome: CLIOutcome) -> String {
        switch outcome {
        case .completed: "Completed"
        case .started: "Started"
        case .cancelled: "Cancelled"
        case .unavailable: "Unavailable"
        case .confirmationDenied: "Confirmation denied"
        case .timedOut: "Timed out"
        case .invalidInput: "Invalid input"
        case .unknownTarget: "Unknown target"
        case .failed: "Failed"
        case .hostUnavailable: "Host unavailable"
        case .providerChanged: "Provider changed"
        case .protocolIncompatible: "Protocol incompatible"
        }
    }

    private func nextPageLine(_ token: String?) -> [String] {
        token.map { ["Next page token: \($0)"] } ?? []
    }
}
