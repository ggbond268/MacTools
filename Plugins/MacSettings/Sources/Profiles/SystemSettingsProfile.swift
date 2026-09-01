import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let macToolsSettingsProfile = UTType(
        exportedAs: "cc.ggbond.mactools.settings-profile",
        conformingTo: .json
    )
}

struct SystemSettingsProfileEntry: Codable, Equatable, Sendable, Identifiable {
    let settingID: SystemSettingID
    var desiredValue: SystemSettingValue
    let category: SystemSettingCategory?

    var id: SystemSettingID { settingID }
}

extension SystemSettingsProfileEntry {
    // Preserve the stable setting ID and existing explicit Light/Dark profile intent.
    // This does not migrate history or infer Auto from an old Boolean observation.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settingID = try container.decode(SystemSettingID.self, forKey: .settingID)
        category = try container.decodeIfPresent(SystemSettingCategory.self, forKey: .category)
        let value = try container.decode(SystemSettingValue.self, forKey: .desiredValue)
        if settingID == "appearance.dark-mode", case let .boolean(dark) = value {
            desiredValue = .choice(id: dark ? "dark" : "light")
        } else {
            desiredValue = value
        }
    }
}

struct SystemSettingsProfile: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let id: UUID
    var name: String
    var profileDescription: String
    let createdAt: Date
    var modifiedAt: Date
    let sourceSystemVersion: String
    let sourceAppVersion: String
    var entries: [SystemSettingsProfileEntry]

    init(
        formatVersion: Int = currentFormatVersion,
        id: UUID = UUID(),
        name: String,
        profileDescription: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        sourceSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        sourceAppVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown",
        entries: [SystemSettingsProfileEntry]
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.profileDescription = profileDescription
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sourceSystemVersion = sourceSystemVersion
        self.sourceAppVersion = sourceAppVersion
        self.entries = entries
    }
}

struct SystemSettingsProfileDraftItem: Equatable, Identifiable {
    let settingID: SystemSettingID
    var isIncluded: Bool
    var desiredValue: SystemSettingValue

    var id: SystemSettingID { settingID }
}

struct SystemSettingsProfileDraft: Equatable {
    var name: String
    var profileDescription: String
    var items: [SystemSettingsProfileDraftItem]

    mutating func setDesiredValue(
        _ value: SystemSettingValue,
        for settingID: SystemSettingID
    ) {
        guard let index = items.firstIndex(where: { $0.settingID == settingID }) else { return }
        items[index].desiredValue = value
        items[index].isIncluded = true
    }

    mutating func setIncluded(_ isIncluded: Bool, for settingID: SystemSettingID) {
        guard let index = items.firstIndex(where: { $0.settingID == settingID }) else { return }
        items[index].isIncluded = isIncluded
    }

    @MainActor
    mutating func setIncluded(
        _ isIncluded: Bool,
        in category: SystemSettingCategory,
        catalog: SystemSettingCatalog
    ) {
        let ids = Set(catalog.records.filter { $0.definition.category == category }.map(\.id))
        for index in items.indices where ids.contains(items[index].settingID) {
            items[index].isIncluded = isIncluded
        }
    }

    @MainActor
    func makeProfile(
        existing: SystemSettingsProfile? = nil,
        catalog: SystemSettingCatalog,
        date: Date = Date()
    ) -> SystemSettingsProfile {
        let categoryByID = Dictionary(
            uniqueKeysWithValues: catalog.records.map { ($0.id, $0.definition.category) }
        )
        let entries = items.filter(\.isIncluded).map {
            SystemSettingsProfileEntry(
                settingID: $0.settingID,
                desiredValue: $0.desiredValue,
                category: categoryByID[$0.settingID]
            )
        }
        // Editing the available controls must not erase deferred or future values.
        let editedIDs = Set(items.map(\.settingID))
        let retainedEntries = (existing?.entries ?? []).filter {
            catalog[$0.settingID] == nil && !editedIDs.contains($0.settingID)
        }
        return SystemSettingsProfile(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            profileDescription: profileDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: existing?.createdAt ?? date,
            modifiedAt: date,
            sourceSystemVersion: existing?.sourceSystemVersion
                ?? ProcessInfo.processInfo.operatingSystemVersionString,
            sourceAppVersion: existing?.sourceAppVersion
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
            entries: entries + retainedEntries
        )
    }
}

