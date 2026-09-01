import Foundation
import MacToolsPluginKit

struct SystemSettingID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        rawValue = value
    }
}

enum SystemSettingCategory: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case accessibility
    case input
    case keyboard
    case finder
    case desktopAndDock
    case screenshots
    case appearance
    case display
    case power
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: MacSettingsStrings.text("Accessibility")
        case .input: MacSettingsStrings.text("Trackpad & Mouse")
        case .keyboard: MacSettingsStrings.text("Keyboard")
        case .finder: MacSettingsStrings.text("Finder")
        case .desktopAndDock: MacSettingsStrings.text("Desktop & Dock")
        case .screenshots: MacSettingsStrings.text("Screenshots")
        case .appearance: MacSettingsStrings.text("Appearance")
        case .display: MacSettingsStrings.text("Displays")
        case .power: MacSettingsStrings.text("Power")
        case .network: MacSettingsStrings.text("Network")
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility: "accessibility"
        case .input: "cursorarrow.motionlines"
        case .keyboard: "keyboard"
        case .finder: "folder"
        case .desktopAndDock: "dock.rectangle"
        case .screenshots: "camera.viewfinder"
        case .appearance: "circle.lefthalf.filled"
        case .display: "display"
        case .power: "battery.100percent"
        case .network: "network"
        }
    }
}

enum SystemSettingExecutionClass: String, Codable, CaseIterable, Sendable {
    case directVerified
    case directAppliesNextUse
    case directRequiresLogout
    case directRequiresRestart
    case existingPluginProvider
    case guidedManual
    case hardwareDependent
    case managedOnly
    case unsupported
}

enum SystemSettingPortability: String, Codable, Sendable {
    case portable
    case deviceSpecific
    case localOnly
    case prohibited
}

struct SystemSettingVersion: Codable, Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init(_ version: OperatingSystemVersion) {
        self.init(version.majorVersion, version.minorVersion, version.patchVersion)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct SystemSettingColor: Codable, Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { (0 ... 1).contains($0) && $0.isFinite }
    }
}

enum SystemSettingValue: Codable, Equatable, Hashable, Sendable {
    case boolean(Bool)
    case integer(Int)
    case decimal(Double)
    case choice(id: String)
    case string(String)
    case url(URL)
    case color(SystemSettingColor)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case boolean
        case integer
        case decimal
        case choice
        case string
        case url
        case color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int.self, forKey: .value))
        case .decimal:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Decimal setting values must be finite."
                )
            }
            self = .decimal(value)
        case .choice:
            self = .choice(id: try container.decode(String.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .url:
            self = .url(try container.decode(URL.self, forKey: .value))
        case .color:
            let color = try container.decode(SystemSettingColor.self, forKey: .value)
            guard color.isValid else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Color components must be finite values between zero and one."
                )
            }
            self = .color(color)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(ValueType.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .decimal(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Decimal setting values must be finite."
                ))
            }
            try container.encode(ValueType.decimal, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .choice(id):
            try container.encode(ValueType.choice, forKey: .type)
            try container.encode(id, forKey: .value)
        case let .string(value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .url(value):
            try container.encode(ValueType.url, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .color(value):
            guard value.isValid else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Color components must be finite values between zero and one."
                ))
            }
            try container.encode(ValueType.color, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    var conciseDescription: String {
        switch self {
        case let .boolean(value): value ? MacSettingsStrings.text("On") : MacSettingsStrings.text("Off")
        case let .integer(value): String(value)
        case let .decimal(value): value.formatted(.number.precision(.fractionLength(0 ... 2)).locale(PluginRuntimeLocalization.locale))
        case let .choice(id): id
        case let .string(value): value
        case let .url(value): value.path(percentEncoded: false)
        case .color: MacSettingsStrings.text("Color")
        }
    }
}

struct SystemSettingChoice: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    @MacSettingsLocalized var title: String
}

// These snapshots stay in local history; portable profiles contain desired values only.
enum SystemSettingStoredPreference: Codable, Equatable, Sendable {
    case missing
    case boolean(Bool)
    case integer(Int)
    case string(String)
}

struct SystemSettingSnapshot: Codable, Equatable, Sendable {
    let value: SystemSettingValue
    var restoration: [String: SystemSettingStoredPreference]? = nil
    var components: [String: SystemSettingSnapshot]? = nil

    var hasRestorationData: Bool { restoration != nil || components != nil }
}

