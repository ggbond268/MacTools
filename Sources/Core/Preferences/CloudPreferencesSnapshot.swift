import Foundation

enum PreferencesArchiveScope: String, Codable, Equatable, Sendable {
    case full
    case portable
}

/// Shared on-disk envelope for manual exports and cloud-synchronized preferences.
/// Sync metadata is optional so either workflow can consume the same document format.
struct PreferencesArchiveDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultFileName = "mactools-preferences-sync.json"

    struct SyncMetadata: Codable, Equatable, Sendable {
        let generation: UInt64
        let deviceID: String
        let deviceName: String
        var parentDocumentID: String? = nil
    }

    let version: Int
    let scope: PreferencesArchiveScope
    let documentID: String
    let timestamp: Date
    let syncMetadata: SyncMetadata?
    let backup: PreferencesBackup

    var generation: UInt64 { syncMetadata?.generation ?? 0 }
    var deviceID: String { syncMetadata?.deviceID ?? "" }
    var deviceName: String { syncMetadata?.deviceName ?? "" }
    var isCloudSnapshot: Bool { syncMetadata != nil }

    init(
        version: Int = Self.currentVersion,
        scope: PreferencesArchiveScope,
        documentID: String = UUID().uuidString,
        timestamp: Date = .now,
        syncMetadata: SyncMetadata? = nil,
        backup: PreferencesBackup
    ) {
        self.version = version
        self.scope = scope
        self.documentID = documentID
        self.timestamp = timestamp
        self.syncMetadata = syncMetadata
        self.backup = backup
    }

    init(
        version: Int = Self.currentVersion,
        generation: UInt64,
        timestamp: Date = .now,
        deviceID: String,
        deviceName: String,
        parentDocumentID: String? = nil,
        backup: PreferencesBackup
    ) {
        self.init(
            version: version,
            scope: .portable,
            timestamp: timestamp,
            syncMetadata: SyncMetadata(
                generation: generation,
                deviceID: deviceID,
                deviceName: deviceName,
                parentDocumentID: parentDocumentID
            ),
            backup: backup
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case scope
        case documentID
        case timestamp
        case timestampEpochSeconds
        case syncMetadata
        case backup

        // Version 1 cloud snapshots stored sync metadata at the document root.
        case generation
        case deviceID
        case deviceName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // Keep the legacy ISO 8601 field readable by older clients, while retaining
        // the exact timestamp used locally for equal-generation comparisons.
        if let seconds = try container.decodeIfPresent(Double.self, forKey: .timestampEpochSeconds) {
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .timestampEpochSeconds, in: container, debugDescription: "Invalid timestamp."
                )
            }
            timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            timestamp = try container.decode(Date.self, forKey: .timestamp)
        }
        backup = try container.decode(PreferencesBackup.self, forKey: .backup)
        scope = try container.decodeIfPresent(PreferencesArchiveScope.self, forKey: .scope) ?? .portable
        documentID = try container.decodeIfPresent(String.self, forKey: .documentID)
            ?? "legacy-cloud-\(timestamp.timeIntervalSince1970)"

        if let metadata = try container.decodeIfPresent(SyncMetadata.self, forKey: .syncMetadata) {
            syncMetadata = metadata
        } else if let generation = try container.decodeIfPresent(UInt64.self, forKey: .generation),
                  let deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID),
                  let deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) {
            syncMetadata = SyncMetadata(
                generation: generation,
                deviceID: deviceID,
                deviceName: deviceName
            )
        } else {
            syncMetadata = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(scope, forKey: .scope)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .timestampEpochSeconds)
        try container.encodeIfPresent(syncMetadata, forKey: .syncMetadata)
        try container.encode(backup, forKey: .backup)
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= PreferencesBackup.maximumFileSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
        }
        return data
    }

    static func decodeJSON(_ data: Data) throws -> PreferencesArchiveDocument {
        guard data.count <= PreferencesBackup.maximumFileSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(PreferencesArchiveDocument.self, from: data)
        guard document.version == currentVersion else {
            throw PreferencesBackupError.unsupportedFormatVersion(document.version)
        }
        try document.backup.validate()
        return document
    }

    static func decodeCompatibleJSON(_ data: Data) throws -> PreferencesArchiveDocument {
        do {
            return try decodeJSON(data)
        } catch let validationError as PreferencesBackupError {
            throw validationError
        } catch {
            let backup = try PreferencesBackup.decodePayloadJSON(data)
            return PreferencesArchiveDocument(
                scope: .full,
                documentID: "legacy-manual-\(backup.exportedAt.timeIntervalSince1970)",
                timestamp: backup.exportedAt,
                backup: backup
            )
        }
    }
}

typealias CloudPreferencesSnapshot = PreferencesArchiveDocument
