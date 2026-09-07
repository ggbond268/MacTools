import AppKit
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

public protocol StorageExplorerTrashRecycling: Sendable {
    func recycle(urls: [URL]) async throws -> [URL: URL]
}

public final class WorkspaceTrashRecycler: StorageExplorerTrashRecycling {
    public init() {}

    public func recycle(urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle(urls) { trashedURLs, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: trashedURLs)
                    }
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
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else {
            return .blocked(reason: "Path is outside the active scan root")
        }

        return .allowed
    }

    public func recycleItem(at path: String, withinRoot root: String) async throws -> URL {
        let validation = validatePathForRemoval(path, withinRoot: root)
        guard case .allowed = validation else {
            throw StorageExplorerSafetyError.blocked(reason: validation.reason ?? "Safety policy violation")
        }

        let url = URL(fileURLWithPath: normalizePath(path))
        let result = try await trashRecycler.recycle(urls: [url])
        return result[url] ?? url
    }

    public func recycleItems(at paths: [String], withinRoot root: String) async throws -> [URL: URL] {
        for path in paths {
            let validation = validatePathForRemoval(path, withinRoot: root)
            guard case .allowed = validation else {
                throw StorageExplorerSafetyError.blocked(reason: "Item \(path) blocked: \(validation.reason ?? "")")
            }
        }

        let urls = paths.map { URL(fileURLWithPath: normalizePath($0)) }
        return try await trashRecycler.recycle(urls: urls)
    }

    // MARK: - Internal Helpers

    private func normalizePath(_ path: String) -> String {
        // Whitespace is part of a filename and must never retarget a removal.
        return Self.stripTrailingSlash(Self.normalizeSlashes(path))
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
