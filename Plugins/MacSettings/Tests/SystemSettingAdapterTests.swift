import XCTest
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class SystemSettingAdapterTests: XCTestCase {

    func testFinderDestinationWritesAndVerifiesBothTargetAndPath() async throws {
        let store = InMemoryFinderPreferencesStore()
        let home = URL(filePath: "/private/tmp/Finder Home", directoryHint: .isDirectory)
        var validated: [URL] = []
        let adapter = FinderWindowDestinationSystemSettingAdapter(
            store: store, homeDirectory: home, validateDirectory: { validated.append($0) }
        )
        for option in FinderWindowDestination.options {
            try await adapter.apply(.choice(id: option.id))
            let result = try await adapter.verify(.choice(id: option.id))
            XCTAssertEqual(result, .verified(.choice(id: option.id)))
        }
        XCTAssertEqual(validated.count, 5, "Recents does not require a physical directory")
        XCTAssertEqual(store.domains["com.apple.finder"]?["NewWindowTargetPath"], .string(
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true).absoluteString
        ))
        store.domains["com.apple.finder"]?["NewWindowTargetPath"] = .string("file:///wrong/")
        let mismatch = try await adapter.verify(.choice(id: "PfID"))
        XCTAssertEqual(mismatch, .mismatch(actual: .choice(id: "PfID")), "Matching target alone is insufficient")
        try await adapter.apply(.choice(id: "PfAF"))
        XCTAssertNil(store.domains["com.apple.finder"]?["NewWindowTargetPath"])
    }

    func testFinderDestinationValidatesCustomDirectoryBeforeMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InMemoryFinderPreferencesStore()
        let adapter = FinderWindowDestinationSystemSettingAdapter(store: store)
        try await adapter.apply(.url(directory))
        let original = try await adapter.snapshot()
        for invalid in [URL(string: "https://example.com/folder")!, directory.appendingPathComponent("missing")] {
            let writeCount = store.writes.count
            do {
                try await adapter.apply(.url(invalid))
                XCTFail("Invalid or missing directories must not be written")
            } catch { }
            XCTAssertEqual(store.writes.count, writeCount)
        }
        let after = try await adapter.snapshot()
        XCTAssertEqual(after, original)
    }

    func testFinderSnapshotRejectsExtraPreferenceKeysBeforeWriting() async throws {
        let store = InMemoryFinderPreferencesStore()
        let adapter = FinderWindowDestinationSystemSettingAdapter(store: store)
        var snapshot = try await adapter.snapshot()
        snapshot.restoration?["UnrelatedPreference"] = .string("injected")
        do {
            _ = try await adapter.restore(snapshot)
            XCTFail("Restoration must only accept its exact allowlist")
        } catch { XCTAssertEqual(error as? SystemSettingAdapterError, .invalidValue) }
        XCTAssertTrue(store.writes.isEmpty)
        do {
            _ = try await adapter.restore(.init(value: .choice(id: "PfHm")))
            XCTFail("Legacy entries cannot promise exact rollback without their original keys")
        } catch { }
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testDomainDefaultsAdapterReadsAndWritesExternalSystemDomainStore() async throws {
        let store = InMemorySystemDefaultsDomainStore(
            domains: ["com.apple.dock": ["tilesize": NSNumber(value: 128.0)]]
        )
        let adapter = DefaultsSystemSettingAdapter(
            domain: "com.apple.dock",
            key: "tilesize",
            decode: { object in
                .decimal((object as? NSNumber)?.doubleValue ?? 48)
            },
            encode: { value in
                guard case let .decimal(size) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return NSNumber(value: size)
            },
            store: store
        )

        let initialValue = try await adapter.read()
        XCTAssertEqual(initialValue, .decimal(128))
        try await adapter.apply(.decimal(41))
        let verification = try await adapter.verify(.decimal(41))
        XCTAssertEqual(verification, .verified(.decimal(41)))
        XCTAssertEqual(store.writes.map(\.domain), ["com.apple.dock"])
        XCTAssertEqual(store.writes.map(\.key), ["tilesize"])
    }

    func testDockSystemEventsAdapterUsesLiveScriptAndPersistedVerification() async throws {
        let persisted = DeterministicSystemSettingAdapter(value: .decimal(48))
        persisted.queuedVerificationOverrides = [
            .mismatch(actual: .decimal(48)),
            .mismatch(actual: .decimal(48)),
        ]
        var scripts: [String] = []
        let adapter = DockSystemEventsSettingAdapter(
            persistedAdapter: persisted,
            preference: .dockSize,
            executeScript: { source in
                scripts.append(source)
            },
            persistenceDelay: {},
            verificationDelay: {}
        )

        try await adapter.apply(.decimal(96))

        XCTAssertEqual(scripts.count, 1)
        XCTAssertTrue(scripts[0].contains("set dock size to 0.7142857142857143"))
        XCTAssertEqual(persisted.appliedValues, [.decimal(96)])
        let verification = try await adapter.verify(.decimal(96))
        XCTAssertEqual(verification, .verified(.decimal(96)))
        XCTAssertTrue(persisted.queuedVerificationOverrides.isEmpty)
    }

    func testDeterministicAdapterCoversReadApplyVerifyAndRollback() async throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let initialValue = try await adapter.read()
        XCTAssertEqual(initialValue, .boolean(false))

        try await adapter.apply(.boolean(true))
        let appliedVerification = try await adapter.verify(.boolean(true))
        XCTAssertEqual(appliedVerification, .verified(.boolean(true)))
        XCTAssertEqual(adapter.appliedValues, [.boolean(true)])

        try await adapter.rollback(to: .boolean(false))
        XCTAssertEqual(adapter.rollbackValues, [.boolean(false)])
        let rolledBackValue = try await adapter.read()
        XCTAssertEqual(rolledBackValue, .boolean(false))
    }

    func testLiveTrackpadAdapterAppliesAndVerifiesHardwareAndPersistedValues() async throws {
        let builtIn = DeterministicSystemSettingAdapter(value: .boolean(false))
        let bluetooth = DeterministicSystemSettingAdapter(value: .boolean(false))
        let persisted = CompositeBooleanSystemSettingAdapter(adapters: [builtIn, bluetooth])
        var liveValue = false
        var liveWrites: [Bool] = []
        let adapter = LiveTrackpadBooleanSystemSettingAdapter(
            persistedAdapter: persisted,
            readLiveValue: { liveValue },
            writeLiveValue: { enabled in
                liveValue = enabled
                liveWrites.append(enabled)
            }
        )

        try await adapter.apply(.boolean(true))
        let applied = try await adapter.verify(.boolean(true))
        XCTAssertEqual(applied, .verified(.boolean(true)))

        try await adapter.rollback(to: .boolean(false))
        let rolledBack = try await adapter.verify(.boolean(false))
        XCTAssertEqual(rolledBack, .verified(.boolean(false)))
        XCTAssertEqual(liveWrites, [true, false])
    }

    func testUniversalAccessAdapterUsesLiveWriterThenVerifiesAndRollsBack() async throws {
        var persistedValue = SystemSettingValue.decimal(1)
        var activeValue = SystemSettingValue.decimal(1)
        var writes: [SystemSettingValue] = []
        let adapter = UniversalAccessSystemSettingAdapter(
            read: { persistedValue },
            readActive: { activeValue },
            write: { value in
                guard case .decimal = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                writes.append(value)
                persistedValue = value
                activeValue = value
            }
        )

        try await adapter.apply(.decimal(2.5))
        let verification = try await adapter.verify(.decimal(2.5))
        XCTAssertEqual(verification, .verified(.decimal(2.5)))

        try await adapter.rollback(to: .decimal(1))
        let rolledBack = try await adapter.read()
        XCTAssertEqual(rolledBack, .decimal(1))
        XCTAssertEqual(writes, [.decimal(2.5), .decimal(1)])
    }

    func testValueSchemasRejectWrongTypesAndOutOfRangeValues() {
        XCTAssertFalse(SystemSettingValueSchema.boolean.accepts(.integer(1)))
        XCTAssertFalse(SystemSettingValueSchema.integer(range: 1 ... 5, step: 1).accepts(.integer(6)))
        XCTAssertFalse(SystemSettingValueSchema.decimal(range: 0 ... 1, step: 0.1).accepts(.decimal(.infinity)))
        XCTAssertFalse(SystemSettingValueSchema.choice(options: [.init(id: "a", title: "A")]).accepts(.choice(id: "b")))
    }

    func testExistingProviderAdapterExecutesThroughCanonicalHostContext() async throws {
        var executedReference: ActionReference?
        let context = PluginActionExecutionHostContext(
            item: { _ in nil },
            execute: { reference, _ in
                executedReference = reference
                return .succeeded(message: nil)
            }
        )
        let adapter = ExistingPluginActionSettingAdapter(
            reader: { .boolean(false) },
            reference: { value in
                guard case let .boolean(enabled) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return ActionReference(
                    key: ActionKey(providerID: "existing-provider", actionID: "set-enabled"),
                    parameters: try ActionParameterSet(["enabled": .boolean(enabled)])
                )
            },
            context: { context }
        )

        try await adapter.apply(.boolean(true))

        XCTAssertEqual(executedReference?.key.providerID, "existing-provider")
        XCTAssertEqual(executedReference?.parameters["enabled"], .boolean(true))
    }
}

@MainActor
private final class InMemorySystemDefaultsDomainStore: SystemDefaultsDomainStoring {
    struct Write {
        let domain: String
        let key: String
    }

    private var domains: [String: [String: Any]]
    private(set) var writes: [Write] = []

    init(domains: [String: [String: Any]]) {
        self.domains = domains
    }

    func object(forKey key: String, inDomain domain: String) throws -> Any? {
        domains[domain]?[key]
    }

    func set(_ object: Any, forKey key: String, inDomain domain: String) throws {
        domains[domain, default: [:]][key] = object
        writes.append(Write(domain: domain, key: key))
    }
}
