import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class AIUsageViewModel: ObservableObject {
    @Published private(set) var preferences: AIUsagePreferences
    @Published private(set) var states: [AIUsageProvider: AIUsageProviderState] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizingKeychain = false
    @Published private(set) var keychainAccessFailure: AIUsageFailure?
    @Published var panelVisible = false
    var onChange: (() -> Void)?
    var onPresentationTick: (() -> Void)?

    private let storage: any PluginStorage
    private let client: any AIUsageFetching
    private let now: () -> Date
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var authorizationTask: Task<Void, Never>?
    private var authorizationGeneration = 0
    private var isActive = false
    private var activityAllowsWork = true
    private var lastAttempts: [AIUsageProvider: Date] = [:]
    static let preferencesKey = "preferences.v1"

    init(storage: any PluginStorage, client: any AIUsageFetching = AIUsageClient(), now: @escaping () -> Date = Date.init) {
        self.storage = storage
        self.client = client
        self.now = now
        var preferences = storage.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(AIUsagePreferences.self, from: $0) } ?? AIUsagePreferences()
        preferences.normalize()
        self.preferences = preferences
    }

    func start() {
        isActive = true
        resume()
    }

    func stop() {
        isActive = false
        cancelWork()
        cancelAuthorization()
        states = [:]
        lastAttempts = [:]
        panelVisible = false
        onChange?()
    }

    func setActivity(_ state: PluginApplicationActivityState) {
        activityAllowsWork = state.allowsBackgroundWork
        if activityAllowsWork { resume() } else { cancelWork() }
    }

    func updatePreferences(_ update: (inout AIUsagePreferences) -> Void) {
        let previous = preferences
        var next = previous
        update(&next)
        next.normalize()
        guard previous != next else { return }
        preferences = next
        if let data = try? JSONEncoder().encode(next) { storage.set(data, forKey: Self.preferencesKey) }
        let accessChanged = previous.allowsCredentialAccess != next.allowsCredentialAccess
            || previous.allowsClaudeKeychain != next.allowsClaudeKeychain
            || previous.enabledProviders != next.enabledProviders
        if accessChanged {
            cancelWork()
            for provider in AIUsageProvider.allCases {
                let sourceChanged = previous.allowsCredentialAccess != next.allowsCredentialAccess
                    || (provider == .claude && previous.allowsClaudeKeychain != next.allowsClaudeKeychain)
                if sourceChanged || !next.queryableProviders.contains(provider) {
                    // Keep server backoff across display and permission changes.
                    if var state = states[provider], case .rateLimited = state.failure {
                        state.snapshot = nil
                        state.credentialID = nil
                        states[provider] = state
                    } else {
                        states[provider] = nil
                        if sourceChanged { lastAttempts[provider] = nil }
                    }
                }
            }
        }
        if previous.refreshInterval != next.refreshInterval {
            for provider in next.enabledProviders {
                guard states[provider]?.failure == nil, let snapshot = states[provider]?.snapshot else { continue }
                states[provider]?.nextRefresh = snapshot.fetchedAt.addingTimeInterval(Double(next.refreshInterval))
            }
        }
        onChange?()
        resume()
    }

    func setClaudeKeychainAccess(_ allowed: Bool) {
        guard allowed != preferences.allowsClaudeKeychain else { return }
        cancelAuthorization()
        keychainAccessFailure = nil
        isAuthorizingKeychain = allowed && isActive && activityAllowsWork
        updatePreferences { $0.allowsClaudeKeychain = allowed }
        guard isAuthorizingKeychain else { return }
        let generation = authorizationGeneration
        let client = client
        authorizationTask = Task { [weak self] in
            let failure = await client.authorizeClaudeKeychain()
            guard let self, !Task.isCancelled, generation == self.authorizationGeneration else { return }
            self.keychainAccessFailure = failure
            self.isAuthorizingKeychain = false
            self.authorizationTask = nil
            self.onChange?()
            self.resume()
        }
    }

    func refresh(manual: Bool = false) {
        guard isActive, activityAllowsWork, task == nil else { return }
        let date = now()
        let providers = preferences.queryableProviders.filter { provider in
            if provider == .claude && isAuthorizingKeychain { return false }
            let state = states[provider] ?? AIUsageProviderState()
            if case .rateLimited = state.failure, date < state.nextRefresh { return false }
            if let last = lastAttempts[provider], date.timeIntervalSince(last) < 60 { return false }
            return manual || date >= state.nextRefresh
        }
        guard !providers.isEmpty else { return }
        for provider in providers { lastAttempts[provider] = date }
        isRefreshing = true
        onChange?()
        let generation = generation
        let client = client
        let allowsKeychain = preferences.allowsClaudeKeychain
        let allowsFileAccess = preferences.allowsCredentialAccess
        task = Task { [weak self] in
            let results = await withTaskGroup(of: (AIUsageProvider, AIUsageFetchResult).self) { group in
                for provider in providers {
                    group.addTask {
                        (provider, await client.fetch(provider, allowsFileAccess: allowsFileAccess, allowsKeychain: allowsKeychain))
                    }
                }
                var results: [(AIUsageProvider, AIUsageFetchResult)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            for (provider, result) in results { self.apply(result, for: provider) }
            self.task = nil
            self.isRefreshing = false
            self.onChange?()
        }
    }

    private func apply(_ fetched: AIUsageFetchResult, for provider: AIUsageProvider) {
        var state = states[provider] ?? AIUsageProviderState()
        if let identity = fetched.credentialID, identity != state.credentialID { state.snapshot = nil }
        state.credentialID = fetched.credentialID
        switch fetched.result {
        case let .success(snapshot):
            state.snapshot = snapshot
            state.failure = nil
            state.failureCount = 0
            state.nextRefresh = now().addingTimeInterval(Double(preferences.refreshInterval))
        case let .failure(error):
            state.failure = error
            state.failureCount = min(state.failureCount + 1, 6)
            if error.clearsSnapshot { state.snapshot = nil }
            let delay: TimeInterval
            if case let .rateLimited(retryAfter) = error {
                delay = max(600, retryAfter)
            } else {
                delay = min(1800, 60 * pow(2, Double(state.failureCount - 1)))
            }
            state.nextRefresh = now().addingTimeInterval(delay)
        }
        states[provider] = state
    }

    private func resume() {
        guard isActive, activityAllowsWork, !preferences.queryableProviders.isEmpty else { return }
        installTimer()
        refresh()
    }

    private func installTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onPresentationTick?()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelAuthorization() {
        authorizationGeneration += 1
        authorizationTask?.cancel()
        authorizationTask = nil
        isAuthorizingKeychain = false
    }

    private func cancelWork() {
        generation += 1
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        isRefreshing = false
    }
}
