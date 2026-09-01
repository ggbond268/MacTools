import CoreFoundation
import Foundation

@MainActor
protocol FinderPreferencesStoring {
    func read(keys: [String], domain: String) throws -> [String: SystemSettingStoredPreference]
    func write(_ values: [String: SystemSettingStoredPreference], domain: String) throws
}

// Exact-domain reads preserve absent keys instead of filling them from global defaults.
// Native preference calls also avoid launching a blocking defaults subprocess.
@MainActor
struct CoreFoundationFinderPreferencesStore: FinderPreferencesStoring {
    private func applicationID(_ domain: String) -> CFString {
        domain == UserDefaults.globalDomain ? kCFPreferencesAnyApplication : domain as CFString
    }

    func read(keys: [String], domain: String) throws -> [String: SystemSettingStoredPreference] {
        let application = applicationID(domain)
        guard CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw SystemSettingAdapterError.unreadable
        }
        let values = CFPreferencesCopyMultiple(
            keys as CFArray, application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? [String: Any] ?? [:]
        return try Dictionary(uniqueKeysWithValues: keys.map { key in
            let value: SystemSettingStoredPreference
            switch values[key] {
            case nil: value = .missing
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                value = .boolean(number.boolValue)
            case let number as NSNumber where ["c", "s", "i", "l", "q"].contains(String(cString: number.objCType)):
                value = .integer(number.intValue)
            case let string as String: value = .string(string)
            default: throw SystemSettingAdapterError.unreadable
            }
            return (key, value)
        })
    }

    func write(_ values: [String: SystemSettingStoredPreference], domain: String) throws {
        let application = applicationID(domain)
        guard !values.keys.contains(where: { CFPreferencesAppValueIsForced($0 as CFString, application) }) else {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("This setting is managed by your organization and cannot be changed."))
        }
        var updates: [String: Any] = [:]
        var removals: [String] = []
        for (key, value) in values {
            switch value {
            case .missing: removals.append(key)
            case let .boolean(value): updates[key] = value
            case let .integer(value): updates[key] = value
            case let .string(value): updates[key] = value
            }
        }
        CFPreferencesSetMultiple(
            updates as CFDictionary, removals as CFArray,
            application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        guard CFPreferencesSynchronize(application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Could not save system preferences."))
        }
    }
}

@MainActor
final class FinderExtensionsSystemSettingAdapter: SystemSettingAdapter {
    private static let key = "AppleShowAllExtensions"
    private let store: any FinderPreferencesStoring

    init(store: any FinderPreferencesStoring = CoreFoundationFinderPreferencesStore()) {
        self.store = store
    }

    func read() async throws -> SystemSettingValue { try await snapshot().value }

    func snapshot() async throws -> SystemSettingSnapshot {
        let global = try store.read(keys: [Self.key], domain: UserDefaults.globalDomain)[Self.key] ?? .missing
        let finder = try store.read(keys: [Self.key], domain: "com.apple.finder")[Self.key] ?? .missing
        let state = ["global": global, "finder": finder]
        return .init(value: try value(from: state), restoration: state)
    }

    private func value(from state: [String: SystemSettingStoredPreference]) throws -> SystemSettingValue {
        guard Set(state.keys) == ["global", "finder"] else { throw SystemSettingAdapterError.invalidValue }
        for value in state.values {
            switch value {
            case .missing, .boolean: break
            default: throw SystemSettingAdapterError.invalidValue
            }
        }
        // Reflect Finder's existing override until the user explicitly changes this setting.
        if case let .boolean(enabled) = state["finder"] { return .boolean(enabled) }
        if case let .boolean(enabled) = state["global"] { return .boolean(enabled) }
        return .boolean(false)
    }

    func apply(_ value: SystemSettingValue) async throws {
        guard case let .boolean(enabled) = value else { throw SystemSettingAdapterError.invalidValue }
        try store.write([Self.key: .boolean(enabled)], domain: UserDefaults.globalDomain)
        // Older plugin previews wrote an app-specific override; do not let it shadow the global value.
        try store.write([Self.key: .missing], domain: "com.apple.finder")
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        let current = try await snapshot()
        if current.value == expectedValue, current.restoration?["finder"] == .missing {
            return .verified(expectedValue)
        }
        return .mismatch(actual: current.value)
    }

    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        guard let state = snapshot.restoration else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This history entry lacks a complete snapshot and cannot be safely restored."))
        }
        guard try value(from: state) == snapshot.value else { throw SystemSettingAdapterError.invalidValue }
        try store.write([Self.key: state["global"]!], domain: UserDefaults.globalDomain)
        try store.write([Self.key: state["finder"]!], domain: "com.apple.finder")
        let current = try await self.snapshot()
        return current == snapshot ? .verified(current.value) : .mismatch(actual: current.value)
    }
}

