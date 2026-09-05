import CryptoKit
import Foundation
import Security
import SQLite3

actor EncryptedClipboardSequentialPasteStore: ClipboardSequentialPasteSessionPersisting {
    private static let rowID = "active"
    private static let envelopeMagic = Data([0x4D, 0x54, 0x51, 0x53, 0x31]) // MTQS1
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL
    private let keyStore: any ClipboardHistoryKeyStoring
    private let fileManager: FileManager
    private let databaseAccess: ClipboardDatabaseAccessCoordinator

    init(
        databaseURL: URL,
        keyStore: any ClipboardHistoryKeyStoring,
        fileManager: FileManager = .default,
        databaseAccess: ClipboardDatabaseAccessCoordinator
    ) {
        self.databaseURL = databaseURL
        self.keyStore = keyStore
        self.fileManager = fileManager
        self.databaseAccess = databaseAccess
    }

    func loadExplicitSession() async throws -> ClipboardSequentialPasteSession? {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        return try databaseAccess.withActiveAccess { () -> ClipboardSequentialPasteSession? in
            try Task.checkCancellation()
            try prepare()
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            let statement = try prepareStatement(
                "SELECT session FROM sequential_paste_session WHERE id = ?1",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(Self.rowID, index: 1, statement: statement, database: database)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                guard result == SQLITE_DONE else { throw sqliteError(database) }
                return nil
            }
            let encrypted = try columnData(statement, index: 0)
            let plaintext = try Self.open(encrypted, key: try encryptionKey())
            let session = try PropertyListDecoder().decode(
                ClipboardSequentialPasteSession.self,
                from: plaintext
            )
            guard session.source == .explicitQueue, !session.isComplete else {
                try deleteSession(database: database)
                return nil
            }
            return session
        }
    }

    func saveExplicitSession(_ session: ClipboardSequentialPasteSession?) async throws {
        try Task.checkCancellation()
        if session == nil, !fileManager.fileExists(atPath: databaseURL.path) {
            return
        }
        try databaseAccess.withActiveAccess {
            try Task.checkCancellation()
            try prepare()
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            guard let session, session.source == .explicitQueue, !session.isComplete else {
                try deleteSession(database: database)
                return
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let plaintext = try encoder.encode(session)
            let encrypted = try Self.seal(plaintext, key: try encryptionKey())
            let statement = try prepareStatement(
                "INSERT INTO sequential_paste_session (id, session) VALUES (?1, ?2) "
                    + "ON CONFLICT(id) DO UPDATE SET session = excluded.session",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(Self.rowID, index: 1, statement: statement, database: database)
            try bind(encrypted, index: 2, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
        }
    }

    private func prepare() throws {
        do {
            try fileManager.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ClipboardHistoryStoreError.unavailableStorage
        }
        try ClipboardHistoryKeyInitializationLock.shared.withLock {
            let hasDatabase = fileManager.fileExists(atPath: databaseURL.path)
            if let key = try keyStore.loadKey() {
                guard key.count == EncryptedClipboardHistoryStore.keyByteCount else {
                    throw ClipboardHistoryStoreError.invalidEncryptionKey
                }
            } else if hasDatabase {
                throw ClipboardHistoryStoreError.missingEncryptionKey
            } else {
                try keyStore.saveKey(Self.makeRandomKey())
            }
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try execute(
            "CREATE TABLE IF NOT EXISTS sequential_paste_session "
                + "(id TEXT PRIMARY KEY NOT NULL, session BLOB NOT NULL)",
            database: database
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: databaseURL.path
        )
    }

    private func encryptionKey() throws -> SymmetricKey {
        guard let data = try keyStore.loadKey() else {
            throw ClipboardHistoryStoreError.missingEncryptionKey
        }
        guard data.count == EncryptedClipboardHistoryStore.keyByteCount else {
            throw ClipboardHistoryStoreError.invalidEncryptionKey
        }
        return SymmetricKey(data: data)
    }

    private static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(Self.rowID.utf8)
        )
        guard let combined = sealed.combined else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        return envelopeMagic + combined
    }

    private static func open(_ storedData: Data, key: SymmetricKey) throws -> Data {
        guard storedData.starts(with: envelopeMagic) else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: Data(storedData.dropFirst(envelopeMagic.count)))
            return try AES.GCM.open(
                sealed,
                using: key,
                authenticating: Data(Self.rowID.utf8)
            )
        } catch {
            throw ClipboardHistoryStoreError.authenticationFailed
        }
    }

    private static func makeRandomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: EncryptedClipboardHistoryStore.keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ClipboardHistoryStoreError.keychain(status) }
        return Data(bytes)
    }

    private func openDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw ClipboardHistoryStoreError.unavailableStorage
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }

    private func deleteSession(database: OpaquePointer) throws {
        let statement = try prepareStatement(
            "DELETE FROM sequential_paste_session WHERE id = ?1",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(Self.rowID, index: 1, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func prepareStatement(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw sqliteError(database) }
        return statement
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bind(
        _ value: String,
        index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func bind(
        _ value: Data,
        index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.sqliteTransient
            )
        }
        guard result == SQLITE_OK else { throw sqliteError(database) }
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else { throw ClipboardHistoryStoreError.invalidEnvelope }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        return Data(bytes: bytes, count: count)
    }

    private func sqliteError(_ database: OpaquePointer) -> ClipboardHistoryStoreError {
        _ = database
        return .unavailableStorage
    }
}
