import CryptoKit
import Foundation
import Security
import SQLite3

final class IncrementalEncryptedClipboardSavedLibraryStore:
    ClipboardSavedLibraryPersisting,
    @unchecked Sendable
{
    private struct StoredMetadata: Codable {
        let id: UUID
        let title: String
        let tags: [String]
        let keyword: String?
        let isFavorite: Bool
        let savedKind: ClipboardSavedItemKind
        let createdAt: Date
        let updatedAt: Date
        var lastUsedAt: Date?
        let sourceApplication: ClipboardSourceApplication?
        let contentKind: ClipboardHistoryContentKind
        let payloadByteCount: Int
        let fileURLs: [String]
        let fileReferenceCount: Int
        let linkURLs: [String]
        let representationTypeIdentifiers: [String]
        let payloadDigest: Data
        let templateSearchText: String?
        let hasDynamicTemplateContent: Bool?
        let clipSearchText: String?
        let imageSearchText: String?

        init(item: ClipboardSavedItem) {
            id = item.id
            title = item.title
            tags = item.tags
            keyword = item.keyword
            isFavorite = item.isFavorite
            savedKind = item.savedKind
            createdAt = item.createdAt
            updatedAt = item.updatedAt
            lastUsedAt = item.lastUsedAt
            sourceApplication = item.sourceApplication
            contentKind = item.contentKind
            payloadByteCount = item.payloadByteCount
            fileURLs = item.fileURLs.map(\.absoluteString)
            fileReferenceCount = item.fileReferenceCount
            linkURLs = item.linkURLs.map(\.absoluteString)
            representationTypeIdentifiers = item.representationTypeIdentifiers
            payloadDigest = item.payloadDigest
            templateSearchText = item.templateSearchText
            hasDynamicTemplateContent = item.hasDynamicTemplateContent
            clipSearchText = item.clipSearchText
            imageSearchText = item.imageSearchText
        }
    }

    private static let metadataMagic = Data([0x4D, 0x54, 0x53, 0x4D, 0x31]) // MTSM1
    private static let payloadMagic = Data([0x4D, 0x54, 0x53, 0x50, 0x31]) // MTSP1
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let minimumFreeDiskReserve = 512 * 1_024 * 1_024

    let databaseURL: URL
    private let keyStore: any ClipboardHistoryKeyStoring
    private let fileManager: FileManager
    private let databaseAccess: ClipboardDatabaseAccessCoordinator
    private let lock = NSLock()
    private var isInvalidated = false

    init(
        databaseURL: URL,
        keyStore: any ClipboardHistoryKeyStoring,
        fileManager: FileManager = .default,
        databaseAccess: ClipboardDatabaseAccessCoordinator = ClipboardDatabaseAccessCoordinator()
    ) {
        self.databaseURL = databaseURL
        self.keyStore = keyStore
        self.fileManager = fileManager
        self.databaseAccess = databaseAccess
    }

    func prepare() throws {
        try databaseAccess.withAccess { try lock.withLock { try prepareLocked() } }
    }

    /// Uninstall permanently retires this instance, including escaped lazy payload loaders.
    func invalidate() {
        databaseAccess.withExclusiveAccess { lock.withLock { isInvalidated = true } }
    }

    func load() throws -> [ClipboardSavedItem] {
        try databaseAccess.withAccess { try lock.withLock {
            guard !isInvalidated else { return [] }
            try prepareLocked()
            let key = try encryptionKeyLocked()
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            let statement = try prepareStatement(
                "SELECT id, metadata FROM saved_items",
                database: database
            )
            defer { sqlite3_finalize(statement) }

            var items: [ClipboardSavedItem] = []
            var stepResult = sqlite3_step(statement)
            while stepResult == SQLITE_ROW {
                guard let identifierText = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: identifierText)) else {
                    throw ClipboardHistoryStoreError.invalidEnvelope
                }
                let encryptedMetadata = try columnData(statement, index: 1)
                let metadataData = try Self.open(
                    encryptedMetadata,
                    magic: Self.metadataMagic,
                    key: key,
                    authenticatedID: id
                )
                let metadata: StoredMetadata
                do {
                    metadata = try JSONDecoder().decode(StoredMetadata.self, from: metadataData)
                } catch {
                    throw ClipboardHistoryStoreError.invalidEnvelope
                }
                guard metadata.id == id else {
                    throw ClipboardHistoryStoreError.invalidEnvelope
                }
                items.append(makeItem(metadata: metadata))
                stepResult = sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE else { throw sqliteError(database) }
            return items
        } }
    }

    func save(_ item: ClipboardSavedItem, payloadChanged: Bool) throws {
        try databaseAccess.withAccess { try lock.withLock {
            guard !isInvalidated else { throw ClipboardHistoryStoreError.unavailableStorage }
            try prepareLocked()
            let key = try encryptionKeyLocked()
            let metadata = try JSONEncoder().encode(StoredMetadata(item: item))
            let encryptedMetadata = try Self.seal(
                metadata,
                magic: Self.metadataMagic,
                key: key,
                authenticatedID: item.id
            )
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            let exists = try contains(id: item.id, database: database)

            if !exists || payloadChanged {
                let payload = try item.loadPayload()
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let encodedPayload = try encoder.encode(payload)
                try requireAvailableDiskCapacity(
                    forAdditionalBytes: encodedPayload.count + encryptedMetadata.count + 128
                )
                let encryptedPayload = try Self.seal(
                    encodedPayload,
                    magic: Self.payloadMagic,
                    key: key,
                    authenticatedID: item.id
                )
                try upsert(
                    id: item.id,
                    metadata: encryptedMetadata,
                    payload: encryptedPayload,
                    database: database
                )
            } else {
                try updateMetadata(
                    id: item.id,
                    metadata: encryptedMetadata,
                    database: database
                )
            }
        } }
    }

    func updateLastUsedAt(id: UUID, date: Date) throws {
        try databaseAccess.withAccess { try lock.withLock {
            guard !isInvalidated else { throw ClipboardHistoryStoreError.unavailableStorage }
            try prepareLocked()
            let key = try encryptionKeyLocked()
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            let statement = try prepareStatement(
                "SELECT metadata FROM saved_items WHERE id = ?1",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, index: 1, statement: statement, database: database)
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else {
                if result == SQLITE_DONE { return }
                throw sqliteError(database)
            }

            let encryptedMetadata = try columnData(statement, index: 0)
            let metadataData = try Self.open(
                encryptedMetadata,
                magic: Self.metadataMagic,
                key: key,
                authenticatedID: id
            )
            var metadata: StoredMetadata
            do {
                metadata = try JSONDecoder().decode(StoredMetadata.self, from: metadataData)
            } catch {
                throw ClipboardHistoryStoreError.invalidEnvelope
            }
            guard metadata.id == id else { throw ClipboardHistoryStoreError.invalidEnvelope }
            metadata.lastUsedAt = date
            let updatedMetadata = try JSONEncoder().encode(metadata)
            let encryptedUpdatedMetadata = try Self.seal(
                updatedMetadata,
                magic: Self.metadataMagic,
                key: key,
                authenticatedID: id
            )
            try updateMetadata(
                id: id,
                metadata: encryptedUpdatedMetadata,
                database: database
            )
        } }
    }

    func delete(id: UUID) throws {
        try databaseAccess.withAccess { try lock.withLock {
            guard !isInvalidated else { return }
            try prepareLocked()
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            let statement = try prepareStatement(
                "DELETE FROM saved_items WHERE id = ?1",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, index: 1, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
        } }
    }

    func removeAll() throws {
        try databaseAccess.withAccess { try lock.withLock {
            guard !isInvalidated,
                  fileManager.fileExists(atPath: databaseURL.path) else { return }
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            try execute("DELETE FROM saved_items", database: database)
            try execute("PRAGMA incremental_vacuum", database: database)
        } }
    }

    private func makeItem(metadata: StoredMetadata) -> ClipboardSavedItem {
        ClipboardSavedItem(
            id: metadata.id,
            title: metadata.title,
            tags: metadata.tags,
            keyword: metadata.keyword,
            isFavorite: metadata.isFavorite,
            savedKind: metadata.savedKind,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            lastUsedAt: metadata.lastUsedAt,
            sourceApplication: metadata.sourceApplication,
            contentKind: metadata.contentKind,
            payloadByteCount: metadata.payloadByteCount,
            fileURLs: metadata.fileURLs.compactMap(URL.init(string:)),
            fileReferenceCount: metadata.fileReferenceCount,
            linkURLs: metadata.linkURLs.compactMap(URL.init(string:)),
            representationTypeIdentifiers: metadata.representationTypeIdentifiers,
            payloadDigest: metadata.payloadDigest,
            templateSearchText: metadata.templateSearchText,
            hasDynamicTemplateContent: metadata.hasDynamicTemplateContent
                ?? ClipboardSnippetTemplateEngine.containsDynamicContent(
                    metadata.templateSearchText ?? ""
                ),
            clipSearchText: metadata.clipSearchText,
            imageSearchText: metadata.imageSearchText,
            payloadLoader: { [weak self] in
                guard let self else { throw ClipboardHistoryPayloadAccessError.unavailable }
                return try self.loadPayload(id: metadata.id)
            }
        )
    }

    func loadPayload(id: UUID) throws -> ClipboardHistoryPayload {
        try databaseAccess.withAccess { try lock.withLock {
            guard !isInvalidated else { throw ClipboardHistoryPayloadAccessError.unavailable }
            let key = try encryptionKeyLocked()
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            let statement = try prepareStatement(
                "SELECT payload FROM saved_items WHERE id = ?1",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, index: 1, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ClipboardHistoryPayloadAccessError.unavailable
            }
            let encryptedPayload = try columnData(statement, index: 0)
            let payloadData = try Self.open(
                encryptedPayload,
                magic: Self.payloadMagic,
                key: key,
                authenticatedID: id
            )
            do {
                return try PropertyListDecoder().decode(ClipboardHistoryPayload.self, from: payloadData)
            } catch {
                throw ClipboardHistoryStoreError.invalidEnvelope
            }
        } }
    }

    private func prepareLocked() throws {
        guard !isInvalidated else { return }
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
                guard try keyStore.loadKey()?.count == EncryptedClipboardHistoryStore.keyByteCount else {
                    throw ClipboardHistoryStoreError.missingEncryptionKey
                }
            }
        }

        let database = try openDatabaseLocked()
        defer { sqlite3_close(database) }
        try execute(
            "CREATE TABLE IF NOT EXISTS saved_items (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL, payload BLOB NOT NULL)",
            database: database
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: databaseURL.path
        )
    }

    private func encryptionKeyLocked() throws -> SymmetricKey {
        guard let data = try keyStore.loadKey() else {
            throw ClipboardHistoryStoreError.missingEncryptionKey
        }
        guard data.count == EncryptedClipboardHistoryStore.keyByteCount else {
            throw ClipboardHistoryStoreError.invalidEncryptionKey
        }
        return SymmetricKey(data: data)
    }

    private func openDatabaseLocked() throws -> OpaquePointer {
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

    private func contains(id: UUID, database: OpaquePointer) throws -> Bool {
        let statement = try prepareStatement(
            "SELECT 1 FROM saved_items WHERE id = ?1 LIMIT 1",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, database: database)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw sqliteError(database) }
        return result == SQLITE_ROW
    }

    private func upsert(
        id: UUID,
        metadata: Data,
        payload: Data,
        database: OpaquePointer
    ) throws {
        let statement = try prepareStatement(
            "INSERT INTO saved_items (id, metadata, payload) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET metadata = excluded.metadata, payload = excluded.payload",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, database: database)
        try bind(metadata, index: 2, statement: statement, database: database)
        try bind(payload, index: 3, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func updateMetadata(id: UUID, metadata: Data, database: OpaquePointer) throws {
        let statement = try prepareStatement(
            "UPDATE saved_items SET metadata = ?1 WHERE id = ?2",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(metadata, index: 1, statement: statement, database: database)
        try bind(id.uuidString, index: 2, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private static func seal(
        _ plaintext: Data,
        magic: Data,
        key: SymmetricKey,
        authenticatedID: UUID
    ) throws -> Data {
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(authenticatedID.uuidString.utf8)
        )
        guard let combined = sealed.combined else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        return magic + combined
    }

    private static func open(
        _ storedData: Data,
        magic: Data,
        key: SymmetricKey,
        authenticatedID: UUID
    ) throws -> Data {
        guard storedData.starts(with: magic) else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: Data(storedData.dropFirst(magic.count)))
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: Data(authenticatedID.uuidString.utf8)
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

    private func requireAvailableDiskCapacity(forAdditionalBytes count: Int) throws {
        let values = try databaseURL.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard available - Int64(count) >= Int64(Self.minimumFreeDiskReserve) else {
            throw ClipboardHistoryStoreError.insufficientDiskSpace
        }
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
        sqlite3_errcode(database) == SQLITE_FULL ? .insufficientDiskSpace : .unavailableStorage
    }
}
