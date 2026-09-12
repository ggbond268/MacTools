import Foundation
import LocalAuthentication
import MacToolsPluginKit
import Security

protocol AIAssistantSecretStoring: Sendable {
    func containsAPIKey() throws -> Bool
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

struct AIAssistantSecretStore: AIAssistantSecretStoring {
    static let defaultService = "cc.ggbond.mactools.ai-assistant"
    static let defaultAccount = "ai-assistant.openai.api-key"

    let service: String
    let account: String

    init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func containsAPIKey() throws -> Bool {
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
            return true
        default:
            throw AIAssistantSecretStoreError.security(status)
        }
    }

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw AIAssistantSecretStoreError.unexpectedItemData
            }

            guard let apiKey = String(data: data, encoding: .utf8) else {
                throw AIAssistantSecretStoreError.unexpectedItemData
            }
            return apiKey
        case errSecItemNotFound:
            return nil
        default:
            throw AIAssistantSecretStoreError.security(status)
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAPIKey.isEmpty else {
            try deleteAPIKey()
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
                throw AIAssistantSecretStoreError.security(updateStatus)
            }
        default:
            throw AIAssistantSecretStoreError.security(status)
        }
    }

    func deleteAPIKey() throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIAssistantSecretStoreError.security(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}

enum AIAssistantSecretStoreError: Error, Equatable, Sendable {
    case unexpectedItemData
    case security(OSStatus)
}

extension AIAssistantSecretStoreError: LocalizedError {
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
