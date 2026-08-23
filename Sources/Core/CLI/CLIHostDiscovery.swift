import Foundation

struct CLIStartupDeadline: Sendable {
    typealias Now = @Sendable () -> ContinuousClock.Instant
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let instant: ContinuousClock.Instant
    private let now: Now
    private let sleep: Sleep

    init(duration: Duration) {
        let clock = ContinuousClock()
        self.init(
            duration: duration,
            now: { clock.now },
            sleep: { try await clock.sleep(for: $0) }
        )
    }

    init(
        duration: Duration,
        now: @escaping Now,
        sleep: @escaping Sleep
    ) {
        instant = now().advanced(by: duration)
        self.now = now
        self.sleep = sleep
    }

    var isExpired: Bool { now() >= instant }

    var remaining: Duration {
        let value = now().duration(to: instant)
        return value > .zero ? value : .zero
    }

    var remainingTimeInterval: TimeInterval {
        let components = remaining.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func sleepUntilExpired() async throws {
        let delay = remaining
        if delay > .zero { try await sleep(delay) }
    }

    func sleep(upTo maximum: Duration) async throws {
        let delay = min(maximum, remaining)
        if delay > .zero { try await sleep(delay) }
    }
}

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
        deadline: CLIStartupDeadline
    ) async throws -> URL {
        guard !deadline.isExpired else {
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
            try? await deadline.sleepUntilExpired()
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
