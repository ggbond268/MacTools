import XCTest
@testable import MacTools

final class PluginPackageManifestTests: XCTestCase {
    func testManifestValidationAcceptsCurrentPackageFormat() throws {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            bundleRelativePath: "Demo.bundle",
            capabilities: .init(primaryPanel: true)
        )

        XCTAssertNoThrow(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0"))
    }

    func testManifestValidationRejectsPreviousPluginKitVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            pluginKitVersion: 1,
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .unsupportedPluginKitVersion(1))
        }
    }

    func testManifestValidationRejectsUnsafeBundlePath() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "0.15.0",
            bundleRelativePath: "../Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .invalidBundleRelativePath("../Demo.bundle"))
        }
    }

    func testManifestValidationRejectsInvalidVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0-beta",
            minHostVersion: "0.15.0",
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .invalidVersion("1.0-beta"))
        }
    }

    func testManifestValidationRejectsReservedOrTerminatedPluginIdentifiers() {
        for id in ["marketplace", "fan-control\n", "fan-control\r"] {
            let manifest = PluginPackageManifest(
                id: id,
                displayName: "Demo",
                version: "1.0.0",
                minHostVersion: "0.15.0",
                bundleRelativePath: "Demo.bundle"
            )

            XCTAssertThrowsError(
                try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")
            ) { error in
                XCTAssertEqual(error as? PluginPackageManifestError, .invalidIdentifier(id))
            }
        }
    }

    func testManifestValidationRejectsIncompatibleHostVersion() {
        let manifest = PluginPackageManifest(
            id: "com.example.demo",
            displayName: "Demo",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            bundleRelativePath: "Demo.bundle"
        )

        XCTAssertThrowsError(try PluginPackageManifestLoader.validate(manifest, hostVersion: "0.16.0")) { error in
            XCTAssertEqual(
                error as? PluginPackageManifestError,
                .incompatibleHostVersion(required: "1.0.0", current: "0.16.0")
            )
        }
    }

    func testExtractionPackagesDeclareTheirRequiredHostCompatibility() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectations = [
            (
                path: "Plugins/MouseEnhancer/plugin.json",
                minimum: "1.2.0",
                compatibleHost: "1.2.0",
                incompatibleHost: "1.1.6" as String?
            ),
            (
                path: "Plugins/TrackpadGestures/plugin.json",
                minimum: "1.2.1",
                compatibleHost: "1.2.1",
                incompatibleHost: "1.2.0"
            ),
        ]
        for expectation in expectations {
            let relativePath = expectation.path
            let manifestURL = repositoryRoot.appendingPathComponent(relativePath)
            let manifest = try JSONDecoder().decode(
                PluginPackageManifest.self,
                from: PluginSourceManifestTestProjection.data(
                    pluginDirectoryName: manifestURL.deletingLastPathComponent().lastPathComponent
                )
            )

            XCTAssertEqual(manifest.minHostVersion, expectation.minimum)
            XCTAssertNoThrow(
                try PluginPackageManifestLoader.validate(
                    manifest,
                    hostVersion: expectation.compatibleHost
                )
            )
            if let incompatibleHost = expectation.incompatibleHost {
                XCTAssertThrowsError(
                    try PluginPackageManifestLoader.validate(
                        manifest,
                        hostVersion: incompatibleHost
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? PluginPackageManifestError,
                        .incompatibleHostVersion(
                            required: expectation.minimum,
                            current: incompatibleHost
                        )
                    )
                }
            }
        }
    }

    func testCurrentHostVersionCanLoadEveryRepositoryPluginManifest() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let versionConfiguration = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Configs/AppVersion.xcconfig"),
            encoding: .utf8
        )
        let hostVersion = try XCTUnwrap(
            versionConfiguration
                .split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("MARKETING_VERSION =") }?
                .split(separator: "=", maxSplits: 1)
                .last?
                .trimmingCharacters(in: .whitespaces)
        )
        let pluginDirectory = repositoryRoot.appendingPathComponent("Plugins", isDirectory: true)
        let pluginURLs = try FileManager.default.contentsOfDirectory(
            at: pluginDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for pluginURL in pluginURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = pluginURL.appendingPathComponent("plugin.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifest = try JSONDecoder().decode(
                PluginPackageManifest.self,
                from: PluginSourceManifestTestProjection.data(
                    pluginDirectoryName: pluginURL.lastPathComponent
                )
            )

            XCTAssertNoThrow(
                try PluginPackageManifestLoader.validate(manifest, hostVersion: hostVersion),
                "\(pluginURL.lastPathComponent) requires host \(manifest.minHostVersion), current host is \(hostVersion)"
            )
        }
    }

    func testManifestDecodesWithCategoryAndReleaseChannel() throws {
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "0.15.0",
          "pluginKitVersion": 3,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": { "primaryPanel": true, "componentPanel": false, "configuration": true },
          "permissions": [],
          "category": "display",
          "releaseChannel": "beta",
          "localizedMetadata": {
            "en": {
              "displayName": "Demo",
              "summary": "Demo plugin"
            },
            "zh-Hans": {
              "displayName": "示例",
              "summary": "示例插件"
            }
          }
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: json)
        XCTAssertEqual(manifest.category, "display")
        XCTAssertEqual(manifest.releaseChannel, "beta")
        XCTAssertEqual(manifest.capabilities.settings, .form)
        XCTAssertEqual(manifest.localizedMetadata?["en"]?.summary, "Demo plugin")
    }

    func testManifestDecodesWithoutCategoryAndReleaseChannelGracefully() throws {
        // Legacy plugin.json files without category/releaseChannel should still decode.
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "0.15.0",
          "pluginKitVersion": 3,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": { "primaryPanel": true, "componentPanel": false, "configuration": false },
          "permissions": []
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(PluginPackageManifest.self, from: json)
        XCTAssertNil(manifest.category)
        XCTAssertNil(manifest.releaseChannel)
    }

    func testRichProjectedManifestDecodesProductMetadata() throws {
        let manifest = try JSONDecoder().decode(
            PluginPackageManifest.self,
            from: PluginSourceManifestTestProjection.data(pluginDirectoryName: "Appearance")
        )

        XCTAssertEqual(manifest.presentation?.publisher, "MacTools")
        XCTAssertEqual(
            manifest.presentation?.longDescription.localizedValue(preferredLanguages: ["en-US"]),
            "Switch macOS between light and dark appearance from any MacTools action surface."
        )
        XCTAssertEqual(manifest.actions?.providers.first?.kind, "static")
        XCTAssertEqual(
            manifest.actions?.providers.first?.staticActions.map(\.id),
            ["toggle", "set-enabled", "set-mode"]
        )
        XCTAssertEqual(manifest.requirements?.architectures, ["arm64", "x86_64"])
        XCTAssertEqual(manifest.privacy?.networkUse, "none")
        let searchKeywords = PluginProductMetadata.searchKeywords(
            presentation: manifest.presentation,
            discovery: manifest.discovery,
            requirements: manifest.requirements,
            privacy: manifest.privacy,
            actions: manifest.actions,
            setup: manifest.setup,
            relationships: manifest.relationships
        )
        XCTAssertTrue(searchKeywords.contains("Toggle Appearance"))
        XCTAssertTrue(searchKeywords.contains("night-shift"))
    }

    func testUnknownOptionalProductFieldDoesNotBreakRuntimeDecoding() throws {
        let json = """
        {
          "id": "demo",
          "displayName": "Demo",
          "version": "1.0.0",
          "minHostVersion": "1.0.0",
          "pluginKitVersion": 4,
          "bundleRelativePath": "Demo.bundle",
          "capabilities": {"primaryPanel": false, "componentPanel": false, "settings": "none"},
          "permissions": [],
          "futureProductSection": {"newField": true}
        }
        """.data(using: .utf8)!

        XCTAssertNoThrow(try JSONDecoder().decode(PluginPackageManifest.self, from: json))
    }

    func testLocalizedMetadataMatchesPreferredLanguageAndFallbacks() {
        let metadata = [
            "en": PluginLocalizedMetadata(displayName: "Calendar", summary: "Events"),
            "zh-Hans": PluginLocalizedMetadata(displayName: "日历", summary: "日程"),
            "zh-Hant": PluginLocalizedMetadata(displayName: "行事曆", summary: "事件")
        ]

        XCTAssertEqual(
            PluginLocalizationMatcher.localizedMetadata(
                from: metadata,
                preferredLanguages: ["en-US"]
            )?.displayName,
            "Calendar"
        )
        XCTAssertEqual(
            PluginLocalizationMatcher.localizedMetadata(
                from: metadata,
                preferredLanguages: ["zh-HK"]
            )?.displayName,
            "行事曆"
        )
        XCTAssertEqual(
            PluginLocalizationMatcher.localizedMetadata(
                from: metadata,
                preferredLanguages: ["fr-FR"]
            )?.displayName,
            "Calendar"
        )
    }
}

enum PluginSourceManifestTestProjection {
    static func data(pluginDirectoryName: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(pluginDirectoryName, isDirectory: true)
            .appendingPathComponent("plugin.json")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactools-manifest-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destinationURL = temporaryDirectory.appendingPathComponent("plugin.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.currentDirectoryURL = repositoryRoot
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/plugins/copy-plugin-manifest.py").path,
            "copy",
            "--source", sourceURL.path,
            "--destination", destinationURL.path,
            "--configuration", "Release",
            "--app-version-config",
            repositoryRoot.appendingPathComponent("Configs/AppVersion.xcconfig").path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown projection error"
            throw projectionError(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Data(contentsOf: destinationURL)
    }

    private static func projectionError(_ message: String) -> NSError {
        NSError(
            domain: "PluginSourceManifestTestProjection",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
