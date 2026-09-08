import Darwin
import Foundation
import MacToolsFileSystem

public final class StorageExplorerScanner: StorageExplorerScanning, @unchecked Sendable {
    public let workerCount: Int
    private let cache = StorageExplorerDirectoryCache()

    public init(workerCount: Int = 2) { self.workerCount = min(max(workerCount, 1), 4) }

    public func invalidate(paths: [String]) { cache.invalidate(paths: paths) }
    public func clearCache() { cache.invalidate(paths: nil) }

    public func scan(
        rootURL: URL,
        progressHandler: (@Sendable (StorageExplorerScanProgress) -> Void)? = nil
    ) async throws -> StorageItem {
        let snapshot = try await scanSnapshot(rootURL: rootURL) { progressHandler?($0.progress) }
        guard let root = snapshot.tree() else { throw CocoaError(.fileNoSuchFile) }
        return root
    }

    public func scanSnapshot(
        rootURL: URL,
        update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void
    ) async throws -> StorageExplorerSnapshot {
        let cancellation = StorageExplorerCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                // Blocking filesystem calls run on bounded GCD workers, outside the cooperative executor.
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let state = try ScanWork(rootURL: rootURL, cancellation: cancellation, update: update)
                        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
                            while let job = state.next() {
                                do {
                                    let (listing, cached) = try cache.read(path: job.path, cancelled: { cancellation.isCancelled })
                                    let entries = listing.entries.compactMap { entry -> StorageItem? in
                                        guard let bytes = entry.nameBytes,
                                              let name = String(bytes: bytes.dropLast().map { UInt8(bitPattern: $0) }, encoding: .utf8),
                                              name != ".", name != "..", !name.contains("/") else { return nil }
                                        let url = URL(fileURLWithPath: job.path).appendingPathComponent(name)
                                        let directory = entry.fileType == .directory
                                        let dataless = (entry.flags ?? 0) & UInt32(SF_DATALESS) != 0
                                        let package = directory && !dataless && ((try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true)
                                        var item = StorageItem(name: name, path: url.path, url: url, isDirectory: directory,
                                            isPackage: package, isSymlink: entry.fileType == .symlink,
                                            size: directory ? 0 : max(entry.dataLength ?? 0, 0),
                                            allocatedSize: directory ? 0 : max(entry.allocatedSize ?? 0, 0),
                                            modificationDate: entry.modificationDate, parentPath: job.path)
                                        item.isCloudPlaceholder = dataless
                                        item.isIncomplete = directory
                                        return item
                                    }
                                    state.finish(job: job, listing: listing, entries: entries, cached: cached)
                                } catch is CancellationError {
                                    state.finishCancelled()
                                } catch {
                                    state.finishFailed(job: job, error: error)
                                }
                            }
                        }
                        if cancellation.isCancelled { throw CancellationError() }
                        continuation.resume(returning: state.result())
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

private final class StorageExplorerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Cached enumeration is only reused for a short window and invalidated by file events.
/// Every scan still visits directory jobs and recomputes global hard-link accounting.
private final class StorageExplorerDirectoryCache: @unchecked Sendable {
    private struct Entry { let listing: FileSystemDirectoryListing; let date: Date }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var epoch = 0
    private var count = 0

    func invalidate(paths: [String]?) {
        lock.withLock {
            epoch += 1
            guard let paths else { entries.removeAll(); count = 0; return }
            let stale = entries.keys.filter { directory in
                paths.contains { path in
                    path == directory || path.hasPrefix(directory + "/") || directory.hasPrefix(path + "/")
                }
            }
            for path in stale { count -= entries.removeValue(forKey: path)?.listing.entries.count ?? 0 }
        }
    }

    func read(path: String, cancelled: () -> Bool) throws -> (FileSystemDirectoryListing, Bool) {
        let (hit, version): (FileSystemDirectoryListing?, Int) = lock.withLock {
            let entry = entries[path]
            return (entry.flatMap { Date().timeIntervalSince($0.date) < 30 ? $0.listing : nil }, epoch)
        }
        if cancelled() { throw CancellationError() }
        if let hit { return (hit, true) }
        let listing = try FileSystemDirectoryReader.read(path: path, cancelled: cancelled)
        lock.withLock {
            guard epoch == version else { return }
            count -= entries.removeValue(forKey: path)?.listing.entries.count ?? 0
            if count + listing.entries.count > 100_000 { entries.removeAll(); count = 0 }
            if listing.entries.count <= 100_000 {
                entries[path] = Entry(listing: listing, date: Date())
                count += listing.entries.count
            }
        }
        return (listing, false)
    }
}

private final class ScanWork: @unchecked Sendable {
    struct Job { let path: String; let packageOwner: String? }
    private let condition = NSCondition()
    private let cancellation: StorageExplorerCancellation
    private let update: @Sendable (StorageExplorerScanUpdate) -> Void
    private var jobs: [Job] = []
    private var active = 0
    private var snapshot: StorageExplorerSnapshot
    private var changed: Set<String> = []
    private var inodes: Set<StorageFileInode> = []
    private var progress = StorageExplorerScanProgress()
    private let started = Date()
    private var lastReport = Date.distantPast
    private let device: UInt64

    init(rootURL: URL, cancellation: StorageExplorerCancellation,
         update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void) throws {
        // Expand /tmp and /var once, then require physical paths for every directory open.
        guard let resolved = realpath(rootURL.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        let path = String(cString: resolved)
        free(resolved)
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
        self.cancellation = cancellation
        self.update = update
        self.device = UInt64(UInt32(bitPattern: status.st_dev))
        self.snapshot = StorageExplorerSnapshot(rootPath: path)
        let url = URL(fileURLWithPath: path)
        let dataless = status.st_flags & UInt32(SF_DATALESS) != 0
        let package = !dataless && ((try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true)
        var root = StorageItem(name: url.lastPathComponent, path: path, url: url, isDirectory: true, isPackage: package)
        root.isIncomplete = true
        root.isCloudPlaceholder = dataless
        root.skippedCount = dataless ? 1 : 0
        snapshot.apply([root])
        changed.insert(path)
        progress.skippedCount = dataless ? 1 : 0
        if !dataless { jobs = [Job(path: path, packageOwner: package ? path : nil)] }
        publish(force: true)
    }

    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while jobs.isEmpty && active > 0 && !cancellation.isCancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
        }
        guard !cancellation.isCancelled, let job = jobs.popLast() else { return nil }
        active += 1
        return job
    }

    func finishCancelled() {
        condition.lock(); defer { condition.unlock() }
        active -= 1
        condition.broadcast()
    }

    func finishFailed(job: Job, error: Error) {
        condition.lock(); defer { condition.unlock() }
        let path = job.packageOwner ?? job.path
        if let code = (error as? POSIXError)?.code, code == .EACCES || code == .EPERM {
            snapshot.items[path]?.isAccessDenied = true
        }
        addTotals(to: path, bytes: 0, allocated: 0, count: 0, skipped: 1)
        progress.skippedCount += 1
        active -= 1
        publish()
        condition.broadcast()
    }

    func finish(job: Job, listing: FileSystemDirectoryListing, entries: [StorageItem], cached: Bool) {
        condition.lock(); defer { condition.unlock() }
        let owner = job.packageOwner ?? job.path
        let metadata = Dictionary(listing.entries.compactMap { entry -> (String, FileSystemBulkAttributeEntry)? in
            guard let name = entry.displayName else { return nil }
            return (name, entry)
        }, uniquingKeysWith: { first, _ in first })
        var bytes: Int64 = 0
        var allocated: Int64 = 0
        var skipped = listing.skippedCount + listing.entries.count - entries.count
        for var item in entries {
            guard let entry = metadata[item.name] else { skipped += 1; continue }
            if !item.isDirectory, (entry.linkCount ?? 1) > 1,
               let device = entry.devid, let inode = entry.fileID {
                let key = StorageFileInode(device: dev_t(truncatingIfNeeded: device), inode: ino_t(inode))
                if !inodes.insert(key).inserted { item.size = 0; item.allocatedSize = 0 }
            }
            if item.isDirectory {
                if item.isCloudPlaceholder || entry.devid != device {
                    item.skippedCount = 1
                    skipped += 1
                } else {
                    jobs.append(Job(path: item.path, packageOwner: job.packageOwner ?? (item.isPackage ? item.path : nil)))
                }
            }
            bytes += item.size
            allocated += item.allocatedSize
            if job.packageOwner == nil {
                snapshot.apply([item])
                changed.insert(item.path)
            }
        }
        if job.packageOwner == nil { snapshot.items[job.path]?.childCount = entries.count }
        else { snapshot.items[owner]?.childCount += entries.count }
        addTotals(to: owner, bytes: bytes, allocated: allocated, count: entries.count, skipped: skipped)
        progress.filesScanned += entries.count
        progress.bytesScanned += bytes
        progress.allocatedBytesScanned += allocated
        progress.skippedCount += skipped
        progress.currentPath = job.path
        progress.cachedDirectories += cached ? 1 : 0
        active -= 1
        publish()
        condition.broadcast()
    }

    private func addTotals(to path: String, bytes: Int64, allocated: Int64, count: Int, skipped: Int) {
        var current: String? = path
        while let path = current, var item = snapshot.items[path] {
            item.size += bytes
            item.allocatedSize += allocated
            item.scannedCount += count
            item.skippedCount += skipped
            snapshot.items[path] = item
            changed.insert(path)
            current = item.parentPath
        }
    }

    private func publish(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.15 else { return }
        lastReport = now
        progress.elapsed = now.timeIntervalSince(started)
        update(StorageExplorerScanUpdate(items: changed.compactMap { snapshot.items[$0] }, progress: progress))
        changed.removeAll(keepingCapacity: true)
    }

    func result() -> StorageExplorerSnapshot {
        for path in snapshot.items.keys {
            let incomplete = (snapshot.items[path]?.skippedCount ?? 0) > 0
            snapshot.items[path]?.isIncomplete = incomplete
            changed.insert(path)
        }
        publish(force: true)
        snapshot.progress = progress
        return snapshot
    }
}
