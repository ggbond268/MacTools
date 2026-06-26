import XCTest

// FinderContextMenuLogic is compiled directly into this test bundle (the Finder
// Sync extension is an app-extension, not an importable framework), so it is
// referenced here without an import.
final class FinderContextMenuLogicTests: XCTestCase {
    func testShellEscapedWrapsPlainPathInSingleQuotes() {
        XCTAssertEqual(
            FinderContextMenuLogic.shellEscaped("/Users/me/file.txt"),
            "'/Users/me/file.txt'"
        )
    }

    func testShellEscapedKeepsSpacesInsideQuotes() {
        XCTAssertEqual(
            FinderContextMenuLogic.shellEscaped("/Users/me/My File.txt"),
            "'/Users/me/My File.txt'"
        )
    }

    func testShellEscapedEscapesEmbeddedSingleQuote() {
        // it's.txt -> 'it'\''s.txt'
        XCTAssertEqual(
            FinderContextMenuLogic.shellEscaped("it's.txt"),
            "'it'\\''s.txt'"
        )
    }
}
