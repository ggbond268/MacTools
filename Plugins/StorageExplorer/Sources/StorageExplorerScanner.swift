import Foundation

public final class StorageExplorerScanner: @unchecked Sendable {
    public init() {}

    public func scan(
        rootURL: URL,
        progressHandler: (@Sendable (StorageExplorerScanProgress) -> Void)? = nil
    ) async throws -> StorageItem {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }

        var progress = StorageExplorerScanProgress()
        var seenInodes: Set<StorageFileInode> = []
        var lastReportedTime = CFAbsoluteTimeGetCurrent()

        func checkCancellationAndReport(path: String, addedSize: Int64) throws {
            try Task.checkCancellation()
            progress.filesScanned += 1
            progress.bytesScanned += addedSize
            progress.currentPath = path

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastReportedTime >= 0.08 || progress.filesScanned % 100 == 0 {
                lastReportedTime = now
                progressHandler?(progress)
            }
        }

        func measuredSize(url: URL, values: URLResourceValues) -> (logical: Int64, allocated: Int64) {
            var fileStat = stat()
            if lstat(url.path, &fileStat) == 0 {
                let inode = StorageFileInode(device: fileStat.st_dev, inode: fileStat.st_ino)
                guard seenInodes.insert(inode).inserted else { return (0, 0) }

                // Measure the link itself, never the destination's payload.
                if values.isSymbolicLink == true {
                    return (max(Int64(fileStat.st_size), 0), max(Int64(fileStat.st_blocks) * 512, 0))
                }
                return (
                    max(Int64(values.fileSize ?? Int(fileStat.st_size)), 0),
                    max(Int64(values.totalFileAllocatedSize ?? (Int(fileStat.st_blocks) * 512)), 0)
                )
            }
            return (Int64(values.fileSize ?? 0), Int64(values.totalFileAllocatedSize ?? 0))
        }

        func crawl(url: URL) throws -> StorageItem {
            try Task.checkCancellation()

            let resourceKeys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
                .nameKey
            ]

            let resourceValues: URLResourceValues
            do {
                resourceValues = try url.resourceValues(forKeys: resourceKeys)
            } catch {
                return StorageItem(
                    name: url.lastPathComponent,
                    path: url.path,
                    url: url,
                    isDirectory: false,
                    isAccessDenied: true
                )
            }

            let isDirectory = resourceValues.isDirectory ?? false
            let isPackage = resourceValues.isPackage ?? false
            let isSymlink = resourceValues.isSymbolicLink ?? false
            let modDate = resourceValues.contentModificationDate
            let name = resourceValues.name ?? url.lastPathComponent

            let (logicalSize, allocatedSize) = measuredSize(url: url, values: resourceValues)
            let addedSize = logicalSize

            try checkCancellationAndReport(path: url.path, addedSize: addedSize)

            // If it is a symlink, do not traverse
            if isSymlink {
                return StorageItem(
                    name: name,
                    path: url.path,
                    url: url,
                    isDirectory: false,
                    isPackage: false,
                    isSymlink: true,
                    size: logicalSize,
                    allocatedSize: allocatedSize,
                    modificationDate: modDate,
                    childCount: 0,
                    children: []
                )
            }

            // If it is a package, crawl internally to get total size but treat as a single unit
            if isDirectory && isPackage {
                var totalPackageSize = logicalSize
                var totalPackageAllocated = allocatedSize
                var packageChildCount = 0

                if let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey],
                    options: []
                ) {
                    for case let fileURL as URL in enumerator {
                        try Task.checkCancellation()
                        if let childValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]) {
                            if childValues.isSymbolicLink == true {
                                enumerator.skipDescendants()
                            }
                            let (childLogical, childAllocated) = measuredSize(url: fileURL, values: childValues)
                            totalPackageSize += childLogical
                            totalPackageAllocated += childAllocated
                            packageChildCount += 1
                            try checkCancellationAndReport(path: fileURL.path, addedSize: childLogical)
                        }
                    }
                }

                return StorageItem(
                    name: name,
                    path: url.path,
                    url: url,
                    isDirectory: true,
                    isPackage: true,
                    isSymlink: false,
                    size: totalPackageSize,
                    allocatedSize: totalPackageAllocated,
                    modificationDate: modDate,
                    childCount: packageChildCount,
                    children: []
                )
            }

            // If it is a regular directory, traverse direct children
            if isDirectory {
                let contents: [URL]
                do {
                    contents = try fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: []
                    )
                } catch {
                    return StorageItem(
                        name: name,
                        path: url.path,
                        url: url,
                        isDirectory: true,
                        modificationDate: modDate,
                        isAccessDenied: true
                    )
                }

                var children: [StorageItem] = []
                var dirTotalSize: Int64 = 0
                var dirTotalAllocated: Int64 = 0
                let dirTotalChildCount = contents.count

                for childURL in contents {
                    let childItem = try crawl(url: childURL)
                    dirTotalSize += childItem.size
                    dirTotalAllocated += childItem.allocatedSize
                    children.append(childItem)
                }

                // Sort children by size descending for clear visual ranking
                children.sort { $0.size > $1.size }

                return StorageItem(
                    name: name,
                    path: url.path,
                    url: url,
                    isDirectory: true,
                    isPackage: false,
                    isSymlink: false,
                    size: dirTotalSize,
                    allocatedSize: dirTotalAllocated,
                    modificationDate: modDate,
                    childCount: dirTotalChildCount,
                    children: children
                )
            }

            // Regular file
            return StorageItem(
                name: name,
                path: url.path,
                url: url,
                isDirectory: false,
                isPackage: false,
                isSymlink: false,
                size: logicalSize,
                allocatedSize: allocatedSize,
                modificationDate: modDate,
                childCount: 0,
                children: []
            )
        }

        let result = try crawl(url: rootURL)
        progressHandler?(progress)
        return result
    }
}
