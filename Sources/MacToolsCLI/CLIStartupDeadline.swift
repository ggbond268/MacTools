import Foundation

struct CLIStartupDeadline {
    let instant: ContinuousClock.Instant

    init(
        timeout: Duration,
        now: ContinuousClock.Instant = .now
    ) {
        instant = now.advanced(by: timeout)
    }

    init(instant: ContinuousClock.Instant) {
        self.instant = instant
    }

    func cappedInstant(
        upTo maximum: Duration,
        reserving reserve: Duration = .zero,
        now: ContinuousClock.Instant = .now
    ) -> ContinuousClock.Instant? {
        guard reserve >= .zero else { return nil }
        let operationDeadline = instant.advanced(by: .zero - reserve)
        guard now < operationDeadline else { return nil }
        return min(operationDeadline, now.advanced(by: maximum))
    }
}

struct CLIRequestDeadlinePlan {
    let requestDeadline: CLIStartupDeadline
    let startupDeadline: CLIStartupDeadline
    let responseBudget: Duration
}

struct CLIRequestDeadlinePolicy {
    func makePlan(
        responseTimeoutSeconds: Int?,
        now: ContinuousClock.Instant = .now
    ) -> CLIRequestDeadlinePlan {
        let responseBudget = responseTimeoutSeconds.map { Duration.seconds($0 + 1) }
            ?? .seconds(10)
        let requestDeadline = CLIStartupDeadline(timeout: responseBudget, now: now)
        let startupDeadline = CLIStartupDeadline(
            instant: min(requestDeadline.instant, now.advanced(by: .seconds(10)))
        )
        return CLIRequestDeadlinePlan(
            requestDeadline: requestDeadline,
            startupDeadline: startupDeadline,
            responseBudget: responseBudget
        )
    }
}

struct CLIRequestCleanupPolicy {
    let budget: Duration

    func responseDeadline(
        within deadline: CLIStartupDeadline,
        maximumWait: Duration,
        now: ContinuousClock.Instant = .now
    ) -> ContinuousClock.Instant? {
        deadline.cappedInstant(upTo: maximumWait, reserving: budget, now: now)
    }

    func performCleanup(
        within deadline: CLIStartupDeadline,
        now: ContinuousClock.Instant = .now,
        cancel: (ContinuousClock.Instant) async -> Void,
        invalidate: () -> Void
    ) async {
        defer { invalidate() }
        guard let cleanupDeadline = deadline.cappedInstant(upTo: budget, now: now) else {
            return
        }
        await cancel(cleanupDeadline)
    }
}

struct CLIConnectionLifecyclePolicy {
    func preserveConnectionOnSuccess<Value>(
        operation: () async throws -> Value,
        invalidate: () -> Void
    ) async rethrows -> Value {
        do {
            return try await operation()
        } catch {
            invalidate()
            throw error
        }
    }
}
