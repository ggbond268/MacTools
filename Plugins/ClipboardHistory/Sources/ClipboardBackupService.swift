import CryptoKit
import Foundation
import SQLite3

struct ClipboardBackupSummary: Equatable, Sendable {
    var added = 0
    var merged = 0
    var conflicts = 0
    var skipped = 0
    var disabledKeywords = 0
    var missingFileReferences = 0
    var removed = 0
}

struct ClipboardBackupNotice: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case identifierConflict, disabledKeyword }
    let kind: Kind
    let id: UUID
    let originalID: UUID
    let title: String?
    let keyword: String?
}

enum ClipboardBackupPhase: Sendable {
    case reading, encrypting(Int), validating(Int), staging(Int, Int), finishing
}

/// Owns encrypted staging files; releasing a preview discards all uncommitted work.
final class ClipboardBackupPreview: @unchecked Sendable {
    let directory: URL
    let databaseURL: URL
    let manifest: ClipboardBackupManifest
    let summary: ClipboardBackupSummary
    let fingerprint: Data
    let replacement: Bool
    let stagedFingerprint: Data

    init(directory: URL, manifest: ClipboardBackupManifest, summary: ClipboardBackupSummary,
         fingerprint: Data, stagedFingerprint: Data, replacement: Bool) {
        self.directory = directory
        databaseURL = directory.appendingPathComponent("staged.sqlite3")
        self.manifest = manifest
        self.summary = summary
        self.fingerprint = fingerprint
        self.stagedFingerprint = stagedFingerprint
        self.replacement = replacement
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

final class ClipboardBackupService: @unchecked Sendable {
    let databaseURL: URL
    let rollbackURL: URL
    private let keyStore: any ClipboardHistoryKeyStoring
    private let access: ClipboardDatabaseAccessCoordinator
    let maximumItemBytes: Int
    /// Fault injection never runs in production; tests exercise transaction rollback boundaries.
    var commitPageLimitForTesting: Int?
    var checkpoint: (@Sendable (String) throws -> Void)?

    init(databaseURL: URL, keyStore: any ClipboardHistoryKeyStoring,
         access: ClipboardDatabaseAccessCoordinator, maximumItemBytes: Int) {
        self.databaseURL = databaseURL
        self.rollbackURL = databaseURL.deletingLastPathComponent().appendingPathComponent("clipboard-rollback.sqlite3")
        self.keyStore = keyStore
        self.access = access
        self.maximumItemBytes = min(max(1, maximumItemBytes), 64 * 1_024 * 1_024)
    }

    private func key() throws -> SymmetricKey {
        guard let data = try keyStore.loadKey(), data.count == 32 else { throw ClipboardBackupError.storage }
        return SymmetricKey(data: data)
    }

    private func directory() throws -> URL {
        let url = databaseURL.deletingLastPathComponent().appendingPathComponent("clipboard-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    func backUp(to url: URL, password: String, scope: ClipboardBackupScope,
                progress: @Sendable (ClipboardBackupPhase) -> Void = { _ in }) throws -> ClipboardBackupManifest {
        guard !scope.isEmpty else { throw ClipboardBackupError.invalidArchive }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved != databaseURL.standardizedFileURL.resolvingSymlinksInPath(),
              resolved != rollbackURL.standardizedFileURL.resolvingSymlinksInPath(),
              url.pathExtension.lowercased() == "mactoolsclipboard" else { throw ClipboardBackupError.storage }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mactoolsclipboard")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress(.reading)
        let key = try key()
        let writer = try ClipboardBackupArchive.Writer(url: temporary, password: password)
        var manifest = ClipboardBackupManifest(scope: scope)
        try access.withActiveAccess {
            let source = try ClipboardBackupDatabase(url: databaseURL, key: key)
            try source.execute("BEGIN")
            defer { try? source.execute("ROLLBACK") }
            try source.forEach { original in
                try checkpoint?("reading")
                guard let record = try original.selected(scope: scope) else { return }
                let counts = try record.validate(maximumItemBytes: maximumItemBytes)
                try checkpoint?("encrypting")
                try writer.append(record)
                manifest.records += 1
                manifest.history += counts.history
                manifest.saved += counts.saved
                manifest.snippets += counts.snippets
                manifest.payloadBytes += Int64(counts.bytes)
                guard manifest.payloadBytes <= ClipboardBackupArchive.maximumArchiveBytes else { throw ClipboardBackupError.limitExceeded }
                progress(.encrypting(manifest.records))
            }
        }
        try writer.finish(manifest)
        try Task.checkCancellation()
        // POSIX rename atomically replaces an existing archive only after the new file is complete.
        guard rename(temporary.path, url.path) == 0 else { throw ClipboardBackupError.storage }
        return manifest
    }

    func preview(url: URL, password: String, replacing: Bool = false,
                 progress: @Sendable (ClipboardBackupPhase) -> Void = { _ in }) throws -> ClipboardBackupPreview {
        progress(.reading)
        let directory = try directory()
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let key = try key()
        let references = try ClipboardBackupDatabase(url: directory.appendingPathComponent("references.sqlite3"), key: key, create: true)
        try references.prepareMissingReferences()
        let incoming = try ClipboardBackupDatabase(url: directory.appendingPathComponent("incoming.sqlite3"), key: key, create: true)
        try incoming.execute("CREATE TABLE seen (id TEXT PRIMARY KEY NOT NULL)")
        var counts = ClipboardBackupManifest(scope: ClipboardBackupScope())
        var missing = 0
        let manifest = try incoming.transaction {
            try ClipboardBackupArchive.read(url: url, password: password, maximumItemBytes: maximumItemBytes) { record in
                try checkpoint?("validating")
                let value = try record.validate(maximumItemBytes: maximumItemBytes)
                // Reject repeated stable IDs even across record types; never silently overwrite staging.
                try incoming.execute("INSERT INTO seen VALUES (?1)", text: record.id.uuidString)
                try incoming.put(record)
                counts.records += 1
                counts.history += value.history
                counts.saved += value.saved
                counts.snippets += value.snippets
                counts.payloadBytes += Int64(value.bytes)
                missing += value.missing.count
                try references.addMissingReferences(value.missing)
                guard counts.payloadBytes <= ClipboardBackupArchive.maximumArchiveBytes else { throw ClipboardBackupError.limitExceeded }
                progress(.validating(counts.records))
            }
        }
        guard manifest.records == counts.records, manifest.history == counts.history,
              manifest.saved == counts.saved, manifest.snippets == counts.snippets,
              manifest.payloadBytes == counts.payloadBytes,
              manifest.scope.history || counts.history == 0,
              manifest.scope.saved || counts.saved == 0,
              manifest.scope.snippets || counts.snippets == 0 else { throw ClipboardBackupError.invalidArchive }
        let result = try stage(incoming: incoming, directory: directory, key: key, manifest: manifest,
                               missing: missing, replacing: replacing, progress: progress)
        succeeded = true
        return result
    }

    /// The rollback is local and already device encrypted; authentication is still checked per row.
    func previewRollback(progress: @Sendable (ClipboardBackupPhase) -> Void = { _ in }) throws -> ClipboardBackupPreview {
        let directory = try directory()
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let key = try key()
        let references = try ClipboardBackupDatabase(url: directory.appendingPathComponent("references.sqlite3"), key: key, create: true)
        try references.prepareMissingReferences()
        let incoming = try ClipboardBackupDatabase(url: rollbackURL, key: key)
        var manifest = ClipboardBackupManifest(scope: ClipboardBackupScope(history: true, saved: true, snippets: true))
        var missing = 0
        try incoming.forEach { record in
            let counts = try record.validate(maximumItemBytes: maximumItemBytes)
            manifest.records += 1
            manifest.history += counts.history
            manifest.saved += counts.saved
            manifest.snippets += counts.snippets
            manifest.payloadBytes += Int64(counts.bytes)
            missing += counts.missing.count
            try references.addMissingReferences(counts.missing)
        }
        let result = try stage(incoming: incoming, directory: directory, key: key, manifest: manifest,
                               missing: missing, replacing: true, progress: progress)
        succeeded = true
        return result
    }

    private func stage(incoming: ClipboardBackupDatabase, directory: URL, key: SymmetricKey,
                       manifest: ClipboardBackupManifest, missing: Int, replacing: Bool,
                       progress: @Sendable (ClipboardBackupPhase) -> Void) throws -> ClipboardBackupPreview {
        let staged = try ClipboardBackupDatabase(url: directory.appendingPathComponent("staged.sqlite3"), key: key, create: true)
        let fingerprint = try access.withActiveAccess {
            let live = try ClipboardBackupDatabase(url: databaseURL, key: key)
            try live.execute("BEGIN")
            defer { try? live.execute("ROLLBACK") }
            let fingerprint = try live.fingerprint()
            try live.copyRows(to: staged)
            return fingerprint
        }
        let notices = try ClipboardBackupDatabase(url: directory.appendingPathComponent("notices.sqlite3"), key: key, create: true)
        try notices.prepareMissingReferences()
        func report(_ notice: ClipboardBackupNotice) throws {
            let data = try JSONEncoder().encode(notice)
            try notices.addMissingReferences([String(decoding: data, as: UTF8.self)])
        }
        var summary = ClipboardBackupSummary(missingFileReferences: missing)
        try staged.transaction {
            if replacing {
                // Iterate a separate connection so deleting/updating rows cannot disturb the cursor.
                let original = try ClipboardBackupDatabase(url: directory.appendingPathComponent("original.sqlite3"), key: key, create: true)
                try staged.copyRows(to: original)
                let retained = ClipboardBackupScope(history: !manifest.scope.history,
                                                    saved: !manifest.scope.saved, snippets: !manifest.scope.snippets)
                try original.forEach { record in
                    try checkpoint?("staging")
                    if let remainder = try record.selected(scope: retained) {
                        if try !remainder.hasSameMetadata(as: record) { summary.removed += 1 }
                        try staged.put(remainder)
                    } else { summary.removed += 1; try staged.remove(record) }
                }
            }
            try staged.prepareKeywordIndex()
            var processed = 0
            try incoming.forEach { incomingRecord in
                try Task.checkCancellation()
                try checkpoint?("staging")
                var record = incomingRecord
                let local = try staged.lookup(table: record.table, id: record.id)
                let otherTable: ClipboardBackupRecord.Table = record.table == .items ? .saved_items : .items
                let other = try staged.lookup(table: otherTable, id: record.id)
                if let local, try record.hasSamePayload(as: local), try record.canMergeMetadata(with: local) {
                    record = try record.merging(local)
                    if try record.hasSameMetadata(as: local) { summary.skipped += 1 }
                    else { summary.merged += 1 }
                } else if local != nil || other != nil {
                    repeat { record = try incomingRecord.changingID(UUID()) }
                    while try staged.lookup(table: .items, id: record.id) != nil || staged.lookup(table: .saved_items, id: record.id) != nil
                    summary.conflicts += 1
                    try report(ClipboardBackupNotice(kind: .identifierConflict, id: record.id,
                        originalID: incomingRecord.id, title: nil, keyword: nil))
                } else { summary.added += 1 }
                if record.table == .saved_items {
                    if let keyword = try record.snippet.keyword, try staged.keywordConflicts(keyword, id: record.id) {
                        try report(ClipboardBackupNotice(kind: .disabledKeyword, id: record.id,
                            originalID: incomingRecord.id, title: try record.snippet.title, keyword: keyword))
                        record = try record.disablingKeyword()
                        summary.disabledKeywords += 1
                    }
                    try staged.execute("DELETE FROM keywords WHERE id=?1", text: record.id.uuidString)
                    if let keyword = try record.snippet.keyword { try staged.indexKeyword(keyword, id: record.id) }
                }
                try staged.put(record)
                processed += 1
                progress(.staging(processed, manifest.records))
            }
        }
        try Task.checkCancellation()
        return ClipboardBackupPreview(directory: directory, manifest: manifest, summary: summary,
                                      fingerprint: fingerprint, stagedFingerprint: try staged.fingerprint(), replacement: replacing)
    }

    func missingReferences(_ preview: ClipboardBackupPreview, offset: Int) throws -> [String] {
        let references = try ClipboardBackupDatabase(url: preview.directory.appendingPathComponent("references.sqlite3"), key: key())
        return try references.missingReferences(offset: offset)
    }

    func notices(_ preview: ClipboardBackupPreview, offset: Int) throws -> [ClipboardBackupNotice] {
        let database = try ClipboardBackupDatabase(url: preview.directory.appendingPathComponent("notices.sqlite3"), key: key())
        return try database.missingReferences(offset: offset).map {
            try JSONDecoder().decode(ClipboardBackupNotice.self, from: Data($0.utf8))
        }
    }

    func commit(_ preview: ClipboardBackupPreview, progress: @Sendable (ClipboardBackupPhase) -> Void = { _ in }) throws {
        let key = try key()
        try access.withActiveAccess {
            let hadRollback = FileManager.default.fileExists(atPath: rollbackURL.path)
            var committed = false
            defer {
                if preview.replacement, !hadRollback, !committed {
                    try? FileManager.default.removeItem(at: rollbackURL)
                }
            }
            let live = try ClipboardBackupDatabase(url: databaseURL, key: key)
            let staged = try ClipboardBackupDatabase(url: preview.databaseURL, key: key)
            if let limit = commitPageLimitForTesting {
                let statement = try live.statement("PRAGMA max_page_count=\(max(1, limit))")
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw ClipboardBackupError.storage }
            }
            guard try staged.fingerprint() == preview.stagedFingerprint else { throw ClipboardBackupError.invalidArchive }
            try live.execute("ATTACH DATABASE ?1 AS restored", text: preview.databaseURL.path)
            defer { try? live.execute("DETACH DATABASE restored") }
            if preview.replacement {
                // Rollback journals let SQLite commit both files atomically, including recovery
                // after a process crash. WAL cannot provide that multi-database guarantee.
                try live.useDurableRollbackJournal()
                do {
                    // Create the schema inside the transaction: a crash before the first commit
                    // must not leave an empty database that could be mistaken for valid recovery.
                    let rollback = try ClipboardBackupDatabase(url: rollbackURL, key: key, create: true, createTables: false)
                    try rollback.useDurableRollbackJournal()
                }
                try live.execute("ATTACH DATABASE ?1 AS recovery", text: rollbackURL.path)
                try live.execute("PRAGMA recovery.synchronous=FULL")
            }
            defer { if preview.replacement { try? live.execute("DETACH DATABASE recovery") } }
            try live.transaction {
                guard try live.fingerprint() == preview.fingerprint else { throw ClipboardBackupError.changedSincePreview }
                try checkpoint?("beforeSnapshot")
                if preview.replacement {
                    for table in ClipboardBackupRecord.Table.allCases {
                        try Task.checkCancellation()
                        try live.execute("CREATE TABLE IF NOT EXISTS recovery.\(table.rawValue) (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL, payload BLOB NOT NULL)")
                        try live.execute("DELETE FROM recovery.\(table.rawValue)")
                        try live.execute("INSERT INTO recovery.\(table.rawValue) SELECT id,metadata,payload FROM main.\(table.rawValue)")
                    }
                }
                try checkpoint?("beforeCommit")
                try Task.checkCancellation()
                progress(.finishing)
                // No cancellation checks after this point. Live data and its rollback change together.
                for table in ClipboardBackupRecord.Table.allCases {
                    try live.execute("DELETE FROM main.\(table.rawValue)")
                    try checkpoint?("duringCommit")
                    try live.execute("INSERT INTO main.\(table.rawValue) SELECT id,metadata,payload FROM restored.\(table.rawValue)")
                }
            }
            committed = true
        }
    }
}
