import Foundation

struct CloudPreferencesSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultFileName = "mactools-preferences-sync.json"

    let version: Int
    let generation: UInt64
    let timestamp: Date
    let deviceID: String
    let deviceName: String
    let backup: PreferencesBackup

    init(
        version: Int = Self.currentVersion,
        generation: UInt64,
        timestamp: Date = .now,
        deviceID: String,
        deviceName: String,
        backup: PreferencesBackup
    ) {
        self.version = version
        self.generation = generation
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.backup = backup
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

    static func decodeJSON(_ data: Data) throws -> CloudPreferencesSnapshot {
        guard data.count <= PreferencesBackup.maximumFileSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: PreferencesBackup.maximumFileSize)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CloudPreferencesSnapshot.self, from: data)
        try snapshot.backup.validate()
        return snapshot
    }
}
