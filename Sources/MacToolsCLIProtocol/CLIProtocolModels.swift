import Foundation

public enum CLIProtocolVersion {
    public static let minimum = 1
    public static let current = 2
    public static let maximumRequestBytes = 64 * 1_024
    public static let maximumResponseBytes = 4 * 1_024 * 1_024
    public static let maximumInFlightRequestsPerClient = 8
    public static let maximumInFlightRequestsGlobally = 32
}

public enum CLIProtocolNegotiator {
    public static func selectedVersion(
        clientMinimum: Int,
        clientMaximum: Int,
        brokerMinimum: Int = CLIProtocolVersion.minimum,
        brokerMaximum: Int = CLIProtocolVersion.current,
        hostMinimum: Int? = nil,
        hostMaximum: Int? = nil
    ) -> Int? {
        guard clientMinimum <= clientMaximum,
              brokerMinimum <= brokerMaximum else { return nil }
        var minimum = max(clientMinimum, brokerMinimum)
        var maximum = min(clientMaximum, brokerMaximum)
        if let hostMinimum, let hostMaximum {
            guard hostMinimum <= hostMaximum else { return nil }
            minimum = max(minimum, hostMinimum)
            maximum = min(maximum, hostMaximum)
        } else if hostMinimum != nil || hostMaximum != nil {
            return nil
        }
        return minimum <= maximum ? maximum : nil
    }
}

public enum CLIOperation: String, Codable, CaseIterable, Sendable {
    case doctor
    case actionsList = "actions.list"
    case actionsDescribe = "actions.describe"
    case actionsAvailability = "actions.availability"

    public var minimumProtocolVersion: Int { self == .doctor ? 1 : 2 }
}

public enum CLIOutcome: String, Codable, Sendable {
    case completed
    case cancelled
    case invalidInput
    case unknownTarget
    case hostUnavailable
    case protocolIncompatible
}

public enum CLIExitCode: Int32, Codable, Sendable {
    case success = 0
    case invalidInput = 2
    case unknownTarget = 3
    case cancellation = 8
    case transportFailure = 9
    case protocolIncompatible = 10
}

public struct CLIHandshakeRequest: Codable, Equatable, Sendable {
    public let minimumProtocolVersion: Int
    public let maximumProtocolVersion: Int
    public let clientVersion: String
    public let clientBuild: String
    public let launchHostIfNeeded: Bool

    public init(
        minimumProtocolVersion: Int,
        maximumProtocolVersion: Int,
        clientVersion: String,
        clientBuild: String,
        launchHostIfNeeded: Bool
    ) {
        self.minimumProtocolVersion = minimumProtocolVersion
        self.maximumProtocolVersion = maximumProtocolVersion
        self.clientVersion = clientVersion
        self.clientBuild = clientBuild
        self.launchHostIfNeeded = launchHostIfNeeded
    }
}

public struct CLIHandshakeResponse: Codable, Equatable, Sendable {
    public let selectedProtocolVersion: Int?
    public let brokerVersion: String
    public let brokerBuild: String
    public let hostVersion: String?
    public let hostBuild: String?
    public let hostReady: Bool
    public let message: String?

    public init(
        selectedProtocolVersion: Int?,
        brokerVersion: String,
        brokerBuild: String,
        hostVersion: String?,
        hostBuild: String?,
        hostReady: Bool,
        message: String?
    ) {
        self.selectedProtocolVersion = selectedProtocolVersion
        self.brokerVersion = brokerVersion
        self.brokerBuild = brokerBuild
        self.hostVersion = hostVersion
        self.hostBuild = hostBuild
        self.hostReady = hostReady
        self.message = message
    }
}

public struct CLIHostRegistration: Codable, Equatable, Sendable {
    public let minimumProtocolVersion: Int
    public let maximumProtocolVersion: Int
    public let hostVersion: String
    public let hostBuild: String

    public init(
        minimumProtocolVersion: Int,
        maximumProtocolVersion: Int,
        hostVersion: String,
        hostBuild: String
    ) {
        self.minimumProtocolVersion = minimumProtocolVersion
        self.maximumProtocolVersion = maximumProtocolVersion
        self.hostVersion = hostVersion
        self.hostBuild = hostBuild
    }
}

public struct CLIRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: CLIOperation
    public let sentAt: Date
    public let payload: Data?

    public init(
        protocolVersion: Int,
        requestID: UUID,
        operation: CLIOperation,
        sentAt: Date,
        payload: Data?
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.sentAt = sentAt
        self.payload = payload
    }
}

public struct CLIRejection: Codable, Equatable, Sendable {
    public let category: String
    public let message: String?

