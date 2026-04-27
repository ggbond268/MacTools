import Darwin
import Foundation

struct DiskCleanFileItem: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let resolvedSymlinkTarget: String?
}

protocol DiskCleanFileSystemProviding: Sendable {
    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem]
    func itemInfo(at path: String) throws -> DiskCleanFileItem?
    func sizeOfItem(at path: String) throws -> Int64
    func removeItem(at path: String) throws
    func deduplicatedParentChildPaths(_ paths: [String]) -> [String]
}

struct LocalDiskCleanFileSystem: DiskCleanFileSystemProviding, @unchecked Sendable {
    private let fileManager: FileManager
    private let homeDirectory: String

    init(
        fileManager: FileManager = .default,
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.fileManager = fileManager
        self.homeDirectory = Self.normalizeSlashes(homeDirectory)
    }

    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem] {
        let expandedPattern = Self.normalizeSlashes(expandHome(in: pattern))
        guard Self.containsGlob(expandedPattern) else {
            guard let item = try itemInfo(at: expandedPattern) else { return [] }
            return [item]
        }

        let matchedPaths = try Self.globPaths(matching: expandedPattern)
        return try deduplicatedParentChildPaths(matchedPaths)
            .compactMap { try itemInfo(at: $0) }
    }

    func itemInfo(at path: String) throws -> DiskCleanFileItem? {
        let expandedPath = Self.normalizeSlashes(expandHome(in: path))
        guard fileManager.fileExists(atPath: expandedPath) || isSymlink(at: expandedPath) else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: expandedPath)
        let fileType = attributes[.type] as? FileAttributeType
        let isSymlink = fileType == .typeSymbolicLink
        let isDirectory = fileType == .typeDirectory

        return DiskCleanFileItem(
            path: expandedPath,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            resolvedSymlinkTarget: isSymlink ? try? fileManager.destinationOfSymbolicLink(atPath: expandedPath) : nil
        )
    }

    func sizeOfItem(at path: String) throws -> Int64 {
        let expandedPath = Self.normalizeSlashes(expandHome(in: path))
        let attributes = try fileManager.attributesOfItem(atPath: expandedPath)
        let fileType = attributes[.type] as? FileAttributeType

        if fileType != .typeDirectory || fileType == .typeSymbolicLink {
            return Int64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }

        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: expandedPath),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                let itemAttributes = try fileManager.attributesOfItem(atPath: url.path)
                guard (itemAttributes[.type] as? FileAttributeType) != .typeDirectory else {
                    continue
                }
                total += Int64((itemAttributes[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }

        return total
    }

    func removeItem(at path: String) throws {
        let expandedPath = Self.normalizeSlashes(expandHome(in: path))
        guard fileManager.fileExists(atPath: expandedPath) || isSymlink(at: expandedPath) else {
            return
        }
        try fileManager.removeItem(atPath: expandedPath)
    }

    func deduplicatedParentChildPaths(_ paths: [String]) -> [String] {
        let uniqueSortedPaths = Array(Set(paths.map(Self.normalizeSlashes))).sorted()

        var kept: [String] = []
        var keptPathSet: Set<String> = []
        for path in uniqueSortedPaths {
            if Self.hasKeptParent(for: path, in: keptPathSet) {
                continue
            }
            kept.append(path)
            keptPathSet.insert(path)
        }

        return kept
    }

    private func expandHome(in pattern: String) -> String {
        if pattern == "~" || pattern == "$HOME" || pattern == "${HOME}" {
            return homeDirectory
        }
        if pattern.hasPrefix("~/") {
            return homeDirectory + String(pattern.dropFirst())
        }
        if pattern.hasPrefix("$HOME/") {
            return homeDirectory + String(pattern.dropFirst("$HOME".count))
        }
        if pattern.hasPrefix("${HOME}/") {
            return homeDirectory + String(pattern.dropFirst("${HOME}".count))
        }
        return pattern
    }

    private func isSymlink(at path: String) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func containsGlob(_ pattern: String) -> Bool {
        pattern.contains { "*?[".contains($0) }
    }

    private static func globPaths(matching pattern: String) throws -> [String] {
        var globResult = glob_t()
        defer { globfree(&globResult) }

        let status = pattern.withCString { glob($0, 0, nil, &globResult) }
        if status == GLOB_NOMATCH {
            return []
        }
        guard status == 0 else {
            throw DiskCleanFileSystemError.globFailed(pattern: pattern, status: status)
        }
        guard let pathVector = globResult.gl_pathv else {
            return []
        }

        return (0..<Int(globResult.gl_pathc)).compactMap { index in
            guard let pathPointer = pathVector[index] else { return nil }
            return normalizeSlashes(String(cString: pathPointer))
        }
    }

    private static func hasKeptParent(for path: String, in keptPathSet: Set<String>) -> Bool {
        var currentPath = path
        while let slashIndex = currentPath.lastIndex(of: "/") {
            currentPath = String(currentPath[..<slashIndex])
            if currentPath.isEmpty {
                currentPath = "/"
            }
            if keptPathSet.contains(currentPath) {
                return true
            }
            if currentPath == "/" {
                break
            }
        }
        return false
    }

    private enum DiskCleanFileSystemError: LocalizedError {
        case globFailed(pattern: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case let .globFailed(pattern, status):
                return "Failed to expand path pattern \(pattern) (glob status \(status))"
            }
        }
    }

    private static func normalizeSlashes(_ path: String) -> String {
        var normalized = path
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        return normalized
    }
}
