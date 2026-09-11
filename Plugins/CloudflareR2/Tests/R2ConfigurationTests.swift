import Foundation
import MacToolsPluginKit
import Security
import XCTest

@testable import CloudflareR2Plugin

final class R2ConfigurationTests: XCTestCase {
    func testNightlyServiceNamePreservesExistingStableNamespace() {
        for channel in [nil, "stable", "development", "unknown"] {
            XCTAssertEqual(
                R2KeychainSecretStore(releaseChannel: channel).service,
                "cc.ggbond.mactools.cloudflare-r2"
            )
        }
        XCTAssertEqual(
            R2KeychainSecretStore(releaseChannel: "nightly").service,
            "cc.ggbond.mactools.cloudflare-r2.nightly"
        )
    }

    func testNightlySecretWritesDoNotAffectStable() throws {
        let service = "cc.ggbond.mactools.cloudflare-r2.tests.\(UUID().uuidString)"
        let stable = R2KeychainSecretStore(service: service, releaseChannel: "stable")
        let nightly = R2KeychainSecretStore(service: service, releaseChannel: "nightly")
        defer {
            for item in [stable, nightly] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: item.service,
                    kSecAttrAccount as String: item.account,
                ] as CFDictionary)
            }
        }

        try stable.saveSecret("stable-secret")
        XCTAssertFalse(try nightly.containsSecret())
        XCTAssertNil(try nightly.loadSecret())
        try nightly.saveSecret("nightly-secret")
        try nightly.saveSecret("updated-nightly-secret")
        XCTAssertEqual(try nightly.loadSecret(), "updated-nightly-secret")
        XCTAssertEqual(try stable.loadSecret(), "stable-secret")
    }

    func testConfigurationRequiresEveryCoreFieldAndTrimsValues() async {
        await MainActor.run {
            let store = R2ConfigurationStore(
                storage: R2MemoryStorage(), secrets: R2SecretStoreMock(secret: nil))
            store.accountID = " account "
            store.bucket = " bucket "
            store.accessKeyID = " key "
            store.publicBaseURL = " https://files.example.com/ "
            store.objectPrefix = " uploads/2026 "
            XCTAssertEqual(
                store.configuration,
                R2Configuration(
                    accountID: "account", bucket: "bucket", accessKeyID: "key",
                    publicBaseURL: "https://files.example.com/", objectPrefix: "uploads/2026"))
            XCTAssertTrue(store.configuration.isComplete)
            store.accountID = " "
            XCTAssertFalse(store.configuration.isComplete)
        }
    }

    func testStoreLoadsPersistedConfigurationAndSecretPresence() async {
        await MainActor.run {
            let storage = R2MemoryStorage(values: [
                "account-id": "account", "bucket": "bucket", "access-key-id": "access",
                "public-base-url": "https://files.example.com", "object-prefix": "images",
                "preserves-file-name": true,
            ])
            let store = R2ConfigurationStore(
                storage: storage, secrets: R2SecretStoreMock(secret: "secret"))
            XCTAssertEqual(store.accountID, "account")
            XCTAssertEqual(store.bucket, "bucket")
            XCTAssertEqual(store.accessKeyID, "access")
            XCTAssertEqual(store.publicBaseURL, "https://files.example.com")
            XCTAssertEqual(store.objectPrefix, "images")
            XCTAssertTrue(store.hasStoredSecret)
            XCTAssertNil(store.errorMessage)
            XCTAssertNil(storage.values["preserves-file-name"])
        }
    }

    func testPublicURLValidationRejectsRelativeAndAcceptsHTTPS() async {
        await MainActor.run {
            let store = R2ConfigurationStore(
                storage: R2MemoryStorage(), secrets: R2SecretStoreMock(secret: nil))
            store.publicBaseURL = "cdn.example.com"
            XCTAssertNotNil(store.publicBaseURLValidationMessage)
            store.publicBaseURL = "https://cdn.example.com"
            XCTAssertNil(store.publicBaseURLValidationMessage)
            store.publicBaseURL = ""
            XCTAssertNil(store.publicBaseURLValidationMessage)
        }
    }

    func testObjectPrefixValidationRejectsRelativeSegments() async {
        await MainActor.run {
            let store = R2ConfigurationStore(
                storage: R2MemoryStorage(),
                secrets: R2SecretStoreMock(secret: nil)
            )
            store.objectPrefix = "uploads/../private"
            XCTAssertNotNil(store.objectPrefixValidationMessage)
            store.objectPrefix = "uploads/2026"
            XCTAssertNil(store.objectPrefixValidationMessage)
        }
    }

    func testSavePersistsTrimmedValuesAndMovesSecretToSecretStore() async throws {
        let storage = await MainActor.run { R2MemoryStorage() }
        let secrets = R2SecretStoreMock(secret: nil)
        let store = await MainActor.run { R2ConfigurationStore(storage: storage, secrets: secrets) }
        await MainActor.run {
            store.accountID = " account "
            store.bucket = " bucket "
            store.accessKeyID = " access "
            store.publicBaseURL = " https://files.example.com "
            store.objectPrefix = " uploads "
            store.secretAccessKey = " secret "
            store.save()
        }
        let values = await MainActor.run { storage.values }
        XCTAssertEqual(values["account-id"] as? String, "account")
        XCTAssertEqual(values["bucket"] as? String, "bucket")
        XCTAssertEqual(values["access-key-id"] as? String, "access")
        XCTAssertEqual(values["public-base-url"] as? String, "https://files.example.com")
        XCTAssertEqual(values["object-prefix"] as? String, "uploads")
        XCTAssertEqual(try secrets.loadSecret(), "secret")
        await MainActor.run {
            XCTAssertEqual(store.secretAccessKey, "")
            XCTAssertTrue(store.hasStoredSecret)
        }
    }

    func testBlankSecretDoesNotOverwriteStoredSecret() async throws {
        let secrets = R2SecretStoreMock(secret: "existing")
        let store = await MainActor.run {
            R2ConfigurationStore(storage: R2MemoryStorage(), secrets: secrets)
        }
        await MainActor.run {
            store.secretAccessKey = "  "
            store.save()
        }
        XCTAssertEqual(try secrets.loadSecret(), "existing")
        XCTAssertEqual(secrets.saveCount, 0)
    }

    func testLoadSecretThrowsWhenMissing() async {
        let store = await MainActor.run {
            R2ConfigurationStore(storage: R2MemoryStorage(), secrets: R2SecretStoreMock(secret: nil))
        }
        do {
            _ = try await MainActor.run { try store.loadSecret() }
            XCTFail("Expected missingSecret")
        } catch { XCTAssertEqual(error as? R2UploadError, .missingSecret) }
    }

    func testSecretStoreErrorsAreExposed() async {
        let secrets = R2SecretStoreMock(secret: nil)
        secrets.error = R2SecretStoreTestError.failed
        let store = await MainActor.run {
            R2ConfigurationStore(storage: R2MemoryStorage(), secrets: secrets)
        }
        await MainActor.run {
            XCTAssertEqual(store.errorMessage, "Secret store failed")
            store.save()
            XCTAssertEqual(store.errorMessage, "Secret store failed")
        }
    }

    func testKeychainStoreSaveOverwriteAndLoad() throws {
        let service = "cc.ggbond.mactools.cloudflare-r2.tests.\(UUID().uuidString)"
        let store = R2KeychainSecretStore(service: service, account: "secret")
        defer { deleteKeychainItem(service: service, account: "secret") }
        XCTAssertFalse(try store.containsSecret())
        XCTAssertNil(try store.loadSecret())
        try store.saveSecret(" first ")
        XCTAssertTrue(try store.containsSecret())
        XCTAssertEqual(try store.loadSecret(), "first")
        try store.saveSecret("second")
        XCTAssertEqual(try store.loadSecret(), "second")
    }

    func testKeychainStoreIgnoresBlankSecret() throws {
        let service = "cc.ggbond.mactools.cloudflare-r2.tests.\(UUID().uuidString)"
        let store = R2KeychainSecretStore(service: service, account: "secret")
        defer { deleteKeychainItem(service: service, account: "secret") }
        try store.saveSecret("   \n")
        XCTAssertFalse(try store.containsSecret())
    }

    private func deleteKeychainItem(service: String, account: String) {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
    }
}

enum R2SecretStoreTestError: LocalizedError {
    case failed
    var errorDescription: String? { "Secret store failed" }
}

final class R2SecretStoreMock: R2SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSecret: String?
    private var storedSaveCount = 0
    var error: Error?
    init(secret: String?) { storedSecret = secret }
    var saveCount: Int { lock.withLock { storedSaveCount } }
    func containsSecret() throws -> Bool {
        try lock.withLock {
            if let error { throw error }
            return storedSecret != nil
        }
    }
    func loadSecret() throws -> String? {
        try lock.withLock {
            if let error { throw error }
            return storedSecret
        }
    }
    func saveSecret(_ value: String) throws {
        try lock.withLock {
            if let error { throw error }
            storedSecret = value.trimmingCharacters(in: .whitespacesAndNewlines)
            storedSaveCount += 1
        }
    }
}

@MainActor
final class R2MemoryStorage: PluginStorage {
    var values: [String: Any]
    init(values: [String: Any] = [:]) { self.values = values }
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values.removeValue(forKey: legacyKey) else { return }
        values[key] = value
    }
}
