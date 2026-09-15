import Foundation
import MacToolsPluginKit

struct ActionInputItem: Hashable, Identifiable {
    let descriptor: ActionInputDescriptor
    let definition: ActionDefinition
    let generation: UUID
    var id: ActionKey { descriptor.key }
}

enum ActionInputError: Error {
    case unavailable, invalidInput, invalidSession
}

@MainActor
final class ActionInputRegistry {
    private struct Registration {
        let item: ActionInputItem
        let identity: ObjectIdentifier
        let provider: any PluginActionInputProviding
    }
    private let preparationTimeout: Duration
    init(preparationTimeout: Duration = .seconds(10)) { self.preparationTimeout = preparationTimeout }
    private var registrations: [ActionKey: Registration] = [:]
    private(set) var items: [ActionInputItem] = []

    func synchronize(
        _ plugins: [any MacToolsPlugin],
        readDescriptors: ((any MacToolsPlugin) -> [ActionInputDescriptor])? = nil,
        definitionLookup: ((ActionKey) -> ActionDefinition?)? = nil
    ) {
        var next: [ActionKey: Registration] = [:]
        for plugin in plugins {
            guard let input = plugin as? any PluginActionInputProviding,
                  let actions = plugin as? any PluginActionProviding else { continue }
            for descriptor in readDescriptors?(plugin) ?? input.actionInputDescriptors {
                guard descriptor.key.providerID == plugin.metadata.id,
                      let definition = definitionLookup.map({ $0(descriptor.key) }) ?? actions.actionDefinitions.first(where: { $0.key == descriptor.key }),
                      Self.isValid(descriptor, for: definition), next[descriptor.key] == nil else { continue }
                let previous = registrations[descriptor.key]
                let identity = ObjectIdentifier(plugin)
                let generation = previous?.identity == identity
                    && previous?.item.descriptor == descriptor && previous?.item.definition == definition
                    ? previous!.item.generation : UUID()
                next[descriptor.key] = Registration(
                    item: ActionInputItem(descriptor: descriptor, definition: definition, generation: generation),
                    identity: identity, provider: input
                )
            }
        }
        registrations = next
        items = next.values.map(\.item).sorted { $0.id.id < $1.id.id }
    }

    static func isValid(_ descriptor: ActionInputDescriptor, for definition: ActionDefinition) -> Bool {
        guard descriptor.key == definition.key, descriptor.schemaVersion == definition.parameterSchemaVersion,
              descriptor.maximumUTF8Bytes > 0,
              descriptor.maximumUTF8Bytes <= ActionParameterSet.maximumStringByteCount,
              !descriptor.destination.isEmpty, !descriptor.submitTitle.isEmpty,
              let parameter = definition.parameters.first(where: { $0.id == descriptor.parameterID }),
              parameter.kind == .string, parameter.isRequired,
              parameter.privacy == .sensitive, parameter.portability == .localOnly else { return false }
        return true
    }

    func contains(_ item: ActionInputItem) -> Bool { registrations[item.id]?.item == item }

    func prepare(_ item: ActionInputItem) async throws -> PreparedActionInput {
        guard let registration = registrations[item.id], registration.item == item else {
            throw ActionInputError.unavailable
        }
        let waiter = InputPreparationWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.begin(continuation)
                guard !waiter.isFinished else { return }
                waiter.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: self.preparationTimeout) } catch { return }
                    waiter.fail(ActionInputError.unavailable)
                }
                waiter.operation = Task { @MainActor [weak self] in
                    do {
                        let session = try await registration.provider.prepareActionInput(item.descriptor)
                        let prepared = PreparedActionInput(item: item, session: session, provider: registration.provider)
                        let probe = try? ActionParameterSet(entries: session.parameters.entries + [
                            .init(name: item.descriptor.parameterID, value: .string("validation")),
                        ])
                        guard !waiter.isFinished, !Task.isCancelled, self?.contains(item) == true,
                              let probe, !session.destination.isEmpty,
                              ActionRegistry.parameterValidationFailure(probe, for: item.definition) == nil else {
                            prepared.release()
                            waiter.fail(ActionInputError.invalidSession)
                            return
                        }
                        waiter.succeed(prepared)
                    } catch { waiter.fail(error) }
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.fail(CancellationError()) }
        }
    }

    func reference(_ prepared: PreparedActionInput, message: String) throws -> ActionReference {
        guard contains(prepared.item), !prepared.isReleased,
              Date().timeIntervalSince(prepared.createdAt) < 300 else { throw ActionInputError.unavailable }
        guard Self.accepts(message, descriptor: prepared.item.descriptor) else { throw ActionInputError.invalidInput }
        let parameters = try ActionParameterSet(entries: prepared.session.parameters.entries + [
            .init(name: prepared.item.descriptor.parameterID, value: .string(message)),
        ])
        guard ActionRegistry.parameterValidationFailure(parameters, for: prepared.item.definition) == nil else {
            throw ActionInputError.invalidSession
        }
        return ActionReference(key: prepared.item.id, schemaVersion: prepared.item.descriptor.schemaVersion, parameters: parameters)
    }

    static func accepts(_ message: String, descriptor: ActionInputDescriptor) -> Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && message.utf8.count <= descriptor.maximumUTF8Bytes
    }
}

@MainActor
final class PreparedActionInput {
    let item: ActionInputItem
    let session: ActionInputSession
    let createdAt = Date()
    private let provider: any PluginActionInputProviding
    private(set) var isReleased = false

    init(item: ActionInputItem, session: ActionInputSession, provider: any PluginActionInputProviding) {
        self.item = item
        self.session = session
        self.provider = provider
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        provider.releaseActionInput(session)
    }
}

@MainActor
private final class InputPreparationWaiter {
    var operation: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<PreparedActionInput, Error>?
    private(set) var isFinished = false

    func begin(_ continuation: CheckedContinuation<PreparedActionInput, Error>) {
        guard !isFinished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
    }
    func succeed(_ value: PreparedActionInput) {
        guard !isFinished else { value.release(); return }
        isFinished = true
        timeout?.cancel()
        continuation?.resume(returning: value)
        continuation = nil
        operation = nil
        timeout = nil
    }
    func fail(_ error: Error) {
        guard !isFinished else { return }
        isFinished = true
        operation?.cancel()
        timeout?.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
        operation = nil
        timeout = nil
    }
}
