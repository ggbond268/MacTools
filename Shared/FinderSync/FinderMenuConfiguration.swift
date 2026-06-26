import Foundation

/// User configuration for the MacTools Finder context menu, shared between the
/// host app (writes it from the settings UI) and the sandboxed extension (reads
/// it to decide which items to show). Persisted as JSON in the shared app group
/// container — see `FinderMenuConfigStore`.
///
/// This file is compiled into BOTH the host app and the extension targets (they
/// can't import each other); the JSON written by one is decoded by the other.
struct FinderMenuConfiguration: Codable, Equatable {
    var copyAbsolutePath: Bool
    var copyShellEscapedPath: Bool
    var copyFileName: Bool
    var copyFileURL: Bool
    var newFileEnabled: Bool
    var openInTerminal: Bool
    var openWithApps: [OpenWithApp]

    init(
        copyAbsolutePath: Bool = true,
        copyShellEscapedPath: Bool = true,
        copyFileName: Bool = true,
        copyFileURL: Bool = true,
        newFileEnabled: Bool = true,
        openInTerminal: Bool = true,
        openWithApps: [OpenWithApp] = []
    ) {
        self.copyAbsolutePath = copyAbsolutePath
        self.copyShellEscapedPath = copyShellEscapedPath
        self.copyFileName = copyFileName
        self.copyFileURL = copyFileURL
        self.newFileEnabled = newFileEnabled
        self.openInTerminal = openInTerminal
        self.openWithApps = openWithApps
    }

    /// Defaults match the previously hard-coded menu, so a fresh install behaves
    /// exactly like before any configuration is saved.
    static let `default` = FinderMenuConfiguration()

    /// True when no copy action is enabled (used to hide the empty submenu).
    var hasAnyCopyAction: Bool {
        copyAbsolutePath || copyShellEscapedPath || copyFileName || copyFileURL
    }
}

/// A user-configured "Open With" application entry.
struct OpenWithApp: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var appPath: String
    /// Lowercased file extensions this entry applies to; empty = all files.
    var fileExtensions: [String]

    init(id: UUID = UUID(), name: String, appPath: String, fileExtensions: [String] = []) {
        self.id = id
        self.name = name
        self.appPath = appPath
        self.fileExtensions = fileExtensions
    }

    /// Whether this entry should appear for a file with the given (lowercased)
    /// extension. An empty `fileExtensions` matches everything.
    func matches(fileExtension ext: String) -> Bool {
        fileExtensions.isEmpty || fileExtensions.contains(ext.lowercased())
    }
}