enum SystemSettingValueSchema: Codable, Equatable, Sendable {
    case boolean
    case integer(range: ClosedRange<Int>, step: Int)
    case decimal(range: ClosedRange<Double>, step: Double?)
    case choice(options: [SystemSettingChoice])
    case directoryChoice(options: [SystemSettingChoice])
    case string(maximumLength: Int)
    case url
    case color

    func accepts(_ value: SystemSettingValue) -> Bool {
        switch (self, value) {
        case (.boolean, .boolean):
            true
        case let (.integer(range, step), .integer(value)):
            range.contains(value) && step > 0 && (value - range.lowerBound).isMultiple(of: step)
        case let (.decimal(range, step), .decimal(value)):
            value.isFinite && range.contains(value) && (step == nil || step! > 0)
        case let (.choice(options), .choice(id)):
            !id.isEmpty && options.contains { $0.id == id }
        case let (.directoryChoice, .choice(id)):
            // Unknown native destinations may be displayed and restored, but not newly selected.
            !id.isEmpty && id.count <= 100
        case let (.directoryChoice, .url(url)):
            FinderWindowDestination.isLocalDirectoryURL(url)
        case let (.string(maximumLength), .string(value)):
            maximumLength > 0 && value.count <= maximumLength
        case (.url, .url):
            true
        case let (.color, .color(value)):
            value.isValid
        default:
            false
        }
    }

    var isValid: Bool {
        switch self {
        case .boolean, .url, .color:
            true
        case let .integer(range, step):
            range.lowerBound <= range.upperBound && step > 0
        case let .decimal(range, step):
            range.lowerBound.isFinite
                && range.upperBound.isFinite
                && range.lowerBound <= range.upperBound
                && (step == nil || (step!.isFinite && step! > 0))
        case let .choice(options), let .directoryChoice(options):
            !options.isEmpty
                && Set(options.map(\.id)).count == options.count
                && options.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty }
        case let .string(maximumLength):
            maximumLength > 0
        }
    }
}

struct SystemSettingSystemDestination: Codable, Equatable, Sendable {
    let pane: String
    let anchor: String?

    var url: URL? {
        // System Settings uses an opaque URL, not a //host URL or an anchor= query.
        // Only offer destinations whose pane and optional native anchor are known.
        let panes: Set<String> = [
            "com.apple.Accessibility-Settings.extension", "com.apple.Appearance-Settings.extension",
            "com.apple.Desktop-Settings.extension", "com.apple.Displays-Settings.extension",
            "com.apple.Keyboard-Settings.extension", "com.apple.Trackpad-Settings.extension",
            "com.apple.Mouse-Settings.extension",
        ]
        guard panes.contains(pane) else { return nil }
        if let anchor {
            let anchors: Set<String> = ["AX_FEATURE_POINTERCONTROL", "AX_CURSOR_SIZE", "AX_FEATURE_ZOOM", "AX_FEATURE_KEYBOARD"]
            guard pane == "com.apple.Accessibility-Settings.extension", anchors.contains(anchor) else { return nil }
        }
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = pane
        if let anchor, !anchor.isEmpty {
            components.percentEncodedQuery = anchor
        }
        return components.url
    }
}

struct SystemSettingRequirements: Codable, Equatable, Sendable {
    let minimumSystemVersion: SystemSettingVersion
    let maximumSystemVersion: SystemSettingVersion?
    let requiredHardware: String?
    let requiredPermissionID: String?
    let existingProviderID: String?

    init(
        minimumSystemVersion: SystemSettingVersion = .init(14),
        maximumSystemVersion: SystemSettingVersion? = nil,
        requiredHardware: String? = nil,
        requiredPermissionID: String? = nil,
        existingProviderID: String? = nil
    ) {
        self.minimumSystemVersion = minimumSystemVersion
        self.maximumSystemVersion = maximumSystemVersion
        self.requiredHardware = requiredHardware
        self.requiredPermissionID = requiredPermissionID
        self.existingProviderID = existingProviderID
    }
}

struct SystemSettingDefinition: Identifiable {
    let id: SystemSettingID
    @MacSettingsLocalized var title: String
    @MacSettingsLocalized var description: String
    let category: SystemSettingCategory
    let systemImage: String
    let schema: SystemSettingValueSchema
    let defaultValue: SystemSettingValue?
    let executionClass: SystemSettingExecutionClass
    let requirements: SystemSettingRequirements
    let portability: SystemSettingPortability
    let isSensitive: Bool
    let canReset: Bool
    let canRollback: Bool
    let verificationAvailable: Bool
    let searchTerms: [String]
    let destination: SystemSettingSystemDestination?
    let implementationNote: String

