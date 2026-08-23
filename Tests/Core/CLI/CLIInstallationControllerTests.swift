import XCTest
@testable import MacTools

@MainActor
final class CLIInstallationControllerTests: XCTestCase {
    func testInstallsAndRemovesOnlyOwnedSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("MacTools.app/Contents/MacOS/mactools")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: source.path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755]
        ))
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = CLIInstallationController(
            homeDirectory: root,
            bundledCLIURL: source
        )
        XCTAssertEqual(controller.status, .notInstalled)
        controller.install()
        XCTAssertEqual(controller.status, .installed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: controller.installURL.path),
            source.path
        )
        controller.uninstall()
        XCTAssertEqual(controller.status, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.installURL.path))
    }

    func testRefusesRegularFileConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source/mactools")
        let destination = root.appendingPathComponent(".local/bin/mactools")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: Data("keep".utf8)))
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = CLIInstallationController(homeDirectory: root, bundledCLIURL: source)
        XCTAssertEqual(controller.status, .conflict)
        controller.install()
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertEqual(controller.status, .conflict)
    }
}
