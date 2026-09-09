import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class CommandPaletteInputModel: ObservableObject {
    @Published private(set) var item: ActionInputItem?
    @Published var message = ""
    @Published private(set) var destination = ""
    @Published private(set) var feedback: String?
    @Published private(set) var isBusy = false
    @Published var confirmationRequested = false
    private var prepared: PreparedActionInput?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var canSubmit: Bool {
        guard let item else { return false }
        return !isBusy && ActionInputRegistry.accepts(message, descriptor: item.descriptor)
    }

    func compose(_ item: ActionInputItem, message: String, registry: ActionInputRegistry) {
        reset()
        self.item = item
        self.message = message
        destination = item.descriptor.destination
        isBusy = true
        let generation = generation
        task = Task { @MainActor in
            do {
                let session = try await registry.prepare(item)
                guard self.generation == generation, !Task.isCancelled else { session.release(); return }
                prepared = session
                destination = session.session.destination
            } catch {
                guard self.generation == generation else { return }
                feedback = FeatureL10n.string("操作不可用，请返回后重试。")
            }
            isBusy = false
            task = nil
        }
    }

    func submit(
        _ item: ActionInputItem, message: String, host: PluginHost,
        approved: Bool = false, onStarted: @escaping @MainActor () -> Void
    ) {
        guard !isBusy, ActionInputRegistry.accepts(message, descriptor: item.descriptor) else { return }
        self.item = item
        self.message = message
        if item.definition.risk == .confirmationRequired && !approved {
            confirmationRequested = true
            return
        }
        isBusy = true
        feedback = nil
        let generation = generation
        task = Task { @MainActor in
            var owned = prepared
            prepared = nil
            do {
                if owned == nil { owned = try await host.actionInputRegistry.prepare(item) }
                guard let session = owned else { throw ActionInputError.invalidSession }
                guard generation == self.generation, !Task.isCancelled else { session.release(); return }
                guard session.session.destination == destination || destination.isEmpty else {
                    throw ActionInputError.invalidSession
                }
                let reference = try host.actionInputRegistry.reference(session, message: message)
                let confirmation: (any ActionConfirmationRequesting)? = approved
                    ? item.definition.confirmation.map {
                        MatchingApprovedActionConfirmationService(expectedRequest: ActionConfirmationRequest(
                            reference: reference, confirmation: $0, source: .unifiedSearch
                        ))
                    } : nil
                let start = await host.actionExecutor.startSurfaceIndependentTrackingCompletion(
                    ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground),
                    expectedDefinition: item.definition,
                    confirmationService: confirmation,
                    completionObserver: { _ in session.release() }
                )
                switch start.outcome {
                case .started:
                    owned = nil // The executor's completion observer owns the session now.
                    if item.definition.capabilities.contains(.reportsProgress) {
                        onStarted()
                    } else if let completion = start.completion {
                        for await outcome in completion {
                            guard generation == self.generation else { return }
                            feedback = ActionSurfaceExecutionSupport.feedback(for: outcome)
                            if feedback == nil { onStarted() }
                        }
                    }
                case .cancelled:
                    session.release()
                case let .rejected(reason):
                    session.release()
                    feedback = ActionSurfaceExecutionSupport.message(for: reason)
                }
            } catch {
                owned?.release()
                guard generation == self.generation else { return }
                feedback = FeatureL10n.string("操作不可用，请返回后重试。")
            }
            guard generation == self.generation else { return }
            isBusy = false
            task = nil
        }
    }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        prepared?.release()
        prepared = nil
        item = nil
        message = ""
        destination = ""
        feedback = nil
        isBusy = false
        confirmationRequested = false
    }
}
