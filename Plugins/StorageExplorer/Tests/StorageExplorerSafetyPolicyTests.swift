import Foundation
import XCTest
@testable import StorageExplorerPlugin

final class MockTrashRecycler: StorageExplorerTrashRecycling, @unchecked Sendable {
    var recycledURLs: [URL] = []
    var shouldFail: Bool = false

    func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult {
        if shouldFail {
            throw NSError(domain: "MockTrashRecycler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recycle failed"])
        }
        recycledURLs.append(contentsOf: urls)
        return StorageExplorerRecycleResult(moved: Dictionary(
            uniqueKeysWithValues: urls.map { ($0, URL(fileURLWithPath: "/Users/dummy/.Trash/\($0.lastPathComponent)")) }
        ))
    }
}

private final class ReplacingTrashRecycler: StorageExplorerTrashRecycling, @unchecked Sendable {
    let originalURL: URL
    private(set) var recycledURLs: [URL] = []
    private(set) var recycledContents: Data?

    init(originalURL: URL) {
        self.originalURL = originalURL
    }

    func recycle(urls: [URL]) async throws -> StorageExplorerRecycleResult {
        recycledURLs = urls
        let stagedURL = try XCTUnwrap(urls.first)
        recycledContents = try Data(contentsOf: stagedURL)
        try Data("replacement".utf8).write(to: originalURL)
        try FileManager.default.removeItem(at: stagedURL)
        return StorageExplorerRecycleResult(
            moved: [stagedURL: URL(fileURLWithPath: "/Users/dummy/.Trash/" + stagedURL.lastPathComponent)]
        )
    }
}

final class StorageExplorerSafetyPolicyTests: XCTestCase {
    private var tempDirectory: URL!
    private var mockRecycler: MockTrashRecycler!
    private var policy: StorageExplorerSafetyPolicy!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        if let physical = realpath(tempDirectory.path, nil) {
            tempDirectory = URL(fileURLWithPath: String(cString: physical))
            free(physical)
        }
        mockRecycler = MockTrashRecycler()
        policy = StorageExplorerSafetyPolicy(trashRecycler: mockRecycler, homeDirectory: "/Users/testuser")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Path Shape Tests

    func testEmptyPathIsBlocked() {
        let result = policy.validatePathShape("")
        XCTAssertFalse(result.isAllowed)
    }

    func testRelativePathIsBlocked() {
        let result = policy.validatePathShape("relative/path/to/file")
        XCTAssertFalse(result.isAllowed)
    }

    func testPathTraversalIsBlocked() {
        let result = policy.validatePathShape("/tmp/foo/../bar")
        XCTAssertFalse(result.isAllowed)
    }

    func testControlCharactersAreBlocked() {
        let result = policy.validatePathShape("/tmp/foo\u{0000}bar")
        XCTAssertFalse(result.isAllowed)
    }

    // MARK: - System Protected Roots Tests

    func testSystemRootIsBlocked() {
        let root = tempDirectory.path
        let result = policy.validatePathForRemoval("/", withinRoot: root)
        XCTAssertFalse(result.isAllowed)
    }

    func testSystemDirectoriesAreBlocked() {
        let root = tempDirectory.path
        let systemPaths = [
            "/System",
            "/System/Library",
            "/bin/ls",
            "/usr/bin/python3",
            "/private/var",
            "/etc/hosts",
            "/Library",
            "/Library/Extensions",
            "/Volumes"
        ]
        for path in systemPaths {
            let result = policy.validatePathForRemoval(path, withinRoot: root)
            XCTAssertFalse(result.isAllowed, "Path \(path) should be blocked")
        }
    }

    func testSensitiveUserPathsAreBlocked() {
        let root = "/Users/testuser"
        let sensitive = [
            "/Users/testuser/Library/Keychains/login.keychain-db",
            "/Users/testuser/.ssh/id_rsa",
            "/Users/testuser/.gnupg/secring.gpg",
            "/Users/testuser/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/testuser/Library/Mobile Documents/com~apple~CloudDocs"
        ]
        for path in sensitive {
            let result = policy.validatePathForRemoval(path, withinRoot: root)
            XCTAssertFalse(result.isAllowed, "Sensitive path \(path) should be blocked")
        }
    }

