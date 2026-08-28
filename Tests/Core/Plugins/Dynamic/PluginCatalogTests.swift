import CryptoKit
import Foundation
import XCTest
@testable import MacTools

final class PluginCatalogTests: XCTestCase {
    func testPluginKit2KeepsLegacyProductionCatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(for: 2),
            URL(string: "https://mactools.ggbond.app/plugins/catalog.json")
        )
    }

    func testPluginKit3UsesVersionedProductionCatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(for: 3),
            URL(string: "https://mactools.ggbond.app/plugins/v3/catalog.json")
        )
    }

    func testPluginKit4KeepsImmutableVersionedCatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(for: 4),
            URL(string: "https://mactools.ggbond.app/plugins/v4/catalog.json")
        )
    }

    func testReleasedPluginKit5CatalogKeepsSchema2URL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(for: 5),
            URL(string: "https://mactools.ggbond.app/plugins/v5/catalog.json")
        )
    }

    func testConfiguredNightlyCatalogOverridesProductionURL() throws {
        let nightlyURL = try XCTUnwrap(
            URL(string: "https://mactools.ggbond.app/nightly/plugins/v5/catalog.json")
        )

        XCTAssertEqual(
            PluginCatalogProviderConfiguration.configuredProductionCatalogURL(
                for: 5,
                infoDictionary: ["MTPluginCatalogURL": nightlyURL.absoluteString]
            ),
            nightlyURL
        )
    }

    func testNightlyChannelDerivesVersionedCatalogWhenBuildSettingIsEmpty() {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.configuredProductionCatalogURL(
                for: 6,
                infoDictionary: [
                    "MTPluginCatalogURL": "",
                    "MTReleaseChannel": "nightly"
                ]
            ),
            URL(string: "https://mactools.ggbond.app/nightly/plugins/v6/catalog.json")
        )
    }

    func testNightlyChannelDerivesVersionedCatalogWhenBuildSettingIsUnresolved() {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.configuredProductionCatalogURL(
                for: 6,
                infoDictionary: [
                    "MTPluginCatalogURL": "$(PLUGIN_CATALOG_URL)",
                    "MTReleaseChannel": "nightly"
                ]
            ),
            URL(string: "https://mactools.ggbond.app/nightly/plugins/v6/catalog.json")
        )
    }

    func testConfiguredCatalogRejectsNonHTTPSURL() {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.configuredProductionCatalogURL(
                for: 5,
                hostVersion: "1.2.0",
                infoDictionary: ["MTPluginCatalogURL": "file:///tmp/catalog.json"]
            ),
            URL(string: "https://mactools.ggbond.app/plugins/v5/catalog.json")
        )
    }

    func testReleasedVersionKeepsSchema2CompatibilityCatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(forHostVersion: "1.2.0"),
            URL(string: "https://mactools.ggbond.app/plugins/v5/catalog.json")
        )
    }

    func testEmptyConfiguredCatalogFollowsSupportedPluginKitVersion() {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.configuredProductionCatalogURL(
                for: 6,
                infoDictionary: ["MTPluginCatalogURL": ""]
            ),
            URL(string: "https://mactools.ggbond.app/plugins/v6/catalog.json")
        )
    }

    func testSchema3HostUsesSchema3CompatibilityCatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(forHostVersion: "1.2.1"),
            URL(string: "https://mactools.ggbond.app/plugins/v5/schema3/catalog.json")
        )
    }

    func testConfiguredStableCatalogFollowsHostSchemaCompatibility() {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.configuredProductionCatalogURL(
                for: 5,
                hostVersion: "1.2.1",
                infoDictionary: [
                    "MTPluginCatalogURL": "",
                    "MTReleaseChannel": "stable"
                ]
            ),
            URL(string: "https://mactools.ggbond.app/plugins/v5/schema3/catalog.json")
        )
    }

    func testFuturePluginKitUsesItsOwnVersionedCatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL(
                forHostVersion: "1.3.0",
                pluginKitVersion: 6
            ),
            URL(string: "https://mactools.ggbond.app/plugins/v6/catalog.json")
        )
    }

    func testCurrentVerifierRejectsSchemaVersion1() throws {
        let catalog = makeCatalog(schemaVersion: 1)
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertThrowsError(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        ) { error in
            XCTAssertEqual(error as? PluginCatalogVerifierError, .unsupportedSchemaVersion(1))
        }
    }

    func testCurrentVerifierRejectsLegacyPluginKit2Catalog() throws {
        let catalog = makeCatalog(pluginKitVersion: 2)
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertThrowsError(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        ) { error in
            XCTAssertEqual(error as? PluginCatalogVerifierError, .unsupportedPluginKitVersion(2))
        }
    }

    func testEnvironmentHTTPSCatalogURLUsesProductionSource() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/plugins/catalog.json"))
        let source = PluginCatalogProviderConfiguration.defaultSource(
            environment: ["MACTOOLS_PLUGIN_CATALOG_URL": url.absoluteString]
        )

        XCTAssertEqual(source, .production(url))
    }

    func testEnvironmentFileCatalogURLUsesLocalDevelopmentSource() {
        let url = URL(fileURLWithPath: "/tmp/catalog.dev.json")
        let source = PluginCatalogProviderConfiguration.defaultSource(
            environment: ["MACTOOLS_PLUGIN_CATALOG_URL": url.absoluteString]
        )

        XCTAssertEqual(source, .localDevelopment(url))
    }

    func testLocalDevelopmentCatalogAcceptsUnsignedValidCatalog() throws {
        let catalog = makeCatalog()
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertNoThrow(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        )
    }

    func testLocalDevelopmentAcceptsSchema3EnrichedCatalog() throws {
        let manifest = try appearanceManifest()
        let catalog = makeCatalog(
            schemaVersion: 3,
            plugins: [makeEntry(from: manifest)]
        )
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.2.0")

        XCTAssertNoThrow(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        )
        XCTAssertEqual(
            catalog.plugins.first?.presentation?.longDescription.localizedValue(
                preferredLanguages: ["en-US"]
            ),
            "Switch macOS between light and dark appearance from any MacTools action surface."
        )
    }

    func testProductionCatalogRequiresSignature() throws {
        let catalog = makeCatalog()
        let verifier = PluginCatalogVerifier.production(hostVersion: "1.0.0", publicKey: nil)

        XCTAssertThrowsError(
            try verifier.verify(catalog, sourceKind: .production)
        ) { error in
            XCTAssertEqual(error as? PluginCatalogVerifierError, .missingSignature)
        }
    }

    func testRejectsDuplicatePluginIDs() throws {
        let entry = makeEntry(id: "com.example.demo")
        let catalog = makeCatalog(plugins: [entry, entry])
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertThrowsError(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        ) { error in
            XCTAssertEqual(error as? PluginCatalogVerifierError, .duplicatePluginID("com.example.demo"))
        }
    }

    func testRejectsIncompatibleCatalogHostVersion() throws {
        let catalog = makeCatalog(minimumHostVersion: "2.0.0")
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertThrowsError(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        ) { error in
            XCTAssertEqual(
                error as? PluginCatalogVerifierError,
                .incompatibleHostVersion(required: "2.0.0", current: "1.0.0")
            )
        }
    }

    func testAcceptsCatalogContainingEntriesForNewerHosts() throws {
        let futureEntry = makeEntry(minimumHostVersion: "2.0.0")
        let catalog = makeCatalog(plugins: [futureEntry])
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertNoThrow(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        )
    }

    func testRejectsRevokedCatalogEntry() throws {
        let catalog = makeCatalog(
            revoked: [
                PluginCatalogRevocation(id: "com.example.demo", versions: ["1.0.0"], reason: "撤回")
            ]
        )
        let verifier = PluginCatalogVerifier.localDevelopment(hostVersion: "1.0.0")

        XCTAssertThrowsError(
            try verifier.verify(catalog, sourceKind: .localDevelopment)
        ) { error in
            XCTAssertEqual(error as? PluginCatalogVerifierError, .revokedPlugin("com.example.demo"))
        }
    }

    func testProductionCatalogVerifiesEd25519Signature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let unsignedCatalog = makeCatalog()
        let unsignedData = try PluginCatalogCoding.encoder.encode(unsignedCatalog)
        let payload = try PluginCatalogSigning.signedPayload(fromCatalogData: unsignedData)
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        let signedCatalog = makeCatalog(
            signature: PluginCatalog.Signature(algorithm: "ed25519", value: signature)
        )
        let signedData = try PluginCatalogCoding.encoder.encode(signedCatalog)
        let verifier = PluginCatalogVerifier.production(
            hostVersion: "1.0.0",
            publicKey: privateKey.publicKey
        )

        XCTAssertNoThrow(
            try verifier.verify(signedCatalog, sourceKind: .production, rawData: signedData)
        )
    }

    func testEnrichedMetadataIsCoveredByCatalogSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = try appearanceManifest()
        let entry = makeEntry(from: manifest)
        let unsignedCatalog = makeCatalog(schemaVersion: 3, plugins: [entry])
        let unsignedData = try PluginCatalogCoding.encoder.encode(unsignedCatalog)
        let payload = try PluginCatalogSigning.signedPayload(fromCatalogData: unsignedData)
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        let signedCatalog = makeCatalog(
            schemaVersion: 3,
            plugins: [entry],
            signature: PluginCatalog.Signature(algorithm: "ed25519", value: signature)
        )
        let signedData = try PluginCatalogCoding.encoder.encode(signedCatalog)
        let verifier = PluginCatalogVerifier.production(
            hostVersion: "1.2.0",
            publicKey: privateKey.publicKey
        )

        XCTAssertNoThrow(
            try verifier.verify(signedCatalog, sourceKind: .production, rawData: signedData)
        )

        let presentation = try XCTUnwrap(manifest.presentation)
        let tamperedPresentation = PluginProductMetadata.Presentation(
            longDescription: presentation.longDescription,
            examples: presentation.examples,
            screenshots: presentation.screenshots,
            documentationURL: presentation.documentationURL,
            supportURL: presentation.supportURL,
            publisher: "Tampered Publisher",
            license: presentation.license
        )
        let tamperedEntry = makeEntry(from: manifest, presentation: tamperedPresentation)
        let tamperedCatalog = makeCatalog(
            schemaVersion: 3,
            plugins: [tamperedEntry],
            signature: PluginCatalog.Signature(algorithm: "ed25519", value: signature)
        )
        let tamperedData = try PluginCatalogCoding.encoder.encode(tamperedCatalog)

        XCTAssertThrowsError(
            try verifier.verify(tamperedCatalog, sourceKind: .production, rawData: tamperedData)
        ) { error in
            XCTAssertEqual(error as? PluginCatalogVerifierError, .invalidSignature)
        }
    }

    private func makeCatalog(
        schemaVersion: Int = 2,
        minimumHostVersion: String = "0.1.0",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        plugins: [PluginCatalogEntry]? = nil,
        revoked: [PluginCatalogRevocation] = [],
        signature: PluginCatalog.Signature? = nil
    ) -> PluginCatalog {
        PluginCatalog(
            schemaVersion: schemaVersion,
            catalogID: "com.example.catalog",
            generatedAt: Date(timeIntervalSince1970: 0),
            minimumHostVersion: minimumHostVersion,
            pluginKitVersion: pluginKitVersion,
            plugins: plugins ?? [makeEntry()],
            revoked: revoked,
            signature: signature
        )
    }

    private func makeEntry(
        id: String = "com.example.demo",
        minimumHostVersion: String = "0.1.0"
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: "1.0.0",
            minimumHostVersion: minimumHostVersion,
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/Demo.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
    }

    private func makeEntry(
        from manifest: PluginPackageManifest,
        presentation: PluginProductMetadata.Presentation? = nil
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: manifest.id,
            displayName: manifest.displayName,
            summary: manifest.localizedMetadata?["en"]?.summary ?? manifest.displayName,
            version: manifest.version,
            minimumHostVersion: manifest.minHostVersion,
            pluginKitVersion: manifest.pluginKitVersion,
            capabilities: manifest.capabilities,
            permissions: manifest.permissions,
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/\(manifest.id).mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            ),
            category: manifest.category,
            localizedMetadata: manifest.localizedMetadata,
            presentation: presentation ?? manifest.presentation,
            discovery: manifest.discovery,
            requirements: manifest.requirements,
            privacy: manifest.privacy,
            actions: manifest.actions,
            setup: manifest.setup,
            relationships: manifest.relationships
        )
    }

    private func appearanceManifest() throws -> PluginPackageManifest {
        return try JSONDecoder().decode(
            PluginPackageManifest.self,
            from: PluginSourceManifestTestProjection.data(pluginDirectoryName: "Appearance")
        )
    }
}
