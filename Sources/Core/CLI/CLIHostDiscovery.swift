import Foundation

enum CLIHostDiscoveryError: Error, Equatable, LocalizedError {
    case timedOut

    var errorDescription: String? {
        "MacTools host discovery did not finish before the startup deadline."
    }
}

enum CLIHostRecoveryDecision: Equatable {
    case continueHandshake
    case launchExactHost
    case waitForReplacement
    case rejectBrokerVersion
    case rejectHostVersion
}

enum CLIHostRecoveryPolicy {
    static func decision(
        brokerMatches: Bool,
        hostMatches: Bool,
        launchAllowed: Bool,
        didLaunch: Bool
    ) -> CLIHostRecoveryDecision {
        if brokerMatches, hostMatches { return .continueHandshake }
        if launchAllowed, !didLaunch { return .launchExactHost }
        if didLaunch { return .waitForReplacement }
        return brokerMatches ? .rejectHostVersion : .rejectBrokerVersion
    }
}

struct CLIHostDiscovery: Sendable {
    typealias Locate = @Sendable (String, String, String) throws -> URL

    private let locate: Locate

    init(locator: CLIHostLocator) {
        locate = { bundleIdentifier, version, build in
            try locator.locate(
                bundleIdentifier: bundleIdentifier,
                version: version,
                build: build
            )
        }
    }

    init(locate: @escaping Locate) {
        self.locate = locate
    }

    func locate(
        bundleIdentifier: String,
        version: String,
        build: String,
        deadline: Date
    ) async throws -> URL {
        guard deadline.timeIntervalSinceNow > 0 else {
            throw CLIHostDiscoveryError.timedOut
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Result<URL, Error>.self)
        let worker = Task.detached { [locate] in
            let result = Result {
                try locate(bundleIdentifier, version, build)
            }
            continuation.yield(result)
            continuation.finish()
        }
        let timeout = Task {
            try? await Task.sleep(
                for: .seconds(max(0, deadline.timeIntervalSinceNow))
            )
            guard !Task.isCancelled else { return }
            continuation.yield(.failure(CLIHostDiscoveryError.timedOut))
            continuation.finish()
        }
        defer {
            worker.cancel()
            timeout.cancel()
        }

        return try await withTaskCancellationHandler {
            for await result in stream {
                try Task.checkCancellation()
                return try result.get()
            }
            try Task.checkCancellation()
            throw CLIHostDiscoveryError.timedOut
        } onCancel: {
            continuation.yield(.failure(CancellationError()))
            continuation.finish()
        }
    }
}
