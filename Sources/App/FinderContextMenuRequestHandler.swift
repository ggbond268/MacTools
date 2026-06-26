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

    /// File extensions the New File action may create. A strict allow list keeps
    /// the feature to its intended types and — because a custom URL scheme can be
    /// invoked by any process on the system — prevents path traversal through the
    /// `ext` parameter (e.g. `../../etc/foo`).
    static let allowedNewFileExtensions: Set<String> = ["txt", "md", "json"]

    static func isSupportedNewFileExtension(_ ext: String) -> Bool {
        allowedNewFileExtensions.contains(ext)
    }

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
              let ext = params["ext"], isSupportedNewFileExtension(ext) else {
            AppLog.finderContextMenu.error("mactools://newfile missing dir or unsupported ext")
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
        // Defense-in-depth: the resolved file must sit directly inside the target
        // directory. The allow-listed ext already rules out traversal; this guard
        // keeps that invariant even if the naming inputs ever change.
        guard fileURL.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path else {
            AppLog.finderContextMenu.error(
                "mactools://newfile resolved outside target directory: \(fileURL.path, privacy: .public)"
            )
            return false
        }
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
