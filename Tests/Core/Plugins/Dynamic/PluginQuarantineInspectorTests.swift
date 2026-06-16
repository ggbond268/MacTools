import Darwin
import Foundation
import XCTest
@testable import MacTools

final class PluginQuarantineInspectorTests: XCTestCase {
    private var temporaryRoot: URL!
    private let inspector = PluginQuarantineInspector()

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginQuarantineInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testDetectsQuarantineOnRootAndNestedItems() throws {
        let package = try makePackage()
        PluginQuarantineTestSupport.setQuarantine(atPath: package.rootURL.path)
        PluginQuarantineTestSupport.setQuarantine(atPath: package.executableURL.path)
        PluginQuarantineTestSupport.setQuarantine(atPath: package.hiddenFileURL.path)

        let quarantinedURLs = try inspector.quarantinedItemURLs(in: package.rootURL)

        XCTAssertEqual(
            Set(quarantinedURLs.map(\.path)),
            [package.rootURL.path, package.executableURL.path, package.hiddenFileURL.path]
        )
    }

    func testCleanPackageReportsNoQuarantinedItems() throws {
        let package = try makePackage()

        XCTAssertEqual(try inspector.quarantinedItemURLs(in: package.rootURL), [])
    }

    func testStripRemovesQuarantineFromEveryItem() throws {
        let package = try makePackage()
        PluginQuarantineTestSupport.setQuarantine(atPath: package.rootURL.path)
        PluginQuarantineTestSupport.setQuarantine(atPath: package.manifestURL.path)
        PluginQuarantineTestSupport.setQuarantine(atPath: package.executableURL.path)
        PluginQuarantineTestSupport.setQuarantine(atPath: package.hiddenFileURL.path)

        try inspector.stripQuarantine(at: package.rootURL)

        XCTAssertEqual(PluginQuarantineTestSupport.quarantinedPaths(under: package.rootURL), [])
        XCTAssertEqual(try inspector.quarantinedItemURLs(in: package.rootURL), [])
    }

    func testStripFailureOnReadOnlyFileMapsToStripFailedError() throws {
        let package = try makePackage()
        PluginQuarantineTestSupport.setQuarantine(atPath: package.manifestURL.path)
        PluginQuarantineTestSupport.setQuarantine(atPath: package.executableURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: package.executableURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: package.executableURL.path
            )
        }

        XCTAssertThrowsError(try inspector.stripQuarantine(at: package.rootURL)) { error in
            guard case let PluginQuarantineError.stripFailed(failedCount, path, reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(failedCount, 1)
            XCTAssertEqual(path, package.executableURL.path)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertNotNil((error as? PluginQuarantineError)?.errorDescription)
        }

        // Writable files were still stripped; only the read-only one keeps the flag.
        XCTAssertFalse(PluginQuarantineTestSupport.hasQuarantine(atPath: package.manifestURL.path))
        XCTAssertTrue(PluginQuarantineTestSupport.hasQuarantine(atPath: package.executableURL.path))
    }

    func testStripDoesNotFollowSymlinksOutsideThePackage() throws {
        let package = try makePackage()
        let outsideFileURL = temporaryRoot.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outsideFileURL)
        PluginQuarantineTestSupport.setQuarantine(atPath: outsideFileURL.path)

        let symlinkURL = package.rootURL.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFileURL)
        PluginQuarantineTestSupport.setQuarantine(atPath: symlinkURL.path)

        let quarantinedURLs = try inspector.quarantinedItemURLs(in: package.rootURL)
        XCTAssertEqual(quarantinedURLs.map(\.path), [symlinkURL.path])

        try inspector.stripQuarantine(at: package.rootURL)

        XCTAssertFalse(PluginQuarantineTestSupport.hasQuarantine(atPath: symlinkURL.path))
        XCTAssertTrue(PluginQuarantineTestSupport.hasQuarantine(atPath: outsideFileURL.path))
    }

    private struct FixturePackage {
        let rootURL: URL
        let manifestURL: URL
        let executableURL: URL
        let hiddenFileURL: URL
    }

    private func makePackage() throws -> FixturePackage {
        let rootURL = temporaryRoot.appendingPathComponent("Demo.mactoolsplugin", isDirectory: true)
        let macOSURL = rootURL
            .appendingPathComponent("Demo.bundle", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let manifestURL = rootURL.appendingPathComponent("plugin.json")
        let executableURL = macOSURL.appendingPathComponent("Demo")
        let hiddenFileURL = rootURL.appendingPathComponent(".hidden")
        try Data("manifest".utf8).write(to: manifestURL)
        try Data("binary".utf8).write(to: executableURL)
        try Data("hidden".utf8).write(to: hiddenFileURL)

        return FixturePackage(
            rootURL: rootURL,
            manifestURL: manifestURL,
            executableURL: executableURL,
            hiddenFileURL: hiddenFileURL
        )
    }
}
