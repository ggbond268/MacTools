import Foundation
import LocalAuthentication
import MacToolsPluginKit
import Security

protocol TranslatorSecretStoring: Sendable {
    func containsAPIKey() throws -> Bool
    func containsAPIKey(forProfileID profileID: String) throws -> Bool
    func loadAPIKey() throws -> String?
    func loadAPIKey(forProfileID profileID: String) throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func saveAPIKey(_ apiKey: String, forProfileID profileID: String) throws
    func deleteAPIKey() throws
    func deleteAPIKey(forProfileID profileID: String) throws
}

extension TranslatorSecretStoring {
    func containsAPIKey(forProfileID profileID: String) throws -> Bool {
        try containsAPIKey()
    }

    func loadAPIKey(forProfileID profileID: String) throws -> String? {
        try loadAPIKey()
    }

    func saveAPIKey(_ apiKey: String, forProfileID profileID: String) throws {
        try saveAPIKey(apiKey)
    }

    func deleteAPIKey(forProfileID profileID: String) throws {
        try deleteAPIKey()
    }
}

struct OpenAICompatibleSecretStore: TranslatorSecretStoring {
    static let defaultService = "cc.ggbond.mactools.translator"
    static let defaultAccount = "translator.openai.api-key"
    static func account(profileID: String) -> String {
        "translator.provider.\(profileID).api-key"
    }

    let service: String
    let account: String

    init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        releaseChannel: String? = Bundle.main.object(forInfoDictionaryKey: "MTReleaseChannel") as? String
    ) {
        self.service = service + (releaseChannel == "nightly" ? ".nightly" : "")
        self.account = account
    }

    func containsAPIKey() throws -> Bool {
        try containsAPIKey(account: account)
    }

    func containsAPIKey(forProfileID profileID: String) throws -> Bool {
        try containsAPIKey(account: Self.account(profileID: profileID))
    }

    func loadAPIKey() throws -> String? {
        try loadAPIKey(account: account)
    }

    func loadAPIKey(forProfileID profileID: String) throws -> String? {
        try loadAPIKey(account: Self.account(profileID: profileID))
    }

    func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, account: account)
    }

    func saveAPIKey(_ apiKey: String, forProfileID profileID: String) throws {
        try saveAPIKey(apiKey, account: Self.account(profileID: profileID))
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(account: account)
    }

    func deleteAPIKey(forProfileID profileID: String) throws {
        try deleteAPIKey(account: Self.account(profileID: profileID))
    }

    private func containsAPIKey(account: String) throws -> Bool {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case errSecInteractionNotAllowed:
            // The item likely exists but cannot be inspected without user interaction.
            // Treat it as present so a blank settings save preserves it.
            return true
        default:
            throw OpenAICompatibleSecretStoreError.security(status)
        }
    }

    private func loadAPIKey(account: String) throws -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OpenAICompatibleSecretStoreError.unexpectedItemData
            }

            guard let apiKey = String(data: data, encoding: .utf8) else {
                throw OpenAICompatibleSecretStoreError.unexpectedItemData
            }
            return apiKey
        case errSecItemNotFound:
            return nil
        default:
            throw OpenAICompatibleSecretStoreError.security(status)
        }
    }

    private func saveAPIKey(_ apiKey: String, account: String) throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAPIKey.isEmpty else {
            try deleteAPIKey(account: account)
            return
        }

        let data = Data(trimmedAPIKey.utf8)
        var attributes = baseQuery
        attributes[kSecAttrAccount as String] = account
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            var updateAttributes: [String: Any] = [:]
            updateAttributes[kSecValueData as String] = data
            updateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            var updateQuery = baseQuery
            updateQuery[kSecAttrAccount as String] = account
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw OpenAICompatibleSecretStoreError.security(updateStatus)
            }
        default:
            throw OpenAICompatibleSecretStoreError.security(status)
        }
    }

    private func deleteAPIKey(account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAICompatibleSecretStoreError.security(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}

enum OpenAICompatibleSecretStoreError: Error, Equatable, Sendable {
    case unexpectedItemData
    case security(OSStatus)
}

extension OpenAICompatibleSecretStoreError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .unexpectedItemData:
            return localization.string("secretStore.error.unexpectedItemData", defaultValue: "API Key 数据无效。")
        case .security:
            return localization.string("secretStore.error.security", defaultValue: "无法访问钥匙串。")
        }
    }
}
