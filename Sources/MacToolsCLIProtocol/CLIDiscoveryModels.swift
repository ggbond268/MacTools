import Foundation

public enum CLIDiscoveryLimits {
    public static let defaultPageSize = 50
    public static let maximumPageSize = 100
    public static let maximumCatalogSize = 4_096
    public static let maximumTextBytes = 1_024
}

public struct CLIActionListRequest: Codable, Equatable, Sendable {
    public let pageSize: Int
    public let cursor: String?

    public init(pageSize: Int = CLIDiscoveryLimits.defaultPageSize, cursor: String? = nil) {
        self.pageSize = pageSize
        self.cursor = cursor
    }
}

public struct CLIActionTargetRequest: Codable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

public struct CLIActionSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct CLIActionPage: Codable, Equatable, Sendable {
    public let actions: [CLIActionSummary]
    public let generation: String
    public let nextCursor: String?

    public init(actions: [CLIActionSummary], generation: String, nextCursor: String?) {
        self.actions = actions
        self.generation = generation
        self.nextCursor = nextCursor
    }
}

public struct CLIActionParameter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case string, integer, double, boolean }
    public enum Privacy: String, Codable, Sendable { case publicValue, sensitive }
    public enum Portability: String, Codable, Sendable { case portable, localOnly }
    public let id: String
    public let kind: Kind
    public let isRequired: Bool
    public let privacy: Privacy
    public let portability: Portability

    public init(id: String, kind: Kind, isRequired: Bool, privacy: Privacy, portability: Portability) {
        self.id = id
        self.kind = kind
        self.isRequired = isRequired
        self.privacy = privacy
        self.portability = portability
    }
}

public struct CLIActionDescription: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let parameterSchemaVersion: Int
    public let parameters: [CLIActionParameter]
    public let executionSupported: Bool

    public init(id: String, title: String, description: String, parameterSchemaVersion: Int,
                parameters: [CLIActionParameter], executionSupported: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.parameterSchemaVersion = parameterSchemaVersion
        self.parameters = parameters
        self.executionSupported = executionSupported
    }
}

public struct CLIActionAvailability: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case providerUnavailable }
    public let id: String
    public let eligible: Bool
    public let available: Bool
    public let reason: Reason?

    public init(id: String, eligible: Bool = true, available: Bool, reason: Reason?) {
        self.id = id
        self.eligible = eligible
        self.available = available
        self.reason = reason
    }
}

public enum CLIDiscoveryValidation {
    public static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    public static func validID(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && validDigest(String(parts[1]))) else { return false }
        let key = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        return key.count == 2 && key.allSatisfy { validComponent(String($0)) }
    }

    public static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func cursorParts(_ value: String) -> (generation: String, offset: Int)? {
        guard value.utf8.count <= 80 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, validDigest(String(parts[0])),
              let offset = Int(parts[1]), offset > 0,
              offset < CLIDiscoveryLimits.maximumCatalogSize,
              String(offset) == parts[1] else { return nil }
        return (String(parts[0]), offset)
    }

    public static func validate(_ request: CLIActionListRequest) throws {
        guard (1...CLIDiscoveryLimits.maximumPageSize).contains(request.pageSize),
              request.cursor == nil || cursorParts(request.cursor!) != nil else {
            throw CLIProtocolCodecError.invalidObject
        }
    }

    public static func validate(_ request: CLIActionTargetRequest) throws {
        guard validID(request.id) else { throw CLIProtocolCodecError.invalidObject }
    }

    public static func validate(_ page: CLIActionPage, request: CLIActionListRequest) throws {
        try validate(request)
        guard validDigest(page.generation), page.actions.count <= request.pageSize,
              page.actions.map(\.id) == page.actions.map(\.id).sorted(),
              Set(page.actions.map(\.id)).count == page.actions.count,
              page.actions.allSatisfy({ validID($0.id) && validText($0.title, allowEmpty: false) })
        else { throw CLIProtocolSemanticError.invalidResponse }
        let previous = request.cursor.flatMap(cursorParts)
        guard (previous == nil || previous?.generation == page.generation),
              (previous?.offset ?? 0) + page.actions.count <= CLIDiscoveryLimits.maximumCatalogSize else {
            throw CLIProtocolSemanticError.invalidResponse
        }
        if let next = page.nextCursor {
            guard let parts = cursorParts(next), parts.generation == page.generation,
                  !page.actions.isEmpty,
                  parts.offset == (previous?.offset ?? 0) + page.actions.count else {
                throw CLIProtocolSemanticError.invalidResponse
            }
        }
    }

    public static func validate(_ action: CLIActionDescription, id: String) throws {
        guard action.id == id, validID(id), validText(action.title, allowEmpty: false),
              validText(action.description), action.parameterSchemaVersion > 0,
              action.parameters.count <= 32, !action.executionSupported,
              Set(action.parameters.map(\.id)).count == action.parameters.count,
              action.parameters.allSatisfy({ validComponent($0.id) }) else {
            throw CLIProtocolSemanticError.invalidResponse
        }
    }

    public static func validate(_ availability: CLIActionAvailability, id: String) throws {
        guard availability.id == id, validID(id), availability.eligible,
              availability.available == (availability.reason == nil) else {
            throw CLIProtocolSemanticError.invalidResponse
        }
    }

    public static func validText(_ value: String, allowEmpty: Bool = true) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= CLIDiscoveryLimits.maximumTextBytes
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Closed recursive shape validation: neither saved values nor unknown metadata can pass through.
    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= CLIProtocolVersion.maximumResponseBytes else {
            throw CLIProtocolCodecError.responseTooLarge
        }
        try CLIProtocolCodec.rejectDuplicateFieldsRecursively(in: data)
        let decoded = try CLIProtocolCodec.decodeResponse(type, from: data)
        let canonical = try CLIProtocolCodec.encodeResponse(decoded)
        guard let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let reencoded = try JSONSerialization.jsonObject(with: canonical) as? NSDictionary,
              original.isEqual(reencoded) else {
            throw CLIProtocolCodecError.invalidObject
        }
        return decoded
    }

}