    var isProfileEligible: Bool {
        portability == .portable && !isSensitive
            && executionClass != .guidedManual
            && executionClass != .unsupported
            && executionClass != .managedOnly
    }

    var searchDocument: String {
        ([title, description, category.title] + searchTerms
            + MacSettingsStrings.searchAliases(for: $title)
            + MacSettingsStrings.searchAliases(for: $description))
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    func displayDescription(for value: SystemSettingValue) -> String {
        if case let .choice(id) = value {
            switch schema {
            case let .choice(options), let .directoryChoice(options):
                return options.first(where: { $0.id == id })?.title ?? MacSettingsStrings.format("Current Location (%@)", "\(id)")
            default: break
            }
        }
        return value.conciseDescription
    }

    func acceptsPortableValue(_ value: SystemSettingValue) -> Bool {
        guard isProfileEligible, schema.accepts(value) else { return false }
        if case let .directoryChoice(options) = schema {
            guard case let .choice(id) = value else { return false }
            return options.contains { $0.id == id }
        }
        return true
    }
}

enum SystemSettingAvailability: Equatable, Sendable {
    case available
    case requiresLogout
    case requiresRestart
    case providerUnavailable(String)
    case hardwareUnavailable(String)
    case permissionMissing(String)
    case guidedManual
    case managedOnly
    case unsupported(String)
    case systemVersionUnsupported

    var isActionableAttention: Bool {
        switch self {
        case .requiresLogout, .requiresRestart, .providerUnavailable, .hardwareUnavailable,
             .permissionMissing:
            true
        case .available, .guidedManual, .managedOnly, .unsupported, .systemVersionUnsupported:
            false
        }
    }
}

struct SystemSettingEnvironment: Sendable {
    let systemVersion: SystemSettingVersion
    let availableHardware: Set<String>
    let grantedPermissionIDs: Set<String>
    let availableProviderIDs: Set<String>
    var unavailableProviderReasons: [String: String] = [:]

    static var current: SystemSettingEnvironment {
        SystemSettingEnvironment(
            systemVersion: .init(ProcessInfo.processInfo.operatingSystemVersion),
            availableHardware: [],
            grantedPermissionIDs: MacSettingsPermission.currentGrantedIDs,
            availableProviderIDs: []
        )
    }
}

enum MacSettingsPermission {
    static let fullDiskAccess = "full-disk-access"

    static var currentGrantedIDs: Set<String> {
        hasFullDiskAccess ? [fullDiskAccess] : []
    }

    static var fullDiskAccessSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// macOS has no public Full Disk Access status API. Opening either protected file
    /// read-only is a side-effect-free capability check. The authorization is bound at
    /// process launch, so evaluating it while constructing the environment is sufficient.
    private static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        let protectedPaths = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
        return protectedPaths.contains { path in
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            try? handle.close()
            return true
        }
    }
}

enum SystemSettingCompatibilityEvaluator {
    static func availability(
        for definition: SystemSettingDefinition,
        environment: SystemSettingEnvironment
    ) -> SystemSettingAvailability {
        let requirements = definition.requirements
        guard environment.systemVersion >= requirements.minimumSystemVersion,
              requirements.maximumSystemVersion.map({ environment.systemVersion <= $0 }) ?? true else {
            return .systemVersionUnsupported
        }
        if let hardware = requirements.requiredHardware,
           !environment.availableHardware.contains(hardware) {
            return .hardwareUnavailable(hardware)
        }
        if let permissionID = requirements.requiredPermissionID,
           !environment.grantedPermissionIDs.contains(permissionID) {
            return .permissionMissing(permissionID)
        }
        if let providerID = requirements.existingProviderID,
           !environment.availableProviderIDs.contains(providerID) {
            return .providerUnavailable(environment.unavailableProviderReasons[providerID] ?? providerID)
        }

        switch definition.executionClass {
        case .directVerified, .directAppliesNextUse, .existingPluginProvider, .hardwareDependent:
            return .available
        case .directRequiresLogout:
            return .requiresLogout
        case .directRequiresRestart:
            return .requiresRestart
        case .guidedManual:
            return .guidedManual
        case .managedOnly:
            return .managedOnly
        case .unsupported:
            return .unsupported(definition.implementationNote)
        }
    }
}