    public init(category: String, message: String?) {
        self.category = category
        self.message = message
    }
}

public struct CLIResponseEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let protocolVersion: Int?
    public let requestID: UUID
    public let operation: CLIOperation
    public let startedAt: Date
    public let finishedAt: Date
    public let outcome: CLIOutcome
    public let message: String?
    public let rejection: CLIRejection?
    public let payload: Data?

    public init(
        schemaVersion: Int = 1,
        protocolVersion: Int?,
        requestID: UUID,
        operation: CLIOperation,
        startedAt: Date,
        finishedAt: Date,
        outcome: CLIOutcome,
        message: String?,
        rejection: CLIRejection?,
        payload: Data?
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.message = message
        self.rejection = rejection
        self.payload = payload
    }

    public static func failure(
        request: CLIRequestEnvelope,
        outcome: CLIOutcome,
        category: String,
        message: String?,
        startedAt: Date = .now
    ) -> Self {
        Self(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            operation: request.operation,
            startedAt: startedAt,
            finishedAt: .now,
            outcome: outcome,
            message: message,
            rejection: CLIRejection(category: category, message: message),
            payload: nil
        )
    }
}

public struct CLIDoctorRecord: Codable, Equatable, Sendable {
    public let hostVersion: String
    public let hostBuild: String
    public let protocolVersion: Int
    public let brokerServiceStatus: String

    public init(
        hostVersion: String,
        hostBuild: String,
        protocolVersion: Int,
        brokerServiceStatus: String
    ) {
        self.hostVersion = hostVersion
        self.hostBuild = hostBuild
        self.protocolVersion = protocolVersion
        self.brokerServiceStatus = brokerServiceStatus
    }
}

public enum CLIProtocolSemanticError: Error, Equatable {
    case invalidHandshake
    case invalidResponse
    case invalidDoctorRecord
}

public enum CLIProtocolSemanticValidator {
    public static func validate(
        handshake: CLIHandshakeResponse,
        clientMinimum: Int = CLIProtocolVersion.minimum,
        clientMaximum: Int = CLIProtocolVersion.current
    ) throws {
        guard clientMinimum <= clientMaximum,
              !handshake.brokerVersion.isEmpty,
              !handshake.brokerBuild.isEmpty,
              (handshake.hostVersion == nil) == (handshake.hostBuild == nil)
        else { throw CLIProtocolSemanticError.invalidHandshake }
        if handshake.hostReady {
            guard handshake.hostVersion?.isEmpty == false,
                  handshake.hostBuild?.isEmpty == false,
                  handshake.selectedProtocolVersion != nil
            else { throw CLIProtocolSemanticError.invalidHandshake }
        } else if handshake.hostVersion != nil {
            guard handshake.selectedProtocolVersion == nil else {
                throw CLIProtocolSemanticError.invalidHandshake
            }
        }
        if let selected = handshake.selectedProtocolVersion {
            guard (clientMinimum...clientMaximum).contains(selected) else {
                throw CLIProtocolSemanticError.invalidHandshake
            }
        }
    }

    public static func validate(
        response: CLIResponseEnvelope,
        matching request: CLIRequestEnvelope
    ) throws {
        guard response.schemaVersion == 1,
              response.protocolVersion == request.protocolVersion,
              response.requestID == request.requestID,
              response.operation == request.operation,
              response.outcome != .unknownTarget || request.operation != .doctor,
              response.finishedAt >= response.startedAt
        else { throw CLIProtocolSemanticError.invalidResponse }
        switch response.outcome {
        case .completed:
            guard response.payload != nil,
                  response.rejection == nil,
                  response.message == nil
            else { throw CLIProtocolSemanticError.invalidResponse }
        case .cancelled, .invalidInput, .unknownTarget, .hostUnavailable, .protocolIncompatible:
            guard response.payload == nil,
                  let rejection = response.rejection,
                  !rejection.category.isEmpty,
                  rejection.message == response.message
            else { throw CLIProtocolSemanticError.invalidResponse }
        }
    }

    public static func validate(
        doctorRecord: CLIDoctorRecord,
        response: CLIResponseEnvelope,
        handshake: CLIHandshakeResponse
    ) throws {
        guard response.operation == .doctor,
              response.outcome == .completed,
              doctorRecord.protocolVersion == response.protocolVersion,
              doctorRecord.hostVersion == handshake.hostVersion,
              doctorRecord.hostBuild == handshake.hostBuild,
              !doctorRecord.brokerServiceStatus.isEmpty
        else { throw CLIProtocolSemanticError.invalidDoctorRecord }
    }
}
