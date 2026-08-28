import Foundation
import XCTest
@testable import TranslatorPlugin

final class OpenAICompatibleSecretStoreTests: XCTestCase {
    private var service: String!
    private var store: OpenAICompatibleSecretStore!

    override func setUpWithError() throws {
        try super.setUpWithError()

        service = "cc.ggbond.mactools.translator.tests.\(UUID().uuidString)"
        store = OpenAICompatibleSecretStore(service: service, releaseChannel: "stable")
        try store.deleteAPIKey()
    }

    override func tearDownWithError() throws {
        try store?.deleteAPIKey()
        store = nil
        service = nil

        try super.tearDownWithError()
    }

    func testSaveLoadDeleteAPIKey() throws {
        try store.saveAPIKey("  sk-test-value  ")

        XCTAssertEqual(try store.loadAPIKey(), "sk-test-value")

        try store.deleteAPIKey()

        XCTAssertNil(try store.loadAPIKey())
    }

    func testNightlyServiceNamePreservesExistingStableNamespace() {
        for channel in [nil, "stable", "development", "unknown"] {
            XCTAssertEqual(
                OpenAICompatibleSecretStore(releaseChannel: channel).service,
                "cc.ggbond.mactools.translator"
            )
        }
        XCTAssertEqual(
            OpenAICompatibleSecretStore(releaseChannel: "nightly").service,
            "cc.ggbond.mactools.translator.nightly"
        )
    }

    func testNightlySecretWritesAndDeletesDoNotAffectStable() throws {
        let nightly = OpenAICompatibleSecretStore(service: service, releaseChannel: "nightly")
        let profileID = UUID().uuidString
        defer {
            try? nightly.deleteAPIKey()
            try? nightly.deleteAPIKey(forProfileID: profileID)
            try? store.deleteAPIKey(forProfileID: profileID)
        }

        try store.saveAPIKey("stable-key")
        try store.saveAPIKey("stable-profile-key", forProfileID: profileID)
        XCTAssertNil(try nightly.loadAPIKey())
        XCTAssertNil(try nightly.loadAPIKey(forProfileID: profileID))

        try nightly.saveAPIKey("nightly-key")
        try nightly.saveAPIKey("nightly-profile-key", forProfileID: profileID)
        try nightly.saveAPIKey("updated-nightly-key")
        XCTAssertEqual(try nightly.loadAPIKey(), "updated-nightly-key")
        XCTAssertEqual(try nightly.loadAPIKey(forProfileID: profileID), "nightly-profile-key")

        try nightly.deleteAPIKey()
        try nightly.deleteAPIKey(forProfileID: profileID)
        XCTAssertEqual(try store.loadAPIKey(), "stable-key")
        XCTAssertEqual(try store.loadAPIKey(forProfileID: profileID), "stable-profile-key")
    }

    func testSavingBlankDeletesExistingAPIKey() throws {
        try store.saveAPIKey("sk-test-value")

        try store.saveAPIKey("   \n\t  ")

        XCTAssertNil(try store.loadAPIKey())
    }

    func testLoadAPIKeyThrowsWhenStoredDataIsNotUTF8() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service!,
            kSecAttrAccount as String: OpenAICompatibleSecretStore.defaultAccount,
            kSecValueData as String: Data([0xFF, 0xFE]),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? OpenAICompatibleSecretStoreError, .unexpectedItemData)
        }
    }
}
