import Foundation
import XCTest
@testable import StorageExplorerPlugin

@MainActor
final class StorageExplorerControllerTests: XCTestCase {
    func testObsoleteProgressAndFailureCannotReplaceNewScan() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let first = URL(fileURLWithPath: "/tmp/storage-first")
        let second = URL(fileURLWithPath: "/tmp/storage-second")
        controller.startScan(at: first)
        try await waitUntil { scanner.hasRequest(first.path) }
        controller.startScan(at: second)
        try await waitUntil { scanner.hasRequest(second.path) }
        scanner.emit(path: first.path, size: 900)
        scanner.finish(path: first.path, error: CancellationError())
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.isScanning)
        XCTAssertEqual(controller.scanRootURL, second)
        XCTAssertEqual(controller.status.progress.bytesScanned, 0)
        scanner.finish(path: second.path)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.path, second.path)
        XCTAssertEqual(controller.scanState, .completed)
    }

    func testSelectionTotalsSpanFoldersAndNormalizeAncestorOverlap() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let root = URL(fileURLWithPath: "/tmp/storage-selection")
        controller.startScan(at: root)
        try await waitUntil { scanner.hasRequest(root.path) }
        let snapshot = Self.fixture(root: root.path)
        scanner.finish(path: root.path, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        controller.toggleSelection(path: root.path + "/a/one")
        controller.drillDown(to: try XCTUnwrap(snapshot.items[root.path + "/b"]))
        controller.toggleSelection(path: root.path + "/b/two")
        XCTAssertEqual(controller.totalSelectedBytes, 600)
        XCTAssertEqual(controller.selectedItemsForReview.count, 2)
        controller.toggleSelection(path: root.path + "/a")
        XCTAssertFalse(controller.basket.contains(root.path + "/a/one"))
        XCTAssertEqual(controller.totalSelectedBytes, 600)
        controller.toggleSelection(path: root.path + "/a/one")
        XCTAssertEqual(controller.basket.count, 2)
        controller.confirmTrash()
        XCTAssertEqual(controller.reviewItems.count, 2)
        XCTAssertTrue(controller.isConfirmingTrash)
    }

    func testPartialResultsCanBeExploredButNotStaged() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let path = "/tmp/storage-partial"
        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.emit(path: path, size: 100)
        try await waitUntil { controller.rootItem != nil }
        XCTAssertTrue(controller.isScanning)
        controller.toggleSelection(path: path)
        XCTAssertTrue(controller.basket.isEmpty)
        controller.cancelScan()
        scanner.finish(path: path)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.scanState, .cancelled)
    }

    func testSwitchingRootsClearsOldResultsAndSelectionImmediately() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let first = "/tmp/storage-old", second = "/tmp/storage-new"
        controller.startScan(at: URL(fileURLWithPath: first))
        try await waitUntil { scanner.hasRequest(first) }
        scanner.finish(path: first, snapshot: Self.fixture(root: first))
        try await waitUntil { !controller.isScanning }
        controller.toggleSelection(path: first + "/a")
        controller.startScan(at: URL(fileURLWithPath: second))
        XCTAssertNil(controller.currentDirectory)
        XCTAssertTrue(controller.basket.isEmpty)
        try await waitUntil { scanner.hasRequest(second) }
        scanner.finish(path: second)
        try await waitUntil { !controller.isScanning }
    }

    func testNavigationDuringProgressSurvivesCompletion() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let path = "/tmp/storage-navigation"
        let snapshot = Self.fixture(root: path)
        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.emitSnapshot(path: path, snapshot: snapshot)
        try await waitUntil { controller.rootItem != nil }
        controller.drillDown(to: try XCTUnwrap(snapshot.items[path + "/b"]))
        scanner.finish(path: path, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.currentPath, path + "/b")
    }

    func testFilesystemChangesInvalidateCachedRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.bin")
        try Data(repeating: 1, count: 10).write(to: file)
        let controller = StorageExplorerController()
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.size, 10)
        try Data(repeating: 2, count: 400).write(to: file)
        try await waitUntil { controller.isStale }
        controller.startScan(at: try XCTUnwrap(controller.scanRootURL))
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.size, 400)
    }

    func testFilesystemChangesDoNotMarkAnActiveScanStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner)
        controller.startScan(at: root)
        try await waitUntil { scanner.hasRequest(root.path) }

        try Data(repeating: 1, count: 32).write(to: root.appendingPathComponent("during-scan.bin"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.isScanning)
        XCTAssertFalse(controller.isStale)

        scanner.finish(path: root.path)
        try await waitUntil { !controller.isScanning }
        XCTAssertFalse(controller.isStale)

        try Data(repeating: 2, count: 64).write(to: root.appendingPathComponent("after-scan.bin"))
        try await waitUntil { controller.isStale }
    }

    func testAllocatedSpaceIsTheDefaultMetricAndProgressTracksIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 16_384).write(to: root.appendingPathComponent("payload.bin"))
        let controller = StorageExplorerController(observeChanges: false)

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }

        XCTAssertEqual(controller.metric, .allocated)
        XCTAssertGreaterThan(controller.status.progress.allocatedBytesScanned, 0)
    }

    func testUnrelatedFilesystemChangeDoesNotBlockReviewOfUnchangedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.bin")
        let unrelated = root.appendingPathComponent("unrelated.bin")
        try Data(repeating: 1, count: 10).write(to: selected)
        try Data(repeating: 2, count: 10).write(to: unrelated)
        let controller = StorageExplorerController()
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == selected.lastPathComponent }) }
        let selectedPath = try XCTUnwrap(controller.rows.first(where: { $0.name == selected.lastPathComponent })?.item.path)
        controller.toggleSelection(path: selectedPath)

        try Data(repeating: 3, count: 20).write(to: unrelated)
        try await waitUntil { controller.isStale }
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [selectedPath])
    }

    func testChangedSelectedItemMustBeRefreshedBeforeReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.bin")
        try Data(repeating: 1, count: 10).write(to: selected)
        let controller = StorageExplorerController()
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == selected.lastPathComponent }) }
        let selectedPath = try XCTUnwrap(controller.rows.first(where: { $0.name == selected.lastPathComponent })?.item.path)
        controller.toggleSelection(path: selectedPath)

        try Data(repeating: 2, count: 100).write(to: selected)
        try await waitUntil { controller.isStale }
        controller.confirmTrash()

        XCTAssertFalse(controller.isConfirmingTrash)
        XCTAssertTrue(controller.reviewItems.isEmpty)
        XCTAssertNotNil(controller.lastErrorMessage)
    }

    static func fixture(root: String) -> StorageExplorerSnapshot {
        func item(_ suffix: String, _ parent: String?, _ size: Int64, _ directory: Bool) -> StorageItem {
            let path = root + suffix
            return StorageItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                url: URL(fileURLWithPath: path), isDirectory: directory, size: size,
                allocatedSize: size * 2, parentPath: parent.map { root + $0 })
        }
        var snapshot = StorageExplorerSnapshot(rootPath: root)
        snapshot.apply([item("", nil, 300, true), item("/a", "", 100, true), item("/b", "", 200, true),
                        item("/a/one", "/a", 100, false), item("/b/two", "/b", 200, false)])
        return snapshot
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for controlled scan")
    }
}

