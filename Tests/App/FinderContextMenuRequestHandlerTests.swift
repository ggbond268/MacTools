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
}
