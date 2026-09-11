import CryptoKit
import Foundation
import XCTest
@testable import MacTools

@MainActor
final class PluginPackageResolverTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginPackageResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testLocalPackageIsCopiedAndValidated() async throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let entry = try makeEntry(for: packageURL, id: "com.example.demo", version: "1.0.0")
        let resolver = PluginPackageResolver(
            temporaryDirectory: temporaryRoot.appendingPathComponent("Temporary", isDirectory: true)
        )

        let resolvedURL = try await resolver.resolvePackage(for: entry)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedURL.path))
        XCTAssertNotEqual(resolvedURL.path, packageURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testRejectsChecksumMismatch() async throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let entry = PluginCatalogEntry(
            id: "com.example.demo",
            displayName: "Demo",
            summary: "示例插件",
            version: "1.0.0",
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: packageURL,
                sha256: String(repeating: "b", count: 64),
                size: try PluginPackageResolver.packageMetrics(for: packageURL).size
            )
        )
        let resolver = PluginPackageResolver(
            temporaryDirectory: temporaryRoot.appendingPathComponent("Temporary", isDirectory: true)
        )

        do {
            _ = try await resolver.resolvePackage(for: entry)
            XCTFail("Expected checksum mismatch")
        } catch let error as PluginPackageResolverError {
            guard case .checksumMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsManifestMismatch() async throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let entry = try makeEntry(for: packageURL, id: "com.example.other", version: "1.0.0")
        let resolver = PluginPackageResolver(
            temporaryDirectory: temporaryRoot.appendingPathComponent("Temporary", isDirectory: true)
        )

        do {
            _ = try await resolver.resolvePackage(for: entry)
            XCTFail("Expected manifest mismatch")
        } catch {
            XCTAssertEqual(error as? PluginPackageResolverError, .manifestMismatch(field: "id"))
        }
    }

    func testRejectsReleaseChannelMismatch() async throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let entry = try makeEntry(
            for: packageURL,
            id: "com.example.demo",
            version: "1.0.0",
            releaseChannel: "beta"
        )
        let resolver = PluginPackageResolver(
            temporaryDirectory: temporaryRoot.appendingPathComponent("Temporary", isDirectory: true)
        )

        do {
            _ = try await resolver.resolvePackage(for: entry)
            XCTFail("Expected release channel mismatch")
        } catch {
            XCTAssertEqual(error as? PluginPackageResolverError, .manifestMismatch(field: "releaseChannel"))
        }
    }

    func testZipPackageExpandsToMactoolsPluginDirectory() async throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let zipURL = temporaryRoot.appendingPathComponent("Demo.mactoolsplugin.zip")
        try zipPackage(packageURL, to: zipURL)
        let entry = try makeEntry(for: zipURL, id: "com.example.demo", version: "1.0.0")
        let resolver = PluginPackageResolver(
            temporaryDirectory: temporaryRoot.appendingPathComponent("Temporary", isDirectory: true)
        )

        let resolvedURL = try await resolver.resolvePackage(for: entry)

        XCTAssertEqual(resolvedURL.pathExtension, "mactoolsplugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolvedURL.appendingPathComponent("plugin.json").path))
    }

    func testDirectoryPackageMetricsIncludeBundleContents() throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let executableURL = packageURL
            .appendingPathComponent("Demo.bundle", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Demo", isDirectory: false)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("before".utf8).write(to: executableURL)
        let before = try PluginPackageResolver.packageMetrics(for: packageURL)

        try Data("after".utf8).write(to: executableURL)
        let after = try PluginPackageResolver.packageMetrics(for: packageURL)

        XCTAssertNotEqual(before.sha256, after.sha256)
    }

    func testDirectoryPackageMetricsUseStableRelativePathOrder() throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let contentsURL = packageURL
            .appendingPathComponent("Demo.bundle", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        let codeSignatureURL = contentsURL
            .appendingPathComponent("_CodeSignature", isDirectory: true)
            .appendingPathComponent("CodeResources", isDirectory: false)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)

        try FileManager.default.createDirectory(
            at: codeSignatureURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("signature".utf8).write(to: codeSignatureURL)
        try Data("info".utf8).write(to: infoPlistURL)

        let metrics = try PluginPackageResolver.packageMetrics(for: packageURL)
        let expected = stableDirectoryMetrics(
            root: packageURL,
            files: [
                "Demo.bundle/Contents/Info.plist",
                "Demo.bundle/Contents/_CodeSignature/CodeResources",
                "plugin.json",
            ]
        )

        XCTAssertEqual(metrics, expected)
    }

    func testDirectoryPackageMetricsSkipSymbolicLinks() throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let payloadURL = packageURL.appendingPathComponent("payload", isDirectory: false)
        let linkURL = packageURL.appendingPathComponent("linked-payload", isDirectory: false)
        try Data("included".utf8).write(to: payloadURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: payloadURL)

        let metrics = try PluginPackageResolver.packageMetrics(for: packageURL)
        let expected = stableDirectoryMetrics(
            root: packageURL,
            files: ["payload", "plugin.json"]
        )

        XCTAssertEqual(metrics, expected)
    }

    func testDirectoryPackageMetricsSkipFinderHiddenFiles() throws {
        let packageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        var payloadURL = packageURL.appendingPathComponent("payload", isDirectory: false)
        try Data("hidden".utf8).write(to: payloadURL)
        var resourceValues = URLResourceValues()
        resourceValues.isHidden = true
        try payloadURL.setResourceValues(resourceValues)

        let metrics = try PluginPackageResolver.packageMetrics(for: packageURL)
        let expected = stableDirectoryMetrics(root: packageURL, files: ["plugin.json"])

        XCTAssertEqual(metrics, expected)
    }

    private func makePackage(id: String, version: String) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent("Demo.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Demo",
            version: version,
            minHostVersion: "0.1.0",
            bundleRelativePath: "Demo.bundle"
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))
        return packageURL
    }

    private func makeEntry(
        for packageURL: URL,
        id: String,
        version: String,
        releaseChannel: String? = nil
    ) throws -> PluginCatalogEntry {
        let metrics = try PluginPackageResolver.packageMetrics(for: packageURL)

        return PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: packageURL,
                sha256: metrics.sha256,
                size: metrics.size
            ),
            releaseChannel: releaseChannel
        )
    }

    private func zipPackage(_ packageURL: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            packageURL.path,
            zipURL.path
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func stableDirectoryMetrics(root: URL, files: [String]) -> PluginPackageMetrics {
        var hasher = SHA256()
        var size: Int64 = 0

        for relativePath in files.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let fileURL = root.appendingPathComponent(relativePath)
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: data)
            hasher.update(data: Data([0]))
            size += Int64(data.count)
        }

        let digest = hasher.finalize()
        return PluginPackageMetrics(
            size: size,
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }
}
