import Foundation
import XCTest
@testable import StorageExplorerPlugin

final class MockTrashRecycler: StorageExplorerTrashRecycling, @unchecked Sendable {
    var recycledURLs: [URL] = []
    var shouldFail: Bool = false

    func recycle(urls: [URL]) async throws -> [URL: URL] {
        if shouldFail {
            throw NSError(domain: "MockTrashRecycler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recycle failed"])
        }
        recycledURLs.append(contentsOf: urls)
        return Dictionary(uniqueKeysWithValues: urls.map { ($0, URL(fileURLWithPath: "/Users/dummy/.Trash/\($0.lastPathComponent)")) })
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
        let root = tempDirectory.path
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
}
