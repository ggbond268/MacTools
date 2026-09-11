import Foundation

public enum CLIExecutionLimits {
    public static let defaultTimeoutSeconds = 60
    public static let minimumTimeoutSeconds = 1
    public static let maximumTimeoutSeconds = 300
}

public struct CLIActionRunRequest: Codable, Equatable, Sendable {
    public let id: String
    public let timeoutSeconds: Int

    public init(
        id: String,
        timeoutSeconds: Int = CLIExecutionLimits.defaultTimeoutSeconds
    ) {
        self.id = id
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct CLIActionRunResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case succeeded
    }

    public let id: String
    public let status: Status
    public let message: String?

    public init(id: String, status: Status = .succeeded, message: String?) {
        self.id = id
        self.status = status
        self.message = message
    }
}

public enum CLIExecutionValidation {
    public static func validate(_ request: CLIActionRunRequest) throws {
        guard CLIDiscoveryValidation.validID(request.id),
              (CLIExecutionLimits.minimumTimeoutSeconds...CLIExecutionLimits.maximumTimeoutSeconds)
                .contains(request.timeoutSeconds)
        else { throw CLIProtocolCodecError.invalidObject }
    }

    public static func validate(_ result: CLIActionRunResult, request: CLIActionRunRequest) throws {
        guard result.id == request.id,
              result.status == .succeeded,
              result.message.map({ CLIDiscoveryValidation.validText($0) }) ?? true
        else { throw CLIProtocolSemanticError.invalidResponse }
    }

    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        try CLIDiscoveryValidation.decode(type, from: data)
    }
}
