import Foundation
import MacToolsPluginKit
import Security

struct R2Configuration: Equatable, Sendable {
    var accountID: String
    var bucket: String
    var accessKeyID: String
    var publicBaseURL: String
    var objectPrefix: String

    var isComplete: Bool {
        !accountID.trimmed.isEmpty && !bucket.trimmed.isEmpty && !accessKeyID.trimmed.isEmpty
    }
}

@MainActor
final class R2ConfigurationStore: ObservableObject {
    @Published var accountID: String
    @Published var bucket: String
    @Published var accessKeyID: String
    @Published var publicBaseURL: String
    @Published var objectPrefix: String
    @Published var secretAccessKey = ""
    @Published private(set) var hasStoredSecret = false
    @Published var errorMessage: String?

    private enum Key {
        static let accountID = "account-id"
        static let bucket = "bucket"
        static let accessKeyID = "access-key-id"
        static let publicBaseURL = "public-base-url"
        static let objectPrefix = "object-prefix"
        static let retiredPreservesFileName = "preserves-file-name"
    }

    private let storage: PluginStorage
    private let secrets: R2SecretStoring
    private let localization: PluginLocalization

    init(
        storage: PluginStorage,
        secrets: R2SecretStoring = R2KeychainSecretStore(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.storage = storage
        self.secrets = secrets
        self.localization = localization
        accountID = storage.string(forKey: Key.accountID) ?? ""
        bucket = storage.string(forKey: Key.bucket) ?? ""
        accessKeyID = storage.string(forKey: Key.accessKeyID) ?? ""
        publicBaseURL = storage.string(forKey: Key.publicBaseURL) ?? ""
        objectPrefix = storage.string(forKey: Key.objectPrefix) ?? ""
        storage.removeObject(forKey: Key.retiredPreservesFileName)
        do {
            hasStoredSecret = try secrets.containsSecret()
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    var configuration: R2Configuration {
        R2Configuration(
            accountID: accountID.trimmed,
            bucket: bucket.trimmed,
            accessKeyID: accessKeyID.trimmed,
            publicBaseURL: publicBaseURL.trimmed,
            objectPrefix: objectPrefix.trimmed
        )
    }

    var publicBaseURLValidationMessage: String? {
        let value = publicBaseURL.trimmed
        guard !value.isEmpty else { return nil }
        return R2PublicURLValidator.baseURL(from: value) == nil
            ? localization.string(
                "validation.publicURL",
                defaultValue: "请输入以 http:// 或 https:// 开头的有效地址。"
            )
            : nil
    }

    var objectPrefixValidationMessage: String? {
        R2ObjectPrefixValidator.isValid(objectPrefix.trimmed)
            ? nil
            : localization.string(
                "validation.objectPrefix",
                defaultValue: "对象前缀不能包含 . 或 .. 路径段。"
            )
    }

    func save() {
        storage.set(accountID.trimmed, forKey: Key.accountID)
        storage.set(bucket.trimmed, forKey: Key.bucket)
        storage.set(accessKeyID.trimmed, forKey: Key.accessKeyID)
        storage.set(publicBaseURL.trimmed, forKey: Key.publicBaseURL)
        storage.set(objectPrefix.trimmed, forKey: Key.objectPrefix)
        do {
            if !secretAccessKey.trimmed.isEmpty {
                try secrets.saveSecret(secretAccessKey)
                secretAccessKey = ""
            }
            hasStoredSecret = try secrets.containsSecret()
            errorMessage = nil
        } catch {
            errorMessage = localizedMessage(for: error)
        }
    }

    func loadSecret() throws -> String {
        guard let secret = try secrets.loadSecret(), !secret.isEmpty else {
            throw R2UploadError.missingSecret
        }
        return secret
    }

    private func localizedMessage(for error: Error) -> String {
        if let secretError = error as? R2SecretStoreError {
            return secretError.message(localization: localization)
        }
        return error.localizedDescription
    }
}

protocol R2SecretStoring: Sendable {
    func containsSecret() throws -> Bool
    func loadSecret() throws -> String?
    func saveSecret(_ value: String) throws
}

struct R2KeychainSecretStore: R2SecretStoring {
    let service: String
    let account: String

    init(service: String = "cc.ggbond.mactools.cloudflare-r2", account: String = "secret-access-key") {
        self.service = service
        self.account = account
    }

    func containsSecret() throws -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess || status == errSecInteractionNotAllowed { return true }
        if status == errSecItemNotFound { return false }
        throw R2SecretStoreError.security(status)
    }

    func loadSecret() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw R2SecretStoreError.security(status)
        }
        return value
    }

    func saveSecret(_ value: String) throws {
        let value = value.trimmed
        guard !value.isEmpty else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw R2SecretStoreError.security(status) }
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else { throw R2SecretStoreError.security(updateStatus) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum R2SecretStoreError: LocalizedError {
    case security(OSStatus)

    var errorDescription: String? {
        message(localization: PluginLocalization(bundle: .main))
    }

    func message(localization: PluginLocalization) -> String {
        switch self {
        case let .security(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return localization.format(
                "error.keychain.access",
                defaultValue: "无法访问钥匙串：%@（%d）",
                detail,
                status
            )
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
