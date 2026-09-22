import Foundation

enum AIUsageProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
    var symbol: String { self == .codex ? "terminal" : "sparkle" }
    var dashboardURL: URL {
        URL(string: self == .codex
            ? "https://chatgpt.com/codex/settings/usage"
            : "https://claude.ai/settings/usage")!
    }
}

struct AIUsageWindow: Equatable, Sendable, Identifiable {
    let id: String
    let usedPercent: Double
    let resetsAt: Date?
    let duration: TimeInterval?

    var fraction: Double { min(max(usedPercent / 100, 0), 1) }
    var remainingPercent: Double { (1 - fraction) * 100 }
}

struct AIUsageSnapshot: Equatable, Sendable {
    let windows: [AIUsageWindow]
    let plan: String?
    let fetchedAt: Date

    var highestUsage: Double? { windows.map(\.usedPercent).max() }
}

enum AIUsageFailure: Error, Equatable, Sendable {
    case signInRequired
    case unsupportedLogin
    case credentialUnreadable
    case keychainPermission
    case expired
    case network
    case rateLimited(retryAfter: TimeInterval)
    case server
    case invalidResponse

    var clearsSnapshot: Bool {
        switch self {
        case .signInRequired, .unsupportedLogin, .credentialUnreadable, .keychainPermission, .expired:
            true
        default:
            false
        }
    }
}

struct AIUsageProviderState: Equatable, Sendable {
    var snapshot: AIUsageSnapshot?
    var failure: AIUsageFailure?
    var credentialID: String?
    var nextRefresh = Date.distantPast
    var failureCount = 0

    func isStale(at date: Date, interval: TimeInterval) -> Bool {
        guard let snapshot else { return false }
        return failure != nil || date.timeIntervalSince(snapshot.fetchedAt) > max(2 * interval, 600)
            || snapshot.windows.contains { $0.resetsAt.map { $0 <= date } == true }
    }
}

struct AIUsagePreferences: Codable, Equatable, Sendable {
    var allowsCredentialAccess = false
    var allowsClaudeKeychain = false
    var codexEnabled = true
    var claudeEnabled = true
    var refreshInterval = 300
    var showsMenuBar = false

    static let refreshIntervals = [120, 300, 900, 1800]
    var enabledProviders: [AIUsageProvider] {
        AIUsageProvider.allCases.filter { $0 == .codex ? codexEnabled : claudeEnabled }
    }

    func canReadCredentials(for provider: AIUsageProvider) -> Bool {
        allowsCredentialAccess || (provider == .claude && allowsClaudeKeychain)
    }

    var queryableProviders: [AIUsageProvider] { enabledProviders.filter { canReadCredentials(for: $0) } }

    mutating func normalize() {
        if !Self.refreshIntervals.contains(refreshInterval) { refreshInterval = 300 }
    }
}

struct AIUsageFetchResult: Sendable {
    let credentialID: String?
    let result: Result<AIUsageSnapshot, AIUsageFailure>
}

protocol AIUsageFetching: Sendable {
    func fetch(_ provider: AIUsageProvider, allowsFileAccess: Bool, allowsKeychain: Bool) async -> AIUsageFetchResult
    func authorizeClaudeKeychain() async -> AIUsageFailure?
}
