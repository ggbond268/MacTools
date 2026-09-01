import XCTest
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class SystemSettingAdapterTests: XCTestCase {
    func testFinderExtensionsUseGlobalDomainAndRestoreAbsentKeysAndLegacyOverride() async throws {
        let store = InMemoryFinderPreferencesStore(domains: [
            "com.apple.finder": ["AppleShowAllExtensions": .boolean(true)],
        ])
        let adapter = FinderExtensionsSystemSettingAdapter(store: store)
        let original = try await adapter.snapshot()
        XCTAssertEqual(original.value, .boolean(true))
        try await adapter.apply(.boolean(true))
        let applied = try await adapter.verify(.boolean(true))
        XCTAssertEqual(applied, .verified(.boolean(true)))
        XCTAssertEqual(store.domains[UserDefaults.globalDomain]?["AppleShowAllExtensions"], .boolean(true))
        XCTAssertNil(store.domains["com.apple.finder"]?["AppleShowAllExtensions"])
        let restored = try await adapter.restore(original)
        XCTAssertEqual(restored, .verified(.boolean(true)))
        XCTAssertNil(store.domains[UserDefaults.globalDomain]?["AppleShowAllExtensions"])
        XCTAssertEqual(store.domains["com.apple.finder"]?["AppleShowAllExtensions"], .boolean(true))
    }

    func testFinderDestinationReadsNativeCustomUnknownAndAbsentPreferences() async throws {
        let store = InMemoryFinderPreferencesStore()
        let adapter = FinderWindowDestinationSystemSettingAdapter(store: store)
        let absent = try await adapter.read()
        XCTAssertEqual(absent, .choice(id: "PfAF"))
        for option in FinderWindowDestination.options {
            store.domains["com.apple.finder"] = ["NewWindowTarget": .string(option.id)]
            let current = try await adapter.read()
            XCTAssertEqual(current, .choice(id: option.id))
        }
        let url = URL(filePath: "/private/tmp/My Projects/资料", directoryHint: .isDirectory)
        store.domains["com.apple.finder"] = [
            "NewWindowTarget": .string("PfLo"), "NewWindowTargetPath": .string(url.absoluteString),
        ]
        let custom = try await adapter.read()
        XCTAssertEqual(custom, .url(url))
        store.domains["com.apple.finder"]?["NewWindowTarget"] = .string("PfXX")
        let unknown = try await adapter.snapshot()
        XCTAssertEqual(unknown.value, .choice(id: "PfXX"))
        XCTAssertTrue(SystemSettingValueSchema.directoryChoice(options: FinderWindowDestination.options).accepts(unknown.value))
        do {
            try await adapter.apply(unknown.value)
            XCTFail("Unknown targets must be preserved, not offered as new writes")
        } catch { XCTAssertEqual(error as? SystemSettingAdapterError, .invalidValue) }
        let restored = try await adapter.restore(unknown)
        XCTAssertEqual(restored, .verified(unknown.value))
    }

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

    func testNativeFinderPreferencesStorePreservesTypesAndRemovesKeysInIsolatedDomain() throws {
        let domain = "cc.ggbond.mactools.tests.finder.\(UUID().uuidString)"
        let store = CoreFoundationFinderPreferencesStore()
        defer { try? store.write(["flag": .missing, "path": .missing], domain: domain) }
        try store.write(["flag": .boolean(false), "path": .string("file:///tmp/a%20b/")], domain: domain)
        let values = try store.read(keys: ["flag", "path", "absent"], domain: domain)
        XCTAssertEqual(values, ["flag": .boolean(false), "path": .string("file:///tmp/a%20b/"), "absent": .missing])
        try store.write(["flag": .missing], domain: domain)
        XCTAssertEqual(try store.read(keys: ["flag"], domain: domain)["flag"], .missing)
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

    func testProcessDefaultsStorePreservesValueTypesInWriteArguments() throws {
        XCTAssertEqual(
            try ProcessSystemDefaultsDomainStore.writeArguments(for: NSNumber(value: true)),
            ["-bool", "true"]
        )
        XCTAssertEqual(
            try ProcessSystemDefaultsDomainStore.writeArguments(for: NSNumber(value: 41)),
            ["-int", "41"]
        )
        XCTAssertEqual(
            try ProcessSystemDefaultsDomainStore.writeArguments(for: NSNumber(value: 41.5)),
            ["-float", "41.5"]
        )
        XCTAssertEqual(
            try ProcessSystemDefaultsDomainStore.writeArguments(for: "bottom"),
            ["-string", "bottom"]
        )
    }

    func testDockSystemEventsPreferenceBuildsAllowlistedLiveScripts() throws {
        XCTAssertTrue(
            try DockSystemEventsPreference.dockSize
                .script(for: .decimal(72))
                .contains("set dock size to 0.5")
        )
        XCTAssertTrue(
            try DockSystemEventsPreference.screenEdge
                .script(for: .choice(id: "right"))
                .contains("set screen edge to right")
        )
        XCTAssertTrue(
            try DockSystemEventsPreference.showRecents
                .script(for: .boolean(false))
                .contains("set show recents to false")
        )
        XCTAssertThrowsError(
            try DockSystemEventsPreference.screenEdge.script(for: .choice(id: "injected value"))
        )
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

    func testCompositeAdapterReportsMismatchAcrossDevices() async throws {
        let builtIn = DeterministicSystemSettingAdapter(value: .boolean(true))
        let bluetooth = DeterministicSystemSettingAdapter(value: .boolean(false))
        let adapter = CompositeBooleanSystemSettingAdapter(adapters: [builtIn, bluetooth])

        let mismatch = try await adapter.verify(.boolean(true))
        XCTAssertEqual(mismatch, .mismatch(actual: .boolean(true)))
        try await adapter.apply(.boolean(false))
        let verification = try await adapter.verify(.boolean(false))
        XCTAssertEqual(verification, .verified(.boolean(false)))
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

    func testDefaultsAdaptersApplyVerifyAndRollbackAccessibilityValues() async throws {
        let suiteName = "cc.ggbond.mactools.tests.accessibility.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keyboardZoom = DefaultsSystemSettingAdapter(
            defaults: defaults,
            key: "closeViewHotkeysEnabled",
            decode: { object in
                .boolean((object as? NSNumber)?.boolValue ?? false)
            },
            encode: { value in
                guard case let .boolean(enabled) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return NSNumber(value: enabled)
            }
        )
        let pointerSize = DefaultsSystemSettingAdapter(
            defaults: defaults,
            key: "mouseDriverCursorSize",
            decode: { object in
                .decimal((object as? NSNumber)?.doubleValue ?? 1)
            },
            encode: { value in
                guard case let .decimal(size) = value else {
                    throw SystemSettingAdapterError.invalidValue
                }
                return NSNumber(value: size)
            }
        )

        try await keyboardZoom.apply(.boolean(true))
        let keyboardZoomVerification = try await keyboardZoom.verify(.boolean(true))
        XCTAssertEqual(keyboardZoomVerification, .verified(.boolean(true)))
        try await keyboardZoom.rollback(to: .boolean(false))
        let rolledBackKeyboardZoom = try await keyboardZoom.read()
        XCTAssertEqual(rolledBackKeyboardZoom, .boolean(false))

        try await pointerSize.apply(.decimal(2.5))
        let pointerSizeVerification = try await pointerSize.verify(.decimal(2.5))
        XCTAssertEqual(pointerSizeVerification, .verified(.decimal(2.5)))
        try await pointerSize.rollback(to: .decimal(1))
        let rolledBackPointerSize = try await pointerSize.read()
        XCTAssertEqual(rolledBackPointerSize, .decimal(1))
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

    func testUniversalAccessAdapterRejectsSavedValueWhenActiveStateDidNotChange() async throws {
        var persistedValue = SystemSettingValue.boolean(false)
        let adapter = UniversalAccessSystemSettingAdapter(
            read: { persistedValue },
            readActive: { .boolean(false) },
            write: { persistedValue = $0 }
        )

        try await adapter.apply(.boolean(true))

        let verification = try await adapter.verify(.boolean(true))
        XCTAssertEqual(verification, .mismatch(actual: .boolean(false)))
    }

    func testTrackpadSecondaryClickAdapterAppliesAndVerifiesGestureChoice() async throws {
        var selection = "two-fingers"
        var writes: [String] = []
        let adapter = TrackpadSecondaryClickSystemSettingAdapter(
            read: { selection },
            write: {
                selection = $0
                writes.append($0)
            }
        )

        let initialValue = try await adapter.read()
        XCTAssertEqual(initialValue, .choice(id: "two-fingers"))
        try await adapter.apply(.choice(id: "bottom-left"))
        let verification = try await adapter.verify(.choice(id: "bottom-left"))
        XCTAssertEqual(verification, .verified(.choice(id: "bottom-left")))
        XCTAssertEqual(writes, ["bottom-left"])
    }

    func testLiveScrollSpeedAdapterMapsTenPointScaleToRuntimeRawValue() async throws {
        var rawSpeed = 0.3
        var writes: [Double] = []
        let adapter = LiveScrollSpeedSystemSettingAdapter(
            read: { rawSpeed },
            write: {
                rawSpeed = $0
                writes.append($0)
            }
        )

        let initialValue = try await adapter.read()
        XCTAssertEqual(initialValue, .decimal(3))
        try await adapter.apply(.decimal(7.5))
        let verification = try await adapter.verify(.decimal(7.5))
        XCTAssertEqual(verification, .verified(.decimal(7.5)))
        XCTAssertEqual(writes, [0.75])
        do {
            try await adapter.apply(.decimal(11))
            XCTFail("Expected an out-of-range value to fail")
        } catch {
            XCTAssertEqual(error as? SystemSettingAdapterError, .invalidValue)
        }
    }

    func testValueSchemasRejectWrongTypesAndOutOfRangeValues() {
        XCTAssertFalse(SystemSettingValueSchema.boolean.accepts(.integer(1)))
        XCTAssertFalse(SystemSettingValueSchema.integer(range: 1 ... 5, step: 1).accepts(.integer(6)))
        XCTAssertFalse(SystemSettingValueSchema.decimal(range: 0 ... 1, step: 0.1).accepts(.decimal(.infinity)))
        XCTAssertFalse(SystemSettingValueSchema.choice(options: [.init(id: "a", title: "A")]).accepts(.choice(id: "b")))
    }

    func testTypedValueRoundTripsEveryPortableCase() throws {
        let values: [SystemSettingValue] = [
            .boolean(false),
            .integer(4),
            .decimal(1.5),
            .choice(id: "left"),
            .string("value"),
            .url(URL(filePath: "/tmp", directoryHint: .isDirectory)),
            .color(.init(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)),
        ]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([SystemSettingValue].self, from: data), values)
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
