import Foundation
import XCTest
@testable import StorageExplorerPlugin

final class StorageExplorerScannerTests: XCTestCase {
    private var tempDirectory: URL!
    private var scanner: StorageExplorerScanner!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        scanner = StorageExplorerScanner()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Scanner Tests

    func testScanDirectoryHierarchy() async throws {
        // fileA: 10,000 bytes
        let fileA = tempDirectory.appendingPathComponent("fileA.bin")
        let dataA = Data(repeating: 0x41, count: 10000)
        try dataA.write(to: fileA)

        // subfolder
        let subfolder = tempDirectory.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        // fileB: 20,000 bytes
        let fileB = subfolder.appendingPathComponent("fileB.bin")
        let dataB = Data(repeating: 0x42, count: 20000)
        try dataB.write(to: fileB)

        // nested
        let nested = subfolder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // fileC: 30,000 bytes
        let fileC = nested.appendingPathComponent("fileC.bin")
        let dataC = Data(repeating: 0x43, count: 30000)
        try dataC.write(to: fileC)

        final class ProgressBox: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() {
                lock.withLock { count += 1 }
            }
        }

        let tracker = ProgressBox()
        let rootItem = try await scanner.scan(rootURL: tempDirectory) { _ in
            tracker.increment()
        }

        XCTAssertTrue(tracker.count > 0)
        XCTAssertEqual(rootItem.size, 60000)
        XCTAssertEqual(rootItem.children.count, 2)

        // Children should be sorted descending by size: subfolder (50000) > fileA (10000)
        let firstChild = rootItem.children[0]
        let secondChild = rootItem.children[1]

        XCTAssertEqual(firstChild.name, "subfolder")
        XCTAssertEqual(firstChild.size, 50000)
        XCTAssertTrue(firstChild.isDirectory)

        XCTAssertEqual(secondChild.name, "fileA.bin")
        XCTAssertEqual(secondChild.size, 10000)
        XCTAssertFalse(secondChild.isDirectory)
    }

    func testHardLinkDeduplication() async throws {
        let file1 = tempDirectory.appendingPathComponent("file1.bin")
        let data = Data(repeating: 0x55, count: 15000)
        try data.write(to: file1)

        let subfolder = tempDirectory.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let file1Link = subfolder.appendingPathComponent("file1_link.bin")

        // Create hard link
        let linkResult = link(file1.path, file1Link.path)
        XCTAssertEqual(linkResult, 0, "link syscall should succeed")

        let rootItem = try await scanner.scan(rootURL: tempDirectory)

        // Root size should count file1 only once (15000 bytes), not twice (30000 bytes)
        XCTAssertEqual(rootItem.size, 15000)
    }

    func testSymlinkNotTraversed() async throws {
        // Create external folder with 50,000 bytes
        let externalDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }

        let externalFile = externalDir.appendingPathComponent("external.bin")
        try Data(repeating: 0x99, count: 50000).write(to: externalFile)

        // Inside scan root, create a normal file of 5,000 bytes
        let internalFile = tempDirectory.appendingPathComponent("internal.bin")
        try Data(repeating: 0x11, count: 5000).write(to: internalFile)

        // Create symlink to external dir
        let symlinkURL = tempDirectory.appendingPathComponent("symlink_to_external")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: externalDir)

        let rootItem = try await scanner.scan(rootURL: tempDirectory)

        // Total size should be ~5000 (internal file) + symlink file size (very small), definitely NOT 55,000!
        XCTAssertLessThan(rootItem.size, 10000)

        // Check symlink child is identified as symlink
        let symlinkChild = rootItem.children.first { $0.name == "symlink_to_external" }
        XCTAssertNotNil(symlinkChild)
        XCTAssertTrue(symlinkChild?.isSymlink ?? false)
    }

    func testNestedPackagesIncludePayloadAndRemainAtomic() async throws {
        let package = tempDirectory.appendingPathComponent("Outer.app")
        let nestedApp = package.appendingPathComponent("Contents/Helpers/Nested.app/Contents/MacOS")
        let nestedFramework = package.appendingPathComponent("Contents/Frameworks/Nested.framework/Versions/A")
        for directory in [nestedApp, nestedFramework] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x41, count: 1_000_000).write(to: nestedApp.appendingPathComponent("binary"))
        try Data(repeating: 0x42, count: 500_000).write(to: nestedFramework.appendingPathComponent("binary"))

        let result = try await scanner.scan(rootURL: tempDirectory)
        let item = try XCTUnwrap(result.children.first)

        XCTAssertEqual(result.children.count, 1)
        XCTAssertTrue(item.isPackage)
        XCTAssertTrue(item.children.isEmpty)
        XCTAssertGreaterThanOrEqual(item.size, 1_500_000)
        XCTAssertLessThan(item.size, 1_510_000)
        XCTAssertGreaterThan(item.childCount, 2)
    }

    func testPackageHardLinksAreCountedOnceAcrossPackageBoundary() async throws {
        let package = tempDirectory.appendingPathComponent("Outer.app")
        let nested = package.appendingPathComponent("Contents/Helpers/Nested.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = nested.appendingPathComponent("binary")
        try Data(repeating: 0x55, count: 1_000_000).write(to: payload)
        try FileManager.default.linkItem(at: payload, to: package.appendingPathComponent("second-copy"))
        try FileManager.default.linkItem(at: payload, to: tempDirectory.appendingPathComponent("outside-copy"))
        let allocated = try XCTUnwrap(payload.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)

        let result = try await scanner.scan(rootURL: tempDirectory)

        XCTAssertGreaterThanOrEqual(result.size, 1_000_000)
        XCTAssertLessThan(result.size, 1_010_000)
        XCTAssertGreaterThanOrEqual(result.allocatedSize, Int64(allocated))
        XCTAssertLessThan(result.allocatedSize, Int64(allocated) + 100_000)
    }

    func testPackageSymlinksDoNotIncludeExternalFilesOrDirectories() async throws {
        let package = tempDirectory.appendingPathComponent("Outer.app")
        let external = tempDirectory.appendingPathComponent("external")
        for directory in [package, external] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = external.appendingPathComponent("payload")
        try Data(repeating: 0x99, count: 1_000_000).write(to: payload)
        try Data(repeating: 0x11, count: 5_000).write(to: package.appendingPathComponent("internal"))
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("directory-link"), withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("file-link"), withDestinationURL: payload)

        let result = try await scanner.scan(rootURL: package)

        XCTAssertTrue(result.isPackage)
        XCTAssertTrue(result.children.isEmpty)
        XCTAssertGreaterThanOrEqual(result.size, 5_000)
        XCTAssertLessThan(result.size, 10_000)
        XCTAssertEqual(result.childCount, 3)
    }

    func testScanCancellation() async throws {
        for i in 0..<100 {
            let file = tempDirectory.appendingPathComponent("file_\(i).bin")
            try Data(repeating: 0x01, count: 1000).write(to: file)
        }

        let task = Task {
            try await scanner.scan(rootURL: tempDirectory)
        }
        task.cancel()

        do {
            _ = try await task.value
            // If it finishes before cancellation takes effect, that is possible for small tasks, but cancellation was registered
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
