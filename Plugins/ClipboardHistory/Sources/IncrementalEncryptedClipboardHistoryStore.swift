import CryptoKit
import Foundation
import SQLite3

final class IncrementalEncryptedClipboardHistoryStore: ClipboardHistoryPersisting, @unchecked Sendable {
    private struct StoredMetadata: Codable {
        let id: UUID
        let text: String
        let capturedAt: Date
        let sourceApplication: ClipboardSourceApplication?
        let kind: ClipboardHistoryContentKind
        let payloadByteCount: Int
        let filterContentKinds: [ClipboardHistoryContentKind]?
        let fileURLs: [String]?
        let fileReferenceCount: Int?
        let linkURLs: [String]?
        let representationTypeIdentifiers: [String]?
        let payloadDigest: Data
        // These summary fields were added while the incremental store was already in use by
        // development builds. Keep them optional so older encrypted rows remain decodable.
        let allowsRichTextImport: Bool?
        let textCharacterCount: Int?
        let textLineCount: Int?
        let isSearchTextTruncated: Bool?
        let lastUsedAt: Date?
        let imageSearchText: String?
        let hasCompletedImageTextIndexing: Bool?
        let isInHistory: Bool?
        let savedMetadata: ClipboardHistorySavedMetadata?

        init(item: ClipboardHistoryItem) {
            id = item.id
            text = item.text
            capturedAt = item.capturedAt
            sourceApplication = item.sourceApplication
            kind = item.kind
            payloadByteCount = item.payloadByteCount
            filterContentKinds = item.filterContentKinds.sorted { $0.rawValue < $1.rawValue }
            fileURLs = item.fileURLs.map(\.absoluteString)
            fileReferenceCount = item.fileReferenceCount
            linkURLs = item.linkURLs.map(\.absoluteString)
            representationTypeIdentifiers = item.representationTypeIdentifiers
            payloadDigest = item.payloadDigest
            allowsRichTextImport = item.allowsRichTextImport
            textCharacterCount = item.textCharacterCount
            textLineCount = item.textLineCount
            isSearchTextTruncated = item.isSearchTextTruncated
            lastUsedAt = item.lastUsedAt
            imageSearchText = item.imageSearchText
            hasCompletedImageTextIndexing = item.hasCompletedImageTextIndexing
            isInHistory = item.isInHistory
            savedMetadata = item.savedMetadata
        }
    }

    private static let metadataMagic = Data([0x4D, 0x54, 0x48, 0x4D, 0x31]) // MTHM1
    private static let payloadMagic = Data([0x4D, 0x54, 0x48, 0x50, 0x31]) // MTHP1
    private static let schemaVersion = 1
    private static let minimumFreeDiskReserve = 512 * 1_024 * 1_024
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let databaseURL: URL
    let legacyFileURL: URL?

    private let keyStore: any ClipboardHistoryKeyStoring
    private let fileManager: FileManager
    private let postCommitMaintenance: (@Sendable () throws -> Void)?
    private let lock = NSLock()
    private var cachedItems: [UUID: ClipboardHistoryItem] = [:]
    private var isInvalidated = false

    init(
        databaseURL: URL,
        legacyFileURL: URL? = nil,
        keyStore: any ClipboardHistoryKeyStoring = ClipboardHistoryKeychainStore(),
        fileManager: FileManager = .default,
        postCommitMaintenance: (@Sendable () throws -> Void)? = nil
    ) {
        self.databaseURL = databaseURL
        self.legacyFileURL = legacyFileURL
        self.keyStore = keyStore
        self.fileManager = fileManager
        self.postCommitMaintenance = postCommitMaintenance
    }

    func prepare() throws {
        try lock.withLock {
            try prepareLocked()
        }
    }

