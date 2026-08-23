import Foundation

enum CLIProtocolVersion {
    static let minimum = 1
    static let current = 1
    static let maximumRequestBytes = 64 * 1_024
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumPageSize = 256
}

enum CLIProtocolNegotiator {
    static func selectedVersion(
        clientMinimum: Int,
        clientMaximum: Int,
        brokerMinimum: Int = CLIProtocolVersion.minimum,
        brokerMaximum: Int = CLIProtocolVersion.current,
        hostMinimum: Int? = nil,
        hostMaximum: Int? = nil
    ) -> Int? {
        var minimum = max(clientMinimum, brokerMinimum)
        var maximum = min(clientMaximum, brokerMaximum)
        if let hostMinimum, let hostMaximum {
            minimum = max(minimum, hostMinimum)
            maximum = min(maximum, hostMaximum)
        } else if hostMinimum != nil || hostMaximum != nil {
            return nil
        }
        return minimum <= maximum ? maximum : nil
    }
}

enum CLIOperation: String, Codable, CaseIterable, Sendable {
    case doctor
    case actionsList = "actions.list"
    case actionsDescribe = "actions.describe"
    case actionsAvailability = "actions.availability"
    case actionsRun = "actions.run"
    case workflowsList = "workflows.list"
    case workflowsDescribe = "workflows.describe"
    case workflowsRun = "workflows.run"
    case pluginsList = "plugins.list"
    case pluginsDescribe = "plugins.describe"
    case pluginsDoctor = "plugins.doctor"
}

enum CLIOutcome: String, Codable, Sendable {
    case completed
    case started
    case cancelled
    case unavailable
    case confirmationDenied
    case timedOut
    case invalidInput
    case unknownTarget
    case failed
    case hostUnavailable
    case providerChanged
    case protocolIncompatible
}

enum CLIExitCode: Int32, Codable, Sendable {
    case success = 0
    case invalidInput = 2
    case unknownTarget = 3
    case unavailable = 4
    case confirmationFailure = 5
    case actionFailure = 6
    case timeout = 7
    case cancellation = 8
    case transportFailure = 9
    case protocolIncompatible = 10
}

struct CLIHandshakeRequest: Codable, Equatable, Sendable {
    let minimumProtocolVersion: Int
    let maximumProtocolVersion: Int
    let clientVersion: String
    let clientBuild: String
}

struct CLIHandshakeResponse: Codable, Equatable, Sendable {
    let selectedProtocolVersion: Int?
    let brokerVersion: String
    let brokerBuild: String
    let hostVersion: String?
    let hostBuild: String?
    let hostReady: Bool
    let message: String?
}

struct CLIHostRegistration: Codable, Equatable, Sendable {
    let minimumProtocolVersion: Int
    let maximumProtocolVersion: Int
    let hostVersion: String
    let hostBuild: String
}

struct CLIRequestEnvelope: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let operation: CLIOperation
    let sentAt: Date
    let payload: Data?
}

struct CLIRejection: Codable, Equatable, Sendable {
    let category: String
    let message: String?
}

struct CLIResponseEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let protocolVersion: Int?
    let requestID: UUID
    let operation: CLIOperation
    let actionReference: CLIActionReference?
    let startedAt: Date
    let finishedAt: Date?
    let outcome: CLIOutcome
    let message: String?
    let rejection: CLIRejection?
    let payload: Data?

    static func failure(
        request: CLIRequestEnvelope,
        outcome: CLIOutcome,
        category: String,
        message: String?,
        actionReference: CLIActionReference? = nil,
        startedAt: Date = .now
    ) -> Self {
        Self(
            schemaVersion: 1,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            operation: request.operation,
            actionReference: actionReference,
            startedAt: startedAt,
            finishedAt: .now,
            outcome: outcome,
            message: message,
            rejection: CLIRejection(category: category, message: message),
            payload: nil
        )
    }

    func replacingOperation(_ operation: CLIOperation) -> Self {
        Self(
            schemaVersion: schemaVersion,
            protocolVersion: protocolVersion,
            requestID: requestID,
            operation: operation,
            actionReference: actionReference,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            message: message,
            rejection: rejection,
            payload: payload
        )
    }
}

struct CLIActionKey: Codable, Hashable, Sendable {
    let providerID: String
    let actionID: String

    var id: String { "\(providerID)/\(actionID)" }

    init(providerID: String, actionID: String) {
        self.providerID = providerID
        self.actionID = actionID
    }

    init?(id: String) {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        providerID = String(parts[0])
        actionID = String(parts[1])
    }
}

struct CLIActionReference: Codable, Hashable, Sendable {
    let key: CLIActionKey
    let schemaVersion: Int
}

struct CLIActionParameter: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: String
    let isRequired: Bool
    let privacy: String
    let portability: String
}

struct CLIActionRecord: Codable, Equatable, Sendable {
    let reference: CLIActionReference
    let title: String
    let subtitle: String?
    let description: String
    let systemImage: String
    let parameters: [CLIActionParameter]
    let availability: CLIAvailabilityRecord
    let cliEligibility: CLIAvailabilityRecord
    let capabilities: [String]
    let externalInvocationPolicy: String
}

struct CLIAvailabilityRecord: Codable, Equatable, Sendable {
    let isAvailable: Bool
    let reason: String?
}

struct CLIActionListRequest: Codable, Equatable, Sendable {
    let runnableOnly: Bool
    let continuationToken: String?
}

struct CLIListRequest: Codable, Equatable, Sendable {
    let continuationToken: String?
}

struct CLIPage<Record: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let records: [Record]
    let continuationToken: String?
}

struct CLIActionTargetRequest: Codable, Equatable, Sendable {
    let key: CLIActionKey
}

enum CLIParameterValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case string, integer, double, boolean }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "A double parameter must be finite."
                )
            }
            self = .double(value)
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .double(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "A double parameter must be finite."
                    )
                )
            }
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

enum CLIParameterInputSource: String, Codable, Sendable {
    case arguments
    case standardInput
    case protectedFile
}

struct CLIActionRunRequest: Codable, Equatable, Sendable {
    let key: CLIActionKey
    let parameters: [String: CLIParameterValue]
    let inputSource: CLIParameterInputSource
    let noWait: Bool
}

struct CLIWorkflowTargetRequest: Codable, Equatable, Sendable {
    let nameOrID: String
}

struct CLIWorkflowRunRequest: Codable, Equatable, Sendable {
    let nameOrID: String
    let noWait: Bool
}

struct CLIWorkflowRecord: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let stepCount: Int
    let actionReference: CLIActionReference
    let availability: CLIAvailabilityRecord
}


struct CLIPluginTargetRequest: Codable, Equatable, Sendable {
    let pluginID: String
}

struct CLIPluginRecord: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let version: String
    let state: String
    let diagnostic: String?
    let requiresRestart: Bool
    let permissions: [CLIPluginPermissionRecord]
    let publishedActionCount: Int
}

struct CLIPluginPermissionRecord: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let isGranted: Bool
    let status: String
}

struct CLIDoctorRecord: Codable, Equatable, Sendable {
    let hostVersion: String
    let hostBuild: String
    let protocolVersion: Int
    let actionCount: Int
    let workflowCount: Int
    let pluginCount: Int
    let brokerServiceStatus: String
}
