import Darwin
import Foundation

enum MacToolsAppIntentCircuitBreakerAdmission: Equatable, Sendable {
    case admitted
    case rateLimited
    case unavailable
}

protocol MacToolsAppIntentCircuitBreaking: Sendable {
    func admitInvocation(
        actionIdentifier: String
    ) async -> MacToolsAppIntentCircuitBreakerAdmission
}

actor MacToolsAppIntentCircuitBreaker: MacToolsAppIntentCircuitBreaking {
    static let shared = MacToolsAppIntentCircuitBreaker()

    private struct State: Codable {
        var invocationDatesByAction: [String: [Date]]
        var globalInvocationDates: [Date]
    }

    private static let defaultWindow: TimeInterval = 10
    private static let defaultMaximumInvocationCountPerAction = 8
    private static let defaultMaximumGlobalInvocationCount = 64
    private static let futureDateTolerance: TimeInterval = 1

    private let stateURL: URL
    private let lockURL: URL
    private let window: TimeInterval
    private let maximumInvocationCountPerAction: Int
    private let maximumGlobalInvocationCount: Int
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    init(
        stateURL: URL = MacToolsAppIntentCircuitBreaker.defaultStateURL(),
        window: TimeInterval = defaultWindow,
        maximumInvocationCountPerAction: Int = defaultMaximumInvocationCountPerAction,
        maximumGlobalInvocationCount: Int = defaultMaximumGlobalInvocationCount,
        now: @escaping @Sendable () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        precondition(window > 0)
        precondition(maximumInvocationCountPerAction > 0)
        precondition(maximumGlobalInvocationCount >= maximumInvocationCountPerAction)
        self.stateURL = stateURL
        lockURL = stateURL.appendingPathExtension("lock")
        self.window = window
        self.maximumInvocationCountPerAction = maximumInvocationCountPerAction
        self.maximumGlobalInvocationCount = maximumGlobalInvocationCount
        self.now = now
        self.fileManager = fileManager
    }

    func admitInvocation(
        actionIdentifier: String
    ) async -> MacToolsAppIntentCircuitBreakerAdmission {
        guard !actionIdentifier.isEmpty else { return .unavailable }
        let currentDate = now()
        let directoryURL = stateURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            AppLog.appIntents.error("Could not create circuit-breaker storage: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            AppLog.appIntents.error("Could not open circuit-breaker lock: errno \(errno)")
            return .unavailable
        }
        defer { Darwin.close(descriptor) }
        guard await acquireLock(descriptor) else { return .unavailable }
        defer { flock(descriptor, LOCK_UN) }

        var state: State
        if fileManager.fileExists(atPath: stateURL.path) {
            guard let data = try? Data(contentsOf: stateURL),
                  let decoded = try? JSONDecoder().decode(State.self, from: data)
            else {
                _ = persist(State(
                    invocationDatesByAction: [actionIdentifier: [currentDate]],
                    globalInvocationDates: [currentDate]
                ))
                AppLog.appIntents.error("Circuit-breaker state was unreadable and has been reset")
                return .unavailable
            }
            state = decoded
        } else {
            state = State(invocationDatesByAction: [:], globalInvocationDates: [])
        }

        let cutoff = currentDate.addingTimeInterval(-window)
        let futureLimit = currentDate.addingTimeInterval(Self.futureDateTolerance)
        state.globalInvocationDates.removeAll { $0 <= cutoff || $0 > futureLimit }
        for identifier in Array(state.invocationDatesByAction.keys) {
            state.invocationDatesByAction[identifier]?.removeAll {
                $0 <= cutoff || $0 > futureLimit
            }
            if state.invocationDatesByAction[identifier]?.isEmpty == true {
                state.invocationDatesByAction.removeValue(forKey: identifier)
            }
        }

        let actionInvocationDates = state.invocationDatesByAction[actionIdentifier] ?? []
        guard actionInvocationDates.count < maximumInvocationCountPerAction,
              state.globalInvocationDates.count < maximumGlobalInvocationCount else {
            _ = persist(state)
            return .rateLimited
        }

        state.invocationDatesByAction[actionIdentifier, default: []].append(currentDate)
        state.globalInvocationDates.append(currentDate)
        return persist(state) ? .admitted : .unavailable
    }

    private func acquireLock(_ descriptor: Int32) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !Task.isCancelled {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return true
            }
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EINTR else {
                AppLog.appIntents.error("Could not acquire circuit-breaker lock: errno \(lockError)")
                return false
            }
            guard clock.now < deadline else {
                AppLog.appIntents.error("Timed out acquiring circuit-breaker lock")
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        AppLog.appIntents.debug("Cancelled while waiting for the circuit-breaker lock")
        return false
    }

    private func persist(_ state: State) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try data.write(to: stateURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: stateURL.path
            )
            return true
        } catch {
            AppLog.appIntents.error("Could not persist circuit-breaker state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func defaultStateURL(fileManager: FileManager = .default) -> URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "cc.ggbond.MacTools"
        return applicationSupportURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("AppIntents", isDirectory: true)
            .appendingPathComponent("invocation-circuit-breaker.json")
    }
}
