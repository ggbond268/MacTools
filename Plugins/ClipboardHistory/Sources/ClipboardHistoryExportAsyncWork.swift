import Foundation

enum ClipboardHistoryExportAsyncWork {
    static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Runs a staged filesystem commit without turning a successful commit into a cancellation.
    /// The operation must check cancellation immediately before its irreversible commit point.
    static func runCommitting<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

@MainActor
final class ClipboardHistoryExportOperationRegistry {
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var entry: Entry?

    var isIdle: Bool { entry == nil }

    @discardableResult
    func install(id: UUID, task: Task<Void, Never>) -> Bool {
        guard entry == nil else { return false }
        entry = Entry(id: id, task: task)
        return true
    }

    func cancel() {
        let task = entry?.task
        entry = nil
        task?.cancel()
    }

    func finish(id: UUID) {
        guard entry?.id == id else { return }
        entry = nil
    }
}
