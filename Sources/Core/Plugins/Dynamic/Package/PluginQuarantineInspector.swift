import Darwin
import Foundation

enum PluginQuarantineError: LocalizedError, Equatable {
    case enumerationFailed(path: String)
    case attributeCheckFailed(path: String, reason: String)
    case stripFailed(failedCount: Int, path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .enumerationFailed(path):
            return AppL10n.pluginsFormat(
                "plugin.error.quarantine.enumerationFailedFormat",
                defaultValue: "无法检查插件包的隔离状态：%@",
                path
            )
        case let .attributeCheckFailed(path, reason):
            return AppL10n.pluginsFormat(
                "plugin.error.quarantine.attributeCheckFailedFormat",
                defaultValue: "无法读取插件文件的隔离标记：%@（%@）",
                path,
                reason
            )
        case let .stripFailed(failedCount, path, reason):
            return AppL10n.pluginsFormat(
                "plugin.error.quarantine.stripFailedFormat",
                defaultValue: "无法移除 %d 个插件文件的隔离标记，例如 %@（%@）。",
                failedCount,
                path,
                reason
            )
        }
    }
}

protocol PluginQuarantineInspecting {
    func quarantinedItemURLs(in packageURL: URL) throws -> [URL]
    func stripQuarantine(at packageURL: URL) throws
}

/// Detects and removes the `com.apple.quarantine` extended attribute from plugin packages.
///
/// Browser-downloaded zips carry the quarantine attribute and both `ditto` extraction and
/// `FileManager` copy/move propagate it onto every file of the package. A quarantined,
/// codesigned-but-not-notarized bundle is rejected by Gatekeeper when a hardened host
/// dlopens it, so the attribute must be gone before the bundle reaches the loader.
struct PluginQuarantineInspector: PluginQuarantineInspecting {
    static let quarantineAttributeName = "com.apple.quarantine"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func quarantinedItemURLs(in packageURL: URL) throws -> [URL] {
        try packageItemURLs(in: packageURL).filter { itemURL in
            try hasQuarantineAttribute(atPath: itemURL.path)
        }
    }

    func stripQuarantine(at packageURL: URL) throws {
        var failures: [(path: String, reason: String)] = []

        for itemURL in try packageItemURLs(in: packageURL) {
            let path = itemURL.path
            guard removexattr(path, Self.quarantineAttributeName, XATTR_NOFOLLOW) != 0 else {
                continue
            }

            let code = errno
            // ENOATTR: already clean. ENOTSUP: the file system cannot carry xattrs,
            // so it cannot carry a quarantine flag either.
            if code == ENOATTR || code == ENOTSUP {
                continue
            }

            failures.append((path: path, reason: Self.errnoDescription(code)))
        }

        guard let firstFailure = failures.first else {
            return
        }

        throw PluginQuarantineError.stripFailed(
            failedCount: failures.count,
            path: firstFailure.path,
            reason: firstFailure.reason
        )
    }

    // Every file-system object in the package is visited, not just the bundle executable:
    // ditto stamps each extracted entry and Gatekeeper evaluates nested bundle items, so a
    // single missed file keeps dlopen blocked. Packages are small, which makes one xattr
    // syscall per entry cheaper than reasoning about which files matter.
    //
    // The path-based enumerator yields paths relative to the package root, so every
    // returned URL keeps the caller's root prefix (the URL-based enumerator rewrites
    // children to /private/var while the root stays /var, producing mixed prefixes).
    // It also never descends into symlinked directories.
    private func packageItemURLs(in packageURL: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(atPath: packageURL.path) else {
            throw PluginQuarantineError.enumerationFailed(path: packageURL.path)
        }

        var itemURLs = [packageURL]

        for case let relativePath as String in enumerator {
            itemURLs.append(packageURL.appendingPathComponent(relativePath))
        }

        return itemURLs
    }

    private func hasQuarantineAttribute(atPath path: String) throws -> Bool {
        // XATTR_NOFOLLOW everywhere: a crafted package could contain symlinks pointing
        // outside the package, and following them would inspect or strip foreign files.
        let size = getxattr(path, Self.quarantineAttributeName, nil, 0, 0, XATTR_NOFOLLOW)
        if size >= 0 {
            return true
        }

        let code = errno
        if code == ENOATTR || code == ENOTSUP {
            return false
        }

        throw PluginQuarantineError.attributeCheckFailed(path: path, reason: Self.errnoDescription(code))
    }

    private static func errnoDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
