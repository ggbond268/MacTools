import Foundation

public enum PluginPrivateDataKeychainIdentity {
    public static let encryptionKeyAccount = "encryption-key.v1"

    public static func service(
        pluginID: String,
        hostBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        "\(hostBundleIdentifier ?? "cc.ggbond.mactools").\(pluginID)"
    }
}

@MainActor
public struct PluginRuntimeContext {
    public let pluginID: String
    public let resourceBundle: Bundle
    public let resourceSubdirectory: String?
    public let storage: PluginStorage
    public let supportDirectory: URL?
    public let cacheDirectory: URL?
    public let temporaryDirectory: URL?

    public init(
        pluginID: String,
        resourceBundle: Bundle = .main,
        resourceSubdirectory: String? = nil,
        storage: PluginStorage? = nil,
        supportDirectory: URL? = nil,
        cacheDirectory: URL? = nil,
        temporaryDirectory: URL? = nil
    ) {
        self.pluginID = pluginID
        self.resourceBundle = resourceBundle
        self.resourceSubdirectory = resourceSubdirectory
        self.storage = storage ?? UserDefaultsPluginStorage(pluginID: pluginID)
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    public func resourceURL(forResource name: String, withExtension ext: String?) -> URL? {
        if let resourceSubdirectory,
           let url = resourceBundle.url(
               forResource: name,
               withExtension: ext,
               subdirectory: resourceSubdirectory
           ) {
            return url
        }

        return resourceBundle.url(forResource: name, withExtension: ext)
    }
}

@MainActor
public protocol PluginStorage {
    func object(forKey key: String) -> Any?
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func integer(forKey key: String) -> Int
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String)
}

@MainActor
public final class UserDefaultsPluginStorage: PluginStorage {
    private let pluginID: String
    private let userDefaults: UserDefaults

    public init(pluginID: String, userDefaults: UserDefaults = .standard) {
        self.pluginID = pluginID
        self.userDefaults = userDefaults
    }

    public func object(forKey key: String) -> Any? {
        userDefaults.object(forKey: storageKey(for: key))
    }

    public func data(forKey key: String) -> Data? {
        userDefaults.data(forKey: storageKey(for: key))
    }

    public func string(forKey key: String) -> String? {
        userDefaults.string(forKey: storageKey(for: key))
    }

    public func stringArray(forKey key: String) -> [String]? {
        userDefaults.stringArray(forKey: storageKey(for: key))
    }

    public func integer(forKey key: String) -> Int {
        userDefaults.integer(forKey: storageKey(for: key))
    }

    public func bool(forKey key: String) -> Bool {
        userDefaults.bool(forKey: storageKey(for: key))
    }

    public func set(_ value: Any?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }

        userDefaults.set(value, forKey: storageKey(for: key))
    }

    public func removeObject(forKey key: String) {
        userDefaults.removeObject(forKey: storageKey(for: key))
    }

    public func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        let scopedKey = storageKey(for: key)

        guard userDefaults.object(forKey: scopedKey) == nil,
              let legacyValue = userDefaults.object(forKey: legacyKey)
        else {
            return
        }

        userDefaults.set(legacyValue, forKey: scopedKey)
        userDefaults.removeObject(forKey: legacyKey)
    }

    private func storageKey(for key: String) -> String {
        "plugin.\(pluginID).\(key)"
    }

    public static func removeAllValues(pluginID: String, userDefaults: UserDefaults = .standard) {
        let prefix = "plugin.\(pluginID)."

        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            userDefaults.removeObject(forKey: key)
        }
    }
}
