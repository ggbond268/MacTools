import CryptoKit
import Foundation

enum PluginCatalogSignaturePolicy {
    case required(publicKey: Curve25519.Signing.PublicKey?)
    case optionalForLocalDevelopment
}

struct PluginCatalogVerifier {
    private let hostVersion: String
    private let supportedPluginKitVersion: Int
    private let signaturePolicy: PluginCatalogSignaturePolicy

    init(
        hostVersion: String = AppMetadata.shortVersion ?? "0",
        supportedPluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        signaturePolicy: PluginCatalogSignaturePolicy
    ) {
        self.hostVersion = hostVersion
        self.supportedPluginKitVersion = supportedPluginKitVersion
        self.signaturePolicy = signaturePolicy
    }

    static func production(
        hostVersion: String = AppMetadata.shortVersion ?? "0",
        publicKey: Curve25519.Signing.PublicKey? = PluginCatalogSigning.productionPublicKey
    ) -> PluginCatalogVerifier {
        PluginCatalogVerifier(
            hostVersion: hostVersion,
            signaturePolicy: .required(publicKey: publicKey)
        )
    }

    static func localDevelopment(
        hostVersion: String = AppMetadata.shortVersion ?? "0"
    ) -> PluginCatalogVerifier {
        PluginCatalogVerifier(
            hostVersion: hostVersion,
            signaturePolicy: .optionalForLocalDevelopment
        )
    }

    func verify(
        _ catalog: PluginCatalog,
        sourceKind: PluginCatalogSnapshot.SourceKind,
        rawData: Data? = nil
    ) throws {
        guard catalog.schemaVersion == 2 || catalog.schemaVersion == 3 else {
            throw PluginCatalogVerifierError.unsupportedSchemaVersion(catalog.schemaVersion)
        }

        guard !catalog.catalogID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginCatalogVerifierError.invalidCatalogID
        }

        guard PluginVersionComparator.isVersion(hostVersion, atLeast: catalog.minimumHostVersion) else {
            throw PluginCatalogVerifierError.incompatibleHostVersion(
                required: catalog.minimumHostVersion,
                current: hostVersion
            )
        }

        guard catalog.pluginKitVersion == supportedPluginKitVersion else {
            throw PluginCatalogVerifierError.unsupportedPluginKitVersion(catalog.pluginKitVersion)
        }

        try verifySignatureIfNeeded(catalog: catalog, sourceKind: sourceKind, rawData: rawData)
        try verifyEntries(catalog)
    }

    private func verifySignatureIfNeeded(
        catalog: PluginCatalog,
        sourceKind: PluginCatalogSnapshot.SourceKind,
        rawData: Data?
    ) throws {
        switch signaturePolicy {
        case let .required(publicKey):
            guard let signature = catalog.signature else {
                throw PluginCatalogVerifierError.missingSignature
            }

            guard signature.algorithm.lowercased() == "ed25519" else {
                throw PluginCatalogVerifierError.unsupportedSignatureAlgorithm(signature.algorithm)
            }

            guard let publicKey else {
                throw PluginCatalogVerifierError.missingPublicKey
            }

            guard let rawData else {
                throw PluginCatalogVerifierError.signatureVerificationUnavailable
            }

            let signedPayload = try PluginCatalogSigning.signedPayload(fromCatalogData: rawData)
            let signatureData = Data(base64Encoded: signature.value) ?? Data()

            guard publicKey.isValidSignature(signatureData, for: signedPayload) else {
                throw PluginCatalogVerifierError.invalidSignature
            }
        case .optionalForLocalDevelopment:
            guard sourceKind == .localDevelopment else {
                throw PluginCatalogVerifierError.missingSignature
            }
        }
    }

    private func verifyEntries(_ catalog: PluginCatalog) throws {
        var seenIDs: Set<String> = []

        for entry in catalog.plugins {
            let manifest = PluginPackageManifest(
                id: entry.id,
                displayName: entry.displayName,
                version: entry.version,
                minHostVersion: entry.minimumHostVersion,
                pluginKitVersion: entry.pluginKitVersion,
                bundleRelativePath: "Entry.bundle",
                capabilities: entry.capabilities,
                permissions: entry.permissions,
                releaseChannel: entry.releaseChannel
            )
            // A catalog may advertise packages for newer hosts. Validate the
            // package identity and PluginKit ABI here, then enforce each
            // entry's minimum host version when presenting/installing it.
            try PluginPackageManifestLoader.validatePackageIdentity(manifest)
            guard manifest.pluginKitVersion == supportedPluginKitVersion else {
                throw PluginCatalogVerifierError.unsupportedPluginKitVersion(
                    manifest.pluginKitVersion
                )
            }

            guard seenIDs.insert(entry.id).inserted else {
                throw PluginCatalogVerifierError.duplicatePluginID(entry.id)
            }

            guard !entry.package.sha256.isEmpty,
                  entry.package.sha256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil
            else {
                throw PluginCatalogVerifierError.invalidChecksum(entry.id)
            }

            guard entry.package.size > 0 else {
                throw PluginCatalogVerifierError.invalidPackageSize(entry.id)
            }

            guard isSupportedPackageURL(entry.package.url) else {
                throw PluginCatalogVerifierError.invalidPackageURL(entry.package.url)
            }

            if catalog.revoked.contains(where: { $0.matches(pluginID: entry.id, version: entry.version) }) {
                throw PluginCatalogVerifierError.revokedPlugin(entry.id)
            }
        }
    }

    private func isSupportedPackageURL(_ url: URL) -> Bool {
        if url.isFileURL {
            return true
        }

        return url.scheme?.lowercased() == "https"
    }
}

