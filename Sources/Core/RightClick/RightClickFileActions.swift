import AppKit
import Foundation

enum RightClickLocalization {
    private static let appleLanguagesKey = "AppleLanguages"
    private static let rightClickTable = "RightClick"
    private static let finderSyncBundleSuffix = ".right-click.finder-sync"

    static func string(
        _ key: String,
        defaultValue: String,
        bundle: Bundle = .main,
        preferredLanguages: [String]? = nil
    ) -> String {
        for localizedBundle in LocalizedBundleResolver.localizedBundles(
            in: bundle,
            preferredLanguages: preferredLanguages ?? effectivePreferredLanguages(for: bundle),
            baseLanguage: "en"
        ) {
            let localizedValue = localizedBundle.localizedString(forKey: key, value: nil, table: rightClickTable)
            if localizedValue != key {
                return localizedValue
            }
        }

        return defaultValue
    }

    static func format(
        _ key: String,
        defaultValue: String,
        bundle: Bundle = .main,
        preferredLanguages: [String]? = nil,
        _ arguments: CVarArg...
    ) -> String {
        let languages = preferredLanguages ?? effectivePreferredLanguages(for: bundle)
        return String(
            format: string(
                key,
                defaultValue: defaultValue,
                bundle: bundle,
                preferredLanguages: preferredLanguages
            ),
            locale: LocalizedBundleResolver.locale(for: languages.first),
            arguments: arguments
        )
    }

    private static func effectivePreferredLanguages(for bundle: Bundle) -> [String] {
        // Finder Sync is a separate process. It must read the host app's
        // explicit AppleLanguages override rather than this extension's list.
        for bundleIdentifier in preferenceBundleIdentifiers(for: bundle) {
            if let appleLanguages = explicitAppleLanguages(forBundleIdentifier: bundleIdentifier) {
                return appleLanguages
            }
        }

        return Locale.preferredLanguages
    }

    private static func preferenceBundleIdentifiers(for bundle: Bundle) -> [String] {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return []
        }

        return preferenceBundleIdentifiers(forBundleIdentifier: bundleIdentifier)
    }

    private static func preferenceBundleIdentifiers(forBundleIdentifier bundleIdentifier: String) -> [String] {
        if bundleIdentifier.hasSuffix(finderSyncBundleSuffix) {
            let hostBundleIdentifier = String(bundleIdentifier.dropLast(finderSyncBundleSuffix.count))
            return [hostBundleIdentifier, bundleIdentifier]
        }

        return [bundleIdentifier]
    }

    private static func explicitAppleLanguages(forBundleIdentifier bundleIdentifier: String) -> [String]? {
        let applicationID = bundleIdentifier as CFString
        CFPreferencesAppSynchronize(applicationID)
        guard
            let value = CFPreferencesCopyValue(
                appleLanguagesKey as CFString,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? [String],
            !value.isEmpty
        else {
            return nil
        }

        return value
    }

    #if DEBUG
    static func preferenceBundleIdentifiersForTesting(bundleIdentifier: String?) -> [String] {
        guard let bundleIdentifier else {
            return []
        }

        return preferenceBundleIdentifiers(forBundleIdentifier: bundleIdentifier)
    }
    #endif
}

enum RightClickActionError: LocalizedError, Equatable {
    case directoryUnavailable(String)
    case cannotCreateDirectory(String)
    case cannotCreateFile(String)
    case unsupportedFileExtension(String)
    case applicationUnavailable(String)
    case noValidFiles

    var errorDescription: String? {
        switch self {
        case let .directoryUnavailable(path):
            RightClickLocalization.format("error.directoryUnavailable", defaultValue: "文件夹不可用：%@", path)
        case let .cannotCreateDirectory(path):
            RightClickLocalization.format("error.cannotCreateDirectory", defaultValue: "无法新建文件夹：%@", path)
        case let .cannotCreateFile(path):
            RightClickLocalization.format("error.cannotCreateFile", defaultValue: "无法新建文件：%@", path)
        case let .unsupportedFileExtension(ext):
            RightClickLocalization.format("error.unsupportedFileExtension", defaultValue: "不支持的文件类型：%@", ext)
        case let .applicationUnavailable(path):
            RightClickLocalization.format("error.applicationUnavailable", defaultValue: "应用不可用：%@", path)
        case .noValidFiles:
            RightClickLocalization.string("error.noValidFiles", defaultValue: "没有可用的文件")
        }
    }
}