    func load() throws -> [ClipboardHistoryItem] {
        try lock.withLock {
            guard !isInvalidated else { return [] }
            try prepareLocked()
            try migrateLegacyHistoryIfNeededLocked()
            let key = try encryptionKeyLocked()
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }

            let statement = try prepareStatement(
                "SELECT id, metadata FROM items",
                database: database
            )
            defer { sqlite3_finalize(statement) }

            var loaded: [ClipboardHistoryItem] = []
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
                    throw ClipboardHistoryStoreError.authenticationFailed
                }
                let item = makeItem(metadata: metadata)
                loaded.append(item)
                stepResult = sqlite3_step(statement)
            }
            guard stepResult == SQLITE_DONE else {
                throw sqliteError(database)
            }
            loaded.sort { $0.capturedAt > $1.capturedAt }
            cachedItems = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            return loaded
        }
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        try lock.withLock {
            try saveLocked(items)
        }
    }

    private func saveLocked(_ items: [ClipboardHistoryItem]) throws {
        guard !isInvalidated else { return }
        try prepareLocked()
        let key = try encryptionKeyLocked()
        let database = try openDatabaseLocked()
        defer { sqlite3_close(database) }

        try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
        do {
            let requestedIDs = Set(items.map(\.id))
            let existingIDs = try itemIDs(database: database)
            let removedIDs = existingIDs.subtracting(requestedIDs)
            let additionalPayloadBytes = items.reduce(into: 0) { total, item in
                if !existingIDs.contains(item.id)
                    || cachedItems[item.id]?.payloadDigest != item.payloadDigest {
                    total += item.payloadByteCount + 64
                }
            }
            if additionalPayloadBytes > 0 {
                try requireAvailableDiskCapacity(forAdditionalBytes: additionalPayloadBytes)
            }
            var writtenPayloadIDs = Set<UUID>()
            for removedID in removedIDs {
                try deleteItem(id: removedID, database: database)
            }

            for item in items {
                let previous = cachedItems[item.id]
                if previous == item {
                    continue
                }
                let metadata = try JSONEncoder().encode(StoredMetadata(item: item))
                let encryptedMetadata = try Self.seal(
                    metadata,
                    magic: Self.metadataMagic,
                    key: key,
                    authenticatedID: item.id
                )
                if existingIDs.contains(item.id) {
                    if previous?.payloadDigest != item.payloadDigest {
                        let payload = try item.loadPayload()
                        let encryptedPayload = try encryptedPayloadData(
                            payload,
                            id: item.id,
                            key: key
                        )
                        try updateItem(
                            id: item.id,
                            metadata: encryptedMetadata,
                            payload: encryptedPayload,
                            database: database
                        )
                        writtenPayloadIDs.insert(item.id)
                    } else {
                        try updateMetadata(
                            id: item.id,
                            metadata: encryptedMetadata,
                            database: database
                        )
                    }
                } else {
                    let payload = try item.loadPayload()
                    let encryptedPayload = try encryptedPayloadData(
                        payload,
                        id: item.id,
                        key: key
                    )
                    try insertItem(
                        id: item.id,
                        metadata: encryptedMetadata,
                        payload: encryptedPayload,
                        database: database
                    )
                    writtenPayloadIDs.insert(item.id)
                }
            }
            try execute("COMMIT", database: database)
            if !removedIDs.isEmpty {
                // The durable transaction has already committed. Housekeeping failures must not
                // make callers restore an older snapshot or report that the save failed.
                try? execute("PRAGMA incremental_vacuum", database: database)
                try? postCommitMaintenance?()
            }
            for item in items where writtenPayloadIDs.contains(item.id) {
                let id = item.id
                item.configurePayloadLoader({ [weak self] in
                    guard let self else {
                        throw ClipboardHistoryPayloadAccessError.unavailable
                    }
                    return try self.loadPayload(id: id)
                }, discardCachedPayload: true)
            }
            cachedItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    func reset() throws {
        try lock.withLock {
            // Delete the key first so a partially completed reset can never leave an empty store
            // that silently continues using the pre-reset encryption key.
            try keyStore.deleteKey()
            try removeDatabaseFilesLocked()
            try removeLegacyFileLocked()
            cachedItems = [:]
            isInvalidated = false
        }
    }

    func removeAll() throws {
        try lock.withLock {
            isInvalidated = true
            var firstError: Error?
            do {
                try removeDatabaseFilesLocked()
                try removeLegacyFileLocked()
            } catch {
                firstError = error
            }
            do {
                try keyStore.deleteKey()
            } catch {
                firstError = firstError ?? error
            }
            cachedItems = [:]
            if let firstError {
                throw firstError
            }
        }
    }

    private func makeItem(metadata: StoredMetadata) -> ClipboardHistoryItem {
        let decodedFileURLs = metadata.fileURLs?.compactMap(URL.init(string:)) ?? []
        let boundedFileURLs = Array(decodedFileURLs.prefix(
            ClipboardHistoryPayload.maximumMetadataFileURLCount
        ))
        let boundedLinkURLs = Array(
            (metadata.linkURLs?.compactMap(URL.init(string:)) ?? []).prefix(
                ClipboardHistoryPayload.maximumMetadataLinkURLCount
            )
        )
        let boundedRepresentationTypes = Array(
            (metadata.representationTypeIdentifiers ?? [])
                .prefix(ClipboardHistoryPayload.maximumMetadataRepresentationTypeCount)
                .map {
                    String($0.prefix(
                        ClipboardHistoryPayload.maximumMetadataRepresentationTypeCharacterCount
                    ))
                }
        )
        return ClipboardHistoryItem(
            id: metadata.id,
            text: metadata.text,
            capturedAt: metadata.capturedAt,
            sourceApplication: metadata.sourceApplication,
            kind: metadata.kind,
            payloadByteCount: metadata.payloadByteCount,
            filterContentKinds: Set(metadata.filterContentKinds ?? [metadata.kind]),
            fileURLs: boundedFileURLs,
            fileReferenceCount: metadata.fileReferenceCount ?? decodedFileURLs.count,
            linkURLs: boundedLinkURLs,
            representationTypeIdentifiers: boundedRepresentationTypes,
            payloadDigest: metadata.payloadDigest,
            allowsRichTextImport: metadata.allowsRichTextImport ?? false,
            textCharacterCount: metadata.textCharacterCount ?? metadata.text.count,
            textLineCount: metadata.textLineCount ?? Self.lineCount(metadata.text),
            isSearchTextTruncated: metadata.isSearchTextTruncated ?? false,
            isPinned: false,
            lastUsedAt: metadata.lastUsedAt,
            imageSearchText: metadata.imageSearchText,
            hasCompletedImageTextIndexing: metadata.hasCompletedImageTextIndexing ?? false,
            isInHistory: metadata.isInHistory ?? true,
            savedMetadata: metadata.savedMetadata,
            payloadLoader: { [weak self] in
                guard let self else {
                    throw ClipboardHistoryPayloadAccessError.unavailable
                }
                return try self.loadPayload(id: metadata.id)
            }
        )
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    private func loadPayload(id: UUID) throws -> ClipboardHistoryPayload {
        try lock.withLock {
            guard !isInvalidated else {
                throw ClipboardHistoryPayloadAccessError.unavailable
            }
            let key = try encryptionKeyLocked()
            let database = try openDatabaseLocked()
            defer { sqlite3_close(database) }
            let statement = try prepareStatement(
                "SELECT payload FROM items WHERE id = ?1",
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
        }
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
            let hasLegacy = legacyFileURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
            if let keyData = try keyStore.loadKey() {
                guard keyData.count == EncryptedClipboardHistoryStore.keyByteCount else {
                    throw ClipboardHistoryStoreError.invalidEncryptionKey
                }
            } else if hasDatabase || hasLegacy {
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
        let existingSchemaVersion = try integerPragma("user_version", database: database)
        guard existingSchemaVersion <= Self.schemaVersion else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        if existingSchemaVersion == 0 {
            try execute("PRAGMA auto_vacuum = INCREMENTAL", database: database)
            try execute("VACUUM", database: database)
        }
        try execute(
            "CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY NOT NULL, metadata BLOB NOT NULL, payload BLOB NOT NULL)",
            database: database
        )
        try execute("PRAGMA user_version = \(Self.schemaVersion)", database: database)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: databaseURL.path
        )
    }

    private func migrateLegacyHistoryIfNeededLocked() throws {
        guard let legacyFileURL,
              fileManager.fileExists(atPath: legacyFileURL.path) else {
            return
        }
        let database = try openDatabaseLocked()
        let existingCount = try rowCount(database: database)
        sqlite3_close(database)
        guard existingCount == 0 else {
            try removeLegacyFileLocked()
            return
        }

        let legacyStore = EncryptedClipboardHistoryStore(
            fileURL: legacyFileURL,
            keyStore: keyStore,
            fileManager: fileManager
        )
        let legacyItems = try legacyStore.load()
        cachedItems = [:]
        try saveLocked(legacyItems)
        try removeLegacyFileLocked()
    }

    private func encryptionKeyLocked() throws -> SymmetricKey {
        guard let keyData = try keyStore.loadKey() else {
            throw ClipboardHistoryStoreError.missingEncryptionKey
        }
        guard keyData.count == EncryptedClipboardHistoryStore.keyByteCount else {
            throw ClipboardHistoryStoreError.invalidEncryptionKey
        }
        return SymmetricKey(data: keyData)
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

    private func encryptedPayloadData(
        _ payload: ClipboardHistoryPayload,
        id: UUID,
        key: SymmetricKey
    ) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(payload)
        return try Self.seal(
            encoded,
            magic: Self.payloadMagic,
            key: key,
            authenticatedID: id
        )
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
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: Data(storedData.dropFirst(magic.count)))
        } catch {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        do {
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
        guard status == errSecSuccess else {
            throw ClipboardHistoryStoreError.keychain(status)
        }
        return Data(bytes)
    }

    private func requireAvailableDiskCapacity(forAdditionalBytes byteCount: Int) throws {
        let values = try databaseURL.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard available - Int64(byteCount) >= Int64(Self.minimumFreeDiskReserve) else {
            throw ClipboardHistoryStoreError.insufficientDiskSpace
        }
    }

    private func itemIDs(database: OpaquePointer) throws -> Set<UUID> {
        let statement = try prepareStatement("SELECT id FROM items", database: database)
        defer { sqlite3_finalize(statement) }
        var result = Set<UUID>()
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0),
               let id = UUID(uuidString: String(cString: text)) {
                result.insert(id)
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw sqliteError(database) }
        return result
    }

    private func rowCount(database: OpaquePointer) throws -> Int {
        let statement = try prepareStatement("SELECT COUNT(*) FROM items", database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func integerPragma(_ name: String, database: OpaquePointer) throws -> Int {
        let statement = try prepareStatement("PRAGMA \(name)", database: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(database) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func insertItem(
        id: UUID,
        metadata: Data,
        payload: Data,
        database: OpaquePointer
    ) throws {
        let statement = try prepareStatement(
            "INSERT INTO items (id, metadata, payload) VALUES (?1, ?2, ?3)",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, database: database)
        try bind(metadata, index: 2, statement: statement, database: database)
        try bind(payload, index: 3, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func updateItem(
        id: UUID,
        metadata: Data,
        payload: Data,
        database: OpaquePointer
    ) throws {
        let statement = try prepareStatement(
            "UPDATE items SET metadata = ?1, payload = ?2 WHERE id = ?3",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(metadata, index: 1, statement: statement, database: database)
        try bind(payload, index: 2, statement: statement, database: database)
        try bind(id.uuidString, index: 3, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func updateMetadata(
        id: UUID,
        metadata: Data,
        database: OpaquePointer
    ) throws {
        let statement = try prepareStatement(
            "UPDATE items SET metadata = ?1 WHERE id = ?2",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(metadata, index: 1, statement: statement, database: database)
        try bind(id.uuidString, index: 2, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func deleteItem(id: UUID, database: OpaquePointer) throws {
        let statement = try prepareStatement("DELETE FROM items WHERE id = ?1", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, index: 1, statement: statement, database: database)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func prepareStatement(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }
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
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
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
        if sqlite3_errcode(database) == SQLITE_FULL {
            return .insufficientDiskSpace
        }
        return .unavailableStorage
    }

    private func removeDatabaseFilesLocked() throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-journal"),
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeLegacyFileLocked() throws {
        guard let legacyFileURL,
              fileManager.fileExists(atPath: legacyFileURL.path) else { return }
        try fileManager.removeItem(at: legacyFileURL)
    }
}
