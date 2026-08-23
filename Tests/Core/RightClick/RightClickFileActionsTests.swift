import AppKit
import XCTest
@testable import MacTools

final class RightClickPathFormatterTests: XCTestCase {
    func testRelativePathWithinBaseDirectory() {
        let base = URL(fileURLWithPath: "/Users/test/Projects")
        let target = URL(fileURLWithPath: "/Users/test/Projects/MacTools/README.md")

        XCTAssertEqual(
            RightClickPathFormatter.relativePath(of: target, to: base),
            "MacTools/README.md"
        )
    }

    func testRelativePathForSiblingDirectory() {
        let base = URL(fileURLWithPath: "/Users/test/Projects/MacTools")
        let target = URL(fileURLWithPath: "/Users/test/Desktop/note.txt")

        XCTAssertEqual(
            RightClickPathFormatter.relativePath(of: target, to: base),
            "../../Desktop/note.txt"
        )
    }

    func testJoinedRelativePathsFallsBackToAbsolutePathWithoutBase() {
        let target = URL(fileURLWithPath: "/Users/test/Desktop/note.txt")

        XCTAssertEqual(
            RightClickPathFormatter.joinedRelativePaths([target], base: nil),
            "/Users/test/Desktop/note.txt"
        )
    }

    func testShellEscapedWrapsPlainPathInSingleQuotes() {
        XCTAssertEqual(
            RightClickPathFormatter.shellEscaped("/Users/test/My File.txt"),
            "'/Users/test/My File.txt'"
        )
    }

    func testShellEscapedEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(
            RightClickPathFormatter.shellEscaped("/a/it's.txt"),
            "'/a/it'\\''s.txt'"
        )
    }

    func testJoinedShellEscapedPathsAreSpaceSeparated() {
        let urls = [URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/b/y.txt")]
        XCTAssertEqual(
            RightClickPathFormatter.joinedShellEscapedPaths(urls),
            "'/a/x.txt' '/b/y.txt'"
        )
    }

    func testJoinedFileURLs() {
        let urls = [URL(fileURLWithPath: "/a/x.txt"), URL(fileURLWithPath: "/b/y.md")]
        XCTAssertEqual(
            RightClickPathFormatter.joinedFileURLs(urls),
            "file:///a/x.txt\nfile:///b/y.md"
        )
    }
}

final class RightClickCopyTargetResolverTests: XCTestCase {
    func testSelectedItemsPreserveSelectionAndTargetedDirectoryAsRelativeBase() {
        let selectedURLs = [
            URL(fileURLWithPath: "/Users/test/Projects/one.txt"),
            URL(fileURLWithPath: "/Users/test/Projects/two.txt")
        ]
        let targetedURL = URL(fileURLWithPath: "/Users/test/Projects", isDirectory: true)

        let result = RightClickCopyTargetResolver.selectedItems(
            selectedURLs,
            targetedURL: targetedURL
        )

        XCTAssertEqual(result?.urls, selectedURLs)
        XCTAssertEqual(result?.relativeBaseURL, targetedURL)
    }

    func testSelectedItemsDoesNotFallBackToTargetedDirectory() {
        let targetedURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        XCTAssertNil(RightClickCopyTargetResolver.selectedItems([], targetedURL: targetedURL))
    }

    func testCurrentDirectoryUsesTargetedDirectoryAsCopyTarget() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let result = RightClickCopyTargetResolver.currentDirectory(targetedURL: directory)

        XCTAssertEqual(result?.urls, [directory])
        XCTAssertEqual(result?.relativeBaseURL, directory.deletingLastPathComponent())
        XCTAssertEqual(
            RightClickPathFormatter.joinedRelativePaths(
                result?.urls ?? [],
                base: result?.relativeBaseURL
            ),
            directory.lastPathComponent
        )
    }

    func testCurrentDirectoryWithoutTargetReturnsNil() {
        XCTAssertNil(RightClickCopyTargetResolver.currentDirectory(targetedURL: nil))
    }
}

final class RightClickLocalizationTests: XCTestCase {
    func testExplicitEnglishPreferenceUsesEnglishFinderMenuStrings() {
        XCTAssertEqual(
            RightClickLocalization.string(
                "finder.newFolder",
                defaultValue: "新建文件夹",
                preferredLanguages: ["en"]
            ),
            "New Folder"
        )
    }

