import XCTest
@testable import MacTools

final class FinderContextMenuRequestHandlerTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/finder-test", isDirectory: true)

    func testNextAvailableURLUsesBaseNameWhenNoCollision() {
        let url = FinderContextMenuRequestHandler.nextAvailableURL(
            in: directory, baseName: "未命名", ext: "txt",
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "未命名.txt")
    }

    func testNextAvailableURLSkipsExistingNames() {
        let taken: Set<String> = [
            "/tmp/finder-test/未命名.txt",
            "/tmp/finder-test/未命名 2.txt"
        ]
        let url = FinderContextMenuRequestHandler.nextAvailableURL(
            in: directory, baseName: "未命名", ext: "txt",
            fileExists: { taken.contains($0) }
        )
        XCTAssertEqual(url.lastPathComponent, "未命名 3.txt")
    }

    func testNextAvailableURLRespectsExtension() {
        let url = FinderContextMenuRequestHandler.nextAvailableURL(
            in: directory, baseName: "未命名", ext: "json",
            fileExists: { _ in false }
        )
        XCTAssertEqual(url.pathExtension, "json")
    }

    func testSupportedExtensionsAllowIntendedTypes() {
        XCTAssertTrue(FinderContextMenuRequestHandler.isSupportedNewFileExtension("txt"))
        XCTAssertTrue(FinderContextMenuRequestHandler.isSupportedNewFileExtension("md"))
        XCTAssertTrue(FinderContextMenuRequestHandler.isSupportedNewFileExtension("json"))
    }

    func testSupportedExtensionsRejectTraversalAndUnknown() {
        XCTAssertFalse(FinderContextMenuRequestHandler.isSupportedNewFileExtension("../../etc/passwd"))
        XCTAssertFalse(FinderContextMenuRequestHandler.isSupportedNewFileExtension("txt/../../evil"))
        XCTAssertFalse(FinderContextMenuRequestHandler.isSupportedNewFileExtension("exe"))
        XCTAssertFalse(FinderContextMenuRequestHandler.isSupportedNewFileExtension(""))
    }

    // MARK: - Open With

    func testParseOpenWithAcceptsValidAppAndFiles() {
        let items = [
            URLQueryItem(name: "app", value: "/Applications/Code.app"),
            URLQueryItem(name: "file", value: "/tmp/a.txt"),
            URLQueryItem(name: "file", value: "/tmp/b.md")
        ]
        let request = FinderContextMenuRequestHandler.parseOpenWithRequest(
            items, fileExists: { _ in true }, isApplicationBundle: { _ in true }
        )
        XCTAssertEqual(request?.appURL.path, "/Applications/Code.app")
        XCTAssertEqual(request?.files.map(\.path), ["/tmp/a.txt", "/tmp/b.md"])
    }

    func testParseOpenWithRejectsNonAppBundle() {
        let items = [
            URLQueryItem(name: "app", value: "/tmp/not-an-app"),
            URLQueryItem(name: "file", value: "/tmp/a.txt")
        ]
        XCTAssertNil(FinderContextMenuRequestHandler.parseOpenWithRequest(
            items, fileExists: { _ in true }, isApplicationBundle: { _ in false }
        ))
    }

    func testParseOpenWithRejectsWhenNoFilesExist() {
        let items = [
            URLQueryItem(name: "app", value: "/Applications/Code.app"),
            URLQueryItem(name: "file", value: "/tmp/missing.txt")
        ]
        XCTAssertNil(FinderContextMenuRequestHandler.parseOpenWithRequest(
            items, fileExists: { _ in false }, isApplicationBundle: { _ in true }
        ))
    }

    func testParseOpenWithDropsMissingFilesButKeepsExisting() {
        let items = [
            URLQueryItem(name: "app", value: "/Applications/Code.app"),
            URLQueryItem(name: "file", value: "/tmp/exists.txt"),
            URLQueryItem(name: "file", value: "/tmp/missing.txt")
        ]
        let request = FinderContextMenuRequestHandler.parseOpenWithRequest(
            items, fileExists: { $0 == "/tmp/exists.txt" }, isApplicationBundle: { _ in true }
        )
        XCTAssertEqual(request?.files.map(\.path), ["/tmp/exists.txt"])
    }

    func testParseOpenWithRejectsMissingApp() {
        let items = [URLQueryItem(name: "file", value: "/tmp/a.txt")]
        XCTAssertNil(FinderContextMenuRequestHandler.parseOpenWithRequest(
            items, fileExists: { _ in true }, isApplicationBundle: { _ in true }
        ))
    }
}
