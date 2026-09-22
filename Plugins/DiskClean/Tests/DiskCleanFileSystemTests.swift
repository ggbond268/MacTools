import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanFileSystemTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileSystem: LocalDiskCleanFileSystem!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskCleanFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileSystem = LocalDiskCleanFileSystem(homeDirectory: tempDirectory.path)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        fileSystem = nil
        tempDirectory = nil
        try super.tearDownWithError()
    }

    func testExpandsHomeAndGlobPatternsIncludingSpaces() throws {
        try createFile("Library/Caches/Foo/data.bin")
        try createFile("Library/Caches/With Space/data.bin")
        try createFile("Library/Application Support/App/Profile 1/GPUCache/cache.bin")
        try createFile("Library/Application Support/App/Profile 2/GPUCache/cache.bin")

        let cacheMatches = try fileSystem.expandPathPattern("~/Library/Caches/*").map(\.path)
        XCTAssertEqual(
            Set(cacheMatches),
            [
                tempDirectory.appendingPathComponent("Library/Caches/Foo").path,
                tempDirectory.appendingPathComponent("Library/Caches/With Space").path
            ]
        )

        let nestedMatches = try fileSystem
            .expandPathPattern("~/Library/Application Support/App/*/GPUCache")
            .map(\.path)
        XCTAssertEqual(
            Set(nestedMatches),
            [
                tempDirectory.appendingPathComponent("Library/Application Support/App/Profile 1/GPUCache").path,
                tempDirectory.appendingPathComponent("Library/Application Support/App/Profile 2/GPUCache").path
            ]
        )
    }

    func testDeduplicatesParentChildPathsKeepingParents() {
        let parent = tempDirectory.appendingPathComponent("Library/Caches/Foo").path
        let child = tempDirectory.appendingPathComponent("Library/Caches/Foo/Nested").path
        let sibling = tempDirectory.appendingPathComponent("Library/Caches/FooBar").path

        XCTAssertEqual(
            fileSystem.deduplicatedParentChildPaths([child, sibling, parent]),
            [parent, sibling]
        )
    }

    func testDeduplicatesParentChildPathsWhenPrefixSiblingSortsBetweenParentAndChild() {
        let parent = tempDirectory.appendingPathComponent("a").path
        let child = tempDirectory.appendingPathComponent("a/b").path
        let prefixSibling = tempDirectory.appendingPathComponent("a-b").path

        XCTAssertEqual(
            fileSystem.deduplicatedParentChildPaths([child, prefixSibling, parent]),
            [parent, prefixSibling]
        )
    }

    /// Ancestor decomposition depends on direct children and **must include hidden entries** — a `*` glob would miss dotfiles.
    func testDirectChildrenIncludeHiddenEntriesAndDoNotRecurse() throws {
        try createFile("Library/Caches/Foo/visible.bin")
        try createFile("Library/Caches/Foo/.hidden")
        try createFile("Library/Caches/Foo/Nested/deep.bin")

        let children = try fileSystem
            .directChildren(of: tempDirectory.appendingPathComponent("Library/Caches/Foo").path)

        XCTAssertEqual(
            children.map { ($0.path as NSString).lastPathComponent },
            [".hidden", "Nested", "visible.bin"]
        )
        XCTAssertEqual(children.filter(\.isDirectory).map { ($0.path as NSString).lastPathComponent }, ["Nested"])
    }

    func testDirectChildrenThrowsForMissingDirectory() {
        XCTAssertThrowsError(
            try fileSystem.directChildren(of: tempDirectory.appendingPathComponent("nope").path)
        )
    }

    /// Resolve ancestors, keep the leaf as-is: if the candidate itself is a symlink, realpath must not replace it with its target.
    func testPhysicalPathResolvesAncestorsButKeepsLastComponent() throws {
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("Real"),
            withIntermediateDirectories: true
        )
        let aliasURL = tempDirectory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(atPath: aliasURL.path, withDestinationPath: "Real")
        let realParent = DiskCleanTempDirectory.physicalPath(of: tempDirectory.appendingPathComponent("Real").path)

        XCTAssertEqual(
            DiskCleanPhysicalPath.resolve(aliasURL.appendingPathComponent("child").path),
            realParent + "/child",
            "intermediate symlinks must be expanded, or O_NOFOLLOW_ANY will reject the whole path"
        )
        XCTAssertEqual(
            DiskCleanPhysicalPath.resolve(aliasURL.path),
            DiskCleanTempDirectory.physicalPath(of: tempDirectory.path) + "/Alias",
            "keep the leaf symlink as-is: resolving it would delete something else"
        )
    }

    func testSymlinkMetadataReportsTargetWithoutFollowingIt() throws {
        let linkURL = tempDirectory.appendingPathComponent("Library/Caches/SystemLink")
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "/System")

        let item = try XCTUnwrap(fileSystem.itemInfo(at: linkURL.path))

        XCTAssertEqual(item.path, linkURL.path)
        XCTAssertTrue(item.isSymlink)
        XCTAssertEqual(item.resolvedSymlinkTarget, "/System")
    }

    private func createFile(_ relativePath: String, bytes: Int = 1) throws {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(repeating: 0x41, count: bytes)
        try data.write(to: url)
    }
}
