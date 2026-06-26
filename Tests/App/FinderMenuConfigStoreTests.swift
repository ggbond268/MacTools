import XCTest
@testable import MacTools

final class FinderMenuConfigStoreTests: XCTestCase {
    /// Unique temp file in its own directory, so `save()`'s directory creation is
    /// exercised and nothing touches the real Application Support config.
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("finder-menu.json")
    }

    func testSaveThenLoadRoundTrips() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var config = FinderMenuConfiguration.default
        config.openInTerminal = false
        config.copyFileName = false
        config.openWithApps = [
            OpenWithApp(name: "Code", appPath: "/Applications/Code.app", fileExtensions: ["txt", "md"])
        ]

        XCTAssertTrue(FinderMenuConfigStore.save(config, to: fileURL))
        let loaded = FinderMenuConfigStore.load(from: fileURL)

        XCTAssertEqual(loaded, config)
        XCTAssertFalse(loaded.openInTerminal)
        XCTAssertFalse(loaded.copyFileName)
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")
        XCTAssertEqual(loaded.openWithApps.first?.fileExtensions, ["txt", "md"])
    }

    func testLoadMissingFileReturnsDefault() {
        XCTAssertEqual(FinderMenuConfigStore.load(from: makeTempFileURL()), .default)
    }

    func testLoadCorruptDataReturnsDefault() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(FinderMenuConfigStore.load(from: fileURL), .default)
    }

    func testSaveCreatesIntermediateDirectories() throws {
        let fileURL = makeTempFileURL()  // parent directory does not exist yet
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        XCTAssertTrue(FinderMenuConfigStore.save(.default, to: fileURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - OpenWithApp matching

    func testOpenWithAppMatchesListedExtensionsCaseInsensitively() {
        let app = OpenWithApp(name: "Editor", appPath: "/E.app", fileExtensions: ["txt", "md"])
        XCTAssertTrue(app.matches(fileExtension: "txt"))
        XCTAssertTrue(app.matches(fileExtension: "TXT"))
        XCTAssertTrue(app.matches(fileExtension: "md"))
        XCTAssertFalse(app.matches(fileExtension: "png"))
    }

    func testOpenWithAppEmptyExtensionsMatchesEverything() {
        let app = OpenWithApp(name: "Editor", appPath: "/E.app", fileExtensions: [])
        XCTAssertTrue(app.matches(fileExtension: "txt"))
        XCTAssertTrue(app.matches(fileExtension: ""))
    }
}