struct RightClickPathFormatter {
    static func relativePath(of target: URL, to base: URL) -> String {
        let baseComponents = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let targetComponents = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var sharedCount = 0

        while sharedCount < baseComponents.count,
              sharedCount < targetComponents.count,
              baseComponents[sharedCount] == targetComponents[sharedCount] {
            sharedCount += 1
        }

        let upCount = max(0, baseComponents.count - sharedCount)
        let downComponents = targetComponents.dropFirst(sharedCount)
        let components = Array(repeating: "..", count: upCount) + Array(downComponents)
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    static func joinedPaths(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    static func joinedFileNames(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: "\n")
    }

    static func joinedRelativePaths(_ urls: [URL], base: URL?) -> String {
        urls
            .map { url in
                guard let base else {
                    return url.path
                }

                return relativePath(of: url, to: base)
            }
            .joined(separator: "\n")
    }

    /// Shell-escaped paths, space-separated so the whole line can be pasted as
    /// terminal arguments.
    static func joinedShellEscapedPaths(_ urls: [URL]) -> String {
        urls.map { shellEscaped($0.path) }.joined(separator: " ")
    }

    static func joinedFileURLs(_ urls: [URL]) -> String {
        urls.map(\.absoluteString).joined(separator: "\n")
    }

    /// Single-quote wrap, with embedded single quotes escaped as `'\''`.
    static func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct RightClickCopyTargets {
    let urls: [URL]
    let relativeBaseURL: URL?
}

enum RightClickCopyTargetResolver {
    static func selectedItems(_ selectedURLs: [URL], targetedURL: URL?) -> RightClickCopyTargets? {
        guard !selectedURLs.isEmpty else {
            return nil
        }

        return RightClickCopyTargets(urls: selectedURLs, relativeBaseURL: targetedURL)
    }

    static func currentDirectory(targetedURL: URL?) -> RightClickCopyTargets? {
        guard let directory = RightClickTargetResolver.targetDirectory(
            selectedURLs: [],
            targetedURL: targetedURL
        ) else {
            return nil
        }

        return RightClickCopyTargets(
            urls: [directory],
            relativeBaseURL: directory.deletingLastPathComponent()
        )
    }
}

struct RightClickTargetResolver {
    static func targetDirectory(selectedURLs: [URL], targetedURL: URL?) -> URL? {
        if let first = selectedURLs.first {
            return directory(for: first)
        }

        if let targetedURL {
            return directory(for: targetedURL)
        }

        return nil
    }

    static func directory(for url: URL) -> URL {
        if isDirectory(url) {
            return url
        }

        return url.deletingLastPathComponent()
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct RightClickFileNamePlanner {
    static func nextAvailableFolderURL(
        in directory: URL,
        baseName: String = RightClickLocalization.string("file.defaultFolderName", defaultValue: "新建文件夹")
    ) -> URL {
        nextAvailableURL(in: directory, baseName: baseName, pathExtension: nil)
    }

    static func nextAvailableURL(in directory: URL, baseName: String, pathExtension: String?) -> URL {
        let sanitizedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? RightClickLocalization.string("file.untitledName", defaultValue: "未命名")
            : baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExtension = pathExtension?.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        func candidate(_ index: Int?) -> URL {
            let name: String
            if let index {
                name = "\(sanitizedBaseName) \(index)"
            } else {
                name = sanitizedBaseName
            }

            let url = directory.appendingPathComponent(name, isDirectory: normalizedExtension == nil)
            guard let normalizedExtension, !normalizedExtension.isEmpty else {
                return url
            }

            return url.appendingPathExtension(normalizedExtension)
        }

        let manager = FileManager.default
        var url = candidate(nil)
        guard manager.fileExists(atPath: url.path) else {
            return url
        }

        var index = 2
        repeat {
            url = candidate(index)
            index += 1
        } while manager.fileExists(atPath: url.path)

        return url
    }
}

protocol RightClickWorkspaceOpening {
    func activateFileViewerSelecting(_ urls: [URL])
}

struct RightClickWorkspace: RightClickWorkspaceOpening {
    func activateFileViewerSelecting(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

struct RightClickFileActionService {
    var fileManager: FileManager = .default
    var workspace: RightClickWorkspaceOpening = RightClickWorkspace()

    func createFolder(in directory: URL) throws -> URL {
        guard RightClickTargetResolver.isDirectory(directory) else {
            throw RightClickActionError.directoryUnavailable(directory.path)
        }

        let folderURL = RightClickFileNamePlanner.nextAvailableFolderURL(in: directory)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            workspace.activateFileViewerSelecting([folderURL])
            return folderURL
        } catch {
            throw RightClickActionError.cannotCreateDirectory(folderURL.path)
        }
    }

    /// Create an empty file of an allow-listed type inside the target directory,
    /// then reveal it in Finder. The extension allow list also blocks path
    /// traversal through the forwarded `ext` parameter.
    func createFile(in directory: URL, extension fileExtension: String) throws -> URL {
        guard RightClickNewFile.isSupportedExtension(fileExtension) else {
            throw RightClickActionError.unsupportedFileExtension(fileExtension)
        }
        guard RightClickTargetResolver.isDirectory(directory) else {
            throw RightClickActionError.directoryUnavailable(directory.path)
        }
        let fileURL = RightClickFileNamePlanner.nextAvailableURL(
            in: directory,
            baseName: RightClickLocalization.string("file.untitledName", defaultValue: "未命名"),
            pathExtension: fileExtension
        )
        // Defense-in-depth: the resolved file must sit directly inside the target.
        guard fileURL.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path else {
            throw RightClickActionError.cannotCreateFile(fileURL.path)
        }
        // Exclusive create: fail (rather than clobber) if the path appeared
        // between nextAvailableURL and now (TOCTOU). createFile(atPath:) would
        // silently truncate an existing file.
        do {
            try Data().write(to: fileURL, options: .withoutOverwriting)
        } catch {
            throw RightClickActionError.cannotCreateFile(fileURL.path)
        }
        workspace.activateFileViewerSelecting([fileURL])
        return fileURL
    }
}

/// New-file types the right-click menu may create. A strict allow list keeps the
/// feature to its intended types and — because the host's URL scheme can be
/// invoked by any process — prevents path traversal through the `ext` parameter.
enum RightClickNewFile {
    /// Keep this list concise because every entry appears in the Finder submenu.
    /// Binary media and template-based formats are intentionally omitted because
    /// this feature creates zero-byte files rather than usable encoded content.
    static let supportedExtensions: [String] = [
        "txt", "md", "csv",
        "json", "yaml", "yml", "xml",
        "html", "css", "js", "ts",
        "sh", "py"
    ]

    static func isSupportedExtension(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }
}
