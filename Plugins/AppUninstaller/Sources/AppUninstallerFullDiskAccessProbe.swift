import Foundation

enum AppUninstallerFullDiskAccessProbe {
    static func hasAccess() -> Bool {
        hasAccess(homeDirectory: NSHomeDirectory()) { path in
            // Test the protected capability without reading file contents.
            (try? UninstallFileSystem().identity(at: path).isRegular) == true
        }
    }

    static func hasAccess(homeDirectory: String, canOpen: (String) -> Bool) -> Bool {
        let home = UninstallFileSystem.physicalHome(homeDirectory)
        let paths = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist"
        ]
        return paths.contains(where: canOpen)
    }
}
