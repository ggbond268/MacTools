import AppKit
import Darwin
import Foundation

// MARK: - Safety Status & Errors

public enum StorageExplorerSafetyStatus: Equatable, Sendable {
    case allowed
    case blocked(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var reason: String? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }
}

public enum StorageExplorerSafetyError: LocalizedError, Sendable {
    case blocked(reason: String)
    case notFound(path: String)
    case recycleFailed(path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .blocked(reason):
            return "Item is blocked by safety policy: \(reason)"
        case let .notFound(path):
            return "Item not found at: \(path)"
        case let .recycleFailed(path, underlying):
            return "Failed to move \(path) to Trash: \(underlying)"
        }
    }
}

// MARK: - Trash Recycling Protocol

public struct StorageExplorerRecycleResult: Sendable, Equatable {
    public let moved: [URL: URL]
    public let errorDescription: String?

    public init(moved: [URL: URL], errorDescription: String? = nil) {
        self.moved = moved
        self.errorDescription = errorDescription
    }
}

public protocol StorageExplorerTrashRecycling: Sendable {
    func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult
}

public final class WorkspaceTrashRecycler: StorageExplorerTrashRecycling {
    public init() {}

    public func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle(urls) { trashedURLs, error in
                    continuation.resume(returning: StorageExplorerRecycleResult(
                        moved: trashedURLs,
                        errorDescription: error?.localizedDescription
                    ))
                }
            }
        }
    }
}

// MARK: - Safety Policy

public struct StorageExplorerSafetyPolicy: Sendable {
    public let trashRecycler: any StorageExplorerTrashRecycling
    public let homeDirectory: String

