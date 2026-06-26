import Foundation

/// Reads/writes `FinderMenuConfiguration` in the shared app group container so
/// the non-sandboxed host app and the sandboxed extension share one file.
///
/// A plain `UserDefaults(suiteName:)` is unreliable across the sandbox boundary
/// (the two processes resolve different containers); the app group container
/// *directory* is the same for both, so a JSON file there is the robust channel.
enum FinderMenuConfigStore {
    /// Resolved from Info.plist key `MTAppGroupIdentifier`, which both targets
    /// set to `group.$(BUNDLE_IDENTIFIER_PREFIX).mactools` — so it tracks the
    /// bundle-id prefix instead of being hard-coded, and stays in sync with the
    /// `com.apple.security.application-groups` entitlement. Falls back to the
    /// current default if the key is somehow missing.
    static let appGroupIdentifier: String = {
        Bundle.main.object(forInfoDictionaryKey: "MTAppGroupIdentifier") as? String
            ?? "group.com.example.mactools"
    }()

    private static let fileName = "finder-menu-config.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    /// Load the saved configuration, or `.default` when nothing is saved yet or
    /// the file is unreadable/corrupt.
    static func load() -> FinderMenuConfiguration {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(FinderMenuConfiguration.self, from: data)
        else {
            return .default
        }
        return configuration
    }

    /// Persist the configuration to the shared container. Returns false on
    /// failure (missing container / encode / write error) without throwing.
    @discardableResult
    static func save(_ configuration: FinderMenuConfiguration) -> Bool {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(configuration) else {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