enum FinderWindowDestination {
    static let options: [SystemSettingChoice] = [
        .init(id: "PfAF", title: "Recents"),
        .init(id: "PfHm", title: "Home"),
        .init(id: "PfDe", title: "Desktop"),
        .init(id: "PfDo", title: "Documents"),
        .init(id: "PfCm", title: "Computer"),
        .init(id: "PfID", title: "iCloud Drive"),
    ]

    static func isLocalDirectoryURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.query == nil && url.fragment == nil
            && url.path.hasPrefix("/") && !url.path.contains("\0")
    }
}

@MainActor
final class FinderWindowDestinationSystemSettingAdapter: SystemSettingAdapter {
    private static let domain = "com.apple.finder"
    private static let targetKey = "NewWindowTarget"
    private static let pathKey = "NewWindowTargetPath"
    private static let keys = [targetKey, pathKey]
    private let store: any FinderPreferencesStoring
    private let homeDirectory: URL
    private let validateDirectory: (URL) throws -> Void

    init(
        store: any FinderPreferencesStoring = CoreFoundationFinderPreferencesStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        validateDirectory: @escaping (URL) throws -> Void = { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            guard values.isDirectory == true, values.isReadable == true else {
                throw SystemSettingAdapterError.writeFailed(MacSettingsStrings.text("Choose an existing, readable folder."))
            }
        }
    ) {
        self.store = store
        self.homeDirectory = homeDirectory
        self.validateDirectory = validateDirectory
    }

    func read() async throws -> SystemSettingValue { try await snapshot().value }

    func snapshot() async throws -> SystemSettingSnapshot {
        let state = try store.read(keys: Self.keys, domain: Self.domain)
        return .init(value: try value(from: state), restoration: state)
    }

    private func value(from state: [String: SystemSettingStoredPreference]) throws -> SystemSettingValue {
        guard Set(state.keys) == Set(Self.keys) else { throw SystemSettingAdapterError.invalidValue }
        let target: String
        switch state[Self.targetKey] {
        case .missing: target = "PfAF"
        case let .string(value) where !value.isEmpty && value.count <= 100: target = value
        default: throw SystemSettingAdapterError.unreadable
        }
        switch state[Self.pathKey] {
        case .missing, .string: break
        default: throw SystemSettingAdapterError.unreadable
        }
        if target == "PfLo", case let .string(path) = state[Self.pathKey],
           let url = URL(string: path), FinderWindowDestination.isLocalDirectoryURL(url) {
            return .url(url)
        }
        // Preserve unknown targets and incomplete custom destinations for display and exact Undo.
        return .choice(id: target)
    }

    private func preferences(for value: SystemSettingValue) throws -> [String: SystemSettingStoredPreference] {
        let target: String
        let directory: URL?
        switch value {
        case let .choice(id) where FinderWindowDestination.options.contains(where: { $0.id == id }):
            target = id
            directory = switch id {
            case "PfHm": homeDirectory
            case "PfDe": homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
            case "PfDo": homeDirectory.appendingPathComponent("Documents", isDirectory: true)
            case "PfCm": URL(filePath: "/", directoryHint: .isDirectory)
            case "PfID": homeDirectory.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            default: nil // Recents is a native virtual location, not a user-specific folder.
            }
        case let .url(url) where FinderWindowDestination.isLocalDirectoryURL(url):
            target = "PfLo"
            directory = url
        default: throw SystemSettingAdapterError.invalidValue
        }
        return [Self.targetKey: .string(target), Self.pathKey: directory.map { .string($0.absoluteString) } ?? .missing]
    }

    func apply(_ value: SystemSettingValue) async throws {
        let preferences = try preferences(for: value)
        if case let .string(path) = preferences[Self.pathKey], let directory = URL(string: path) {
            // Validate immediately before mutation; an unmounted destination must not overwrite the old one.
            try validateDirectory(directory)
        }
        try store.write(preferences, domain: Self.domain)
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        let expected = try preferences(for: expectedValue)
        let current = try await snapshot()
        return current.restoration == expected ? .verified(expectedValue) : .mismatch(actual: current.value)
    }

    func restore(_ snapshot: SystemSettingSnapshot) async throws -> SystemSettingVerification {
        guard let state = snapshot.restoration else {
            throw SystemSettingAdapterError.unsupported(MacSettingsStrings.text("This history entry lacks a complete snapshot and cannot be safely restored."))
        }
        guard try value(from: state) == snapshot.value else { throw SystemSettingAdapterError.invalidValue }
        // Restoration preserves the original raw URL and absence, even if the old folder is now unmounted.
        try store.write(state, domain: Self.domain)
        let current = try await self.snapshot()
        return current == snapshot ? .verified(current.value) : .mismatch(actual: current.value)
    }
}
