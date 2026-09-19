import Darwin
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
    }

    func testPartialResultsUpdateProgressWithoutReplacingVisibleSnapshot() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let path = "/tmp/storage-partial"
        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.emit(path: path, size: 100)
        try await waitUntil { controller.status.progress.bytesScanned == 100 }
        XCTAssertTrue(controller.isScanning)
        XCTAssertNil(controller.rootItem)
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

    func testExistingNavigationSurvivesAtomicRefreshCompletion() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let path = "/tmp/storage-navigation"
        let snapshot = Self.fixture(root: path)
        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.finish(path: path, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        controller.drillDown(to: try XCTUnwrap(snapshot.items[path + "/b"]))

        controller.startScan(at: URL(fileURLWithPath: path))
        try await waitUntil { scanner.hasRequest(path) }
        scanner.emitSnapshot(path: path, snapshot: snapshot)
        XCTAssertEqual(controller.currentPath, path + "/b")
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
        let controller = StorageExplorerController(observeChanges: false)
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.size, 10)
        try Data(repeating: 2, count: 400).write(to: file)
        let scannedFilePath = try XCTUnwrap(controller.rootItem?.path) + "/file.bin"
        controller.handleObservedChanges([scannedFilePath])
        controller.startScan(at: try XCTUnwrap(controller.scanRootURL))
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.rootItem?.size, 400)
    }

    func testFilesystemChangesDuringScanDoNotInterruptCompletion() async throws {
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

        scanner.finish(path: root.path)
        try await waitUntil { !controller.isScanning }
        XCTAssertEqual(controller.scanState, .completed)
        XCTAssertTrue(controller.snapshotHasObservedChanges)
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
        let controller = StorageExplorerController(observeChanges: false)
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == selected.lastPathComponent }) }
        let selectedPath = try XCTUnwrap(controller.rows.first(where: { $0.name == selected.lastPathComponent })?.item.path)
        controller.toggleSelection(path: selectedPath)

        try Data(repeating: 3, count: 20).write(to: unrelated)
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [selectedPath])
    }

    func testChangedSelectedItemIsRejectedWithoutObserverSignal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.bin")
        try Data(repeating: 1, count: 10).write(to: selected)
        let controller = StorageExplorerController(observeChanges: false)
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == selected.lastPathComponent }) }
        let selectedPath = try XCTUnwrap(controller.rows.first(where: { $0.name == selected.lastPathComponent })?.item.path)
        controller.toggleSelection(path: selectedPath)

        try Data(repeating: 2, count: 100).write(to: selected)
        controller.confirmTrash()

        XCTAssertFalse(controller.isConfirmingTrash)
        XCTAssertTrue(controller.reviewItems.isEmpty)
        XCTAssertNotNil(controller.lastErrorMessage)
    }

    func testChangedDescendantRequiresRefreshBeforeReviewingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("existing.bin"))
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = StorageExplorerController(observeChanges: false)

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == "selected" }) }
        let selected = try XCTUnwrap(controller.rows.first(where: { $0.name == "selected" })?.item)
        controller.toggleSelection(path: selected.path)
        controller.handleObservedChanges([selected.path + "/new.bin"])
        controller.confirmTrash()

        XCTAssertTrue(controller.snapshotHasObservedChanges)
        XCTAssertTrue(controller.reviewNeedsRefresh)
        XCTAssertFalse(controller.isConfirmingTrash)
        XCTAssertNotNil(controller.lastErrorMessage)
    }

    func testLargeObservedChangeBatchConservativelyRequiresFolderRefresh() async throws {
        let scanner = ControlledStorageScanner()
        let controller = StorageExplorerController(scanner: scanner, observeChanges: false)
        let root = "/tmp/storage-many-events"
        controller.startScan(at: URL(fileURLWithPath: root))
        try await waitUntil { scanner.hasRequest(root) }
        let snapshot = Self.fixture(root: root)
        scanner.finish(path: root, snapshot: snapshot)
        try await waitUntil { !controller.isScanning }
        controller.toggleSelection(path: root + "/a")

        controller.handleObservedChanges((0..<33).map { root + "/unrelated-\($0)" })

        XCTAssertTrue(controller.reviewNeedsRefresh)
        controller.confirmTrash()
        XCTAssertFalse(controller.isConfirmingTrash)
    }

    func testSymlinkIsVisibleButCannotBeStaged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination.bin")
        let symbolicLink = root.appendingPathComponent("link.bin")
        try Data([1]).write(to: destination)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: destination)
        let controller = StorageExplorerController(
            scanner: StorageExplorerScanner(publishesItems: true),
            observeChanges: false
        )

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.contains(where: { $0.name == "link.bin" }) }
        let item = try XCTUnwrap(controller.rows.first(where: { $0.name == "link.bin" })?.item)

        XCTAssertTrue(item.isSymlink)
        XCTAssertFalse(controller.canStage(item))
        controller.toggleSelection(path: item.path)
        XCTAssertTrue(controller.basket.isEmpty)
    }

    func testDeduplicatedHardLinkKeepsObservedSizeForReviewValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.bin")
        let duplicate = root.appendingPathComponent("duplicate.bin")
        try Data(repeating: 1, count: 64).write(to: original)
        XCTAssertEqual(link(original.path, duplicate.path), 0)
        let controller = StorageExplorerController(
            scanner: StorageExplorerScanner(publishesItems: true),
            observeChanges: false
        )

        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.count == 2 }
        let hardLinks = controller.rows.map(\.item).filter(\.isHardLinked)
        XCTAssertEqual(hardLinks.count, 2)
        let deduplicated = try XCTUnwrap(hardLinks.first(where: { $0.size == 0 }))
        XCTAssertEqual(deduplicated.observedFileSize, 64)
        controller.toggleSelection(path: deduplicated.path)
        controller.confirmTrash()

        XCTAssertTrue(controller.isConfirmingTrash)
        XCTAssertEqual(controller.reviewItems.map(\.path), [deduplicated.path])
    }

    func testPartialTrashResultRescansAndKeepsOnlyFailedItemForReview() async throws {
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let physical = realpath(root.path, nil) {
            root = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data(repeating: 1, count: 10).write(to: first)
        try Data(repeating: 2, count: 20).write(to: second)
        let recycler = PartialTrashRecycler(successfulPath: first.path)
        let controller = StorageExplorerController(
            safetyPolicy: StorageExplorerSafetyPolicy(trashRecycler: recycler),
            observeChanges: false
        )
        controller.startScan(at: root)
        try await waitUntil { !controller.isScanning }
        try await waitUntil { controller.rows.count == 2 }
        controller.toggleSelection(path: first.path)
        controller.toggleSelection(path: second.path)
        controller.confirmTrash()
        await controller.executeTrash()
        try await waitUntil { !controller.isScanning }

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(controller.basket, [second.path])
        XCTAssertEqual(controller.reviewItems.map(\.path), [second.path])
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

private final class PartialTrashRecycler: StorageExplorerTrashRecycling, @unchecked Sendable {
    let successfulPath: String
    init(successfulPath: String) { self.successfulPath = successfulPath }

    func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult {
        let successfulName = URL(fileURLWithPath: successfulPath).lastPathComponent
        guard let successful = urls.first(where: { $0.lastPathComponent == successfulName }) else {
            return StorageExplorerRecycleResult(moved: [:], errorDescription: "No matching item")
        }
        try FileManager.default.removeItem(at: successful)
        return StorageExplorerRecycleResult(
            moved: [successful: URL(fileURLWithPath: "/Users/dummy/.Trash/" + successful.lastPathComponent)],
            errorDescription: "One item failed"
        )
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
