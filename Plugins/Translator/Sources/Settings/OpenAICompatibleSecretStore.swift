import Foundation
import Security

struct OpenAICompatibleSecretStore: Sendable {
    static let defaultService = "cc.ggbond.mactools.translator"
    static let defaultAccount = "translator.openai.api-key"

    let service: String
    let account: String

    init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw OpenAICompatibleSecretStoreError.unexpectedItemData
            }

            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw OpenAICompatibleSecretStoreError.security(status)
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
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            var updateAttributes: [String: Any] = [:]
            updateAttributes[kSecValueData as String] = data
            updateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw OpenAICompatibleSecretStoreError.security(updateStatus)
            }
        default:
            throw OpenAICompatibleSecretStoreError.security(status)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAICompatibleSecretStoreError.security(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum OpenAICompatibleSecretStoreError: Error, Equatable, Sendable {
    case unexpectedItemData
    case security(OSStatus)
}

extension OpenAICompatibleSecretStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unexpectedItemData:
            return "API Key 数据无效。"
        case .security:
            return "无法访问钥匙串。"
        }
    }
}
