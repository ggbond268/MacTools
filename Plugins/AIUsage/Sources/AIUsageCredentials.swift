import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct AIUsageCredential: Sendable {
    let accessToken: String
    let accountID: String?

    var identity: String {
        SHA256.hash(data: Data((accessToken + (accountID ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

protocol AIUsageCredentialReading: Sendable {
    func read(_ provider: AIUsageProvider, allowsFileAccess: Bool, allowsKeychain: Bool, promptsForKeychain: Bool) async throws -> AIUsageCredential
}

actor AIUsageCredentialReader: AIUsageCredentialReading {
    private let home: URL
    private let environment: [String: String]
    static let maximumFileSize = 1_048_576

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    func read(_ provider: AIUsageProvider, allowsFileAccess: Bool = true, allowsKeychain: Bool, promptsForKeychain: Bool) throws -> AIUsageCredential {
        let directoryKey = provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let defaultDirectory = provider == .codex ? ".codex" : ".claude"
        let directory: URL
        if let path = environment[directoryKey], !path.isEmpty {
            guard path.hasPrefix("/") else { throw AIUsageFailure.credentialUnreadable }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = home.appendingPathComponent(defaultDirectory, isDirectory: true)
        }
        let url = directory.appendingPathComponent(provider == .codex ? "auth.json" : ".credentials.json")
        if allowsFileAccess, FileManager.default.fileExists(atPath: url.path) {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize,
                      size <= Self.maximumFileSize else { throw AIUsageFailure.credentialUnreadable }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maximumFileSize + 1) ?? Data()
                guard data.count <= Self.maximumFileSize else { throw AIUsageFailure.credentialUnreadable }
                return try Self.parse(data, provider: provider, now: Date())
            } catch let error as AIUsageFailure { throw error }
            catch { throw AIUsageFailure.credentialUnreadable }
        }
        guard provider == .claude else { throw AIUsageFailure.signInRequired }
        guard directory.standardizedFileURL == home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL else {
            throw AIUsageFailure.signInRequired
        }
        guard allowsKeychain else { throw AIUsageFailure.keychainPermission }
        return try Self.parse(Self.readClaudeKeychain(prompts: promptsForKeychain), provider: .claude, now: Date())
    }

    static func parse(_ data: Data, provider: AIUsageProvider, now: Date) throws -> AIUsageCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure.credentialUnreadable
        }
        switch provider {
        case .codex:
            let tokens = root["tokens"] as? [String: Any] ?? [:]
            guard let token = validHeader(tokens["access_token"]) ?? validHeader(root["personal_access_token"]) else {
                throw AIUsageFailure.unsupportedLogin
            }
            return AIUsageCredential(accessToken: token, accountID: validHeader(tokens["account_id"]))
        case .claude:
            let oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
            guard let token = validHeader(oauth["accessToken"]) ?? validHeader(oauth["access_token"]) else {
                throw AIUsageFailure.unsupportedLogin
            }
            if let expiry = AIUsageParser.number(oauth["expiresAt"]) {
                let seconds = expiry > 10_000_000_000 ? expiry / 1000 : expiry
                guard seconds > now.timeIntervalSince1970 else { throw AIUsageFailure.expired }
            }
            return AIUsageCredential(accessToken: token, accountID: nil)
        }
    }

    private static func validHeader(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count < 32_768,
              value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        return value
    }

    private static func readClaudeKeychain(prompts: Bool) throws -> Data {
        let authentication = LAContext()
        authentication.interactionNotAllowed = !prompts
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw AIUsageFailure.signInRequired }
        guard status == errSecSuccess, let data = result as? Data,
              data.count <= maximumFileSize else { throw AIUsageFailure.keychainPermission }
        return data
    }
}
