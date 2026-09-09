import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class EncryptedClipboardHistoryStoreTests: XCTestCase {
    func testRoundTripEncryptsPayloadAtRest() throws {
        let fixture = try makeFixture()
        let secretFileURL = "file:///Users/example/secret-design.pdf"
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.plainText,
                    data: Data("never-write-this-plaintext".utf8)
                ),
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.rtf,
                    data: Data("{\\rtf1 never-write-this-plaintext}".utf8)
                ),
            ]),
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.fileURL,
                    data: Data(secretFileURL.utf8)
                ),
            ]),
        ])
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(timeIntervalSince1970: 1_234),
            sourceApplication: ClipboardSourceApplication(
                bundleIdentifier: "com.example.Editor",
                name: "Editor"
            ),
            isPinned: true,
            lastUsedAt: Date(timeIntervalSince1970: 1_235)
        )

        try fixture.store.save([item])
        let raw = try Data(contentsOf: fixture.fileURL)
        XCTAssertNil(raw.range(of: Data(item.text.utf8)))
        XCTAssertNil(raw.range(of: Data(secretFileURL.utf8)))
        XCTAssertEqual(try fixture.store.load(), [item])
        XCTAssertEqual(fixture.keyStore.currentKey?.count, 32)
    }

    func testEncodedItemDerivesSearchTextWithoutDuplicatingItInTheEnvelope() throws {
        let item = sampleItem()
        let encoded = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertNil(object["text"])
        XCTAssertEqual(try JSONDecoder().decode(ClipboardHistoryItem.self, from: encoded), item)
    }

    func testExistingPayloadWithMissingKeyFailsClosed() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem()])

        let missingKeyStore = InMemoryClipboardHistoryKeyStore()
        let reopened = EncryptedClipboardHistoryStore(
            fileURL: fixture.fileURL,
            keyStore: missingKeyStore
        )
        XCTAssertThrowsError(try reopened.load()) { error in
            XCTAssertEqual(error as? ClipboardHistoryStoreError, .missingEncryptionKey)
        }
        XCTAssertNil(missingKeyStore.currentKey)
    }

    func testCorruptPayloadFailsAuthenticationWithoutReplacingSource() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem()])
        var data = try Data(contentsOf: fixture.fileURL)
        data[data.index(before: data.endIndex)] ^= 0x01
        try data.write(to: fixture.fileURL, options: .atomic)
        let corrupted = try Data(contentsOf: fixture.fileURL)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            XCTAssertEqual(error as? ClipboardHistoryStoreError, .authenticationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corrupted)
    }

    func testSavingEmptyHistoryRemovesPayloadButPreservesKey() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem()])
        let key = fixture.keyStore.currentKey
        try fixture.store.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertEqual(fixture.keyStore.currentKey, key)
    }

    func testUninstallCleanupRemovesPayloadAndKeyAndInvalidatesFutureWrites() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem()])
        try fixture.store.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keyStore.currentKey)
        XCTAssertTrue(fixture.keyStore.didDelete)

        try fixture.store.save([sampleItem()])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keyStore.currentKey)
    }

    func testResetRecoversMissingKeyStoreWithoutInvalidatingFutureWrites() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem()])
        try fixture.keyStore.deleteKey()
        XCTAssertThrowsError(try fixture.store.load())

        try fixture.store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(fixture.keyStore.currentKey)

        try fixture.store.save([sampleItem()])
        XCTAssertEqual(try fixture.store.load().count, 1)
    }

    func testSaveRejectsHistoryBeyondTotalPayloadBudget() throws {
        let fixture = try makeFixture()
        let oversizedText = String(
            repeating: "a",
            count: ClipboardRetentionPolicy.maximumTotalPayloadByteCount + 1
        )
        let oversizedItem = ClipboardHistoryItem(
            id: UUID(),
            text: oversizedText,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )

        XCTAssertThrowsError(try fixture.store.save([oversizedItem])) { error in
            XCTAssertEqual(error as? ClipboardHistoryStoreError, .historyTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testLoadRejectsOversizedStoredFileBeforeDecrypting() throws {
        let fixture = try makeFixture()
        let oversizedData = Data(
            repeating: 0,
            count: EncryptedClipboardHistoryStore.maximumStoredFileByteCount + 1
        )
        try oversizedData.write(to: fixture.fileURL)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            XCTAssertEqual(error as? ClipboardHistoryStoreError, .historyTooLarge)
        }
    }

    func testAggregatePayloadBudgetFitsWithinEncodedFileLimit() throws {
        let fixture = try makeFixture()
        let text = String(
            repeating: "\\",
            count: ClipboardRetentionPolicy.maximumTotalPayloadByteCount
        )
        let item = ClipboardHistoryItem(
            id: UUID(),
            text: text,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )

        try fixture.store.save([item])

        let storedSize = try Data(contentsOf: fixture.fileURL).count
        XCTAssertLessThanOrEqual(
            storedSize,
            EncryptedClipboardHistoryStore.maximumStoredFileByteCount
        )
        XCTAssertEqual(try fixture.store.load(), [item])
    }

    private func makeFixture() throws -> (
        store: EncryptedClipboardHistoryStore,
        fileURL: URL,
        keyStore: InMemoryClipboardHistoryKeyStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("history.mth")
        let keyStore = InMemoryClipboardHistoryKeyStore()
        return (
            EncryptedClipboardHistoryStore(fileURL: fileURL, keyStore: keyStore),
            fileURL,
            keyStore
        )
    }

    private func sampleItem() -> ClipboardHistoryItem {
        ClipboardHistoryItem(
            id: UUID(),
            text: "sample",
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
    }
}

final class InMemoryClipboardHistoryKeyStore: ClipboardHistoryKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var shouldFailNextDelete = false
    private(set) var didDelete = false

    var currentKey: Data? {
        lock.withLock { key }
    }

    func loadKey() throws -> Data? {
        lock.withLock { key }
    }

    func saveKey(_ data: Data) throws {
        lock.withLock { key = data }
    }

    func deleteKey() throws {
        try lock.withLock {
            if shouldFailNextDelete {
                shouldFailNextDelete = false
                throw CocoaError(.fileWriteUnknown)
            }
            key = nil
            didDelete = true
        }
    }

    func failNextDelete() {
        lock.withLock { shouldFailNextDelete = true }
    }
}
