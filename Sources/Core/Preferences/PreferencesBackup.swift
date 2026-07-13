import Foundation
import MacToolsPluginKit

struct PreferencesBackup: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let maximumFileSize = 1 * 1024 * 1024

    struct ApplicationPreferences: Codable, Equatable, Sendable {
        let appearancePreference: String
        let languagePreference: String
        let menuBarClickBehavior: String
    }

    let formatVersion: Int
    let exportedAt: Date
    let application: ApplicationPreferences
    let pluginDisplay: PluginDisplayPreferencesBackup
    let shortcutCustomizations: [String: ShortcutCustomization]

    init(
        application: ApplicationPreferences,
        pluginDisplay: PluginDisplayPreferencesBackup,
        shortcutCustomizations: [String: ShortcutCustomization],
        exportedAt: Date = .now
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.application = application
        self.pluginDisplay = pluginDisplay
        self.shortcutCustomizations = shortcutCustomizations
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw PreferencesBackupError.unsupportedFormatVersion(formatVersion)
        }
    }

    func validateApplicationPreferences(
        using validator: (ApplicationPreferences) -> Bool
    ) throws {
        guard validator(application) else {
            throw PreferencesBackupError.invalidApplicationPreferences
        }
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeJSON(_ data: Data) throws -> PreferencesBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(PreferencesBackup.self, from: data)
        try backup.validate()
        return backup
    }

    static func decodeJSON(
        contentsOf url: URL,
        maximumFileSize: Int = maximumFileSize
    ) async throws -> PreferencesBackup {
        try await Task.detached(priority: .userInitiated) {
            let data = try Self.readFile(at: url, maximumSize: maximumFileSize)
            return try Self.decodeJSON(data)
        }.value
    }

    private static func readFile(at url: URL, maximumSize: Int) throws -> Data {
        precondition(maximumSize > 0)

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var data = Data()
        data.reserveCapacity(maximumSize + 1)

        while data.count <= maximumSize {
            let remainingByteCount = maximumSize + 1 - data.count
            guard let chunk = try file.read(upToCount: min(64 * 1024, remainingByteCount)),
                  !chunk.isEmpty
            else {
                break
            }

            data.append(chunk)
        }

        guard data.count <= maximumSize else {
            throw PreferencesBackupError.fileTooLarge(maximumBytes: maximumSize)
        }

        return data
    }
}

struct PluginDisplayPreferencesBackup: Codable, Equatable, Sendable {
    let orderedPluginIDs: [String]
    let hiddenPluginIDs: [String]
}

struct PreferencesImportPreview: Equatable {
    let pluginCount: Int
    let unavailablePluginIDs: [String]
    let shortcutCount: Int
    let unavailableShortcutIDs: [String]
    let installablePlugins: [PreferencesImportInstallablePlugin]

    static func make(
        backup: PreferencesBackup,
        availablePluginIDs: Set<String>,
        availableShortcutIDs: Set<String>,
        pluginManagementItems: [PluginManagementItem],
        applicationPreferencesAreValid: (PreferencesBackup.ApplicationPreferences) -> Bool
    ) throws -> PreferencesImportPreview {
        try backup.validate()
        try backup.validateApplicationPreferences(using: applicationPreferencesAreValid)

        let backedUpPluginIDs = Set(backup.pluginDisplay.orderedPluginIDs)
            .union(backup.pluginDisplay.hiddenPluginIDs)
        let missingPluginIDs = backedUpPluginIDs.subtracting(availablePluginIDs)
        let managementItemsByID = Dictionary(
            pluginManagementItems.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let installablePlugins = missingPluginIDs.compactMap { pluginID -> PreferencesImportInstallablePlugin? in
            guard let item = managementItemsByID[pluginID], item.canInstall else { return nil }
            return PreferencesImportInstallablePlugin(
                id: item.id,
                title: item.title,
                summary: item.summary,
                version: item.version
            )
        }
        let installablePluginIDs = Set(installablePlugins.map(\.id))
        let backedUpShortcutIDs = Set(backup.shortcutCustomizations.keys)
        return PreferencesImportPreview(
            pluginCount: backedUpPluginIDs.intersection(availablePluginIDs).count,
            unavailablePluginIDs: missingPluginIDs.subtracting(installablePluginIDs).sorted(),
            shortcutCount: backedUpShortcutIDs.intersection(availableShortcutIDs).count,
            unavailableShortcutIDs: backedUpShortcutIDs.subtracting(availableShortcutIDs).sorted(),
            installablePlugins: installablePlugins.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        )
    }
}

struct PreferencesImportInstallablePlugin: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String?
    let version: String
}

struct PreferencesImportResult: Equatable {
    let installedPluginIDs: [String]
    let pluginInstallationFailures: [String: String]
    let shortcutErrors: [String: String]
}

enum PreferencesBackupError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case invalidApplicationPreferences
    case fileTooLarge(maximumBytes: Int)
}

@MainActor
protocol PreferencesBackupApplicationStoring: AnyObject {
    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences
    func validates(_ preferences: PreferencesBackup.ApplicationPreferences) -> Bool
    func apply(_ preferences: PreferencesBackup.ApplicationPreferences)
}
