import CryptoKit
import Foundation
import MacToolsPluginKit
import Security

protocol ClipboardHistoryPersisting: Sendable {
    func prepare() throws
    func load() throws -> [ClipboardHistoryItem]
    func save(_ items: [ClipboardHistoryItem]) throws
    func saveChanges(
        _ items: [ClipboardHistoryItem],
        applying mutation: ClipboardHistoryMutation
    ) throws
    func reset() throws
    func removeAll() throws
}

/// Production SQLite storage uses this capability to remove History/Saved clips and snippets in
/// one transaction. It intentionally lives beside history persistence so the existing serialized
/// history worker remains the single writer for a mixed destructive operation.
protocol ClipboardUnifiedDeletionPersisting: ClipboardHistoryPersisting {
    func saveChanges(
        _ items: [ClipboardHistoryItem],
        applying mutation: ClipboardHistoryMutation,
        deletingSavedItemIDs: Set<UUID>
    ) throws
}

extension ClipboardHistoryPersisting {
    /// Legacy stores/test doubles can persist the worker's merged collection. Production SQLite
    /// writes only the affected rows; neither path accepts an obsolete controller snapshot.
    func saveChanges(
        _ items: [ClipboardHistoryItem],
        applying _: ClipboardHistoryMutation
    ) throws {
        try save(items)
    }
}

protocol ClipboardHistoryKeyStoring: Sendable {
    func loadKey() throws -> Data?
    func saveKey(_ data: Data) throws
    func deleteKey() throws
}

enum ClipboardHistoryKeyInitializationLock {
    static let shared = NSLock()
}

/// Serializes access to the Clipboard plugin's shared SQLite database and encryption key.
/// History and snippets keep independent controllers and worker queues, but destructive
/// database lifecycle operations must never race ordinary reads or writes from either store.
final class ClipboardDatabaseAccessCoordinator: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var isInvalidated = false

    func withAccess<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try lock.withLock(operation)
    }

    func withActiveAccess<Result>(_ operation: () throws -> Result) throws -> Result {
        try lock.withLock {
            guard !isInvalidated else { throw ClipboardHistoryStoreError.unavailableStorage }
            return try operation()
        }
    }

    func withExclusiveAccess<Result>(_ operation: () throws -> Result) rethrows -> Result {
        try lock.withLock(operation)
    }

    /// Permanently rejects future database/key access for this plugin instance. Uninstall invokes
    /// this synchronously before private-data cleanup, so a late task cannot recreate storage.
    func invalidate() {
        lock.withLock { isInvalidated = true }
    }
}

enum ClipboardHistoryStoreError: Error, Equatable, Sendable {
    case missingEncryptionKey
    case invalidEncryptionKey
    case invalidEnvelope
    case authenticationFailed
    case historyTooLarge
    case insufficientDiskSpace
    case unavailableStorage
    case keychain(OSStatus)
}

extension ClipboardHistoryStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingEncryptionKey:
            "找不到剪贴板历史的加密密钥。历史记录已停止收集。"
        case .invalidEncryptionKey:
            "剪贴板历史的加密密钥无效。历史记录已停止收集。"
        case .invalidEnvelope:
            "无法读取剪贴板历史。原始加密数据已保留。"
        case .authenticationFailed:
            "无法验证剪贴板历史。原始加密数据已保留。"
        case .historyTooLarge:
            "剪贴板历史超过安全存储上限。请清除现有历史记录。"
        case .insufficientDiskSpace:
            "可用磁盘空间不足，无法保存新的剪贴板历史。"
        case .unavailableStorage:
            "无法使用剪贴板历史的专用存储空间。"
        case .keychain:
            "无法访问用于保护剪贴板历史的钥匙串密钥。"
        }
    }
}

struct ClipboardHistoryKeychainStore: ClipboardHistoryKeyStoring {
    static let defaultService = PluginPrivateDataKeychainIdentity.service(pluginID: "clipboard")
    static let defaultAccount = PluginPrivateDataKeychainIdentity.encryptionKeyAccount

    let service: String
    let account: String