private final class ControlledStorageScanner: StorageExplorerScanning, @unchecked Sendable {
    private struct Request {
        let update: @Sendable (StorageExplorerScanUpdate) -> Void
        let continuation: CheckedContinuation<StorageExplorerSnapshot, Error>
    }
    private let lock = NSLock()
    private var requests: [String: Request] = [:]
    func invalidate(paths: [String]) {}
    func clearCache() {}
    func hasRequest(_ path: String) -> Bool { lock.withLock { requests[path] != nil } }
    func scanSnapshot(rootURL: URL, update: @escaping @Sendable (StorageExplorerScanUpdate) -> Void) async throws -> StorageExplorerSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { requests[rootURL.path] = Request(update: update, continuation: continuation) }
        }
    }
    func emitSnapshot(path: String, snapshot: StorageExplorerSnapshot) {
        let request = lock.withLock { requests[path] }
        request?.update(StorageExplorerScanUpdate(items: Array(snapshot.items.values), progress: snapshot.progress))
    }
    func emit(path: String, size: Int64) {
        let request = lock.withLock { requests[path] }
        var item = StorageItem(name: "root", path: path, url: URL(fileURLWithPath: path), isDirectory: true, size: size)
        item.isIncomplete = true
        request?.update(StorageExplorerScanUpdate(items: [item], progress: StorageExplorerScanProgress(bytesScanned: size, currentPath: path)))
    }
    func finish(path: String, snapshot: StorageExplorerSnapshot? = nil, error: Error? = nil) {
        let request = lock.withLock { requests.removeValue(forKey: path) }
        if let error { request?.continuation.resume(throwing: error); return }
        var result = snapshot ?? StorageExplorerSnapshot(rootPath: path)
        if result.items.isEmpty {
            result.apply([StorageItem(name: "root", path: path, url: URL(fileURLWithPath: path), isDirectory: true)])
        }
        request?.continuation.resume(returning: result)
    }
}