    func testExplicitChinesePreferenceUsesChineseFinderMenuStrings() {
        XCTAssertEqual(
            RightClickLocalization.string(
                "finder.newFolder",
                defaultValue: "New Folder",
                preferredLanguages: ["zh-Hans"]
            ),
            "新建文件夹"
        )
    }

    func testChineseRegionPreferenceMatchesSimplifiedChineseStrings() {
        XCTAssertEqual(
            RightClickLocalization.string(
                "finder.openInTerminal",
                defaultValue: "Open in Terminal",
                preferredLanguages: ["zh-Hans-CN"]
            ),
            "在终端打开"
        )
    }

    func testFinderSyncPreferenceLookupChecksHostAppBeforeExtensionDomain() {
        XCTAssertEqual(
            RightClickLocalization.preferenceBundleIdentifiersForTesting(
                bundleIdentifier: "cc.ggbond.mactools.dev.right-click.finder-sync"
            ),
            [
                "cc.ggbond.mactools.dev",
                "cc.ggbond.mactools.dev.right-click.finder-sync"
            ]
        )
    }

}

final class RightClickFileNamePlannerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testNextAvailableFolderUsesDefaultNameWhenAvailable() throws {
        let url = RightClickFileNamePlanner.nextAvailableFolderURL(
            in: temporaryDirectory,
            baseName: RightClickLocalization.string(
                "file.defaultFolderName",
                defaultValue: "新建文件夹",
                preferredLanguages: ["zh-Hans"]
            )
        )

        XCTAssertEqual(url.lastPathComponent, "新建文件夹")
    }

    func testNextAvailableFolderSkipsExistingNames() throws {
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("新建文件夹", isDirectory: true),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("新建文件夹 2", isDirectory: true),
            withIntermediateDirectories: false
        )

        let url = RightClickFileNamePlanner.nextAvailableFolderURL(
            in: temporaryDirectory,
            baseName: RightClickLocalization.string(
                "file.defaultFolderName",
                defaultValue: "新建文件夹",
                preferredLanguages: ["zh-Hans"]
            )
        )

        XCTAssertEqual(url.lastPathComponent, "新建文件夹 3")
    }

    func testCreateFolderCreatesAndSelectsNewFolder() throws {
        let workspace = RightClickWorkspaceSpy()
        let service = RightClickFileActionService(workspace: workspace)

        let createdURL = try service.createFolder(in: temporaryDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(workspace.selectedURLs, [createdURL])
    }

    func testCreateFileCreatesAllowedTypeAndSelectsIt() throws {
        let workspace = RightClickWorkspaceSpy()
        let service = RightClickFileActionService(workspace: workspace)

        let createdURL = try service.createFile(in: temporaryDirectory, extension: "md")

        XCTAssertEqual(createdURL.pathExtension, "md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(workspace.selectedURLs, [createdURL])
    }

    func testCreateFileRejectsUnsupportedExtension() {
        let service = RightClickFileActionService()
        XCTAssertThrowsError(try service.createFile(in: temporaryDirectory, extension: "exe"))
        XCTAssertThrowsError(try service.createFile(in: temporaryDirectory, extension: "../../etc/x"))
    }

    func testNewFileAllowListAcceptsIntendedRejectsOthers() {
        XCTAssertEqual(
            RightClickNewFile.supportedExtensions,
            [
                "txt", "md", "csv",
                "json", "yaml", "yml", "xml",
                "html", "css", "js", "ts",
                "sh", "py"
            ]
        )
        XCTAssertTrue(RightClickNewFile.isSupportedExtension("MD"))
        XCTAssertTrue(RightClickNewFile.isSupportedExtension("HTML"))
        XCTAssertFalse(RightClickNewFile.isSupportedExtension("exe"))
        XCTAssertFalse(RightClickNewFile.isSupportedExtension("../../etc/passwd"))
        XCTAssertFalse(RightClickNewFile.isSupportedExtension(""))
    }
}

private final class RightClickWorkspaceSpy: RightClickWorkspaceOpening {
    var selectedURLs: [URL] = []

    func activateFileViewerSelecting(_ urls: [URL]) {
        selectedURLs = urls
    }
}
