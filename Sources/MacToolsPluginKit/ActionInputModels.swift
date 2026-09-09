import Foundation

/// Explicit opt-in to host-owned composition. Incomplete inputs are never action references.
public struct ActionInputDescriptor: Hashable, Sendable, Identifiable {
    public let key: ActionKey
    public let schemaVersion: Int
    public let parameterID: String
    public let placeholder: String
    public let destination: String
    public let submitTitle: String
    public let aliases: [String]
    public let maximumUTF8Bytes: Int

    public var id: ActionKey { key }

    public init(
        key: ActionKey, schemaVersion: Int = 1, parameterID: String,
        placeholder: String, destination: String, submitTitle: String,
        aliases: [String] = [], maximumUTF8Bytes: Int = ActionParameterSet.maximumStringByteCount
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.parameterID = parameterID
        self.placeholder = placeholder
        self.destination = destination
        self.submitTitle = submitTitle
        self.aliases = aliases
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }
}

/// Ephemeral, provider-owned preparation. Never persist its identity or fixed parameters.
public struct ActionInputSession: Sendable {
    public let id: UUID
    public let destination: String
    public let parameters: ActionParameterSet

    public init(id: UUID = UUID(), destination: String, parameters: ActionParameterSet = .empty) {
        self.id = id
        self.destination = destination
        self.parameters = parameters
    }
}

@MainActor
public protocol PluginActionInputProviding: AnyObject {
    var actionInputDescriptors: [ActionInputDescriptor] { get }
    func prepareActionInput(_ descriptor: ActionInputDescriptor) async throws -> ActionInputSession
    func releaseActionInput(_ session: ActionInputSession)
}