    public init(
        trashRecycler: any StorageExplorerTrashRecycling = WorkspaceTrashRecycler(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.trashRecycler = trashRecycler
        self.homeDirectory = Self.stripTrailingSlash(Self.normalizeSlashes(homeDirectory))
    }

    public func validatePathShape(_ path: String) -> StorageExplorerSafetyStatus {
        guard !path.isEmpty else {
            return .blocked(reason: "Empty path")
        }
        guard path.hasPrefix("/") else {
            return .blocked(reason: "Path must be absolute")
        }
        guard !Self.containsTraversalComponent(path) else {
            return .blocked(reason: "Path traversal is not allowed")
        }
        guard !Self.containsControlCharacter(path) else {
            return .blocked(reason: "Path contains control characters")
        }
        return .allowed
    }

    public func validatePathForRemoval(_ path: String, withinRoot root: String) -> StorageExplorerSafetyStatus {
        let shapeStatus = validatePathShape(path)
        guard case .allowed = shapeStatus else {
            return shapeStatus
        }

        guard validatePathShape(root).isAllowed else {
            return .blocked(reason: "Invalid scan root")
        }

        let normalizedPath = normalizePath(path)
        let normalizedRoot = normalizePath(root)

        // System root and critical system paths
        if Self.isProtectedSystemRoot(normalizedPath) {
            return .blocked(reason: "Critical macOS system path is protected")
        }

        // Sensitive paths (keychains, credentials, tcc, mobile documents, ssh, gnupg)
        if let reason = sensitiveProtectionReason(for: normalizedPath) {
            return .blocked(reason: reason)
        }

        // Cannot delete user home directory root
        if normalizedPath == homeDirectory {
            return .blocked(reason: "User home directory cannot be removed")
        }

        // Root boundary check
        guard !normalizedRoot.isEmpty else {
            return .blocked(reason: "Invalid scan root")
        }

        // Cannot delete the scan root itself
        if normalizedPath == normalizedRoot {
            return .blocked(reason: "Active scan root cannot be removed")
        }

        // Must be strictly inside the scan root
        guard Self.isEqualOrDescendant(normalizedPath, of: normalizedRoot) else {
            return .blocked(reason: "Path is outside the active scan root")
        }

        return .allowed
    }

    public func recycleItem(at path: String, withinRoot root: String) async throws -> URL {
        let validation = validatePathForRemoval(path, withinRoot: root)
        guard case .allowed = validation else {
            throw StorageExplorerSafetyError.blocked(reason: validation.reason ?? "Safety policy violation")
        }

        let normalizedRoot = normalizePath(root)
        let normalizedPath = normalizePath(path)
        let descriptors = try verifyPhysicalPaths(root: normalizedRoot, items: [(normalizedPath, nil, nil)])
        defer { descriptors.forEach { close($0) } }
        let url = URL(fileURLWithPath: normalizedPath)
        let result = try await trashRecycler.recycle(urls: [url])
        return result.moved[url] ?? url
    }

    public func recycleItems(at paths: [String], withinRoot root: String) async throws -> StorageExplorerRecycleResult {
        for path in paths {
            let validation = validatePathForRemoval(path, withinRoot: root)
            guard case .allowed = validation else {
                throw StorageExplorerSafetyError.blocked(reason: "Item \(path) blocked: \(validation.reason ?? "")")
            }
        }

        let normalizedRoot = normalizePath(root)
        let normalizedPaths = paths.map(normalizePath)
        let descriptors = try verifyPhysicalPaths(
            root: normalizedRoot,
            items: normalizedPaths.map { ($0, nil, nil) }
        )
        defer { descriptors.forEach { close($0) } }
        let urls = normalizedPaths.map { URL(fileURLWithPath: $0) }
        return try await trashRecycler.recycle(urls: urls)
    }

    public func recycleItems(
        _ items: [StorageItem],
        withinRoot root: String,
        rootIdentity: StorageFileInode? = nil
    ) async throws -> StorageExplorerRecycleResult {
        for item in items {
            let validation = validatePathForRemoval(item.path, withinRoot: root)
            guard case .allowed = validation else {
                throw StorageExplorerSafetyError.blocked(
                    reason: "Item \(item.path) blocked: \(validation.reason ?? "")"
                )
            }
        }
        let normalizedRoot = normalizePath(root)
        var descriptors = [try openVerified(path: normalizedRoot, identity: rootIdentity, isDirectory: true)]
        var stagedItems: [StagedItem] = []
        do {
            for item in items {
                descriptors.append(try openVerified(
                    path: normalizePath(item.path),
                    identity: item.fileIdentity,
                    isDirectory: item.isDirectory
                ))
                let staged = try stageVerified(item)
                stagedItems.append(staged)
                descriptors.append(try openVerified(
                    path: staged.stagedURL.path,
                    identity: item.fileIdentity,
                    isDirectory: item.isDirectory
                ))
            }
        } catch {
            restore(stagedItems)
            descriptors.forEach { close($0) }
            throw error
        }
        defer { descriptors.forEach { close($0) } }
        do {
            let result = try await trashRecycler.recycle(urls: stagedItems.map(\.stagedURL))
            var moved: [URL: URL] = [:]
            var recoveryFailures: [String] = []
            for staged in stagedItems {
                if let destination = result.moved[staged.stagedURL] {
                    moved[staged.originalURL] = destination
                } else if !restore(staged) {
                    recoveryFailures.append(staged.originalURL.path)
                }
            }
            cleanupStagingDirectories(stagedItems)
            let recoveryMessage = recoveryFailures.isEmpty
                ? nil
                : "Some items could not be restored after Trash failed: \(recoveryFailures.joined(separator: ", "))"
            return StorageExplorerRecycleResult(
                moved: moved,
                errorDescription: [result.errorDescription, recoveryMessage].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
            )
        } catch {
            restore(stagedItems)
            cleanupStagingDirectories(stagedItems)
            throw error
        }
    }

    // MARK: - Internal Helpers

    private struct StagedItem {
        let originalURL: URL
        let stagedURL: URL
        let stagingDirectory: URL
    }

    /// Trash is path based, while verification is identity based. Move the verified object into
    /// a private, unpredictable sibling directory, verify its identity again, and only then pass
    /// the staged path to NSWorkspace. A path replacement is detected before it reaches Trash.
    private func stageVerified(_ item: StorageItem) throws -> StagedItem {
        let originalURL = URL(fileURLWithPath: normalizePath(item.path))
        let parent = originalURL.deletingLastPathComponent()
        let stagingDirectory = parent.appendingPathComponent(".mactools-trash-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StorageExplorerSafetyError.recycleFailed(
                path: originalURL.path,
                underlying: "A private Trash staging directory could not be created"
            )
        }
        let stagedURL = stagingDirectory.appendingPathComponent(originalURL.lastPathComponent)
        guard renamex_np(originalURL.path, stagedURL.path, UInt32(RENAME_EXCL)) == 0 else {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw StorageExplorerSafetyError.recycleFailed(
                path: originalURL.path,
                underlying: String(cString: strerror(errno))
            )
        }
        let staged = StagedItem(
            originalURL: originalURL,
            stagedURL: stagedURL,
            stagingDirectory: stagingDirectory
        )
        var status = stat()
        guard lstat(stagedURL.path, &status) == 0,
              item.fileIdentity.map({ $0.device == status.st_dev && $0.inode == status.st_ino }) ?? true,
              item.isDirectory == (status.st_mode & S_IFMT == S_IFDIR)
        else {
            _ = restore(staged)
            cleanupStagingDirectories([staged])
            throw StorageExplorerSafetyError.blocked(
                reason: "The item path changed while it was being prepared for Trash"
            )
        }
        return staged
    }

