import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ClipboardHistoryPlugin

final class ClipboardBackupServiceTests: XCTestCase {
    private let password = "a-long-test-password-394"
    private let full = ClipboardBackupScope(history: true, saved: true, snippets: true)

    private final class Fixture {
        let directory: URL
        let keyStore = InMemoryClipboardHistoryKeyStore()
        let history: IncrementalEncryptedClipboardHistoryStore
        let snippets: IncrementalEncryptedClipboardSavedLibraryStore
        let service: ClipboardBackupService
        let url: URL
        init(maximumItemBytes: Int = 5 * 1_024 * 1_024) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("clipboard.sqlite3")
            let access = ClipboardDatabaseAccessCoordinator()
            history = IncrementalEncryptedClipboardHistoryStore(databaseURL: url, keyStore: keyStore, databaseAccess: access)
            snippets = IncrementalEncryptedClipboardSavedLibraryStore(databaseURL: url, keyStore: keyStore, databaseAccess: access)
            service = ClipboardBackupService(databaseURL: url, keyStore: keyStore, access: access, maximumItemBytes: maximumItemBytes)
            try history.prepare()
            try snippets.prepare()
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var archive: URL { directory.appendingPathComponent("test.mactoolsclipboard") }
        func fingerprint() throws -> Data {
            try ClipboardBackupDatabase(url: url, key: SymmetricKey(data: XCTUnwrap(keyStore.currentKey))).fingerprint()
        }
    }

    private func clip(id: UUID = UUID(), text: String = "private-original-representation", history: Bool = true,
                      saved: Bool = true, updated: Date = Date(timeIntervalSince1970: 300),
                      source: ClipboardHistorySource? = nil) -> ClipboardHistoryItem {
        ClipboardHistoryItem(id: id, payload: .plainText(text), capturedAt: Date(timeIntervalSince1970: 100),
            sourceApplication: ClipboardSourceApplication(bundleIdentifier: "test.private.app", name: "Private App"),
            isPinned: false, lastUsedAt: Date(timeIntervalSince1970: 200), imageSearchText: "private OCR metadata",
            hasCompletedImageTextIndexing: true, isInHistory: history,
            savedMetadata: saved ? ClipboardHistorySavedMetadata(title: "Private saved title", tags: ["tag"], savedAt: Date(timeIntervalSince1970: 150), updatedAt: updated) : nil,
            source: source)
    }

    private func snippet(id: UUID = UUID(), title: String = "Snippet", keyword: String? = "hello", text: String = "Hello {{cursor}}") -> ClipboardSavedItem {
        ClipboardSavedItem(id: id, title: title, tags: ["private tag"], keyword: keyword, savedKind: .snippet,
                           createdAt: Date(timeIntervalSince1970: 120), updatedAt: Date(timeIntervalSince1970: 200),
                           lastUsedAt: Date(timeIntervalSince1970: 250), payload: .plainText(text), templateText: text)
    }

    private func backupRecord(for item: ClipboardSavedItem) throws -> ClipboardBackupRecord {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try ClipboardBackupRecord(
            table: .saved_items, id: item.id,
            metadata: JSONEncoder().encode(ClipboardBackupRecord.Snippet(item: item)),
            payload: encoder.encode(item.loadPayload())
        )
    }

