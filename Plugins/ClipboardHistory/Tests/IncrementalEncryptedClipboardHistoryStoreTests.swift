import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import ClipboardHistoryPlugin

final class IncrementalEncryptedClipboardHistoryStoreTests: XCTestCase {
    private enum TestError: Error {
        case maintenanceFailed
        case invalidMetadata
        case sqlite(Int32)
    }

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

    func testURLOnlyLinkMetadataSurvivesLazyReload() throws {
        let fixture = try makeFixture()
        let url = "https://example.com/docs/clipboard"
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.url,
                    data: Data(url.utf8)
                ),
            ]),
        ])
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        try fixture.store.save([item])

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        let loaded = try XCTUnwrap(reopened.load().first)

        XCTAssertNil(loaded.payload)
        XCTAssertEqual(loaded.text, url)
        XCTAssertEqual(loaded.linkURLs.map(\.absoluteString), [url])
        XCTAssertEqual(ClipboardHistorySearch.filter([loaded], query: "example docs"), [loaded])
    }

    func testMetadataWrittenBeforeSummaryFieldsStillLoads() throws {
        let fixture = try makeFixture()
        let item = sampleItem(index: 1)
        try fixture.store.save([item])
        let keyData = try XCTUnwrap(fixture.keyStore.currentKey)
        try removeNewSummaryFields(
            fromMetadataFor: item.id,
            databaseURL: fixture.databaseURL,
            keyData: keyData
        )

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        let loaded = try XCTUnwrap(reopened.load().first)

        XCTAssertEqual(loaded.id, item.id)
        XCTAssertFalse(loaded.allowsRichTextImport)
        XCTAssertEqual(loaded.textCharacterCount, item.text.count)
        XCTAssertEqual(loaded.textLineCount, 1)
        XCTAssertFalse(loaded.isSearchTextTruncated)
        XCTAssertEqual(try loaded.loadPayload().plainText, item.text)
    }

    func testLongURLMetadataIsBoundedWhilePayloadKeepsTheCompleteURL() throws {
        let fixture = try makeFixture()
        let url = "https://example.com/" + String(repeating: "segment/", count: 2_000)
        let payload = ClipboardHistoryPayload(pasteboardItems: [
            ClipboardStoredPasteboardItem(representations: [
                ClipboardStoredRepresentation(
                    typeIdentifier: ClipboardRepresentationType.url,
                    data: Data(url.utf8)
                ),
            ]),
        ])
        let item = ClipboardHistoryItem(
            id: UUID(),
            payload: payload,
            capturedAt: Date(),
            sourceApplication: nil,
            isPinned: false,
            lastUsedAt: nil
        )
        XCTAssertLessThanOrEqual(
            item.linkURLs.first?.absoluteString.utf8.count ?? 0,
            ClipboardHistoryPayload.maximumMetadataURLByteCount
        )
        try fixture.store.save([item])

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        let loaded = try XCTUnwrap(reopened.load().first)
        XCTAssertLessThanOrEqual(
            loaded.linkURLs.first?.absoluteString.utf8.count ?? 0,
            ClipboardHistoryPayload.maximumMetadataURLByteCount
        )
        XCTAssertEqual(try loaded.loadPayload().linkURLs.first?.absoluteString, url)
        XCTAssertEqual(ClipboardPlainTextConversion.text(for: loaded), url)
    }

    func testResetRemovesEverySQLiteSidecarLegacyFileAndKey() throws {
        let fixture = try makeFixture()
        let legacyURL = fixture.directoryURL.appendingPathComponent("history.mth")
        let store = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            legacyFileURL: legacyURL,
            keyStore: fixture.keyStore
        )
        try store.save([sampleItem(index: 1)])
        try Data("legacy".utf8).write(to: legacyURL)
        let sidecars = ["-journal", "-wal", "-shm"].map {
            URL(fileURLWithPath: fixture.databaseURL.path + $0)
        }
        for sidecar in sidecars {
            FileManager.default.createFile(atPath: sidecar.path, contents: Data("sidecar".utf8))
        }

        try store.reset()

        for url in [fixture.databaseURL, legacyURL] + sidecars {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path)
        }
        XCTAssertTrue(fixture.keyStore.didDelete)
        XCTAssertNil(fixture.keyStore.currentKey)
    }

    func testRemoveAllRemovesRollbackJournalAndInvalidatesStore() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem(index: 1)])
        let journalURL = URL(fileURLWithPath: fixture.databaseURL.path + "-journal")
        FileManager.default.createFile(atPath: journalURL.path, contents: Data("journal".utf8))

        try fixture.store.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(fixture.keyStore.didDelete)
        XCTAssertTrue(try fixture.store.load().isEmpty)
    }

    func testPostCommitMaintenanceFailureDoesNotReportDurableSaveAsFailed() throws {
        let fixture = try makeFixture(postCommitMaintenance: {
            throw TestError.maintenanceFailed
        })
        let first = sampleItem(index: 1)
        let second = sampleItem(index: 2)
        try fixture.store.save([first, second])

        XCTAssertNoThrow(try fixture.store.save([second]))

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        XCTAssertEqual(try reopened.load().map(\.id), [second.id])
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

    private func makeFixture(
        postCommitMaintenance: (@Sendable () throws -> Void)? = nil
    ) throws -> (
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
                keyStore: keyStore,
                postCommitMaintenance: postCommitMaintenance
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

    private func removeNewSummaryFields(
        fromMetadataFor id: UUID,
        databaseURL: URL,
        keyData: Data
    ) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            throw TestError.sqlite(openResult)
        }
        defer { sqlite3_close(database) }

        let encryptedMetadata = try metadata(for: id, database: database)
        let magic = Data([0x4D, 0x54, 0x48, 0x4D, 0x31])
        guard encryptedMetadata.starts(with: magic) else {
            throw TestError.invalidMetadata
        }
        let sealedBox = try AES.GCM.SealedBox(
            combined: Data(encryptedMetadata.dropFirst(magic.count))
        )
        let key = SymmetricKey(data: keyData)
        let authenticatedID = Data(id.uuidString.utf8)
        let plaintext = try AES.GCM.open(
            sealedBox,
            using: key,
            authenticating: authenticatedID
        )
        guard var object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw TestError.invalidMetadata
        }
        for key in [
            "allowsRichTextImport",
            "textCharacterCount",
            "textLineCount",
            "isSearchTextTruncated",
        ] {
            guard object.removeValue(forKey: key) != nil else {
                throw TestError.invalidMetadata
            }
        }
        let legacyPlaintext = try JSONSerialization.data(withJSONObject: object)
        let legacyBox = try AES.GCM.seal(
            legacyPlaintext,
            using: key,
            authenticating: authenticatedID
        )
        guard let combined = legacyBox.combined else {
            throw TestError.invalidMetadata
        }
        try updateMetadata(magic + combined, for: id, database: database)
    }

    private func metadata(for id: UUID, database: OpaquePointer) throws -> Data {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT metadata FROM items WHERE id = ?",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw TestError.sqlite(prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            throw TestError.invalidMetadata
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func updateMetadata(
        _ metadata: Data,
        for id: UUID,
        database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "UPDATE items SET metadata = ? WHERE id = ?",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw TestError.sqlite(prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = metadata.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard bindResult == SQLITE_OK else {
            throw TestError.sqlite(bindResult)
        }
        sqlite3_bind_text(statement, 2, id.uuidString, -1, transient)
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else {
            throw TestError.sqlite(stepResult)
        }
    }
}
