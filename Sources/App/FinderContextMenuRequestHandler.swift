import AppKit
import Foundation

/// Handles `mactools://` requests forwarded by the Finder Sync extension.
///
/// The Finder extension is sandboxed and cannot create files in arbitrary user
/// directories or launch other apps, so those actions are forwarded to this
/// non-sandboxed host app through a custom URL scheme. Keeping them here lets the
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
        case "openterminal":
            return handleOpenInTerminal(url)
        case "openwith":
            return handleOpenWith(url)
        default:
            AppLog.finderContextMenu.warning(
                "Unknown mactools URL host: \(url.host ?? "nil", privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Actions

    @MainActor
    private static func handleNewFile(_ url: URL) -> Bool {
        let params = queryParameters(of: url)
        guard let ext = params["ext"], isSupportedNewFileExtension(ext) else {
            AppLog.finderContextMenu.error("mactools://newfile missing or unsupported ext")
            return false
        }
        guard let directory = validatedDirectory(params) else { return false }
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

    @MainActor
    private static func handleOpenInTerminal(_ url: URL) -> Bool {
        guard let directory = validatedDirectory(queryParameters(of: url)) else { return false }
        guard let terminalURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else {
            AppLog.finderContextMenu.error("mactools://openterminal: Terminal app not found")
            return false
        }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }

    /// Open the forwarded files with a user-chosen app. The `app` must be an
    /// existing `.app` bundle and at least one `file` must exist; anything else
    /// is rejected so a malformed (or hostile) request can't reach the file
    /// system in an unexpected way.
    /// Parsed + validated open-with request. Split out of `handleOpenWith` so the
    /// validation is unit-testable without launching anything.
    struct OpenWithRequest: Equatable {
        let appURL: URL
        let files: [URL]
    }

    /// Validate a forwarded open-with request: `app` must be an existing `.app`
    /// bundle and at least one `file` must exist; anything else returns nil. The
    /// file-system probes are injected so tests don't touch the real disk.
    static func parseOpenWithRequest(
        _ items: [URLQueryItem],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isApplicationBundle: (String) -> Bool = isApplicationBundleOnDisk
    ) -> OpenWithRequest? {
        guard let appPath = items.first(where: { $0.name == "app" })?.value,
              !appPath.isEmpty, isApplicationBundle(appPath) else {
            return nil
        }
        let files = items.filter { $0.name == "file" }
            .compactMap(\.value)
            .map { URL(fileURLWithPath: $0) }
            .filter { fileExists($0.path) }
        guard !files.isEmpty else { return nil }
        return OpenWithRequest(appURL: URL(fileURLWithPath: appPath), files: files)
    }

    private static func isApplicationBundleOnDisk(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasSuffix(".app")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    @MainActor
    private static func handleOpenWith(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let request = parseOpenWithRequest(items) else {
            AppLog.finderContextMenu.error("mactools://openwith invalid request")
            return false
        }
        NSWorkspace.shared.open(
            request.files,
            withApplicationAt: request.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }

    // MARK: - Helpers

    private static func queryParameters(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var params: [String: String] = [:]
        for item in items {
            if let value = item.value { params[item.name] = value }
        }
        return params
    }

    /// Resolve and validate the `dir` parameter as an existing directory. The
    /// host app is non-sandboxed, so a malformed request must never reach the
    /// file system: anything that is not a real directory is rejected.
    private static func validatedDirectory(_ params: [String: String]) -> URL? {
        guard let dir = params["dir"], !dir.isEmpty else {
            AppLog.finderContextMenu.error("mactools request missing dir")
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            AppLog.finderContextMenu.error(
                "mactools request dir is not a directory: \(dir, privacy: .public)"
            )
            return nil
        }
        return URL(fileURLWithPath: dir, isDirectory: true)
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