    func testRoundTripAllCategoriesPreservesMetadataAndUsesDestinationKey() throws {
        let source = try Fixture(), destination = try Fixture()
        let item = clip(), saved = snippet()
        try source.history.save([item])
        try source.snippets.save(saved, payloadChanged: true)
        let manifest = try source.service.backUp(to: source.archive, password: password, scope: full)
        XCTAssertEqual(manifest.records, 2)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.added, 2)
        XCTAssertFalse(preview.replacement)
        try destination.service.commit(preview)
        let restored = try XCTUnwrap(destination.history.load().first)
        XCTAssertEqual(restored, item)
        XCTAssertEqual(try restored.loadPayload(), try item.loadPayload())
        let restoredSnippet = try XCTUnwrap(destination.snippets.load().first)
        XCTAssertEqual(restoredSnippet.id, saved.id)
        XCTAssertEqual(restoredSnippet.title, saved.title)
        XCTAssertEqual(restoredSnippet.tags, saved.tags)
        XCTAssertEqual(restoredSnippet.keyword, saved.keyword)
        XCTAssertEqual(restoredSnippet.createdAt, saved.createdAt)
        XCTAssertEqual(restoredSnippet.updatedAt, saved.updatedAt)
        XCTAssertEqual(restoredSnippet.lastUsedAt, saved.lastUsedAt)
        XCTAssertEqual(try restoredSnippet.loadPayload(), try saved.loadPayload())
        XCTAssertNotEqual(source.keyStore.currentKey, destination.keyStore.currentKey)
        let sourceKeyReader = try ClipboardBackupDatabase(url: destination.url, key: SymmetricKey(data: XCTUnwrap(source.keyStore.currentKey)))
        XCTAssertThrowsError(try sourceKeyReader.forEach { _ in })
        let raw = try Data(contentsOf: source.archive)
        for secret in ["private-original-representation", "Private saved title", "private OCR metadata", "test.private.app", "Hello {{cursor}}", password] {
            XCTAssertNil(raw.range(of: Data(secret.utf8)))
        }
        XCTAssertNil(raw.range(of: try XCTUnwrap(source.keyStore.currentKey)))
    }

    func testSelectiveScopesStripUnselectedMembership() throws {
        let source = try Fixture()
        try source.history.save([clip()])
        try source.snippets.save(snippet(), payloadChanged: true)
        for scope in [ClipboardBackupScope(), ClipboardBackupScope(history: true, saved: false, snippets: false), ClipboardBackupScope(history: false, saved: true, snippets: false)] {
            let destination = try Fixture()
            _ = try source.service.backUp(to: source.archive, password: password, scope: scope)
            let preview = try destination.service.preview(url: source.archive, password: password)
            try destination.service.commit(preview)
            let restored = try XCTUnwrap(destination.history.load().first)
            XCTAssertEqual(restored.isInHistory, scope.history)
            XCTAssertEqual(restored.isSaved, scope.saved)
            XCTAssertEqual(try destination.snippets.load().count, scope.snippets ? 1 : 0)
        }
    }

    func testConflictingIDsPreserveBothAndDuplicateSnippetBodiesRemainDistinct() throws {
        let source = try Fixture(), destination = try Fixture()
        let id = UUID()
        try source.history.save([clip(id: id, text: "incoming")])
        try destination.history.save([clip(id: id, text: "local")])
        try source.snippets.save(snippet(title: "Incoming", keyword: "HELLO"), payloadChanged: true)
        try destination.snippets.save(snippet(title: "Local", keyword: "hello"), payloadChanged: true)
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.conflicts, 1)
        XCTAssertEqual(preview.summary.disabledKeywords, 1)
        let notices = try destination.service.notices(preview, offset: 0)
        XCTAssertEqual(notices.filter { $0.kind == .identifierConflict }.count, 1)
        XCTAssertEqual(notices.first { $0.kind == .disabledKeyword }?.title, "Incoming")
        try destination.service.commit(preview)
        XCTAssertEqual(Set(try destination.history.load().map(\.text)), ["local", "incoming"])
        let snippets = try destination.snippets.load()
        XCTAssertEqual(snippets.count, 2)
        XCTAssertEqual(snippets.first { $0.title == "Local" }?.keyword, "hello")
        XCTAssertNil(snippets.first { $0.title == "Incoming" }?.keyword)
    }
    func testKeywordCapacityPreservesLocalBindingsAndAllPayloads() throws {
        let fixture = try Fixture()
        let database = try ClipboardBackupDatabase(
            url: fixture.url, key: SymmetricKey(data: XCTUnwrap(fixture.keyStore.currentKey))
        )
        let local = snippet(keyword: "local", text: "Local content")
        let incoming = snippet(keyword: "incoming", text: "Imported content")
        var localRecord = try backupRecord(for: local)
        var metadata = try localRecord.snippet
        // Capacity accounting reads metadata only; no cache-sized payload is needed here.
        metadata.payloadByteCount = ClipboardSavedItem.maximumKeywordExpansionCacheByteCount
        localRecord.metadata = try JSONEncoder().encode(metadata)
        try database.put(localRecord)
        try database.prepareKeywordIndex()
        let incomingRecord = try backupRecord(for: incoming)
        try database.put(incomingRecord)
        try database.indexKeyword(XCTUnwrap(incoming.keyword), id: incoming.id)
        try database.orderKeyword(id: incoming.id, originalID: incoming.id)
        var disabledIDs: [UUID] = []

        try database.enforceKeywordCapacity { id, _, _ in disabledIDs.append(id) }

        XCTAssertEqual(disabledIDs, [incoming.id])
        let retainedLocal = try XCTUnwrap(database.lookup(table: .saved_items, id: local.id))
        let retainedIncoming = try XCTUnwrap(database.lookup(table: .saved_items, id: incoming.id))
        XCTAssertEqual(retainedLocal.metadata, localRecord.metadata)
        XCTAssertEqual(retainedLocal.payload, localRecord.payload)
        XCTAssertNil(try retainedIncoming.snippet.keyword)
        XCTAssertEqual(retainedIncoming.payload, incomingRecord.payload)
    }

    func testCapacityLossRequiresConsentBeforeCommittingPreview() throws {
        let fixture = try Fixture()
        let local = snippet(keyword: "local", text: "Keep local content")
        let incoming = snippet(keyword: nil, text: "Keep imported content")
        try fixture.snippets.save(local, payloadChanged: true)
        let before = try fixture.fingerprint()
        let key = SymmetricKey(data: try XCTUnwrap(fixture.keyStore.currentKey))
        let live = try ClipboardBackupDatabase(url: fixture.url, key: key)
        let directory = fixture.directory.appendingPathComponent("preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = try ClipboardBackupDatabase(
            url: directory.appendingPathComponent("staged.sqlite3"), key: key, create: true
        )
        try live.copyRows(to: staged)
        try staged.put(backupRecord(for: incoming))
        // Commit consumes a completed preview; archive and capacity calculation have separate coverage.
        let preview = ClipboardBackupPreview(
            directory: directory,
            manifest: ClipboardBackupManifest(scope: full, records: 1),
            summary: ClipboardBackupSummary(added: 1, disabledKeywords: 1, capacityDisabledKeywords: 1),
            fingerprint: before, stagedFingerprint: try staged.fingerprint(), replacement: false
        )

        XCTAssertThrowsError(try fixture.service.commit(preview)) {
            guard case ClipboardBackupError.keywordCapacityConfirmationRequired = $0 else {
                return XCTFail("Expected consent before dropping an imported keyword binding")
            }
        }
        XCTAssertEqual(try fixture.fingerprint(), before)
        try fixture.service.commit(preview, acceptingKeywordCapacityLoss: true)

        let restored = try fixture.snippets.load()
        XCTAssertEqual(Set(restored.map(\.id)), [local.id, incoming.id])
        for expected in [local, incoming] {
            let actual = try XCTUnwrap(restored.first { $0.id == expected.id })
            XCTAssertEqual(actual.keyword, expected.keyword)
            XCTAssertEqual(try actual.loadPayload(), try expected.loadPayload())
        }
    }

    func testPartialReplacementKeepsOtherMembershipAndRollbackRecoversEverything() throws {
        let source = try Fixture(), destination = try Fixture()
        let local = clip(), incoming = clip(text: "incoming")
        let localSnippet = snippet()
        try destination.history.save([local])
        try destination.snippets.save(localSnippet, payloadChanged: true)
        try source.history.save([incoming])
        let before = try destination.fingerprint()
        _ = try source.service.backUp(to: source.archive, password: password, scope: ClipboardBackupScope())
        let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
        XCTAssertEqual(preview.summary.removed, 2)
        try destination.service.commit(preview)
        let items = try destination.history.load()
        XCTAssertEqual(items.first { $0.id == local.id }?.isInHistory, true)
        XCTAssertEqual(items.first { $0.id == local.id }?.isSaved, false)
        XCTAssertEqual(items.first { $0.id == incoming.id }?.isInHistory, false)
        XCTAssertTrue(try destination.snippets.load().isEmpty)
        let rollback = try destination.service.previewRollback()
        try destination.service.commit(rollback)
        let restoredLocal = try XCTUnwrap(destination.history.load().first)
        XCTAssertEqual(try destination.history.load().map(\.id), [local.id])
        XCTAssertEqual(restoredLocal, local)
        XCTAssertEqual(try restoredLocal.loadPayload(), try local.loadPayload())
        let restoredSnippet = try XCTUnwrap(destination.snippets.load().first)
        XCTAssertEqual(restoredSnippet.id, localSnippet.id)
        XCTAssertEqual(restoredSnippet.title, localSnippet.title)
        XCTAssertEqual(restoredSnippet.tags, localSnippet.tags)
        XCTAssertEqual(restoredSnippet.keyword, localSnippet.keyword)
        XCTAssertEqual(try restoredSnippet.loadPayload(), try localSnippet.loadPayload())
        // Payloads are resealed during staging, so compare decoded content rather than ciphertext.
        XCTAssertNotEqual(try destination.fingerprint(), before)
        XCTAssertEqual(try destination.history.load().first?.savedMetadata, local.savedMetadata)
    }

    func testFullReplacementAndCommitFailuresAreAtomic() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip(text: "new")])
        try source.snippets.save(snippet(title: "New"), payloadChanged: true)
        try destination.history.save([clip(text: "old")])
        try destination.snippets.save(snippet(title: "Old"), payloadChanged: true)
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let before = try destination.fingerprint()
        for point in ["beforeSnapshot", "beforeCommit", "duringCommit"] {
            let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
            destination.service.checkpoint = { phase in if phase == point { throw ClipboardBackupError.storage } }
            XCTAssertThrowsError(try destination.service.commit(preview))
            XCTAssertEqual(try destination.fingerprint(), before)
        }
        destination.service.checkpoint = nil
        try destination.service.commit(destination.service.preview(url: source.archive, password: password, replacing: true))
        XCTAssertEqual(try destination.history.load().map(\.text), ["new"])
        XCTAssertEqual(try destination.snippets.load().map(\.title), ["New"])
    }

    func testWrongPasswordCorruptionTruncationReorderAndOversizedFramesDoNotChangeLiveData() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip(), clip(text: "second")])
        try destination.history.save([clip(text: "local")])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let before = try destination.fingerprint(), original = try Data(contentsOf: source.archive)
        XCTAssertThrowsError(try destination.service.preview(url: source.archive, password: "wrong password"))
        var tag = original; tag[tag.count - 1] ^= 1
        var future = original; future[11] = 2
        var kdf = original; kdf.replaceSubrange(12..<16, with: ClipboardBackupArchive.integer(2_000_001, bytes: 4))
        var oversized = original; oversized.replaceSubrange(108..<112, with: ClipboardBackupArchive.integer(UInt64.max, bytes: 4))
        let frames = splitFrames(original)
        let reordered = original.prefix(108) + frames[1] + frames[0] + frames[2]
        let duplicated = original.prefix(108) + frames[0] + frames[0] + frames[1] + frames[2]
        for invalid in [tag, future, kdf, oversized, Data(original.dropLast()), Data(original.prefix(112)), reordered, duplicated, original + Data([0])] {
            try invalid.write(to: source.archive)
            XCTAssertThrowsError(try destination.service.preview(url: source.archive, password: password))
            XCTAssertEqual(try destination.fingerprint(), before)
        }
    }

    func testAuthenticatedMalformedRecordsAndManifestMismatchAreRejected() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip()])
        let database = try ClipboardBackupDatabase(url: source.url, key: SymmetricKey(data: XCTUnwrap(source.keyStore.currentKey)))
        var records: [ClipboardBackupRecord] = []
        try database.forEach { records.append($0) }
        var bad = records[0]; bad.id = UUID()
        for values in [[bad], [records[0], records[0]]] {
            let writer = try ClipboardBackupArchive.Writer(url: source.archive, password: password)
            for record in values { try writer.append(record) }
            try writer.finish(ClipboardBackupManifest(scope: full, records: values.count))
            XCTAssertThrowsError(try destination.service.preview(url: source.archive, password: password))
        }
        let writer = try ClipboardBackupArchive.Writer(url: source.archive, password: password)
        try writer.append(records[0])
        try writer.finish(ClipboardBackupManifest(scope: ClipboardBackupScope(history: false, saved: false, snippets: true), records: 1))
        XCTAssertThrowsError(try destination.service.preview(url: source.archive, password: password))
    }

    private func replacedFixture(originalText: String = "original") throws -> Fixture {
        let source = try Fixture(), destination = try Fixture()
        try destination.history.save([clip(text: originalText)])
        try destination.snippets.save(snippet(title: "Original snippet"), payloadChanged: true)
        try source.history.save([clip(text: "replacement")])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        try destination.service.commit(destination.service.preview(url: source.archive, password: password, replacing: true))
        return destination
    }

    private func rollbackFingerprint(_ fixture: Fixture) throws -> Data {
        try ClipboardBackupDatabase(url: fixture.service.rollbackURL,
            key: SymmetricKey(data: XCTUnwrap(fixture.keyStore.currentKey))).fingerprint()
    }

    func testFailedRecoveryPreservesExistingRollbackAndAllowsRetry() throws {
        for point in ["beforeCommit", "duringCommit"] {
            let destination = try replacedFixture()
            let live = try destination.fingerprint(), rollback = try rollbackFingerprint(destination)
            let preview = try destination.service.previewRollback()
            destination.service.checkpoint = { phase in
                if phase == point { throw ClipboardBackupError.storage }
            }
            XCTAssertThrowsError(try destination.service.commit(preview))
            XCTAssertEqual(try destination.fingerprint(), live)
            XCTAssertEqual(try rollbackFingerprint(destination), rollback)
            destination.service.checkpoint = nil
            try destination.service.commit(destination.service.previewRollback())
            XCTAssertEqual(try destination.history.load().map(\.text), ["original"])
            XCTAssertEqual(try destination.snippets.load().map(\.title), ["Original snippet"])
            XCTAssertEqual(try rollbackFingerprint(destination), live)
        }
    }

    func testConcurrentMutationInvalidatesPreview() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip()])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        try destination.history.save([clip(text: "changed")])
        let before = try destination.fingerprint()
        XCTAssertThrowsError(try destination.service.commit(preview))
        XCTAssertEqual(try destination.fingerprint(), before)
    }

    func testCancellationBeforeEveryPrecommitPhaseLeavesDataAndArchiveUnchanged() async throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip()])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let before = try destination.fingerprint(), archive = try Data(contentsOf: source.archive)
        for point in ["reading", "encrypting", "validating", "staging", "beforeSnapshot", "beforeCommit"] {
            let isBackup = ["reading", "encrypting"].contains(point)
            let service = isBackup ? source.service : destination.service
            service.checkpoint = { phase in if phase == point { throw CancellationError() } }
            do {
                if isBackup { _ = try service.backUp(to: source.archive, password: password, scope: full) }
                else {
                    let preview = try service.preview(url: source.archive, password: password, replacing: true)
                    try service.commit(preview)
                }
                XCTFail("Expected cancellation at \(point)")
            } catch is CancellationError { }
            service.checkpoint = nil
            XCTAssertEqual(try destination.fingerprint(), before)
            XCTAssertEqual(try Data(contentsOf: source.archive), archive)
        }
        let service = destination.service, url = source.archive, password = password
        let cancelled = Task.detached { try Task.checkCancellation(); return try service.preview(url: url, password: password) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancelled task") } catch is CancellationError { }
    }

    private func splitFrames(_ data: Data) -> [Data] {
        var offset = 108, frames: [Data] = []
        while offset < data.count {
            let length = Int(ClipboardBackupArchive.number(data.subdata(in: offset..<(offset + 4)))) + 4
            frames.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return frames
    }
}