enum SystemSettingsProfileValidationIssue: Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case emptyName
    case tooManyEntries
    case duplicateSettingID(SystemSettingID)
    case invalidSettingID(SystemSettingID)
    case invalidDesiredValue(SystemSettingID)
    case sensitiveSetting(SystemSettingID)
    case nonPortableSetting(SystemSettingID)
    case prohibitedSetting(SystemSettingID)
    case unknownSetting(SystemSettingID)
}

struct SystemSettingsProfileValidationResult: Equatable, Sendable {
    let errors: [SystemSettingsProfileValidationIssue]
    let warnings: [SystemSettingsProfileValidationIssue]

    var isValid: Bool { errors.isEmpty }
}

enum SystemSettingsProfileCodecError: Error, Equatable, LocalizedError {
    case fileTooLarge
    case malformedFile
    case validationFailed([SystemSettingsProfileValidationIssue])

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            MacSettingsStrings.text("The profile exceeds the 1 MiB limit.")
        case .malformedFile:
            MacSettingsStrings.text("The profile format is invalid.")
        case .validationFailed:
            MacSettingsStrings.text("The profile contains unsupported or invalid settings.")
        }
    }
}

@MainActor
enum SystemSettingsProfileCodec {
    static let maximumFileSize = 1_048_576
    static let maximumEntryCount = 200
    static let maximumNameLength = 120
    static let maximumDescriptionLength = 2_000

    static func validate(
        _ profile: SystemSettingsProfile,
        catalog: SystemSettingCatalog
    ) -> SystemSettingsProfileValidationResult {
        var errors: [SystemSettingsProfileValidationIssue] = []
        var warnings: [SystemSettingsProfileValidationIssue] = []

        if profile.formatVersion != SystemSettingsProfile.currentFormatVersion {
            errors.append(.unsupportedFormatVersion(profile.formatVersion))
        }
        let normalizedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.isEmpty || normalizedName.count > maximumNameLength
            || profile.profileDescription.count > maximumDescriptionLength {
            errors.append(.emptyName)
        }
        if profile.entries.count > maximumEntryCount {
            errors.append(.tooManyEntries)
        }

        var ids: Set<SystemSettingID> = []
        for entry in profile.entries {
            guard Self.isValidStableID(entry.settingID.rawValue) else {
                errors.append(.invalidSettingID(entry.settingID))
                continue
            }
            guard ids.insert(entry.settingID).inserted else {
                errors.append(.duplicateSettingID(entry.settingID))
                continue
            }
            let record = catalog[entry.settingID]
            if record == nil {
                warnings.append(.unknownSetting(entry.settingID))
            }
            // Deferral must not make a known local-only or sensitive value portable.
            guard let definition = record?.definition
                ?? catalog.deferredDefinitions[entry.settingID] else { continue }
            if definition.isSensitive {
                errors.append(.sensitiveSetting(entry.settingID))
            }
            if definition.portability == .prohibited {
                errors.append(.prohibitedSetting(entry.settingID))
            } else if !definition.isSensitive && !definition.isProfileEligible {
                errors.append(.nonPortableSetting(entry.settingID))
            }
            if !definition.schema.accepts(entry.desiredValue) {
                errors.append(.invalidDesiredValue(entry.settingID))
            } else if definition.isProfileEligible && !definition.acceptsPortableValue(entry.desiredValue) {
                errors.append(.nonPortableSetting(entry.settingID))
            }
        }
        return .init(errors: errors, warnings: warnings)
    }

