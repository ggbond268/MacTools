import Darwin
import Foundation
import MacToolsFileSystem
import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerProgressTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(root.path, nil))
        root = URL(fileURLWithPath: String(cString: physical))
        free(physical)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testWorkerCountsPreserveTotalsAndHardLinksAcrossFolders() async throws {
        for directory in ["a", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let file = root.appendingPathComponent("a/file")
        try Data(repeating: 3, count: 10_000).write(to: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("b/link"))
        for workers in [1, 2, 4] {
            let result = try await StorageExplorerScanner(workerCount: workers).scanSnapshot(rootURL: root) { _ in }
            XCTAssertEqual(result.items[result.rootPath]?.size, 10_000)
            XCTAssertEqual(result.items.count, 5)
            XCTAssertEqual(result.progress.skippedCount, 0)
        }
    }

    func testCacheInvalidationRefreshesNestedContentAndReusesUnaffectedDirectories() async throws {
        for directory in ["a", "b"] {
            let folder = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 20).write(to: folder.appendingPathComponent("file"))
        }
        let scanner = StorageExplorerScanner()
        let first = try await scanner.scanSnapshot(rootURL: root) { _ in }
        let second = try await scanner.scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(second.progress.cachedDirectories, 3)
        let changed = URL(fileURLWithPath: first.rootPath).appendingPathComponent("a/file")
        try Data(repeating: 1, count: 150).write(to: changed)
        scanner.invalidate(paths: [changed.path])
        let refreshed = try await scanner.scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(refreshed.items[refreshed.rootPath]?.size, 170)
        XCTAssertEqual(refreshed.progress.cachedDirectories, 1)
        scanner.clearCache()
        let full = try await scanner.scanSnapshot(rootURL: root) { _ in }
        XCTAssertEqual(full.progress.cachedDirectories, 0)
    }

    func testPrecancelledTaskAlwaysThrows() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StorageExplorerScanner().scanSnapshot(rootURL: root) { _ in }
        }
        do { _ = try await task.value; XCTFail("A cancelled scan must not return a complete snapshot") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStreamCanReconstructFinalIndexAndReportsIncompleteRootFirst() async throws {
        for i in 0..<40 {
            try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("file-\(i)"))
        }
        let events = EventBox()
        let result = try await StorageExplorerScanner().scanSnapshot(rootURL: root) { events.append($0) }
        let captured = events.values
        XCTAssertTrue(captured.first?.items.first?.isIncomplete == true)
        var reconstructed = StorageExplorerSnapshot(rootPath: result.rootPath)
        for event in captured { reconstructed.apply(event.items) }
        XCTAssertEqual(reconstructed.items, result.items)
        XCTAssertEqual(result.items[result.rootPath]?.size, 4_000)
        XCTAssertFalse(result.items[result.rootPath]?.isIncomplete ?? true)
        XCTAssertLessThanOrEqual(captured.count, Int(result.progress.elapsed / 0.15) + 2)
    }

    func testBulkStorageAttributesMatchFilesystemIncludingSparseFile() throws {
        let file = root.appendingPathComponent("sparse.bin")
        let fd = open(file.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, 2_000_000), 0)
        let listing = try FileSystemDirectoryReader.read(path: root.path, cancelled: { false })
        let entry = try XCTUnwrap(listing.entries.first)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey])
        XCTAssertEqual(entry.dataLength, Int64(try XCTUnwrap(values.fileSize)))
        XCTAssertEqual(entry.allocatedSize, Int64(try XCTUnwrap(values.totalFileAllocatedSize)))
        XCTAssertEqual(try XCTUnwrap(entry.modificationDate).timeIntervalSince1970,
                       try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(entry.hasLayoutMismatch)
    }

    func testUnreadableFolderIsReportedAsIncomplete() async throws {
        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { chmod(blocked.path, 0o700) }
        let result = try await StorageExplorerScanner().scanSnapshot(rootURL: root) { _ in }
        XCTAssertGreaterThan(result.progress.skippedCount, 0)
        XCTAssertTrue(result.items[result.rootPath]?.isIncomplete ?? false)
        XCTAssertTrue(result.items.values.contains { $0.name == "blocked" && $0.isAccessDenied })
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StorageExplorerScanUpdate] = []
    var values: [StorageExplorerScanUpdate] { lock.withLock { events } }
    func append(_ event: StorageExplorerScanUpdate) { lock.withLock { events.append(event) } }
}
