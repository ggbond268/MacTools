import CryptoKit
import Foundation
import MacToolsCLIProtocol
import MacToolsPluginKit

enum CLIActionDiscoveryError: Error {
    case notReady
    case catalogTooLarge
    case staleCursor
    case invalidCursor
    case unknownTarget
}

/// The CLI never receives a registry reference, saved input, executor, or provider callback.
@MainActor
final class CLIActionDiscovery {
    static let surface = ActionExposureSurface(rawValue: "cli")
    private let registry: ActionRegistry
    private let workflows: () -> [WorkflowDefinition]
    private let instanceID = UUID().uuidString
    private(set) var isReady = false

    init(registry: ActionRegistry, workflows: @escaping () -> [WorkflowDefinition] = { [] }) {
        self.registry = registry
        self.workflows = workflows
    }

    func markReady() { isReady = true }

    func list(_ request: CLIActionListRequest) throws -> CLIActionPage {
        try CLIDiscoveryValidation.validate(request)
        let catalog = try snapshot()
        var offset = 0
        if let cursor = request.cursor {
            guard let parts = CLIDiscoveryValidation.cursorParts(cursor) else {
                throw CLIActionDiscoveryError.invalidCursor
            }
            guard parts.generation == catalog.generation else { throw CLIActionDiscoveryError.staleCursor }
            guard parts.offset < catalog.items.count else { throw CLIActionDiscoveryError.invalidCursor }
            offset = parts.offset
        }
        let end = min(offset + request.pageSize, catalog.items.count)
        let result = CLIActionPage(
            actions: catalog.items[offset..<end].map { CLIActionSummary(id: $0.record.id, title: $0.record.title) },
            generation: catalog.generation,
            nextCursor: end < catalog.items.count ? "\(catalog.generation).\(end)" : nil
        )
        try CLIDiscoveryValidation.validate(result, request: request)
        return result
    }

    func describe(_ request: CLIActionTargetRequest) throws -> CLIActionDescription {
        try target(request).record
    }

    func availability(_ request: CLIActionTargetRequest) throws -> CLIActionAvailability {
        let item = try target(request)
        let available = registry.availability(for: item.reference).isAvailable
        // Provider messages can interpolate saved inputs or paths. Export a stable reason code only.
        return CLIActionAvailability(id: item.record.id, available: available,
                                     reason: available ? nil : .providerUnavailable)
    }

    private struct Item {
        let reference: ActionReference
        let record: CLIActionDescription
        let revision: String
    }

    private func target(_ request: CLIActionTargetRequest) throws -> Item {
        try CLIDiscoveryValidation.validate(request)
        guard let item = try snapshot().items.first(where: { $0.record.id == request.id }) else {
            throw CLIActionDiscoveryError.unknownTarget
        }
        return item
    }

    private func snapshot() throws -> (items: [Item], generation: String) {
        guard isReady else { throw CLIActionDiscoveryError.notReady }
        guard registry.catalogEntries.count <= CLIDiscoveryLimits.maximumCatalogSize else {
            throw CLIActionDiscoveryError.catalogTooLarge
        }
        let definitions = workflows()
        guard definitions.count <= CLIDiscoveryLimits.maximumCatalogSize else {
            throw CLIActionDiscoveryError.catalogTooLarge
        }
        let byID = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [Item] = []
        // A shared traversal budget bounds work even when many workflows share a large graph.
        var budget = CLIDiscoveryLimits.maximumCatalogSize * 8
        for entry in registry.catalogEntries {
            guard eligible(entry.reference, workflows: byID, visiting: [], depth: 0, budget: &budget),
                  case let .success(action) = registry.registeredAction(for: entry.reference) else { continue }
            let definition = action.definition
            let parameters = definition.parameters.compactMap { parameter -> CLIActionParameter? in
                guard let kind = CLIActionParameter.Kind(rawValue: parameter.kind.rawValue),
                      let privacy = CLIActionParameter.Privacy(rawValue: parameter.privacy.rawValue),
                      let portability = CLIActionParameter.Portability(rawValue: parameter.portability.rawValue)
                else { return nil }
                return CLIActionParameter(id: parameter.id, kind: kind, isRequired: parameter.isRequired,
                                          privacy: privacy, portability: portability)
            }
            guard parameters.count == definition.parameters.count else { continue }
            let id = try identifier(entry.reference)
            // Definition-level copy, not preset titles/subtitles that may contain saved values.
            let record = CLIActionDescription(id: id, title: sanitized(definition.title),
                                              description: sanitized(definition.description),
                                              parameterSchemaVersion: definition.parameterSchemaVersion,
                                              parameters: parameters)
            guard (try? CLIDiscoveryValidation.validate(record, id: id)) != nil else { continue }
            items.append(Item(reference: entry.reference, record: record,
                              revision: "\(action.providerGeneration):\(action.providerExecutionRevision)"))
        }
        guard budget >= 0 else { throw CLIActionDiscoveryError.catalogTooLarge }
        items.sort { $0.record.id < $1.record.id }
        guard Set(items.map { $0.record.id }).count == items.count else {
            throw CLIActionDiscoveryError.catalogTooLarge
        }
        var digest = SHA256()
        digest.update(data: Data(instanceID.utf8))
        for item in items {
            digest.update(data: try CLIProtocolCodec.encodeResponse(item.record))
            digest.update(data: Data(item.revision.utf8))
        }
        return (items, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func eligible(_ reference: ActionReference, workflows: [UUID: WorkflowDefinition],
                          visiting: Set<UUID>, depth: Int, budget: inout Int) -> Bool {
        budget -= 1
        guard budget >= 0,
              case let .success(action) = registry.registeredAction(for: reference),
              action.catalogEntry != nil,
              action.definition.risk == .safe,
              action.definition.capabilities.contains([.background, .automatic]),
              registry.portability(of: reference) == .portable,
              registry.exposurePolicy(for: reference, on: Self.surface) == .automatic else { return false }
        guard reference.key.providerID == AutomationController.providerID else { return true }
        guard depth < WorkflowExecutionLimits.maximumDepth,
              let id = WorkflowExecutionAnalysis.nestedWorkflowID(for: reference.key),
              !visiting.contains(id), let workflow = workflows[id], workflow.isEnabled,
              !workflow.steps.isEmpty, workflow.steps.count <= CLIDiscoveryLimits.maximumCatalogSize else { return false }
        var next = visiting
        next.insert(id)
        return workflow.steps.allSatisfy {
            eligible($0.reference, workflows: workflows, visiting: next, depth: depth + 1, budget: &budget)
        }
    }

    private func identifier(_ reference: ActionReference) throws -> String {
        guard !reference.parameters.entries.isEmpty else { return reference.key.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(reference)).map { String(format: "%02x", $0) }.joined()
        return "\(reference.key.id)@\(digest)"
    }

    private func sanitized(_ value: String) -> String {
        var result = ""
        var bytes = 0
        for scalar in value.unicodeScalars.prefix(CLIDiscoveryLimits.maximumTextBytes * 2) {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            let count = scalar.utf8.count
            guard bytes + count <= CLIDiscoveryLimits.maximumTextBytes else { break }
            result.unicodeScalars.append(scalar)
            bytes += count
        }
        return result
    }
}