    @discardableResult
    private func restore(_ staged: StagedItem) -> Bool {
        guard FileManager.default.fileExists(atPath: staged.stagedURL.path) else { return true }
        return renamex_np(staged.stagedURL.path, staged.originalURL.path, UInt32(RENAME_EXCL)) == 0
    }

    private func restore(_ items: [StagedItem]) {
        for item in items.reversed() { _ = restore(item) }
        cleanupStagingDirectories(items)
    }

    private func cleanupStagingDirectories(_ items: [StagedItem]) {
        for directory in Set(items.map(\.stagingDirectory)) {
            // rmdir only removes an empty directory. Never recursively delete a staged item
            // when rollback could not safely reclaim its original name.
            _ = rmdir(directory.path)
        }
    }

    private func normalizePath(_ path: String) -> String {
        // Whitespace is part of a filename and must never retarget a removal.
        return Self.stripTrailingSlash(Self.normalizeSlashes(path))
    }

    private func verifyPhysicalPaths(
        root: String,
        items: [(path: String, identity: StorageFileInode?, isDirectory: Bool?)]
    ) throws -> [Int32] {
        var descriptors: [Int32] = []
        do {
            descriptors.append(try openVerified(path: root, identity: nil, isDirectory: true))
            for item in items {
                descriptors.append(try openVerified(
                    path: item.path,
                    identity: item.identity,
                    isDirectory: item.isDirectory
                ))
            }
            return descriptors
        } catch {
            descriptors.forEach { close($0) }
            throw error
        }
    }

    private func openVerified(
        path: String,
        identity: StorageFileInode?,
        isDirectory: Bool?
    ) throws -> Int32 {
        let descriptor = open(path, O_EVTONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw StorageExplorerSafetyError.notFound(path: path) }
            throw StorageExplorerSafetyError.blocked(reason: "The item changed or contains a symbolic link")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            close(descriptor)
            throw StorageExplorerSafetyError.blocked(reason: "The item could not be verified")
        }
        if let isDirectory {
            let actualDirectory = status.st_mode & S_IFMT == S_IFDIR
            guard actualDirectory == isDirectory else {
                close(descriptor)
                throw StorageExplorerSafetyError.blocked(reason: "The item type changed")
            }
        }
        if let identity,
           identity.device != status.st_dev || identity.inode != status.st_ino {
            close(descriptor)
            throw StorageExplorerSafetyError.blocked(reason: "The item changed after it was scanned")
        }
        return descriptor
    }

    private func sensitiveProtectionReason(for path: String) -> String? {
        let lower = path.lowercased()
        let protectedLocations = [
            homeDirectory + "/Library/Keychains",
            homeDirectory + "/Library/Application Support/com.apple.TCC",
            homeDirectory + "/Library/Mobile Documents",
            homeDirectory + "/.ssh",
            homeDirectory + "/.gnupg",
            "/Library/Keychains",
            "/Library/Application Support/com.apple.TCC"
        ]
        if protectedLocations.contains(where: { Self.pathsOverlap(lower, $0.lowercased()) }) {
            return "Sensitive location or its containing directory is protected"
        }

        if lower.contains("/library/keychains") || lower.contains("/.ssh") || lower.contains("/.gnupg")
            || lower.contains("keychain") || lower.contains("credential") {
            return "Credentials and key material are protected"
        }

        if lower.contains("/library/application support/com.apple.tcc") || lower.hasSuffix("/tcc.db") {
            return "Privacy permission database is protected"
        }

        if lower.contains("/library/mobile documents") || lower.contains("/mobile documents") {
            return "iCloud synced documents are protected"
        }

        return nil
    }

    private static func containsTraversalComponent(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    private static func containsControlCharacter(_ path: String) -> Bool {
        path.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 127
        }
    }

    private static func isProtectedSystemRoot(_ path: String) -> Bool {
        let normalized = stripTrailingSlash(normalizeSlashes(path)).lowercased()
        if normalized == "/" {
            return true
        }

        let exactRoots = [
            "/private",
            "/var",
            "/var/db",
            "/private/var",
            "/private/var/db",
            "/Volumes",
            "/Network"
        ]
        if exactRoots.contains(where: { isEqualOrDescendant($0.lowercased(), of: normalized) }) {
            return true
        }

        let protectedPrefixes = [
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/etc",
            "/private/etc",
            "/Library/Extensions",
            "/Applications/Utilities"
        ]

        return protectedPrefixes.contains { root in
            pathsOverlap(normalized, root.lowercased())
        } || normalized.hasPrefix("/var/db/")
            || normalized.hasPrefix("/private/var/db/")
    }

    private static func isEqualOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }

    private static func pathsOverlap(_ path: String, _ protectedPath: String) -> Bool {
        isEqualOrDescendant(path, of: protectedPath) || isEqualOrDescendant(protectedPath, of: path)
    }

    private static func normalizeSlashes(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