    init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClipboardHistoryStoreError.keychain(status)
        }
        return data
    }

    func saveKey(_ data: Data) throws {
        guard data.count == EncryptedClipboardHistoryStore.keyByteCount else {
            throw ClipboardHistoryStoreError.invalidEncryptionKey
        }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        guard status == errSecDuplicateItem else {
            throw ClipboardHistoryStoreError.keychain(status)
        }
        // Key creation is intentionally create-only. A concurrent initializer may
        // have installed the winning key after our preceding load returned nil.
        // Replacing that key would make data encrypted by the winner unreadable.
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClipboardHistoryStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class EncryptedClipboardHistoryStore: ClipboardHistoryPersisting, @unchecked Sendable {
    static let keyByteCount = 32
    static let maximumStoredFileByteCount = 96 * 1_024 * 1_024

    private struct Envelope: Codable {
        let schemaVersion: Int
        let items: [ClipboardHistoryItem]
    }

    private static let magic = Data([0x4D, 0x54, 0x48, 0x31]) // MTH1

    let fileURL: URL

    private let keyStore: any ClipboardHistoryKeyStoring
    private let fileManager: FileManager
    private let lock = NSLock()
    private var isInvalidated = false

    init(
        fileURL: URL,
        keyStore: any ClipboardHistoryKeyStoring = ClipboardHistoryKeychainStore(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.fileManager = fileManager
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareLocked()
    }

    func load() throws -> [ClipboardHistoryItem] {
        lock.lock()
        defer { lock.unlock() }

        guard !isInvalidated else {
            return []
        }
        let payloadExists = fileManager.fileExists(atPath: fileURL.path)
        if payloadExists {
            let storedFileSize = try fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
            guard (storedFileSize?.intValue ?? 0) <= Self.maximumStoredFileByteCount else {
                throw ClipboardHistoryStoreError.historyTooLarge
            }
        }
        try prepareLocked()
        guard payloadExists else { return [] }
        guard let keyData = try keyStore.loadKey() else {
            throw ClipboardHistoryStoreError.missingEncryptionKey
        }
        guard keyData.count == Self.keyByteCount else {
            throw ClipboardHistoryStoreError.invalidEncryptionKey
        }

        let storedData = try Data(contentsOf: fileURL)
        guard storedData.starts(with: Self.magic) else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        let combined = storedData.dropFirst(Self.magic.count)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: Data(combined))
        } catch {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        } catch {
            throw ClipboardHistoryStoreError.authenticationFailed
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: plaintext)
        } catch {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        guard envelope.schemaVersion == 2 else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        return envelope.items
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isInvalidated else { return }
        try prepareLocked()
        if items.isEmpty {
            try removePayloadFileIfPresent()
            return
        }
        let totalPayloadByteCount = items.reduce(into: 0) { total, item in
            total += item.payloadByteCount
        }
        guard totalPayloadByteCount <= ClipboardRetentionPolicy.maximumTotalPayloadByteCount else {
            throw ClipboardHistoryStoreError.historyTooLarge
        }

        let keyData: Data
        if let existing = try keyStore.loadKey() {
            keyData = existing
        } else {
            keyData = try Self.makeRandomKey()
            try keyStore.saveKey(keyData)
        }
        guard keyData.count == Self.keyByteCount else {
            throw ClipboardHistoryStoreError.invalidEncryptionKey
        }

        let envelope = Envelope(schemaVersion: 2, items: items)
        let plaintext = try JSONEncoder().encode(envelope)
        let sealedBox = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        guard let combined = sealedBox.combined else {
            throw ClipboardHistoryStoreError.invalidEnvelope
        }
        let storedData = Self.magic + combined
        guard storedData.count <= Self.maximumStoredFileByteCount else {
            throw ClipboardHistoryStoreError.historyTooLarge
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try storedData.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    func reset() throws {
        lock.lock()
        defer { lock.unlock() }

        // Cryptographically erase first. If file cleanup subsequently fails, the old payload is
        // still unreadable and a later reset can finish removing it without reusing the old key.
        try keyStore.deleteKey()
        try removePayloadFileIfPresent()
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }

        isInvalidated = true
        var firstError: Error?
        do {
            try removePayloadFileIfPresent()
        } catch {
            firstError = error
        }
        do {
            try keyStore.deleteKey()
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }

    private func removePayloadFileIfPresent() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func prepareLocked() throws {
        guard !isInvalidated else { return }
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let probeURL = directoryURL.appendingPathComponent(
                ".clipboard-history-write-probe-\(UUID().uuidString)",
                isDirectory: false
            )
            defer { try? fileManager.removeItem(at: probeURL) }
            try Data([0]).write(to: probeURL, options: .atomic)
        } catch {
            throw ClipboardHistoryStoreError.unavailableStorage
        }

        if let keyData = try keyStore.loadKey() {
            guard keyData.count == Self.keyByteCount else {
                throw ClipboardHistoryStoreError.invalidEncryptionKey
            }
            return
        }
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            throw ClipboardHistoryStoreError.missingEncryptionKey
        }
        try keyStore.saveKey(Self.makeRandomKey())
    }

    private static func makeRandomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ClipboardHistoryStoreError.keychain(status)
        }
        return Data(bytes)
    }
}

struct UnavailableClipboardHistoryStore: ClipboardHistoryPersisting {
    func prepare() throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func load() throws -> [ClipboardHistoryItem] {
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func save(_ items: [ClipboardHistoryItem]) throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func reset() throws {
        throw ClipboardHistoryStoreError.unavailableStorage
    }

    func removeAll() throws {}
}
