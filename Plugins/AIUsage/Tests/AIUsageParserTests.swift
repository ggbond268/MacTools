import Foundation
import XCTest
@testable import AIUsagePlugin

final class AIUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexUsesServerWindowDurationsAndRelativeReset() throws {
        let snapshot = try parse(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":34,"reset_after_seconds":120,"limit_window_seconds":18000},"secondary_window":{"used_percent":82.5,"reset_at":1800200000,"limit_window_seconds":604800}}}"#, provider: .codex)
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [34, 82.5])
        XCTAssertEqual(snapshot.windows[0].resetsAt, now.addingTimeInterval(120))
        XCTAssertEqual(snapshot.windows[1].duration, 604_800)
    }

    func testMissingAndBooleanUsageNeverBecomeZero() {
        for json in [#"{}"#, #"{"rate_limit":{"primary_window":{"used_percent":true}}}"#, #"{"rate_limit":{"primary_window":{"reset_at":1800200000}}}"#] {
            XCTAssertThrowsError(try parse(json, provider: .codex))
        }
        XCTAssertThrowsError(try parse(#"{"five_hour":{"utilization":null}}"#, provider: .claude))
    }

    func testExplicitZeroIsValidAndUnavailableWindowsStayAbsent() throws {
        let snapshot = try parse(#"{"rate_limit":{"secondary_window":{"used_percent":0}}}"#, provider: .codex)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "weekly")
        XCTAssertEqual(snapshot.highestUsage, 0)
        XCTAssertNil(snapshot.windows[0].resetsAt)
    }

    func testClaudeParsesLegacyFractionalAndWholeSecondDates() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":20,"resets_at":"2027-01-15T12:00:00.000Z"},"seven_day":{"utilization":60,"resets_at":"2027-01-18T12:00:00Z"}}"#, provider: .claude)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [20, 60])
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt != nil })
    }

    func testClaudeGenericLimitsTakePrecedenceAndKeepFallbackReset() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":10,"resets_at":"2027-01-15T12:00:00Z"},"limits":[{"kind":"session","percent":45},{"kind":"weekly_all","percent":12},{"kind":"weekly_scoped","percent":99}]}"#, provider: .claude)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [45, 12])
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    func testInactiveGenericWindowIsExcluded() throws {
        let snapshot = try parse(#"{"limits":[{"kind":"session","percent":30,"is_active":false},{"kind":"weekly_all","percent":12}]}"#, provider: .claude)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly"])
    }

    func testOverageRemainsVisibleWhileProgressStaysInBounds() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":125},"seven_day":{"utilization":-5}}"#, provider: .claude)
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [125, 0])
        XCTAssertEqual(snapshot.windows.map(\.fraction), [1, 0])
    }

    func testClientUsesOnlyProviderSpecificCredentialsAndEndpoints() {
        let credential = AIUsageCredential(accessToken: "fixture-token", accountID: "fixture-account")
        let codex = AIUsageClient.request(.codex, credential: credential)
        XCTAssertEqual(codex.url?.host, "chatgpt.com")
        XCTAssertEqual(codex.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture-account")
        let claude = AIUsageClient.request(.claude, credential: credential)
        XCTAssertEqual(claude.url?.host, "api.anthropic.com")
        XCTAssertNil(claude.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testRateLimitsHonorRetryAfterAndAuthenticationErrorsStaySanitized() throws {
        for (code, header, expected) in [
            (429, "120", AIUsageFailure.rateLimited(retryAfter: 600)),
            (429, "1800", .rateLimited(retryAfter: 1800)),
            (429, "nan", .rateLimited(retryAfter: 600)),
            (401, "", .expired), (403, "", .expired), (500, "", .server), (302, "", .server)
        ] {
            let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: code,
                                                       httpVersion: nil, headerFields: ["Retry-After": header]))
            XCTAssertThrowsError(try AIUsageClient.validate(response, now: now)) { error in
                XCTAssertEqual(error as? AIUsageFailure, expected)
            }
        }
    }

    func testCodexCredentialsRejectAPIKeysAndHeaderInjection() throws {
        let credential = try AIUsageCredentialReader.parse(Data(#"{"tokens":{"access_token":"test-token","account_id":"account"}}"#.utf8), provider: .codex, now: now)
        XCTAssertEqual(credential.accountID, "account")
        for json in [#"{"OPENAI_API_KEY":"test-key"}"#, #"{"tokens":{"access_token":"bad\r\nheader"}}"#] {
            XCTAssertThrowsError(try AIUsageCredentialReader.parse(Data(json.utf8), provider: .codex, now: now))
        }
    }

    func testClaudeCredentialsRejectExpiredMillisecondsWithoutRefreshing() {
        XCTAssertThrowsError(try AIUsageCredentialReader.parse(
            Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":1700000000000,"refreshToken":"never-used"}}"#.utf8), provider: .claude, now: now
        )) { XCTAssertEqual($0 as? AIUsageFailure, .expired) }
    }

    func testCredentialReaderUsesTemporaryHomeAndDoesNotModifyFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(".codex/auth.json")
        let data = Data(#"{"personal_access_token":"test-pat"}"#.utf8)
        try data.write(to: url)
        let reader = AIUsageCredentialReader(home: directory, environment: [:])
        let credential = try await reader.read(.codex, allowsKeychain: false, promptsForKeychain: false)
        XCTAssertEqual(credential.accessToken, "test-pat")
        XCTAssertEqual(try Data(contentsOf: url), data)
        do {
            _ = try await reader.read(.codex, allowsFileAccess: false, allowsKeychain: false, promptsForKeychain: false)
            XCTFail("A present login file must not be read without file access")
        } catch { XCTAssertEqual(error as? AIUsageFailure, .signInRequired) }

        do {
            _ = try await reader.read(.claude, allowsKeychain: false, promptsForKeychain: false)
            XCTFail("A missing file must not trigger implicit Keychain access")
        } catch { XCTAssertEqual(error as? AIUsageFailure, .keychainPermission) }
        let custom = AIUsageCredentialReader(home: directory, environment: ["CLAUDE_CONFIG_DIR": directory.appendingPathComponent("custom").path])
        do {
            _ = try await custom.read(.claude, allowsKeychain: true, promptsForKeychain: true)
            XCTFail("A custom config directory must never fall back to another account's Keychain")
        } catch { XCTAssertEqual(error as? AIUsageFailure, .signInRequired) }
    }

    private func parse(_ string: String, provider: AIUsageProvider) throws -> AIUsageSnapshot {
        try AIUsageParser.parse(Data(string.utf8), provider: provider, now: now)
    }
}