    func testAncestorsOfSensitiveLocationsAreBlockedInsideHomeScan() {
        for path in [
            "/Users/testuser/Library",
            "/Users/testuser/Library/Application Support",
            "/Users/testuser/library",
            "/Users/testuser/Library/.",
            "/Users/testuser/Library//"
        ] {
            XCTAssertFalse(policy.validatePathForRemoval(path, withinRoot: "/Users/testuser").isAllowed, path)
        }
    }

    func testAncestorsOfProtectedSystemLocationsAreBlockedInsideRootScan() {
        for path in ["/Library", "/Applications", "/applications", "/private", "/var"] {
            let result = policy.validatePathForRemoval(path, withinRoot: "/")
            XCTAssertEqual(result.reason, "Critical macOS system path is protected", path)
        }
    }

    func testProtectedLocationChecksRespectDirectoryBoundaries() {
        for (path, root) in [
            ("/Users/testuser/Library/Caches", "/Users/testuser"),
            ("/Users/testuser/Library/Application Support/Example", "/Users/testuser"),
            ("/Users/testuser/Library Backup", "/Users/testuser"),
            ("/Users/testuser/Downloads", "/Users/testuser"),
            ("/Applications/Example.app", "/Applications"),
            ("/Library/Extensions Backup", "/Library")
        ] {
            XCTAssertTrue(policy.validatePathForRemoval(path, withinRoot: root).isAllowed, path)
        }
    }

    func testBatchWithSensitiveAncestorDoesNotCallRecycler() async {
        do {
            _ = try await policy.recycleItems(
                at: ["/Users/testuser/Downloads/report", "/Users/testuser/Library"],
                withinRoot: "/Users/testuser"
            )
            XCTFail("A parent containing sensitive data must block the whole batch")
        } catch {
            XCTAssertTrue(error is StorageExplorerSafetyError)
        }
        XCTAssertTrue(mockRecycler.recycledURLs.isEmpty)
    }

    func testUserHomeRootIsBlocked() {
        let result = policy.validatePathForRemoval("/Users/testuser", withinRoot: "/Users/testuser")
        XCTAssertFalse(result.isAllowed)
    }

    func testScanRootItselfIsBlocked() {
        let root = tempDirectory.path
        let result = policy.validatePathForRemoval(root, withinRoot: root)
        XCTAssertFalse(result.isAllowed)
    }

    func testItemOutsideScanRootIsBlocked() {
        let root = tempDirectory.appendingPathComponent("subfolder").path
        let outsideItem = tempDirectory.appendingPathComponent("other/file.txt").path
        let result = policy.validatePathForRemoval(outsideItem, withinRoot: root)
        XCTAssertFalse(result.isAllowed)
    }

    // MARK: - Allowed Path & Trash Execution Tests

    func testValidItemInsideScanRootIsAllowed() {
        let root = tempDirectory.path
        let validFile = tempDirectory.appendingPathComponent("valid_file.txt").path
        let result = policy.validatePathForRemoval(validFile, withinRoot: root)
        XCTAssertTrue(result.isAllowed)
    }

    func testRecycleItemUsesTrashRecycler() async throws {
        let root = tempDirectory.path
        let validFile = tempDirectory.appendingPathComponent("file_to_trash.txt").path
        try "sample content".write(toFile: validFile, atomically: true, encoding: .utf8)

        let trashedURL = try await policy.recycleItem(at: validFile, withinRoot: root)
        XCTAssertEqual(mockRecycler.recycledURLs.count, 1)
        XCTAssertEqual(mockRecycler.recycledURLs.first?.path, validFile)
        XCTAssertTrue(trashedURL.path.contains(".Trash"))
    }

