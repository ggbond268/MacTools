import Foundation

/// Flat nodes keep navigation and updates independent of the size of descendant trees.
public struct StorageExplorerSnapshot: Sendable {
    public var progress = StorageExplorerScanProgress()
    public var rootPath: String
    public var items: [String: StorageItem] = [:]
    public var children: [String: [String]] = [:]

    public init(rootPath: String) { self.rootPath = rootPath }

    public mutating func apply(_ updates: [StorageItem]) {
        for item in updates {
            if items[item.path] == nil, let parent = item.parentPath {
                children[parent, default: []].append(item.path)
            }
            items[item.path] = item
        }
    }

    public func children(of path: String) -> [StorageItem] {
        (children[path] ?? []).compactMap { items[$0] }
    }

    /// Compatibility representation for scanner clients that explicitly request a full tree.
    public func tree() -> StorageItem? {
        guard var root = items[rootPath] else { return nil }
        var built = items
        for item in items.values.sorted(by: { $0.path.count > $1.path.count }) {
            guard item.isDirectory && !item.isPackage else { continue }
            var copy = item
            copy.children = (children[item.path] ?? []).compactMap { built[$0] }.sorted { $0.size > $1.size }
            built[item.path] = copy
        }
        root = built[rootPath] ?? root
        return root
    }
}

public struct StorageExplorerScanUpdate: Sendable {
    public let items: [StorageItem]
    public let progress: StorageExplorerScanProgress
}

public protocol StorageExplorerScanning: Sendable {
    func scanSnapshot(rootURL: URL, update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void) async throws -> StorageExplorerSnapshot
    func invalidate(paths: [String])
    func clearCache()
}
