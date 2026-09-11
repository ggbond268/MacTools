import Foundation
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class InMemoryFinderPreferencesStore: FinderPreferencesStoring {
    var domains: [String: [String: SystemSettingStoredPreference]]
    var failNextWriteAfterFirstKey = false
    var ignoreNextPathWrite = false
    private(set) var writes: [String] = []

    init(domains: [String: [String: SystemSettingStoredPreference]] = [:]) {
        self.domains = domains
    }

    func read(keys: [String], domain: String) throws -> [String: SystemSettingStoredPreference] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, domains[domain]?[$0] ?? .missing) })
    }

    func write(_ values: [String: SystemSettingStoredPreference], domain: String) throws {
        for key in values.keys.sorted() {
            writes.append("\(domain).\(key)")
            if ignoreNextPathWrite, key == "NewWindowTargetPath" {
                ignoreNextPathWrite = false
                continue
            }
            if values[key] == .missing { domains[domain, default: [:]][key] = nil }
            else { domains[domain, default: [:]][key] = values[key] }
            if failNextWriteAfterFirstKey {
                failNextWriteAfterFirstKey = false
                throw SystemSettingAdapterError.writeFailed("Injected partial write")
            }
        }
    }
}

@MainActor
final class MacSettingsTestStorage: PluginStorage {
    private var values: [String: Any] = [:]
    var failingNextWriteKey: String?
    var failingWriteKeys: Set<String> = []

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        if failingWriteKeys.contains(key) { return }
        if failingNextWriteKey == key {
            failingNextWriteKey = nil
            return
        }
        values[key] = value
    }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values[legacyKey] = nil
    }
}

@MainActor
final class FirstReadSuspendingSystemSettingAdapter: SystemSettingAdapter {
    var value: SystemSettingValue
    private(set) var firstReadStarted = false
    var suspendNextRead: Bool
    private var firstReadContinuation: CheckedContinuation<SystemSettingValue, Error>?

    init(value: SystemSettingValue, suspendsFirstRead: Bool = true) {
        self.value = value
        self.suspendNextRead = suspendsFirstRead
    }

    func read() async throws -> SystemSettingValue {
        guard suspendNextRead else { return value }
        suspendNextRead = false
        firstReadStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            firstReadContinuation = continuation
        }
    }

    func resumeFirstRead(with value: SystemSettingValue) {
        firstReadContinuation?.resume(returning: value)
        firstReadContinuation = nil
    }

    func apply(_ value: SystemSettingValue) async throws {
        self.value = value
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        value == expectedValue ? .verified(value) : .mismatch(actual: value)
    }
}

@MainActor
final class RollbackFailingSystemSettingAdapter: SystemSettingAdapter {
    var value: SystemSettingValue = .boolean(false)
    var failsRollback = true
    private(set) var rollbackAttempts = 0

    func read() async throws -> SystemSettingValue { value }
    func apply(_ value: SystemSettingValue) async throws { self.value = value }
    func rollback(to value: SystemSettingValue) async throws {
        rollbackAttempts += 1
        if failsRollback { throw SystemSettingAdapterError.writeFailed("Injected rollback failure") }
        self.value = value
    }
}

@MainActor
func makeTestRecord(
    id: SystemSettingID,
    title: String,
    category: SystemSettingCategory = .finder,
    schema: SystemSettingValueSchema = .boolean,
    defaultValue: SystemSettingValue = .boolean(false),
    executionClass: SystemSettingExecutionClass = .directVerified,
    requirements: SystemSettingRequirements = .init(),
    portability: SystemSettingPortability = .portable,
    isSensitive: Bool = false,
    canRollback: Bool = true,
    verificationAvailable: Bool = true,
    adapter: any SystemSettingAdapter
) -> SystemSettingRecord {
    SystemSettingRecord(
        definition: SystemSettingDefinition(
            id: id,
            title: title,
            description: "Test description for \(title)",
            category: category,
            systemImage: "gearshape",
            schema: schema,
            defaultValue: defaultValue,
            executionClass: executionClass,
            requirements: requirements,
            portability: portability,
            isSensitive: isSensitive,
            canReset: true,
            canRollback: canRollback,
            verificationAvailable: verificationAvailable,
            searchTerms: [title, "test alias"],
            destination: .init(pane: "com.apple.Keyboard-Settings.extension", anchor: nil),
            implementationNote: "Deterministic test adapter."
        ),
        adapter: adapter
    )
}

@MainActor
func makeTestCatalog(_ records: [SystemSettingRecord]) -> SystemSettingCatalog {
    try! SystemSettingCatalog(records: records)
}