    func testRecycleItemPreservesTrailingSpaceInFilename() async throws {
        let selected = tempDirectory.appendingPathComponent("report ")
        let sibling = tempDirectory.appendingPathComponent("report")
        try Data([1]).write(to: selected)
        try Data([2]).write(to: sibling)

        _ = try await policy.recycleItem(at: selected.path, withinRoot: tempDirectory.path)

        XCTAssertEqual(mockRecycler.recycledURLs.map(\.path), [selected.path])
        XCTAssertNotEqual(mockRecycler.recycledURLs.first?.path, sibling.path)
    }

    func testRecycleBatchPreservesDistinctWhitespaceFilenames() async throws {
        let selected = ["report ", "report", " leading space"].map { tempDirectory.appendingPathComponent($0) }
        for url in selected { try Data([1]).write(to: url) }

        _ = try await policy.recycleItems(at: selected.map(\.path), withinRoot: tempDirectory.path)

        XCTAssertEqual(mockRecycler.recycledURLs.map(\.path), selected.map(\.path))
    }

    func testInvalidWhitespacePathsCannotBeRetargeted() {
        for path in [" /Users/testuser/Downloads/report", "/Users/testuser/Downloads/report\n"] {
            XCTAssertFalse(policy.validatePathShape(path).isAllowed, path)
        }
    }

    func testRecycleItemFailsWhenBlocked() async {
        let root = tempDirectory.path
        let blockedPath = "/System/Library/CoreServices"
        do {
            _ = try await policy.recycleItem(at: blockedPath, withinRoot: root)
            XCTFail("Should throw error for blocked path")
        } catch {
            XCTAssertTrue(error is StorageExplorerSafetyError)
        }
    }

    func testIdentityValidationRejectsAncestorReplacedBySymlink() async throws {
        let root = tempDirectory.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent("folder")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("payload")
        try Data([1, 2, 3]).write(to: file)
        var status = stat()
        XCTAssertEqual(lstat(file.path, &status), 0)
        let item = StorageItem(
            name: file.lastPathComponent,
            path: file.path,
            url: file,
            isDirectory: false,
            size: 3,
            fileIdentity: StorageFileInode(device: status.st_dev, inode: status.st_ino)
        )
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        try Data([4, 5, 6]).write(to: outside.appendingPathComponent("payload"))

        do {
            _ = try await policy.recycleItems([item], withinRoot: root.path)
            XCTFail("A swapped ancestor symlink must be rejected")
        } catch {
            XCTAssertTrue(error is StorageExplorerSafetyError)
        }
        XCTAssertTrue(mockRecycler.recycledURLs.isEmpty)
    }

    func testVerifiedItemIsPrivatelyStagedBeforePathBasedTrashHandoff() async throws {
        let original = tempDirectory.appendingPathComponent("payload.bin")
        let originalContents = Data("verified original".utf8)
        try originalContents.write(to: original)
        var status = stat()
        XCTAssertEqual(lstat(original.path, &status), 0)
        let item = StorageItem(
            name: original.lastPathComponent,
            path: original.path,
            url: original,
            isDirectory: false,
            size: Int64(originalContents.count),
            fileIdentity: StorageFileInode(device: status.st_dev, inode: status.st_ino)
        )
        let replacingRecycler = ReplacingTrashRecycler(originalURL: original)
        let stagingPolicy = StorageExplorerSafetyPolicy(
            trashRecycler: replacingRecycler,
            homeDirectory: "/Users/testuser"
        )

        let result = try await stagingPolicy.recycleItems([item], withinRoot: tempDirectory.path)

        let stagedURL = try XCTUnwrap(replacingRecycler.recycledURLs.first)
        XCTAssertNotEqual(stagedURL, original)
        XCTAssertTrue(stagedURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".mactools-trash-"))
        XCTAssertEqual(replacingRecycler.recycledContents, originalContents)
        XCTAssertEqual(try Data(contentsOf: original), Data("replacement".utf8))
        XCTAssertNotNil(result.moved[original])
        XCTAssertNil(result.moved[stagedURL])
    }
}
