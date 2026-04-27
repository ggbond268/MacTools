import Darwin
import Foundation

struct DiskCleanFileItem: Equatable {
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let resolvedSymlinkTarget: String?
}

protocol DiskCleanFileSystemProviding {
    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem]
    func itemInfo(at path: String) throws -> DiskCleanFileItem?
    func sizeOfItem(at path: String) throws -> Int64
    func removeItem(at path: String) throws
    func deduplicatedParentChildPaths(_ paths: [String]) -> [String]
}

struct LocalDiskCleanFileSystem: DiskCleanFileSystemProviding {
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

        let root = Self.enumerationRoot(for: expandedPattern)
        guard fileManager.fileExists(atPath: root) else { return [] }

        var matchedPaths: [String] = []
        if Self.pathMatches(path: root, pattern: expandedPattern) {
            matchedPaths.append(root)
        }

        if let enumerator = fileManager.enumerator(atPath: root) {
            for case let relativePath as String in enumerator {
                let path = Self.normalizeSlashes(root + "/" + relativePath)
                if Self.pathMatches(path: path, pattern: expandedPattern) {
                    matchedPaths.append(path)
                }
            }
        }

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
        let uniqueSortedPaths = Array(Set(paths.map(Self.normalizeSlashes))).sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count < rhs.count
        }

        var kept: [String] = []
        for path in uniqueSortedPaths {
            if kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                continue
            }
            kept.append(path)
        }

        return kept.sorted()
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

    private static func enumerationRoot(for pattern: String) -> String {
        guard let globIndex = pattern.firstIndex(where: { "*?[".contains($0) }) else {
            return pattern
        }

        let prefix = String(pattern[..<globIndex])
        guard let slashIndex = prefix.lastIndex(of: "/") else {
            return "."
        }

        let root = String(prefix[..<slashIndex])
        return root.isEmpty ? "/" : root
    }

    private static func containsGlob(_ pattern: String) -> Bool {
        pattern.contains { "*?[".contains($0) }
    }

    private static func pathMatches(path: String, pattern: String) -> Bool {
        pattern.withCString { patternPointer in
            path.withCString { pathPointer in
                Darwin.fnmatch(patternPointer, pathPointer, FNM_PATHNAME) == 0
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
