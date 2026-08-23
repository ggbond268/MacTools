import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class IncrementalEncryptedClipboardHistoryStoreTests: XCTestCase {
    func testRoundTripKeepsMetadataAndPayloadEncryptedAndLoadsPayloadLazily() throws {
        let fixture = try makeFixture()
        let secret = "multi-gigabyte-ready-secret"
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: secret,
            capturedAt: Date(timeIntervalSince1970: 12_345),
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.example.Editor",
                name: "Secret Editor"
            ),
            isPinned: true,
            lastUsedAt: nil
        )

        try fixture.store.save([item])
        XCTAssertNil(item.payload)
        XCTAssertEqual(try item.loadPayload().plainText, secret)
        let rawDatabase = try Data(contentsOf: fixture.databaseURL)
        XCTAssertNil(rawDatabase.range(of: Data(secret.utf8)))
        XCTAssertNil(rawDatabase.range(of: Data("Secret Editor".utf8)))

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        let loaded = try reopened.load()
        let loadedItem = try XCTUnwrap(loaded.first)
        XCTAssertNil(loadedItem.payload)
        XCTAssertEqual(loadedItem.text, secret)
        XCTAssertEqual(try loadedItem.loadPayload().plainText, secret)
        XCTAssertNotNil(loadedItem.payload)
    }

    func testMetadataOnlyUpdateDoesNotRequirePreviouslyStoredPayloadToBeLoaded() throws {
        let fixture = try makeFixture()
        let item = sampleItem(index: 1)
        try fixture.store.save([item])

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        var loaded = try reopened.load()
        XCTAssertNil(loaded[0].payload)
        loaded[0].isPinned = true
        try reopened.save(loaded)
        XCTAssertNil(loaded[0].payload)

        let verified = try reopened.load()
        XCTAssertTrue(verified[0].isPinned)
        XCTAssertNil(verified[0].payload)
        XCTAssertEqual(try verified[0].loadPayload().plainText, item.text)
    }

    func testLegacyEncryptedFileMigratesOnceWithoutLosingPayload() throws {
        let fixture = try makeFixture()
        let legacyURL = fixture.directoryURL.appendingPathComponent("history.mth")
        let legacyStore = EncryptedClipboardHistoryStore(
            fileURL: legacyURL,
            keyStore: fixture.keyStore
        )
        let item = sampleItem(index: 2)
        try legacyStore.save([item])

        let migratingStore = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            legacyFileURL: legacyURL,
            keyStore: fixture.keyStore
        )
        let loaded = try migratingStore.load()

        XCTAssertEqual(loaded, [item])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        XCTAssertEqual(try loaded[0].loadPayload().plainText, item.text)
    }

    func testTenThousandMetadataRowsLoadWithoutMaterializingPayloads() throws {
        let fixture = try makeFixture()
        let items = (0..<ClipboardHistorySettings.maximumSupportedItemCount).map(sampleItem(index:))
        try fixture.store.save(items)

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        let startedAt = Date()
        var loaded = try reopened.load()
        let loadElapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(loaded.count, ClipboardHistorySettings.maximumSupportedItemCount)
        XCTAssertTrue(loaded.allSatisfy { $0.payload == nil })
        XCTAssertLessThan(loadElapsed, 5)

        loaded[5_000].isPinned = true
        let updateStartedAt = Date()
        try reopened.save(loaded)
        let updateElapsed = Date().timeIntervalSince(updateStartedAt)
        XCTAssertLessThan(updateElapsed, 1)
        XCTAssertTrue(try reopened.load().contains(where: { $0.id == loaded[5_000].id && $0.isPinned }))
    }

    private func makeFixture() throws -> (
        store: IncrementalEncryptedClipboardHistoryStore,
        directoryURL: URL,
        databaseURL: URL,
        keyStore: InMemoryClipboardHistoryKeyStore
    ) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let databaseURL = directoryURL.appendingPathComponent("history.sqlite3")
        let keyStore = InMemoryClipboardHistoryKeyStore()
        return (
            IncrementalEncryptedClipboardHistoryStore(
                databaseURL: databaseURL,
                keyStore: keyStore
            ),
            directoryURL,
            databaseURL,
            keyStore
        )
    }

    private func sampleItem(index: Int) -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: "clipboard item \(index)",
            capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
    }
}
