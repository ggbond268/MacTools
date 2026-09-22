import Foundation

public struct StorageExplorerCachedSnapshot: Sendable {
    public let snapshot: StorageExplorerSnapshot
    public let completedAt: Date

    public init(snapshot: StorageExplorerSnapshot, completedAt: Date) {
        self.snapshot = snapshot
        self.completedAt = completedAt
    }
}

public protocol StorageExplorerSnapshotCaching: Sendable {
    func load(rootPath: String) async -> StorageExplorerCachedSnapshot?
    func save(snapshot: StorageExplorerSnapshot, completedAt: Date, rootPath: String) async
}

/// Keeps a small number of recent, complete snapshots for an immediate first paint. Cached
/// snapshots are previews only; the controller always starts a fresh scan before enabling review.
public actor StorageExplorerSnapshotCache: StorageExplorerSnapshotCaching {
    private struct Record: Codable {
        let version: Int
        let rootPath: String
        let completedAt: Date
        let snapshot: StorageExplorerSnapshot
    }

    private let directoryURL: URL
    private let maximumAge: TimeInterval
    private let maximumEntryBytes: Int
    private let maximumEntries: Int

    public init(
        directoryURL: URL? = nil,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        maximumEntryBytes: Int = 64 * 1_024 * 1_024,
        maximumEntries: Int = 4
    ) {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.mactools.app"
        self.directoryURL = directoryURL
            ?? cacheRoot.appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("StorageExplorerSnapshots", isDirectory: true)
        self.maximumAge = maximumAge
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumEntries = max(1, maximumEntries)
    }

    public func load(rootPath: String) async -> StorageExplorerCachedSnapshot? {
        let fileURL = cacheURL(for: rootPath)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= maximumEntryBytes,
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              record.version == 1,
              record.rootPath == rootPath,
              Date().timeIntervalSince(record.completedAt) <= maximumAge,
              record.snapshot.items[record.snapshot.rootPath] != nil
        else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return StorageExplorerCachedSnapshot(snapshot: record.snapshot, completedAt: record.completedAt)
    }

    public func save(snapshot: StorageExplorerSnapshot, completedAt: Date, rootPath: String) async {
        guard snapshot.items[snapshot.rootPath] != nil else { return }
        let record = Record(version: 1, rootPath: rootPath, completedAt: completedAt, snapshot: snapshot)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(record), data.count <= maximumEntryBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: cacheURL(for: rootPath), options: .atomic)
            pruneIfNeeded()
        } catch {
            // Cache failures never affect the fresh scan.
        }
    }

    private func cacheURL(for rootPath: String) -> URL {
        directoryURL.appendingPathComponent(String(format: "%016llx.plist", Self.hash(rootPath)))
    }

    private func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = files.filter { url in
            (try? url.resourceValues(forKeys: keys).isRegularFile) == true
        }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(maximumEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func hash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