enum PluginCatalogVerifierError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidCatalogID
    case incompatibleHostVersion(required: String, current: String)
    case unsupportedPluginKitVersion(Int)
    case duplicatePluginID(String)
    case invalidChecksum(String)
    case invalidPackageSize(String)
    case invalidPackageURL(URL)
    case revokedPlugin(String)
    case missingSignature
    case unsupportedSignatureAlgorithm(String)
    case missingPublicKey
    case signatureVerificationUnavailable
    case invalidSignature

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return AppL10n.pluginsFormat("plugin.error.catalog.unsupportedSchemaFormat", defaultValue: "插件列表版本不支持：%d", version)
        case .invalidCatalogID:
            return AppL10n.plugins("plugin.error.catalog.invalidID", defaultValue: "插件列表 ID 不合法。")
        case let .incompatibleHostVersion(required, current):
            return AppL10n.pluginsFormat(
                "plugin.error.catalog.incompatibleHostFormat",
                defaultValue: "插件列表需要 MacTools %@ 或更高版本，当前版本为 %@。",
                required,
                current
            )
        case let .unsupportedPluginKitVersion(version):
            return AppL10n.pluginsFormat("plugin.error.catalog.unsupportedSDKFormat", defaultValue: "插件列表 SDK 版本不支持：%d", version)
        case let .duplicatePluginID(id):
            return AppL10n.pluginsFormat("plugin.error.catalog.duplicatePluginIDFormat", defaultValue: "插件列表包含重复插件：%@", id)
        case let .invalidChecksum(id):
            return AppL10n.pluginsFormat("plugin.error.catalog.invalidChecksumFormat", defaultValue: "插件包校验值不合法：%@", id)
        case let .invalidPackageSize(id):
            return AppL10n.pluginsFormat("plugin.error.catalog.invalidPackageSizeFormat", defaultValue: "插件包大小不合法：%@", id)
        case let .invalidPackageURL(url):
            return AppL10n.pluginsFormat("plugin.error.catalog.invalidPackageURLFormat", defaultValue: "插件包地址不支持：%@", url.absoluteString)
        case let .revokedPlugin(id):
            return AppL10n.pluginsFormat("plugin.error.catalog.revokedPluginFormat", defaultValue: "插件已被撤回：%@", id)
        case .missingSignature:
            return AppL10n.plugins("plugin.error.catalog.missingSignature", defaultValue: "正式插件列表缺少签名。")
        case let .unsupportedSignatureAlgorithm(algorithm):
            return AppL10n.pluginsFormat("plugin.error.catalog.unsupportedSignatureAlgorithmFormat", defaultValue: "插件列表签名算法不支持：%@", algorithm)
        case .missingPublicKey:
            return AppL10n.plugins("plugin.error.catalog.missingPublicKey", defaultValue: "插件列表缺少内置公钥。")
        case .signatureVerificationUnavailable:
            return AppL10n.plugins("plugin.error.catalog.signatureVerificationUnavailable", defaultValue: "插件列表签名无法校验。")
        case .invalidSignature:
            return AppL10n.plugins("plugin.error.catalog.invalidSignature", defaultValue: "插件列表签名不匹配。")
        }
    }
}
