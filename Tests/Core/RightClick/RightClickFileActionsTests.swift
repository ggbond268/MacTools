import AppKit
import XCTest
@testable import MacTools

final class RightClickPathFormatterTests: XCTestCase {

    func testShellEscapedEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(
            RightClickPathFormatter.shellEscaped("/a/it's.txt"),
            "'/a/it'\\''s.txt'"
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

}

private final class RightClickWorkspaceSpy: RightClickWorkspaceOpening {
    var selectedURLs: [URL] = []

    func activateFileViewerSelecting(_ urls: [URL]) {
        selectedURLs = urls
    }
}
