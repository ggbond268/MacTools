import Foundation

/// Reads/writes `FinderMenuConfiguration` shared between the non-sandboxed host
/// app and the sandboxed Finder Sync extension, via a JSON file under the user's
/// real `~/Library/Application Support/MacTools/`.
///
/// Why a plain file at the real home — and neither an app group nor UserDefaults
/// (both were tried and measured to fail across this sandbox boundary):
/// - The non-sandboxed host app is **denied** write access to the app group
///   container (`~/Library/Group Containers`, managed by containermanagerd —
///   writes fail with "Operation not permitted").
/// - `UserDefaults(suiteName:)` does NOT bridge the two either: the non-sandboxed
///   app's cfprefsd domain and the sandboxed extension's are separate, so the
///   extension only ever reads back `.default`.
///
/// So the host writes a JSON file it CAN write (its real Application Support),
/// and the sandboxed extension reads it through a read-only
/// `temporary-exception.files.home-relative-path` entitlement scoped to
/// `configDirectoryRelativePath`. Both sides must resolve the SAME path: a
/// sandboxed process's `NSHomeDirectory()` is redirected to its container, so we
/// resolve the real home via `getpwuid` on both sides to keep the path identical.
enum FinderMenuConfigStore {
    /// Real user home directory, bypassing the sandbox container redirection so
    /// the host app and the sandboxed extension resolve the exact same file.
    private static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return String(cString: home)
        }
        return NSHomeDirectory()
    }()

    /// Directory the configuration file lives in, relative to the real home. Must
    /// stay in sync with the extension's `home-relative-path` read-only
    /// entitlement (`/Library/Application Support/MacTools/`).
    static let configDirectoryRelativePath = "Library/Application Support/MacTools"

    /// Resolved location of the shared configuration file.
    static var configFileURL: URL {
        URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent(configDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent("finder-menu.json")
    }

    /// Load the saved configuration, or `.default` when nothing is saved yet or
    /// the stored data is unreadable.
    static func load(from fileURL: URL = configFileURL) -> FinderMenuConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              let configuration = try? JSONDecoder().decode(FinderMenuConfiguration.self, from: data)
        else {
            return .default
        }
        return configuration
    }

    /// Persist the configuration. Returns false when the directory cannot be
    /// created or the file cannot be written. Only the non-sandboxed host app is
    /// expected to call this; the sandboxed extension has read-only access.
    @discardableResult
    static func save(_ configuration: FinderMenuConfiguration, to fileURL: URL = configFileURL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
