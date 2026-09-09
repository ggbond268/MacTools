import Foundation
import MacToolsPluginKit

@MainActor
final class SiriController {
    private let client: any SiriClient
    private(set) var phase: SiriPhase = .idle
    private(set) var failure: SiriFailure?
    private(set) var isBusy = false
    private var operation: Task<ActionExecutionResult, Never>?
    var onChange: (() -> Void)?

    init(client: any SiriClient) { self.client = client }

    func start(_ message: String) -> ActionExecutionHandle? {
        guard !isBusy, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= ActionParameterSet.maximumStringByteCount else { return nil }
        isBusy = true
        failure = nil
        phase = .opening
        onChange?()
        let task = Task { @MainActor [self] in await run(message) }
        operation = task
        return ActionExecutionHandle(operation: { await task.value }, cancel: { [weak self] in self?.cancel() })
    }

    func cancel() { operation?.cancel() }

    private func setPhase(_ phase: SiriPhase) { self.phase = phase; onChange?() }

    private func run(_ message: String) async -> ActionExecutionResult {
        var submitted = false
        do {
            try Task.checkCancellation()
            setPhase(.preparing)
            try await client.prepareNewConversation()
            try Task.checkCancellation()
            setPhase(.entering)
            try await client.enter(message)
            try Task.checkCancellation()
            setPhase(.submitting)
            // An error or cancellation at this boundary can no longer justify a retry.
            submitted = true
            try await client.submit(message)
            setPhase(.verifying)
            try await client.verify(message)
            setPhase(.sent)
        } catch {
            if submitted {
                failure = .submissionUncertain
                setPhase(.uncertain)
            } else if Task.isCancelled {
                setPhase(.cancelled)
            } else {
                failure = error as? SiriFailure ?? .unavailable
                setPhase(.failed)
            }
        }
        await client.finish()
        isBusy = false
        operation = nil
        onChange?()
        if phase == .sent { return .succeeded() }
        if phase == .cancelled { return .cancelled }
        // The plugin renders localized, specific feedback from its snapshot.
        return .failed(message: "Siri")
    }
}
