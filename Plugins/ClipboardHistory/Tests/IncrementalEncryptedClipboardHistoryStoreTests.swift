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

    func testTargetedChangesPreserveUnchangedEncryptedRowsAndLazyPayloads() throws {
        let fixture = try makeFixture()
        let originals = (0..<3).map(sampleItem)
        try fixture.store.save(originals)
        var loaded = try fixture.store.load()
        let editedID = loaded[0].id
        let untouchedID = loaded[1].id
        let previous = loaded
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(fixture.databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        let untouchedMetadata = try metadata(for: untouchedID, database: connection)
        loaded[0].setSavedMetadata(ClipboardHistorySavedMetadata(title: "Keep", savedAt: Date()))
        loaded.removeLast()
        try fixture.store.saveChanges(
            loaded,
            applying: ClipboardHistoryMutation.between(previous, loaded)
        )
        XCTAssertEqual(try metadata(for: untouchedID, database: connection), untouchedMetadata)
        XCTAssertTrue(loaded.allSatisfy { $0.payload == nil })
        let reopened = IncrementalEncryptedClipboardHistoryStore(databaseURL: fixture.databaseURL, keyStore: fixture.keyStore)
        let verified = try reopened.load()
        XCTAssertEqual(Set(verified.map(\.id)), [editedID, untouchedID])
        XCTAssertTrue(try XCTUnwrap(verified.first { $0.id == editedID }).isSaved)
        XCTAssertTrue(verified.allSatisfy { $0.payload == nil })
    }

    func testTargetedSaveDoesNotRecreateDeletedItemFromStaleMetadata() throws {
        let fixture = try makeFixture()
        let original = sampleItem(index: 1)
        try fixture.store.save([original])
        let loaded = try XCTUnwrap(fixture.store.load().first)
        var staleUsage = loaded
        staleUsage.lastUsedAt = Date(timeIntervalSince1970: 500)
        let mutation = ClipboardHistoryMutation(changes: [
            .init(id: loaded.id, before: loaded, after: nil),
            .init(id: loaded.id, before: loaded, after: staleUsage),
        ])
        let expected = mutation.applying(to: [loaded])

        try fixture.store.saveChanges(expected, applying: mutation)

        XCTAssertTrue(try fixture.store.load().isEmpty)
    }

    func testMixedHistoryAndSnippetDeletionCommitsInOneSharedTransaction() throws {
        let fixture = try makeFixture()
        let coordinator = ClipboardDatabaseAccessCoordinator()
        let historyStore = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore,
            databaseAccess: coordinator
        )
        let savedStore = IncrementalEncryptedClipboardSavedLibraryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore,
            databaseAccess: coordinator
        )
        let historyItem = sampleItem(index: 1)
        let snippet = ClipboardSavedItem(
            title: "Reusable",
            keyword: ";reuse",
            savedKind: .snippet,
            payload: .plainText("Reusable text"),
            templateText: "Reusable text"
        )
        try historyStore.save([historyItem])
        try savedStore.save(snippet, payloadChanged: true)
        let mutation = ClipboardHistoryMutation.between([historyItem], [])

        try historyStore.saveChanges(
            [],
            applying: mutation,
            deletingSavedItemIDs: [snippet.id]
        )

        XCTAssertTrue(try historyStore.load().isEmpty)
        XCTAssertTrue(try savedStore.load().isEmpty)
    }

    func testRoundTripPreservesUnifiedHistoryAndSavedRolesOnOneItem() throws {
        let fixture = try makeFixture()
        var item = sampleItem(index: 1)
        item.setHistoryMembership(false)
        item.setSavedMetadata(ClipboardHistorySavedMetadata(
            title: "Reusable value",
            tags: ["project", "email"],
            savedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        ))

        try fixture.store.save([item])

        let reopened = IncrementalEncryptedClipboardHistoryStore(
            databaseURL: fixture.databaseURL,
            keyStore: fixture.keyStore
        )
        let loaded = try XCTUnwrap(reopened.load().first)
        XCTAssertEqual(loaded.id, item.id)
        XCTAssertFalse(loaded.isInHistory)
        XCTAssertTrue(loaded.isSaved)
        XCTAssertEqual(loaded.savedMetadata, item.savedMetadata)
        XCTAssertEqual(try loaded.loadPayload().plainText, item.text)
        XCTAssertEqual(ClipboardHistorySearch.filter([loaded], query: "project"), [loaded])
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

    func testResetRotatesEncryptionKeyBeforeNewHistoryIsWritten() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem(index: 1)])
        let previousKey = try XCTUnwrap(fixture.keyStore.currentKey)

        try fixture.store.reset()
        try fixture.store.prepare()

        let replacementKey = try XCTUnwrap(fixture.keyStore.currentKey)
        XCTAssertNotEqual(replacementKey, previousKey)
        XCTAssertTrue(try fixture.store.load().isEmpty)
    }

    func testResetKeyDeletionFailurePreservesHistoryUntilRotationCanSucceed() throws {
        let fixture = try makeFixture()
        try fixture.store.save([sampleItem(index: 1)])
        let previousKey = try XCTUnwrap(fixture.keyStore.currentKey)
        fixture.keyStore.failNextDelete()

        XCTAssertThrowsError(try fixture.store.reset())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
        XCTAssertEqual(fixture.keyStore.currentKey, previousKey)
        XCTAssertEqual(try fixture.store.load().map(\.text), ["clipboard item 1"])

        try fixture.store.reset()
        try fixture.store.prepare()
        XCTAssertNotEqual(fixture.keyStore.currentKey, previousKey)
        XCTAssertTrue(try fixture.store.load().isEmpty)
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

}
