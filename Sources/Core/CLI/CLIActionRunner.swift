import Foundation
import MacToolsCLIProtocol
import MacToolsPluginKit

enum CLIActionRunError: Error {
    case unavailable
    case busy
    case timedOut
    case failed
    case eligibilityChanged
}

@MainActor
final class CLIActionRunner {
    private let discovery: CLIActionDiscovery
    private let executor: ActionExecutor

    init(discovery: CLIActionDiscovery, executor: ActionExecutor) {
        self.discovery = discovery
        self.executor = executor
    }

    func run(
        _ request: CLIActionRunRequest,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> CLIActionRunResult {
        try CLIExecutionValidation.validate(request)
        let deadline = deadline ?? ContinuousClock.now.advanced(
            by: .seconds(request.timeoutSeconds)
        )
        guard ContinuousClock.now < deadline else { throw CLIActionRunError.timedOut }
        let target = try discovery.executionTarget(request)
        let invocation = ActionInvocation(
            reference: target.reference,
            source: .cli,
            mode: .background
        )
        switch await executor.executeForCLI(
            invocation,
            expectedDefinition: target.definition,
            deadline: deadline
        ) {
        case let .completed(.succeeded(message)):
            return CLIActionRunResult(
                id: request.id,
                message: message.map(Self.sanitized)
            )
        case .completed(.cancelled):
            throw CancellationError()
        case .completed(.failed):
            throw CLIActionRunError.failed
        case let .rejected(rejection):
            switch rejection {
            case .unavailable:
                throw CLIActionRunError.unavailable
            case .actionAlreadyRunning:
                throw CLIActionRunError.busy
            case .executionTimedOut:
                throw CLIActionRunError.timedOut
            case .unknownAction:
                throw CLIActionDiscoveryError.unknownTarget
            case .providerFailure:
                throw CLIActionRunError.failed
            default:
                throw CLIActionRunError.eligibilityChanged
            }
        }
    }

    private static func sanitized(_ value: String) -> String {
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
