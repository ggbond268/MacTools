import AppKit
import Foundation

/// Handles `mactools://` requests forwarded by the Finder Sync extension.
///
/// The Finder extension is sandboxed and cannot create files in arbitrary user
/// directories, so file-creating actions are forwarded to this non-sandboxed
/// host app through a custom URL scheme. Keeping creation here lets the
/// extension stay at minimal entitlements (sandbox only) instead of carrying a
/// review-sensitive temporary-exception file-access entitlement.
enum FinderContextMenuRequestHandler {
    /// Custom URL scheme the Finder extension uses to reach the host app.
    static let scheme = "mactools"

    /// Route a forwarded URL. Returns true when it was a recognized request.
    @MainActor
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == scheme else { return false }
        switch url.host {
        case "newfile":
            return handleNewFile(url)
        default:
            AppLog.finderContextMenu.warning(
                "Unknown mactools URL host: \(url.host ?? "nil", privacy: .public)"
            )
            return false
        }
    }

    @MainActor
    private static func handleNewFile(_ url: URL) -> Bool {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var params: [String: String] = [:]
        for item in queryItems {
            if let value = item.value { params[item.name] = value }
        }
        guard let dir = params["dir"], !dir.isEmpty,
              let ext = params["ext"], !ext.isEmpty else {
            AppLog.finderContextMenu.error("mactools://newfile missing dir or ext")
            return false
        }
        // The host app is non-sandboxed; validate the target is a real directory
        // so a malformed request can never create files in an unexpected place.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            AppLog.finderContextMenu.error(
                "mactools://newfile target is not a directory: \(dir, privacy: .public)"
            )
            return false
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        let fileURL = nextAvailableURL(in: directory, baseName: "未命名", ext: ext)
        guard FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil) else {
            AppLog.finderContextMenu.error(
                "mactools://newfile failed to create \(fileURL.path, privacy: .public)"
            )
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        return true
    }

    /// First non-colliding URL of the form `<baseName>.<ext>`,
    /// `<baseName> 2.<ext>`, `<baseName> 3.<ext>`, … inside `directory`.
    ///
    /// `fileExists` is injected so tests can drive the collision logic without a
    /// real file system.
    static func nextAvailableURL(
        in directory: URL,
        baseName: String,
        ext: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while fileExists(candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
