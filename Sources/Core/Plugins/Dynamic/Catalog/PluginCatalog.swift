import Foundation

struct PluginCatalog: Codable, Equatable {
    struct Signature: Codable, Equatable {
        let algorithm: String
        let value: String

        init(algorithm: String, value: String) {
            self.algorithm = algorithm
            self.value = value
        }
    }

    let schemaVersion: Int
    let catalogID: String
    let generatedAt: Date
    let minimumHostVersion: String
    let pluginKitVersion: Int
    let plugins: [PluginCatalogEntry]
    let revoked: [PluginCatalogRevocation]
    let signature: Signature?

    init(
        schemaVersion: Int = 3,
        catalogID: String,
        generatedAt: Date,
        minimumHostVersion: String,
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        plugins: [PluginCatalogEntry],
        revoked: [PluginCatalogRevocation] = [],
        signature: Signature? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.catalogID = catalogID
        self.generatedAt = generatedAt
        self.minimumHostVersion = minimumHostVersion
        self.pluginKitVersion = pluginKitVersion
        self.plugins = plugins
        self.revoked = revoked
        self.signature = signature
    }
}

struct PluginCatalogEntry: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let version: String
    let minimumHostVersion: String
    let pluginKitVersion: Int
    let capabilities: PluginPackageManifest.Capabilities
    let permissions: [String]
    let package: PluginCatalogPackage
    let releaseNotesURL: URL?
    let category: String?
    let releaseChannel: String?
    let localizedMetadata: [String: PluginLocalizedMetadata]?
    let presentation: PluginProductMetadata.Presentation?
    let discovery: PluginProductMetadata.Discovery?
    let requirements: PluginProductMetadata.Requirements?
    let privacy: PluginProductMetadata.Privacy?
    let actions: PluginProductMetadata.Actions?
    let setup: PluginProductMetadata.Setup?
    let relationships: PluginProductMetadata.Relationships?

    init(
        id: String,
        displayName: String,
        summary: String,
        version: String,
        minimumHostVersion: String,
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        capabilities: PluginPackageManifest.Capabilities = .init(),
        permissions: [String] = [],
        package: PluginCatalogPackage,
        releaseNotesURL: URL? = nil,
        category: String? = nil,
        releaseChannel: String? = nil,
        localizedMetadata: [String: PluginLocalizedMetadata]? = nil,
        presentation: PluginProductMetadata.Presentation? = nil,
        discovery: PluginProductMetadata.Discovery? = nil,
        requirements: PluginProductMetadata.Requirements? = nil,
        privacy: PluginProductMetadata.Privacy? = nil,
        actions: PluginProductMetadata.Actions? = nil,
        setup: PluginProductMetadata.Setup? = nil,
        relationships: PluginProductMetadata.Relationships? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.version = version
        self.minimumHostVersion = minimumHostVersion
        self.pluginKitVersion = pluginKitVersion
        self.capabilities = capabilities
        self.permissions = permissions
        self.package = package
        self.releaseNotesURL = releaseNotesURL
        self.category = category
        self.releaseChannel = releaseChannel
        self.localizedMetadata = localizedMetadata
        self.presentation = presentation
        self.discovery = discovery
        self.requirements = requirements
        self.privacy = privacy
        self.actions = actions
        self.setup = setup
        self.relationships = relationships
    }

    var localizedDisplayName: String {
        PluginLocalizationMatcher.localizedMetadata(from: localizedMetadata ?? [:])?.displayName ?? displayName
    }

    var localizedSummary: String {
        PluginLocalizationMatcher.localizedMetadata(from: localizedMetadata ?? [:])?.summary ?? summary
    }
}

struct PluginCatalogPackage: Codable, Equatable {
    let url: URL
    let sha256: String
    let size: Int64

    init(url: URL, sha256: String, size: Int64) {
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

struct PluginCatalogRevocation: Codable, Equatable {
    let id: String
    let versions: [String]
    let reason: String?

    init(id: String, versions: [String] = [], reason: String? = nil) {
        self.id = id
        self.versions = versions
        self.reason = reason
    }

    func matches(pluginID: String, version: String) -> Bool {
        id == pluginID && (versions.isEmpty || versions.contains(version))
    }
}

struct PluginCatalogSnapshot: Equatable {
    enum SourceKind: Equatable {
        case production
        case localDevelopment
    }

    let catalog: PluginCatalog
    let sourceURL: URL
    let sourceKind: SourceKind
    let loadedAt: Date

    var isLocalDevelopment: Bool {
        sourceKind == .localDevelopment
    }
}

enum PluginCatalogCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
