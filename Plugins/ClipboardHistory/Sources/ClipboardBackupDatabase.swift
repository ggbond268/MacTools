import CryptoKit
import Foundation
import SQLite3

/// Private staging databases contain only destination-key-encrypted persistent rows.
final class ClipboardBackupDatabase {
    let handle: OpaquePointer
    let key: SymmetricKey
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, key: SymmetricKey, create: Bool = false) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ClipboardBackupError.storage
        }
        handle = database
        self.key = key
        sqlite3_busy_timeout(database, 1_000)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, Int32(ClipboardBackupArchive.maximumFrameBytes))
        do {
            try execute("PRAGMA temp_store=FILE")
            try execute("PRAGMA cache_size=-2048")
            if create {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                for table in ClipboardBackupRecord.Table.allCases {
                    try execute("CREATE TABLE IF NOT EXISTS \(table.rawValue) (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL, payload BLOB NOT NULL)")
                }
            }
        } catch { sqlite3_close(database); throw error }
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String, values: [Data] = [], text: String? = nil) throws {
        let statement = try statement(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, data) in values.enumerated() { try bind(data, at: Int32(offset + 1), to: statement) }
        if let text { guard sqlite3_bind_text(statement, 1, text, -1, Self.transient) == SQLITE_OK else { throw ClipboardBackupError.storage } }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipboardBackupError.storage }
    }

    func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ClipboardBackupError.storage
        }
        return statement
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func forEachRaw(_ body: (ClipboardBackupRecord.Table, UUID, Data, Data) throws -> Void) throws {
        for table in ClipboardBackupRecord.Table.allCases {
            let statement = try statement("SELECT id, metadata, payload FROM \(table.rawValue) ORDER BY id")
            defer { sqlite3_finalize(statement) }
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                try Task.checkCancellation()
                guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) else {
                    throw ClipboardBackupError.invalidArchive
                }
                try autoreleasepool { try body(table, id, column(statement, 1), column(statement, 2)) }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw ClipboardBackupError.storage }
        }
    }

    func forEach(_ body: (ClipboardBackupRecord) throws -> Void) throws {
        try forEachRaw { table, id, metadata, payload in
            try body(open(table: table, id: id, metadata: metadata, payload: payload))
        }
    }

    func open(table: ClipboardBackupRecord.Table, id: UUID, metadata: Data, payload: Data) throws -> ClipboardBackupRecord {
        let prefix = table == .items ? "MTH" : "MTS"
        return try ClipboardBackupRecord(table: table, id: id,
            metadata: decrypt(metadata, magic: prefix + "M1", id: id),
            payload: decrypt(payload, magic: prefix + "P1", id: id))
    }

    func lookup(table: ClipboardBackupRecord.Table, id: UUID) throws -> ClipboardBackupRecord? {
        let statement = try statement("SELECT metadata, payload FROM \(table.rawValue) WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, Self.transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw ClipboardBackupError.storage }
        return try open(table: table, id: id, metadata: column(statement, 0), payload: column(statement, 1))
    }

    func put(_ record: ClipboardBackupRecord) throws {
        let prefix = record.table == .items ? "MTH" : "MTS"
        try putRaw(table: record.table, id: record.id,
                   metadata: encrypt(record.metadata, magic: prefix + "M1", id: record.id),
                   payload: encrypt(record.payload, magic: prefix + "P1", id: record.id))
    }

    func putRaw(table: ClipboardBackupRecord.Table, id: UUID, metadata: Data, payload: Data) throws {
        let statement = try statement("INSERT INTO \(table.rawValue) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata, payload=excluded.payload")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, Self.transient)
        try bind(metadata, at: 2, to: statement)
        try bind(payload, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipboardBackupError.storage }
    }

    func remove(_ record: ClipboardBackupRecord) throws {
        try execute("DELETE FROM \(record.table.rawValue) WHERE id=?1", text: record.id.uuidString)
    }

    func fingerprint() throws -> Data {
        var digest = SHA256()
        try forEachRaw { table, id, metadata, payload in
            digest.update(data: Data((table.rawValue + id.uuidString).utf8))
            digest.update(data: ClipboardBackupArchive.integer(UInt64(metadata.count)))
            digest.update(data: metadata)
            digest.update(data: ClipboardBackupArchive.integer(UInt64(payload.count)))
            digest.update(data: payload)
        }
        return Data(digest.finalize())
    }

    func copyRows(to destination: ClipboardBackupDatabase) throws {
        try destination.transaction {
            try forEachRaw { table, id, metadata, payload in
                try destination.putRaw(table: table, id: id, metadata: metadata, payload: payload)
            }
        }
    }

    func keywordToken(_ keyword: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(keyword.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).utf8), using: key))
    }

    func prepareKeywordIndex() throws {
        try execute("CREATE TABLE keywords (token BLOB NOT NULL, id TEXT NOT NULL, PRIMARY KEY(token, id))")
        try forEach { record in
            if record.table == .saved_items, let keyword = try record.snippet.keyword { try indexKeyword(keyword, id: record.id) }
        }
    }

    func indexKeyword(_ keyword: String, id: UUID) throws {
        let statement = try statement("INSERT OR IGNORE INTO keywords VALUES (?1, ?2)")
        defer { sqlite3_finalize(statement) }
        try bind(keywordToken(keyword), at: 1, to: statement)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipboardBackupError.storage }
    }

    func keywordConflicts(_ keyword: String, id: UUID) throws -> Bool {
        let statement = try statement("SELECT 1 FROM keywords WHERE token=?1 AND id != ?2 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind(keywordToken(keyword), at: 1, to: statement)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, Self.transient)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw ClipboardBackupError.storage }
        return result == SQLITE_ROW
    }

    func prepareMissingReferences() throws {
        try execute("CREATE TABLE IF NOT EXISTS missing_references (position INTEGER PRIMARY KEY, id TEXT NOT NULL, path BLOB NOT NULL)")
    }

    func addMissingReferences(_ paths: [String]) throws {
        for path in paths {
            let id = UUID()
            let statement = try statement("INSERT INTO missing_references(id,path) VALUES (?1,?2)")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id.uuidString, -1, Self.transient)
            try bind(encrypt(Data(path.utf8), magic: "MTBF1", id: id), at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipboardBackupError.storage }
        }
    }

    func missingReferences(offset: Int, limit: Int = 50) throws -> [String] {
        guard offset >= 0, limit > 0, limit <= 100 else { throw ClipboardBackupError.limitExceeded }
        let statement = try statement("SELECT id,path FROM missing_references ORDER BY position LIMIT ?1 OFFSET ?2")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(limit))
        sqlite3_bind_int64(statement, 2, Int64(offset))
        var paths: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            try Task.checkCancellation()
            guard let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)),
                  let path = String(data: try decrypt(column(statement, 1), magic: "MTBF1", id: id), encoding: .utf8) else {
                throw ClipboardBackupError.invalidArchive
            }
            paths.append(path)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ClipboardBackupError.storage }
        return paths
    }

    private func bind(_ data: Data, at index: Int32, to statement: OpaquePointer) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
        guard result == SQLITE_OK else { throw ClipboardBackupError.storage }
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, count <= ClipboardBackupArchive.maximumFrameBytes, let bytes = sqlite3_column_blob(statement, index) else {
            throw ClipboardBackupError.limitExceeded
        }
        return Data(bytes: bytes, count: count)
    }

    private func encrypt(_ data: Data, magic: String, id: UUID) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(id.uuidString.utf8))
        guard let combined = sealed.combined else { throw ClipboardBackupError.invalidArchive }
        return Data(magic.utf8) + combined
    }

    private func decrypt(_ data: Data, magic: String, id: UUID) throws -> Data {
        guard data.starts(with: Data(magic.utf8)) else { throw ClipboardBackupError.invalidArchive }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(data.dropFirst(5))), using: key,
                                    authenticating: Data(id.uuidString.utf8))
        } catch { throw ClipboardBackupError.invalidArchive }
    }
}