    static func encode(
        _ profile: SystemSettingsProfile,
        catalog: SystemSettingCatalog
    ) throws -> Data {
        let validation = validate(profile, catalog: catalog)
        guard validation.isValid else {
            throw SystemSettingsProfileCodecError.validationFailed(validation.errors)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        guard data.count <= maximumFileSize else {
            throw SystemSettingsProfileCodecError.fileTooLarge
        }
        return data
    }

    static func decode(
        _ data: Data,
        catalog: SystemSettingCatalog
    ) throws -> (SystemSettingsProfile, SystemSettingsProfileValidationResult) {
        guard data.count <= maximumFileSize else {
            throw SystemSettingsProfileCodecError.fileTooLarge
        }
        guard containsOnlyAllowedKeys(data) else {
            throw SystemSettingsProfileCodecError.malformedFile
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let profile = try? decoder.decode(SystemSettingsProfile.self, from: data) else {
            throw SystemSettingsProfileCodecError.malformedFile
        }
        let validation = validate(profile, catalog: catalog)
        guard validation.isValid else {
            throw SystemSettingsProfileCodecError.validationFailed(validation.errors)
        }
        return (profile, validation)
    }

    private static func isValidStableID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func containsOnlyAllowedKeys(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: [
                  "formatVersion", "id", "name", "profileDescription", "createdAt", "modifiedAt",
                  "sourceSystemVersion", "sourceAppVersion", "entries",
              ]),
              let entries = root["entries"] as? [[String: Any]] else {
            return false
        }
        for entry in entries {
            guard Set(entry.keys).isSubset(of: ["settingID", "desiredValue", "category"]),
                  let desired = entry["desiredValue"] as? [String: Any],
                  Set(desired.keys).isSubset(of: ["type", "value"]),
                  desired["type"] is String else {
                return false
            }
            if let color = desired["value"] as? [String: Any],
               !Set(color.keys).isSubset(of: ["red", "green", "blue", "alpha"]) {
                return false
            }
        }
        return true
    }
}

enum BuiltInSystemSettingsProfiles {
    @MainActor
    static func templates(catalog: SystemSettingCatalog) -> [SystemSettingsProfile] {
        [
            template(
                id: UUID(uuidString: "2B5D31BB-82A4-4E38-9177-0604ED5D6F80")!,
                name: MacSettingsStrings.text("Finder Productivity"),
                description: MacSettingsStrings.text("Show filename extensions, the path bar, and the status bar, and search the current folder by default."),
                values: [
                    "finder.show-all-extensions": .boolean(true),
                    "finder.show-path-bar": .boolean(true),
                    "finder.show-status-bar": .boolean(true),
                    "finder.search-scope": .choice(id: "SCcf"),
                ],
                catalog: catalog
            ),
            template(
                id: UUID(uuidString: "4DAE5F61-7812-4DA9-B6BE-F82680266DAB")!,
                name: MacSettingsStrings.text("Focused Desktop"),
                description: MacSettingsStrings.text("Hide the Dock and disable recent apps in the Dock."),
                values: [
                    "dock.auto-hide": .boolean(true),
                    "dock.show-recents": .boolean(false),
                ],
                catalog: catalog
            ),
            template(
                id: UUID(uuidString: "3DE73F6D-2B52-4641-92D7-3FE6FA22B701")!,
                name: MacSettingsStrings.text("Zen"),
                description: MacSettingsStrings.text(
                    "Hide the Dock and menu bar, remove recent Dock apps, and hide desktop items and widgets."
                ),
                values: [
                    "dock.auto-hide": .boolean(true),
                    "dock.show-recents": .boolean(false),
                    "desktop.menu-bar-auto-hide": .choice(id: "always"),
                    "desktop.show-items-on-desktop": .boolean(false),
                    "desktop.show-items-in-stage-manager": .boolean(false),
                    "desktop.show-widgets-on-desktop": .boolean(false),
                    "desktop.show-widgets-in-stage-manager": .boolean(false),
                ],
                catalog: catalog
            ),
        ]
    }

    @MainActor
    private static func template(
        id: UUID,
        name: String,
        description: String,
        values: [SystemSettingID: SystemSettingValue],
        catalog: SystemSettingCatalog
    ) -> SystemSettingsProfile {
        let date = Date(timeIntervalSince1970: 0)
        return SystemSettingsProfile(
            id: id,
            name: name,
            profileDescription: description,
            createdAt: date,
            modifiedAt: date,
            sourceSystemVersion: "MacTools built-in",
            sourceAppVersion: "1",
            entries: values.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                guard let record = catalog[id], let value = values[id] else { return nil }
                return .init(
                    settingID: id,
                    desiredValue: value,
                    category: record.definition.category
                )
            }
        )
    }
}
