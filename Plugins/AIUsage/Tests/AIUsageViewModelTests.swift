import AppKit
import MacToolsPluginKit
import SwiftUI
import XCTest
@testable import AIUsagePlugin

@MainActor
final class AIUsageViewModelTests: XCTestCase {
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    func testConsentGatePreventsCredentialAndNetworkWork() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        model.start()
        model.refresh(manual: true)
        await settle(model)
        let count = await client.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.states.isEmpty)
        model.stop()
    }

    func testManualRefreshCoalescesAndEnforcesMinimumInterval() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        model.refresh(manual: true)
        model.refresh(manual: true)
        await settle(model)
        var count = await client.count
        XCTAssertEqual(count, 1)
        model.refresh(manual: true)
        await settle(model)
        count = await client.count
        XCTAssertEqual(count, 1)
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        count = await client.count
        XCTAssertEqual(count, 2)
        model.stop()
    }

    func testNetworkFailureRetainsSnapshotAndRateLimitCannotBeBypassed() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        let first = model.states[.codex]?.snapshot
        await client.setResult(.failure(.network))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        XCTAssertEqual(model.states[.codex]?.snapshot, first)
        XCTAssertEqual(model.states[.codex]?.failure, .network)
        await client.setResult(.failure(.rateLimited(retryAfter: 900)))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        let count = await client.count
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        let after = await client.count
        XCTAssertEqual(count, after)
        XCTAssertEqual(model.states[.codex]?.snapshot, first)
        model.stop()
    }

    func testChangedAccountAndExpiredLoginClearPreviousSnapshot() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        XCTAssertNotNil(model.states[.codex]?.snapshot)
        await client.setIdentity("new-account")
        await client.setResult(.failure(.network))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        XCTAssertNil(model.states[.codex]?.snapshot)
        await client.setResult(.failure(.expired))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        XCTAssertNil(model.states[.codex]?.snapshot)
        XCTAssertEqual(model.states[.codex]?.failure, .expired)
        model.stop()
    }

    func testSleepingStopsRequestsAndWakeRefreshesDueData() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        model.setActivity(.systemSleeping)
        date.addTimeInterval(600)
        model.refresh(manual: true)
        await settle(model)
        var count = await client.count
        XCTAssertEqual(count, 1)
        model.setActivity(.interactive)
        await settle(model)
        count = await client.count
        XCTAssertEqual(count, 2)
        model.stop()
    }

    func testRevokingAccessCancelsWorkAndErasesInMemoryUsage() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        enable(model)
        await settle(model)
        date.addTimeInterval(61)
        model.refresh(manual: true)
        model.updatePreferences { $0.allowsCredentialAccess = false }
        await settle(model)
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertFalse(model.isRefreshing)
        XCTAssertFalse(model.preferences.allowsClaudeKeychain)
        model.stop()
    }

    func testDisablingProviderClearsSnapshotWithoutRevokingAccess() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        model.updatePreferences { $0.allowsCredentialAccess = true }
        model.start()
        await settle(model)
        model.updatePreferences { $0.codexEnabled = false }
        XCTAssertNil(model.states[.codex])
        XCTAssertTrue(model.preferences.allowsCredentialAccess)
        XCTAssertNotNil(model.states[.claude]?.snapshot)
        model.stop()
    }

    func testSettingsAndDashboardOnlyCapabilities() {
        let storage = AIUsageTestStorage()
        let context = PluginRuntimeContext(pluginID: "ai-usage", storage: storage)
        let plugin = AIUsagePlugin(context: context, model: AIUsageViewModel(storage: storage, client: AIUsageTestClient()))
        XCTAssertNil(plugin.primaryPanel)
        XCTAssertNotNil(plugin.componentPanel)
        XCTAssertEqual(plugin.metadata.id, "ai-usage")
        XCTAssertEqual(plugin.settingsPage?.body.layout, .form)
        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
        XCTAssertTrue(plugin.componentPanelState.isEnabled)
        plugin.handleSettingsAction(.setBoolean(controlID: "menu-bar", value: true))
        plugin.handleSettingsAction(.setSelection(controlID: "refresh-interval", optionID: "900"))
        plugin.handleSettingsAction(.setSelection(controlID: "refresh-interval", optionID: "1"))
        let reloaded = AIUsageViewModel(storage: storage, client: AIUsageTestClient())
        XCTAssertTrue(reloaded.preferences.showsMenuBar)
        XCTAssertEqual(reloaded.preferences.refreshInterval, 900)
        XCTAssertFalse(reloaded.preferences.allowsCredentialAccess)
    }

    func testMenuBarShowsAllEnabledServicesAndMatchesPrimaryRemainingQuota() {
        let strings = AIUsageStrings(localization: PluginLocalization(bundle: .main))
        var state = AIUsageProviderState()
        state.snapshot = AIUsageTestClient.snapshot
        state.failure = .network
        let presentation = AIUsageMenuBarPresentation.make(providers: [.codex, .claude], states: [.claude: state],
                                                           interval: 300, now: date, strings: strings)
        XCTAssertEqual(presentation.segments.map(\.provider), [.codex, .claude])
        XCTAssertEqual(presentation.segments.map(\.value), ["—", "66%"])
        XCTAssertTrue(presentation.segments[1].isStale)
        XCTAssertEqual(strings.updated(date, now: date), strings.text("updated.now", "刚刚更新"))
    }

    func testAuthorizationIsIndependentOfServiceVisibilityAndFileAccess() async {
        let client = AIUsageTestClient()
        let model = makeModel(client)
        model.updatePreferences { $0.codexEnabled = false; $0.claudeEnabled = false }
        model.start()
        model.setClaudeKeychainAccess(true)
        await settle(model)
        let authorizations = await client.authorizations
        let requests = await client.count
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(model.preferences.allowsClaudeKeychain)
        XCTAssertFalse(model.preferences.allowsCredentialAccess)
        model.updatePreferences { $0.claudeEnabled = true }
        await settle(model)
        XCTAssertNotNil(model.states[.claude]?.snapshot)
        let fileAccess = await client.lastFileAccess
        XCTAssertFalse(fileAccess)
        model.updatePreferences { $0.allowsCredentialAccess = true }
        await settle(model)
        model.updatePreferences { $0.allowsCredentialAccess = false; $0.claudeEnabled = false }
        XCTAssertTrue(model.preferences.allowsClaudeKeychain)
        model.setClaudeKeychainAccess(false)
        XCTAssertFalse(model.preferences.allowsClaudeKeychain)
        model.stop()
    }

    func testKeychainAuthorizationCannotBypassRateLimit() async {
        let client = AIUsageTestClient()
        await client.setResult(.failure(.rateLimited(retryAfter: 900)))
        let model = makeModel(client)
        model.updatePreferences { $0.allowsCredentialAccess = true; $0.codexEnabled = false }
        model.start()
        await settle(model)
        date.addTimeInterval(61)
        model.setClaudeKeychainAccess(true)
        await settle(model)
        let count = await client.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.preferences.allowsClaudeKeychain)
        model.stop()
    }

    func testDashboardRendersLightDarkAndEmptyStates() async throws {
        let client = AIUsageTestClient()
        let fixture = AIUsageTestClient.snapshot
        let steady = AIUsageSnapshot(windows: fixture.windows.map {
            AIUsageWindow(id: $0.id, usedPercent: $0.id == "weekly" ? 40 : $0.usedPercent, resetsAt: $0.resetsAt, duration: $0.duration)
        }, plan: "pro", fetchedAt: fixture.fetchedAt)
        await client.setResult(.success(steady), for: .claude)
        let model = makeModel(client)
        let plugin = AIUsagePlugin(context: PluginRuntimeContext(pluginID: "ai-usage", resourceBundle: Bundle(for: Self.self), storage: AIUsageTestStorage()), model: model)
        model.updatePreferences { $0.allowsCredentialAccess = true }
        model.start()
        await settle(model)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsAIUsageQA")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let view = AIUsageComponentView(model: model, strings: plugin.strings, assets: plugin.assets, openSettings: {})
                .frame(width: 304, height: CGFloat(plugin.descriptor.span.height * 8))
                .environment(\.colorScheme, scheme)
                .environment(\.pluginComponentTheme, .system(colorScheme: scheme, contrast: .standard))
            let bitmap = try render(view, size: NSSize(width: 304, height: plugin.descriptor.span.height * 8), scheme: scheme)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(scheme == .light ? "dashboard-light.png" : "dashboard-dark.png"))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 304)
        }
        let previousLanguage = PluginRuntimeLocalization.preferredLanguages.first
        PluginRuntimeLocalization.source.setPreference("en")
        do {
            defer { PluginRuntimeLocalization.source.setPreference(previousLanguage) }
            let english = try render(AIUsageComponentView(model: model, strings: plugin.strings, assets: plugin.assets, openSettings: {}),
                                     size: NSSize(width: 304, height: plugin.descriptor.span.height * 8), scheme: .light)
            try XCTUnwrap(english.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("dashboard-english.png"))
        }
        let services = AIUsageServiceSettingsView(model: model, strings: plugin.strings, assets: plugin.assets)
            .pluginSettingsCardBackground(.standard).padding(16)
        let settings = try render(services, size: NSSize(width: 620, height: 130), scheme: .light)
        try XCTUnwrap(settings.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("services.png"))
        let presentation = AIUsageMenuBarPresentation.make(providers: model.preferences.enabledProviders, states: model.states,
                                                           interval: 300, now: Date(), strings: plugin.strings)
        let menuImage = AIUsageMenuBarController.makeImage(presentation, assets: plugin.assets)
        let menu = try render(Image(nsImage: menuImage).padding(8), size: NSSize(width: menuImage.size.width + 16, height: 38), scheme: .light)
        try XCTUnwrap(menu.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("menubar.png"))
        let exhausted = AIUsageSnapshot(windows: fixture.windows.map {
            AIUsageWindow(id: $0.id, usedPercent: $0.id == "weekly" ? 100 : $0.usedPercent, resetsAt: $0.resetsAt, duration: $0.duration)
        }, plan: "plus", fetchedAt: fixture.fetchedAt)
        await client.setResult(.success(exhausted))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        let exhaustedBitmap = try render(AIUsageComponentView(model: model, strings: plugin.strings, assets: plugin.assets, openSettings: {}),
                                         size: NSSize(width: 304, height: plugin.descriptor.span.height * 8), scheme: .light)
        try XCTUnwrap(exhaustedBitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("dashboard-exhausted.png"))
        await client.setResult(.failure(.network))
        date.addTimeInterval(61)
        model.refresh(manual: true)
        await settle(model)
        let stale = try render(AIUsageComponentView(model: model, strings: plugin.strings, assets: plugin.assets, openSettings: {}),
                               size: NSSize(width: 304, height: plugin.descriptor.span.height * 8), scheme: .light)
        try XCTUnwrap(stale.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("dashboard-stale.png"))
        model.updatePreferences { $0.allowsCredentialAccess = false }
        let bitmap = try render(AIUsageComponentView(model: model, strings: plugin.strings, assets: plugin.assets, openSettings: {}),
                                size: NSSize(width: 304, height: plugin.descriptor.span.height * 8), scheme: .light)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("dashboard-empty.png"))
        model.stop()
    }

    func testSingleWindowDashboardRendersWeeklyAndFiveHourPace() async throws {
        let scenarios: [(name: String, duration: Int, remaining: Int, used: Int, period: AIUsagePace.Period, level: AIUsagePace.Level)] = [
            ("weekly-steady", 604_800, 588_600, 5, .weekly, .steady),
            ("five-hour-steady", 18_000, 17_700, 5, .fiveHour, .steady),
            ("five-hour-ahead", 18_000, 9_000, 80, .fiveHour, .ahead)
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsAIUsageQA")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousLanguage = PluginRuntimeLocalization.preferredLanguages.first
        defer { PluginRuntimeLocalization.source.setPreference(previousLanguage) }
        for scenario in scenarios {
            let observedAt = Date()
            let payload = Data("""
                {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":\(scenario.used),"reset_after_seconds":\(scenario.remaining),"limit_window_seconds":\(scenario.duration)}}}
                """.utf8)
            let snapshot = try AIUsageParser.parse(payload, provider: .codex, now: observedAt)
            let client = AIUsageTestClient()
            await client.setResult(.success(snapshot))
            let model = makeModel(client)
            let plugin = AIUsagePlugin(context: PluginRuntimeContext(pluginID: "ai-usage", resourceBundle: Bundle(for: Self.self), storage: AIUsageTestStorage()), model: model)
            enable(model)
            await settle(model)
            defer { model.stop() }
            let state = try XCTUnwrap(model.states[.codex])
            let pace = try XCTUnwrap(AIUsagePace.make(state: state, now: Date(), refreshInterval: 300))
            XCTAssertEqual(pace.period, scenario.period)
            XCTAssertEqual(pace.level, scenario.level)
            XCTAssertEqual(state.snapshot?.windows.count, 1)
            model.panelVisible = true
            for language in ["zh-Hans", "en"] {
                PluginRuntimeLocalization.source.setPreference(language)
                for scheme in [ColorScheme.light, .dark] {
                    let bitmap = try render(AIUsageComponentView(model: model, strings: plugin.strings, assets: plugin.assets, openSettings: {}),
                                            size: NSSize(width: 304, height: plugin.descriptor.span.height * 8), scheme: scheme)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: directory.appendingPathComponent("dashboard-\(scenario.name)-\(language)-\(scheme == .light ? "light" : "dark").png"))
                }
            }
        }
    }

    private func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let hosting = NSHostingView(rootView: content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.pluginComponentTheme, .system(colorScheme: scheme, contrast: .standard)))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func makeModel(_ client: AIUsageTestClient) -> AIUsageViewModel {
        AIUsageViewModel(storage: AIUsageTestStorage(), client: client, now: { self.date })
    }

    private func enable(_ model: AIUsageViewModel) {
        model.updatePreferences { $0.allowsCredentialAccess = true; $0.claudeEnabled = false }
        model.start()
    }

    private func settle(_ model: AIUsageViewModel) async {
        for _ in 0..<1000 {
            await Task.yield()
            if !model.isRefreshing && !model.isAuthorizingKeychain { return }
        }
        XCTFail("Refresh did not settle")
    }
}

