import XCTest
import SwiftUI
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class DynamicPluginLoaderTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "DynamicPluginLoaderTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicPluginLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        temporaryRoot = nil
    }

    func testValidateLoadedPluginsAcceptsSinglePluginMatchingManifestID() throws {
        let record = makeRecord(id: "com.example.demo")
        let plugin = MockLoadedPlugin(id: "com.example.demo")

        XCTAssertNoThrow(try DynamicPluginLoader.validateLoadedPlugins([plugin], for: record))
    }

    func testValidateLoadedPluginsRejectsEmptyPluginList() {
        let record = makeRecord(id: "com.example.demo")

        XCTAssertThrowsError(try DynamicPluginLoader.validateLoadedPlugins([], for: record)) { error in
            XCTAssertEqual(
                error as? DynamicPluginLoaderError,
                .invalidPluginCount(expected: "com.example.demo", actual: 0)
            )
        }
    }

    func testValidateLoadedPluginsRejectsMultiplePluginsFromOnePackage() {
        let record = makeRecord(id: "com.example.demo")
        let plugins = [
            MockLoadedPlugin(id: "com.example.demo"),
            MockLoadedPlugin(id: "com.example.extra")
        ]

        XCTAssertThrowsError(try DynamicPluginLoader.validateLoadedPlugins(plugins, for: record)) { error in
            XCTAssertEqual(
                error as? DynamicPluginLoaderError,
                .invalidPluginCount(expected: "com.example.demo", actual: 2)
            )
        }
    }

    func testValidateLoadedPluginsRejectsRuntimeIdentifierMismatch() {
        let record = makeRecord(id: "com.example.demo")
        let plugin = MockLoadedPlugin(id: "com.example.other")

        XCTAssertThrowsError(try DynamicPluginLoader.validateLoadedPlugins([plugin], for: record)) { error in
            XCTAssertEqual(
                error as? DynamicPluginLoaderError,
                .pluginIdentifierMismatch(expected: "com.example.demo", actual: "com.example.other")
            )
        }
    }

    func testLoadStripsQuarantineFromInstalledPackageAfterTrustValidationPasses() throws {
        let packageURL = try makeInstalledPackage(id: "com.example.demo")
        PluginQuarantineTestSupport.setQuarantine(atPath: packageURL.path)
        PluginQuarantineTestSupport.setQuarantine(
            atPath: packageURL.appendingPathComponent("plugin.json").path
        )
        let record = makeRecord(id: "com.example.demo", packageURL: packageURL)
        let loader = makeLoader(trustValidator: RecordingTrustValidator())

        let results = loader.loadInstalledPlugins(from: [record])

        // Loading the fixture bundle still fails (it has no real executable), but the
        // quarantine flag must already be gone by the time dlopen is attempted.
        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results.first?.errorMessage)
        XCTAssertEqual(PluginQuarantineTestSupport.quarantinedPaths(under: packageURL), [])
    }

    func testLoadKeepsQuarantineWhenTrustValidationFails() throws {
        let packageURL = try makeInstalledPackage(id: "com.example.demo")
        PluginQuarantineTestSupport.setQuarantine(atPath: packageURL.path)
        let record = makeRecord(id: "com.example.demo", packageURL: packageURL)
        let validator = RecordingTrustValidator()
        validator.validationError = PluginTrustValidatorError.hostTeamIdentifierUnavailable
        let loader = makeLoader(trustValidator: validator)

        let results = loader.loadInstalledPlugins(from: [record])

        XCTAssertEqual(
            results.first?.errorMessage,
            PluginTrustValidatorError.hostTeamIdentifierUnavailable.localizedDescription
        )
        XCTAssertTrue(PluginQuarantineTestSupport.hasQuarantine(atPath: packageURL.path))
    }

    private func makeLoader(trustValidator: PluginTrustValidating) -> DynamicPluginLoader {
        let store = PluginPackageStore(
            rootDirectory: temporaryRoot.appendingPathComponent("Store", isDirectory: true),
            userDefaults: defaults,
            hostVersion: "1.0.0",
            trustValidator: trustValidator
        )
        return DynamicPluginLoader(packageStore: store, trustValidator: trustValidator)
    }

    private func makeInstalledPackage(id: String) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent("Demo.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: packageURL.appendingPathComponent("plugin.json"))
        return packageURL
    }

    private func makeRecord(id: String, packageURL: URL? = nil) -> PluginPackageRecord {
        let packageURL = packageURL ?? URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin", isDirectory: true)
        return PluginPackageRecord(
            id: id,
            manifest: PluginPackageManifest(
                id: id,
                displayName: "Demo",
                version: "1.0.0",
                minHostVersion: "0.15.2",
                bundleRelativePath: "Demo.bundle"
            ),
            packageURL: packageURL,
            bundleURL: packageURL.appendingPathComponent("Demo.bundle", isDirectory: true),
            state: .enabled,
            requiresRestartToFullyUnload: false
        )
    }
}

private final class RecordingTrustValidator: PluginTrustValidating {
    private(set) var validatedBundleURLs: [URL] = []
    var validationError: Error?

    func validatePluginBundle(at bundleURL: URL) throws {
        validatedBundleURLs.append(bundleURL)

        if let validationError {
            throw validationError
        }
    }
}

@MainActor
private final class MockLoadedPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String) {
        metadata = PluginMetadata(
            id: id,
            title: "Demo",
            iconName: "shippingbox",
            iconTint: .blue,
            order: 1,
            defaultDescription: "Demo"
        )
    }
}
