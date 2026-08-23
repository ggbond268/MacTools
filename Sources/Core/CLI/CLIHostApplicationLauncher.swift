import AppKit
import Foundation

enum CLIHostApplicationLaunchError: Error, Equatable, LocalizedError {
    case timedOut
    case noRunningApplication
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Launch Services did not finish opening MacTools before the startup deadline."
        case .noRunningApplication:
            return "Launch Services did not return a running MacTools application."
        case let .failed(message):
            return "Launch Services failed to open MacTools: \(message)"
        }
    }
}

struct CLIHostApplicationLauncher {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void
    typealias OpenApplication = (
        URL,
        NSWorkspace.OpenConfiguration,
        @escaping Completion
    ) -> Void

    private let openApplication: OpenApplication

    init(workspace: NSWorkspace = .shared) {
        openApplication = { applicationURL, configuration, completion in
            workspace.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    completion(.failure(CLIHostApplicationLaunchError.failed(
                        error.localizedDescription
                    )))
                } else if application == nil {
                    completion(.failure(CLIHostApplicationLaunchError.noRunningApplication))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    init(openApplication: @escaping OpenApplication) {
        self.openApplication = openApplication
    }

    func launch(applicationURL: URL, deadline: CLIStartupDeadline) async throws {
        guard !deadline.isExpired else { throw CLIHostApplicationLaunchError.timedOut }
        let (stream, continuation) = AsyncStream.makeStream(of: Result<Void, Error>.self)
        openApplication(applicationURL, Self.makeOpenConfiguration()) { result in
            continuation.yield(result)
            continuation.finish()
        }
        let timeoutTask = Task {
            try? await deadline.sleepUntilExpired()
            guard !Task.isCancelled else { return }
            continuation.yield(.failure(CLIHostApplicationLaunchError.timedOut))
            continuation.finish()
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            for await result in stream {
                try Task.checkCancellation()
                return try result.get()
            }
            try Task.checkCancellation()
            throw CLIHostApplicationLaunchError.noRunningApplication
        } onCancel: {
            continuation.yield(.failure(CancellationError()))
            continuation.finish()
        }
    }

    static func makeOpenConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }
}