actor AIUsageTestClient: AIUsageFetching {
    private(set) var count = 0
    private(set) var authorizations = 0
    private(set) var lastFileAccess = true
    private var identity = "test-account"
    private var result: Result<AIUsageSnapshot, AIUsageFailure> = .success(snapshot)
    private var providerResults: [AIUsageProvider: Result<AIUsageSnapshot, AIUsageFailure>] = [:]
    static let snapshot = AIUsageSnapshot(windows: [
        AIUsageWindow(id: "session", usedPercent: 34, resetsAt: Date().addingTimeInterval(7200), duration: 18_000),
        AIUsageWindow(id: "weekly", usedPercent: 82, resetsAt: Date().addingTimeInterval(172_800), duration: 604_800)
    ], plan: "plus", fetchedAt: Date())

    func fetch(_ provider: AIUsageProvider, allowsFileAccess: Bool, allowsKeychain: Bool) async -> AIUsageFetchResult {
        count += 1
        lastFileAccess = allowsFileAccess
        await Task.yield()
        return AIUsageFetchResult(credentialID: identity, result: providerResults[provider] ?? result)
    }
    func authorizeClaudeKeychain() async -> AIUsageFailure? { authorizations += 1; return nil }
    func setResult(_ result: Result<AIUsageSnapshot, AIUsageFailure>) {
        self.result = result
        providerResults = [:]
    }
    func setResult(_ result: Result<AIUsageSnapshot, AIUsageFailure>, for provider: AIUsageProvider) {
        providerResults[provider] = result
    }
    func setIdentity(_ identity: String) { self.identity = identity }
}

@MainActor
final class AIUsageTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
