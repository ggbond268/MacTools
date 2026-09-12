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

    func testNewPasswordMinimumCountsUserPerceivedCharacters() throws {
        let fixture = try Fixture()
        for password in ["12345678901", "中文密码", String(repeating: "e\u{301}", count: 11)] {
            XCTAssertThrowsError(try fixture.service.backUp(to: fixture.archive, password: password, scope: full)) {
                guard case ClipboardBackupError.invalidPassword = $0 else { return XCTFail("Expected short password error") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.archive.path))
        }
        for password in ["123456789012", String(repeating: "中", count: 12), String(repeating: "e\u{301}", count: 12)] {
            _ = try fixture.service.backUp(to: fixture.archive, password: password, scope: full)
            let preview = try fixture.service.preview(url: fixture.archive, password: password)
            XCTAssertEqual(preview.manifest.records, 0)
        }
        XCTAssertThrowsError(try fixture.service.backUp(to: fixture.archive,
            password: String(repeating: "中", count: 342), scope: full)) {
            guard case ClipboardBackupError.passwordTooLong = $0 else { return XCTFail("Expected long password error") }
        }
    }

    func testRestoreAcceptsLegacyPasswordWithFewerThanTwelveCharacters() throws {
        let fixture = try Fixture()
        let password = "中文密码" // Four characters, twelve UTF-8 bytes: valid under the original rule.
        // Construct an empty version-one archive with the original password policy.
        let salt = Data(repeating: 7, count: 32)
        let key = SymmetricKey(size: .bits256)
        let header = ClipboardBackupArchive.magic + ClipboardBackupArchive.integer(1, bytes: 4)
            + ClipboardBackupArchive.integer(UInt64(ClipboardBackupArchive.iterations), bytes: 4) + salt
        let wrappingKey = try ClipboardBackupArchive.derive(password: password, salt: salt, rounds: ClipboardBackupArchive.iterations)
        let wrapped = try XCTUnwrap(AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: wrappingKey, authenticating: header).combined)
        var manifest = ClipboardBackupManifest(scope: full)
        manifest.digest = Data(SHA256.hash(data: Data()))
        let terminal = Data([2]) + (try JSONEncoder().encode(manifest))
        let authentication = Data(SHA256.hash(data: header + wrapped)) + ClipboardBackupArchive.integer(0)
        let sealed = try XCTUnwrap(AES.GCM.seal(terminal, using: key,
            nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)), authenticating: authentication).combined)
        let archive = header + wrapped + ClipboardBackupArchive.integer(UInt64(sealed.count), bytes: 4) + sealed
        try archive.write(to: fixture.archive)
        let preview = try fixture.service.preview(url: fixture.archive, password: password)
        XCTAssertEqual(preview.manifest.records, 0)
        XCTAssertFalse(preview.replacement)
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

    func testRoundTripPreservesRemoteAndLegacyUnknownSources() throws {
        for origin in [ClipboardHistorySource.universalClipboard, .unknown] {
            let source = try Fixture(), destination = try Fixture()
            let item = clip(source: origin)
            try source.history.save([item])
            _ = try source.service.backUp(to: source.archive, password: password, scope: full)
            let preview = try destination.service.preview(url: source.archive, password: password)
            try destination.service.commit(preview)
            let restored = try XCTUnwrap(destination.history.load().first)
            XCTAssertEqual(restored.source, origin)
            XCTAssertNil(restored.sourceApplication)
            XCTAssertEqual(restored.savedMetadata, item.savedMetadata)
            XCTAssertEqual(try restored.loadPayload(), try item.loadPayload())
        }
    }

    func testMergingMatchingHistoryPreservesRemoteSourceInEitherDirection() throws {
        for remoteIsLocal in [true, false] {
            let source = try Fixture(), destination = try Fixture()
            let id = UUID()
            let incoming = clip(id: id, source: remoteIsLocal ? nil : .universalClipboard)
            let local = clip(id: id, source: remoteIsLocal ? .universalClipboard : nil)
            try source.history.save([incoming])
            try destination.history.save([local])
            _ = try source.service.backUp(to: source.archive, password: password, scope: full)
            let preview = try destination.service.preview(url: source.archive, password: password)
            // A legacy archive adds no metadata when the local row already has remote provenance.
            XCTAssertEqual(preview.summary.merged, remoteIsLocal ? 0 : 1)
            XCTAssertEqual(preview.summary.skipped, remoteIsLocal ? 1 : 0)
            try destination.service.commit(preview)
            let items = try destination.history.load()
            XCTAssertEqual(items.count, 1)
            let restored = try XCTUnwrap(items.first)
            XCTAssertEqual(restored.id, id)
            XCTAssertEqual(restored.source, .universalClipboard)
            XCTAssertNil(restored.sourceApplication)
            XCTAssertEqual(try restored.loadPayload(), try local.loadPayload())

            let database = try ClipboardBackupDatabase(
                url: destination.url, key: SymmetricKey(data: XCTUnwrap(destination.keyStore.currentKey))
            )
            let metadata = try XCTUnwrap(database.lookup(table: .items, id: id)).history
            XCTAssertEqual(metadata.source, .universalClipboard)
            XCTAssertNil(metadata.sourceApplication, "Remote provenance must not retain an unrelated local application")
        }
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

    func testMergeMatchingIDsCombinesMembershipAndNewerMetadata() throws {
        let source = try Fixture(), destination = try Fixture()
        let id = UUID()
        try source.history.save([clip(id: id, history: false, updated: Date(timeIntervalSince1970: 500))])
        try destination.history.save([clip(id: id, saved: false)])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.merged, 1)
        try destination.service.commit(preview)
        let result = try XCTUnwrap(destination.history.load().first)
        XCTAssertTrue(result.isSaved)
        XCTAssertTrue(result.isInHistory)
        XCTAssertEqual(result.savedMetadata?.updatedAt, Date(timeIntervalSince1970: 500))
    }

    func testUnchangedMatchingIDIsSkippedAndPartialReplacementDoesNotCountUntouchedCategories() throws {
        let source = try Fixture(), destination = try Fixture()
        let item = clip()
        try source.history.save([item])
        try destination.history.save([item])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        XCTAssertEqual(try destination.service.preview(url: source.archive, password: password).summary.skipped, 1)
        let historyOnly = clip(text: "untouched history", saved: false)
        try destination.history.save([historyOnly])
        _ = try source.service.backUp(to: source.archive, password: password, scope: ClipboardBackupScope())
        let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
        XCTAssertEqual(preview.summary.removed, 0)
        try destination.service.commit(preview)
        XCTAssertTrue(try destination.history.load().contains { $0.id == historyOnly.id && $0.isInHistory })
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

    func testDuplicateClipDigestsKeepMeaningfulDistinctMetadata() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip()])
        try destination.history.save([clip()])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        try destination.service.commit(destination.service.preview(url: source.archive, password: password))
        XCTAssertEqual(try destination.history.load().count, 2)
    }

    private func capacitySnippet(_ index: Int, bytes: Int, keyword: Bool = true) -> ClipboardSavedItem {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        return snippet(id: id, title: "Snippet \(index)", keyword: keyword ? "key\(index)" : nil,
                       text: String(repeating: "a", count: bytes))
    }

    @MainActor
    func testCapacityMergeRequiresConsentAndAllRetainedKeywordsCanExpand() async throws {
        let source = try Fixture(), destination = try Fixture()
        let bytes = 5 * 1_024 * 1_024
        for index in [100, 101] { try destination.snippets.save(capacitySnippet(index, bytes: bytes), payloadChanged: true) }
        for index in [1, 2] { try source.snippets.save(capacitySnippet(index, bytes: bytes), payloadChanged: true) }
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let before = try destination.fingerprint()
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.capacityDisabledKeywords, 1)
        XCTAssertEqual(preview.summary.disabledKeywords, 1)
        XCTAssertEqual(preview.summary.added, 2)
        let notices = try destination.service.notices(preview, offset: 0)
        XCTAssertEqual(notices.first?.kind, .keywordCapacity)
        XCTAssertEqual(notices.first?.keyword, "key2")
        XCTAssertEqual(try destination.fingerprint(), before)
        XCTAssertThrowsError(try destination.service.commit(preview)) {
            guard case ClipboardBackupError.keywordCapacityConfirmationRequired = $0 else {
                return XCTFail("Expected explicit consent before removing keyword bindings")
            }
        }
        XCTAssertEqual(try destination.fingerprint(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.service.rollbackURL.path))
        try destination.service.commit(preview, acceptingKeywordCapacityLoss: true)
        let restored = try destination.snippets.load()
        XCTAssertEqual(restored.count, 4)
        XCTAssertEqual(Set(restored.compactMap(\.keyword)), ["key1", "key100", "key101"])
        for item in restored { XCTAssertEqual(try item.loadPayload().plainText?.utf8.count, bytes) }

        let controller = ClipboardSavedLibraryController(pasteboard: BackupCapacityPasteboardStub(), persistence: destination.snippets)
        let loaded = expectation(description: "All retained keyword templates are ready")
        controller.onChange = {
            let keywords = controller.items.filter { $0.keyword != nil }
            if keywords.count == 3 && keywords.allSatisfy({ controller.templateForKeywordExpansion(id: $0.id) != nil }) {
                loaded.fulfill()
            }
        }
        controller.start()
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNil(controller.errorMessage)
        controller.onChange = nil
        controller.stop()
    }

    func testDiscardingCapacityConfirmationKeepsLocalDataAndDeletesPreview() throws {
        let source = try Fixture(), destination = try Fixture()
        let bytes = 5 * 1_024 * 1_024
        for index in [100, 101, 102] { try destination.snippets.save(capacitySnippet(index, bytes: bytes), payloadChanged: true) }
        try source.snippets.save(capacitySnippet(1, bytes: bytes), payloadChanged: true)
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let before = try destination.fingerprint()
        var preview: ClipboardBackupPreview? = try destination.service.preview(url: source.archive, password: password)
        let directory = try XCTUnwrap(preview?.directory)
        XCTAssertEqual(preview?.summary.capacityDisabledKeywords, 1)
        preview = nil
        XCTAssertEqual(try destination.fingerprint(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.service.rollbackURL.path))
    }

    func testCapacityUsesUTF8BytesAndDoesNotDoubleCountMatchingIDs() throws {
        let mebibyte = 1_024 * 1_024
        for extraByte in [0, 1] {
            let source = try Fixture(), destination = try Fixture()
            let shared = capacitySnippet(100, bytes: 5 * mebibyte)
            for item in [shared, capacitySnippet(101, bytes: 5 * mebibyte), capacitySnippet(102, bytes: 4 * mebibyte)] {
                try destination.snippets.save(item, payloadChanged: true)
            }
            try source.snippets.save(shared, payloadChanged: true)
            let incoming = snippet(title: "Unicode", keyword: "unicode",
                text: String(repeating: "é", count: mebibyte) + String(repeating: "x", count: extraByte))
            try source.snippets.save(incoming, payloadChanged: true)
            // Snippets without keywords do not consume the keyword expansion budget.
            try source.snippets.save(capacitySnippet(200, bytes: 5 * mebibyte, keyword: false), payloadChanged: true)
            _ = try source.service.backUp(to: source.archive, password: password, scope: full)
            let preview = try destination.service.preview(url: source.archive, password: password)
            XCTAssertEqual(preview.summary.capacityDisabledKeywords, extraByte)
            try destination.service.commit(preview, acceptingKeywordCapacityLoss: extraByte == 1)
            let restored = try destination.snippets.load()
            XCTAssertEqual(restored.count, 5)
            XCTAssertEqual(restored.first { $0.id == incoming.id }?.keyword, extraByte == 0 ? "unicode" : nil)
            XCTAssertEqual(try restored.first { $0.id == incoming.id }?.loadPayload().plainText, try incoming.loadPayload().plainText)
        }
    }

    func testCapacityAccountsForKeywordsRemovedByLaterMetadataMerges() throws {
        let source = try Fixture(), destination = try Fixture()
        let bytes = 5 * 1_024 * 1_024
        for index in [100, 101, 102] { try destination.snippets.save(capacitySnippet(index, bytes: bytes), payloadChanged: true) }
        var updated = capacitySnippet(100, bytes: bytes)
        updated.updateMetadata(title: updated.title, tags: updated.tags, keyword: nil,
            templateText: updated.templateText, updatedAt: Date(timeIntervalSince1970: 500))
        try source.snippets.save(updated, payloadChanged: true)
        try source.snippets.save(capacitySnippet(1, bytes: bytes), payloadChanged: true)
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.capacityDisabledKeywords, 0)
        try destination.service.commit(preview)
        XCTAssertEqual(Set(try destination.snippets.load().compactMap(\.keyword)), ["key1", "key101", "key102"])
    }

    func testCapacityReplacementReleasesRemovedLocalKeywords() throws {
        let source = try Fixture(), destination = try Fixture()
        let bytes = 5 * 1_024 * 1_024
        for index in [100, 101, 102] { try destination.snippets.save(capacitySnippet(index, bytes: bytes), payloadChanged: true) }
        for index in [1, 2] { try source.snippets.save(capacitySnippet(index, bytes: bytes), payloadChanged: true) }
        let history = clip()
        try destination.history.save([history])
        _ = try source.service.backUp(to: source.archive, password: password,
            scope: ClipboardBackupScope(history: false, saved: false, snippets: true))
        let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
        XCTAssertEqual(preview.summary.capacityDisabledKeywords, 0)
        try destination.service.commit(preview)
        XCTAssertEqual(Set(try destination.snippets.load().compactMap(\.keyword)), ["key1", "key2"])
        XCTAssertEqual(try destination.history.load().map(\.id), [history.id])
        try destination.service.commit(destination.service.previewRollback())
        XCTAssertEqual(Set(try destination.snippets.load().compactMap(\.keyword)), ["key100", "key101", "key102"])
    }

    func testCapacitySkipsOversizedCandidatesAndKeepsLaterSmallerOnes() throws {
        let source = try Fixture(), destination = try Fixture()
        let mebibyte = 1_024 * 1_024
        for (index, size) in [(100, 5), (101, 5), (102, 3)] {
            try destination.snippets.save(capacitySnippet(index, bytes: size * mebibyte), payloadChanged: true)
        }
        try source.snippets.save(capacitySnippet(1, bytes: 4 * mebibyte), payloadChanged: true)
        try source.snippets.save(capacitySnippet(2, bytes: 2 * mebibyte), payloadChanged: true)
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.capacityDisabledKeywords, 1)
        XCTAssertEqual(try destination.service.notices(preview, offset: 0).first?.keyword, "key1")
        try destination.service.commit(preview, acceptingKeywordCapacityLoss: true)
        let restored = try destination.snippets.load()
        XCTAssertEqual(restored.count, 5)
        XCTAssertEqual(Set(restored.compactMap(\.keyword)), ["key2", "key100", "key101", "key102"])
    }

    func testCapacityPreservesImportOrderAfterConflictIDsAreReassigned() throws {
        let source = try Fixture(), destination = try Fixture()
        let bytes = 5 * 1_024 * 1_024
        let local = capacitySnippet(1, bytes: bytes)
        try destination.snippets.save(local, payloadChanged: true)
        try destination.snippets.save(capacitySnippet(100, bytes: bytes), payloadChanged: true)
        try source.snippets.save(snippet(id: local.id, title: "First imported", keyword: "first",
            text: String(repeating: "b", count: bytes)), payloadChanged: true)
        try source.snippets.save(capacitySnippet(2, bytes: bytes), payloadChanged: true)
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.conflicts, 1)
        XCTAssertEqual(preview.summary.capacityDisabledKeywords, 1)
        try destination.service.commit(preview, acceptingKeywordCapacityLoss: true)
        let restored = try destination.snippets.load()
        XCTAssertEqual(restored.count, 4)
        XCTAssertEqual(Set(restored.compactMap(\.keyword)), ["key1", "key100", "first"])
        XCTAssertNotEqual(restored.first { $0.keyword == "first" }?.id, local.id)
    }

    func testDiscardingReplacementPreviewLeavesLocalDataAndRollbackUntouched() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip(text: "incoming")])
        try destination.history.save([clip(text: "local")])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let before = try destination.fingerprint()
        var stagingDirectory: URL?
        do {
            let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
            stagingDirectory = preview.directory
            XCTAssertGreaterThan(preview.summary.removed, 0)
            XCTAssertEqual(try destination.fingerprint(), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.service.rollbackURL.path))
            // Dismissing the preview without calling commit is the confirmation's Cancel path.
            withExtendedLifetime(preview) {}
        }
        XCTAssertEqual(try destination.fingerprint(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.service.rollbackURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagingDirectory).path))
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

    func testEveryReplacementScopeKeepsUnselectedLocalCategories() throws {
        for flags in 1...7 {
            let scope = ClipboardBackupScope(history: flags & 1 != 0, saved: flags & 2 != 0, snippets: flags & 4 != 0)
            let source = try Fixture(), destination = try Fixture()
            let local = clip(text: "local"), incoming = clip(text: "incoming"), localSnippet = snippet()
            try source.history.save([incoming])
            try source.snippets.save(snippet(keyword: "incoming"), payloadChanged: true)
            try destination.history.save([local])
            try destination.snippets.save(localSnippet, payloadChanged: true)
            _ = try source.service.backUp(to: source.archive, password: password, scope: scope)
            let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
            try destination.service.commit(preview)
            let items = try destination.history.load()
            if scope.history && scope.saved { XCTAssertFalse(items.contains { $0.id == local.id }) }
            else {
                let kept = try XCTUnwrap(items.first { $0.id == local.id })
                XCTAssertEqual(kept.isInHistory, !scope.history)
                XCTAssertEqual(kept.isSaved, !scope.saved)
            }
            XCTAssertEqual(try destination.snippets.load().contains { $0.id == localSnippet.id }, !scope.snippets)
        }
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

    func testConfiguredItemLimitIsEnforcedAndMissingFileReferenceIsReported() throws {
        let source = try Fixture(), destination = try Fixture(maximumItemBytes: 16)
        try source.history.save([clip(text: String(repeating: "x", count: 100))])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        XCTAssertThrowsError(try destination.service.preview(url: source.archive, password: password))
        let missing = source.directory.appendingPathComponent("does-not-exist.txt")
        let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [.init(typeIdentifier: "public.file-url", data: Data(missing.absoluteString.utf8))])])
        let item = ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil)
        try source.history.save([item])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let target = try Fixture()
        let preview = try target.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.summary.missingFileReferences, 1)
        XCTAssertEqual(try target.service.missingReferences(preview, offset: 0), [missing.path])
        try target.service.commit(preview)
        XCTAssertEqual(try target.history.load().first?.loadPayload().fileURLs, [missing])
    }

    func testSQLiteFullDuringCommitRollsBackBothTables() throws {
        let source = try Fixture(), destination = try Fixture()
        try source.history.save([clip(text: String(repeating: "x", count: 256 * 1_024))])
        try destination.history.save([clip(text: "local")])
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password, replacing: true)
        let before = try destination.fingerprint()
        destination.service.commitPageLimitForTesting = 1
        XCTAssertThrowsError(try destination.service.commit(preview))
        XCTAssertEqual(try destination.fingerprint(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.service.rollbackURL.path))
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

    func testActualTaskCancellationAfterSnapshotPreservesExistingRollback() async throws {
        let destination = try replacedFixture()
        let live = try destination.fingerprint(), rollback = try rollbackFingerprint(destination)
        let preview = try destination.service.previewRollback(), service = destination.service
        service.checkpoint = { phase in
            if phase == "beforeCommit" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let worker = Task.detached { try service.commit(preview) }
        do { try await worker.value; XCTFail("Expected cancellation after snapshot copy") }
        catch is CancellationError { }
        XCTAssertEqual(try destination.fingerprint(), live)
        XCTAssertEqual(try rollbackFingerprint(destination), rollback)
    }

    func testSQLiteFullDuringRecoveryPreservesExistingRollback() throws {
        let destination = try replacedFixture(originalText: String(repeating: "x", count: 512 * 1_024))
        let database = try ClipboardBackupDatabase(url: destination.url,
            key: SymmetricKey(data: XCTUnwrap(destination.keyStore.currentKey)))
        try database.execute("VACUUM")
        let live = try destination.fingerprint(), rollback = try rollbackFingerprint(destination)
        let preview = try destination.service.previewRollback()
        destination.service.commitPageLimitForTesting = 1
        XCTAssertThrowsError(try destination.service.commit(preview))
        XCTAssertEqual(try destination.fingerprint(), live)
        XCTAssertEqual(try rollbackFingerprint(destination), rollback)
    }

    func testIncompleteFirstRollbackCannotBeRestored() throws {
        let destination = try Fixture()
        try destination.history.save([clip(text: "keep local")])
        let live = try destination.fingerprint()
        // Models a process stopping after creating the file but before committing its schema.
        do {
            _ = try ClipboardBackupDatabase(url: destination.service.rollbackURL,
                key: SymmetricKey(data: XCTUnwrap(destination.keyStore.currentKey)), create: true, createTables: false)
        }
        XCTAssertThrowsError(try destination.service.previewRollback())
        XCTAssertEqual(try destination.fingerprint(), live)
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

    func testArchiveOmitsQueueAndPreferencesTables() throws {
        let source = try Fixture(), destination = try Fixture()
        let database = try ClipboardBackupDatabase(url: source.url, key: SymmetricKey(data: XCTUnwrap(source.keyStore.currentKey)))
        try database.execute("CREATE TABLE runtime_secret (value TEXT)")
        try database.execute("INSERT INTO runtime_secret VALUES ('queue-and-preferences-secret')")
        _ = try source.service.backUp(to: source.archive, password: password, scope: full)
        let preview = try destination.service.preview(url: source.archive, password: password)
        XCTAssertEqual(preview.manifest.records, 0)
        try destination.service.commit(preview)
        let raw = try Data(contentsOf: source.archive)
        XCTAssertNil(raw.range(of: Data("queue-and-preferences-secret".utf8)))
        let target = try ClipboardBackupDatabase(url: destination.url, key: SymmetricKey(data: XCTUnwrap(destination.keyStore.currentKey)))
        XCTAssertThrowsError(try target.execute("DELETE FROM runtime_secret"))
    }

    func testLargeSyntheticArchiveKeepsMemoryBoundedAndMainActorResponsive() async throws {
        let source = try Fixture(), destination = try Fixture()
        let database = try ClipboardBackupDatabase(url: source.url, key: SymmetricKey(data: XCTUnwrap(source.keyStore.currentKey)))
        // 128 MiB of independently encrypted representations, generated one record at a time.
        try database.transaction {
            for _ in 0..<512 {
                try autoreleasepool {
                    let payload = ClipboardHistoryPayload(pasteboardItems: [.init(representations: [
                        .init(typeIdentifier: "public.data", data: Data(repeating: 0xA7, count: 256 * 1_024))
                    ])])
                    let item = ClipboardHistoryItem(id: UUID(), payload: payload, capturedAt: Date(), sourceApplication: nil, isPinned: false, lastUsedAt: nil)
                    let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                    try database.put(ClipboardBackupRecord(table: .items, id: item.id,
                        metadata: JSONEncoder().encode(IncrementalEncryptedClipboardHistoryStore.StoredMetadata(item: item)),
                        payload: encoder.encode(payload)))
                }
            }
        }
        let before = residentBytes()
        let peaks = BackupMemorySamples()
        let service = source.service, target = destination.service, url = source.archive, password = password
        let heartbeat = expectation(description: "main actor stays responsive during archive work")
        let work = Task.detached {
            _ = try service.backUp(to: url, password: password, scope: ClipboardBackupScope(history: true, saved: true, snippets: true)) { phase in
                if case .encrypting(1) = phase { Task { @MainActor in heartbeat.fulfill() } }
                peaks.sample()
            }
            let preview = try target.preview(url: url, password: password) { _ in peaks.sample() }
            try target.commit(preview)
            return preview.manifest.records
        }
        await fulfillment(of: [heartbeat], timeout: 1)
        let restoredCount = try await work.value
        XCTAssertEqual(restoredCount, 512)
        // The archive exceeds this allowance; retaining its full plaintext would fail this bound.
        XCTAssertLessThan(peaks.peak - min(before, peaks.peak), 96 * 1_024 * 1_024)
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

@MainActor
private final class BackupCapacityPasteboardStub: ClipboardPasteboardAccess {
    var changeCount: Int { 0 }
    var typeNames: Set<String> { [] }
    func readPlainText() -> String? { nil }
    func readPayload(maximumByteCount: Int) -> ClipboardPasteboardReadResult { .empty }
    func writePlainText(_ text: String) -> Bool { false }
    func writePayload(_ payload: ClipboardHistoryPayload) -> Bool { false }
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private final class BackupMemorySamples: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64 = 0
    var peak: UInt64 { lock.withLock { maximum } }
    func sample() { lock.withLock { maximum = max(maximum, residentBytes()) } }
}
