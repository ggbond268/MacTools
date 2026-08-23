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

    func testCurrentPluginKitUsesVersion6CatalogURL() throws {
        XCTAssertEqual(
            PluginCatalogProviderConfiguration.productionCatalogURL,
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
}
