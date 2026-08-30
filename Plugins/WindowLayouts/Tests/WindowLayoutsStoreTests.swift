import XCTest
import MacToolsPluginKit
@testable import WindowLayoutsPlugin

@MainActor
final class WindowLayoutsStoreTests: XCTestCase {
    func testPersistsCustomCommandsWithStableActionIDs() throws {
        let storage = StoreMemoryStorage()
        let store = WindowLayoutsStore(storage: storage)
        let command = try XCTUnwrap(store.addCustomCommand(name: "  Reading  "))

        let reloaded = WindowLayoutsStore(storage: storage)
        XCTAssertEqual(reloaded.customCommands.first?.id, command.id)
        XCTAssertEqual(reloaded.customCommands.first?.name, "Reading")
        XCTAssertEqual(reloaded.customCommands.first?.actionID, command.actionID)
    }

    func testPersistsAndResetsCommandFeedbackPreference() {
        let storage = StoreMemoryStorage()
        let store = WindowLayoutsStore(storage: storage)

        XCTAssertFalse(store.showsCommandFeedback)
        store.setShowsCommandFeedback(true)
        XCTAssertTrue(WindowLayoutsStore(storage: storage).showsCommandFeedback)

        store.reset()
        XCTAssertFalse(WindowLayoutsStore(storage: storage).showsCommandFeedback)
    }

    func testPersistsAndResetsModifierDragConfiguration() {
        let storage = StoreMemoryStorage()
        let store = WindowLayoutsStore(storage: storage)

        XCTAssertFalse(store.modifierDragEnabled)
        XCTAssertEqual(store.modifierDragModifiers, [.control, .option])

        store.setModifierDragModifiers([.shift, .command])
        store.setModifierDragEnabled(true)

        let reloaded = WindowLayoutsStore(storage: storage)
        XCTAssertTrue(reloaded.modifierDragEnabled)
        XCTAssertEqual(reloaded.modifierDragModifiers, [.shift, .command])

        reloaded.reset()
        let reset = WindowLayoutsStore(storage: storage)
        XCTAssertFalse(reset.modifierDragEnabled)
        XCTAssertEqual(reset.modifierDragModifiers, [.control, .option])
    }

    func testRejectsEmptyModifierDragCombination() {
        let store = WindowLayoutsStore(storage: StoreMemoryStorage())

        store.setModifierDragModifiers([])

        XCTAssertEqual(store.modifierDragModifiers, [.control, .option])
    }

    func testMigratesLegacyBrandedShortcutPresetNames() {
        let raycastStorage = StoreMemoryStorage()
        raycastStorage.set("raycast", forKey: "shortcut-preset")
        XCTAssertEqual(
            WindowLayoutsStore(storage: raycastStorage).shortcutPreset,
            .controlOption
        )
        XCTAssertEqual(
            raycastStorage.string(forKey: "shortcut-preset"),
            "control-option"
        )

        let rectangleStorage = StoreMemoryStorage()
        rectangleStorage.set("rectangle", forKey: "shortcut-preset")
        XCTAssertEqual(
            WindowLayoutsStore(storage: rectangleStorage).shortcutPreset,
            .controlOptionCommand
        )
        XCTAssertEqual(
            rectangleStorage.string(forKey: "shortcut-preset"),
            "control-option-command"
        )
    }

    func testUnknownFutureShortcutPresetFallsBackWithoutOverwritingIt() {
        let storage = StoreMemoryStorage()
        storage.set("future-preset", forKey: "shortcut-preset")

        XCTAssertEqual(WindowLayoutsStore(storage: storage).shortcutPreset, .none)
        XCTAssertEqual(storage.string(forKey: "shortcut-preset"), "future-preset")
    }

    func testDuplicateCreatesNewActionIdentitiesAndPreservesConfiguration() throws {
        let store = WindowLayoutsStore(storage: StoreMemoryStorage())
        var command = try XCTUnwrap(store.addCustomCommand(name: "Centered"))
        command.width = .points(900)
        command.anchor = .top
        XCTAssertTrue(store.updateCustomCommand(command))

        let copy = try XCTUnwrap(store.duplicateCustomCommand(id: command.id, copySuffix: "Copy"))
        XCTAssertNotEqual(copy.id, command.id)
        XCTAssertNotEqual(copy.actionID, command.actionID)
        XCTAssertEqual(copy.width, .points(900))
        XCTAssertEqual(copy.anchor, .top)
    }

    func testCustomRunLinkPolicyNotifiesSafetyRegistryOnlyForPersistedChanges() throws {
        let store = WindowLayoutsStore(storage: StoreMemoryStorage())
        var command = try XCTUnwrap(store.addCustomCommand(name: "Safety"))
        var safetyMutationCount = 0
        store.onSafetyPolicyMutation = { safetyMutationCount += 1 }

        command.name = "Renamed"
        XCTAssertTrue(store.updateCustomCommand(command))
        XCTAssertEqual(safetyMutationCount, 0)

        command.allowExternalInvocation = false
        XCTAssertTrue(store.updateCustomCommand(command))
        XCTAssertTrue(store.updateCustomCommand(command))
        XCTAssertEqual(safetyMutationCount, 1)
    }

    func testDuplicateKeepsCopySuffixAtNameLengthBoundary() throws {
        let store = WindowLayoutsStore(storage: StoreMemoryStorage())
        let source = try XCTUnwrap(store.addCustomCommand(
            name: String(repeating: "A", count: 80)
        ))

        let copy = try XCTUnwrap(store.duplicateCustomCommand(id: source.id, copySuffix: "Copy"))

        XCTAssertEqual(copy.name.count, 80)
        XCTAssertTrue(copy.name.hasSuffix(" Copy"))
        XCTAssertEqual(store.customCommands.count, 2)
    }

    func testCorruptLibraryIsQuarantinedAndEditingRecovers() throws {
        let storage = StoreMemoryStorage()
        let corruptData = Data("not-json".utf8)
        storage.set(corruptData, forKey: "library.v1")

        let store = WindowLayoutsStore(storage: storage)
        let command = try XCTUnwrap(store.addCustomCommand(name: "Recovered"))

        XCTAssertEqual(command.name, "Recovered")
        XCTAssertEqual(storage.data(forKey: "library.v1.quarantined"), corruptData)
        XCTAssertNotEqual(storage.data(forKey: "library.v1"), corruptData)
    }

    func testReloadNormalizesPersistedCommandGeometry() throws {
        let storage = StoreMemoryStorage()
        let command = WindowCustomCommand(
            name: "   ",
            width: .points(9_000),
            height: .fraction(0.001),
            anchor: .center,
            offsetX: 2_000,
            offsetY: -2_000
        )
        storage.set(
            try JSONEncoder().encode(StoreLibraryEnvelope(
                formatVersion: 1,
                customCommands: [command]
            )),
            forKey: "library.v1"
        )

        let store = WindowLayoutsStore(storage: storage)
        let normalized = try XCTUnwrap(store.customCommands.first)

        XCTAssertEqual(normalized.name, "Custom Layout")
        XCTAssertEqual(normalized.width, .points(3_000))
        XCTAssertEqual(normalized.height, .fraction(0.05))
        XCTAssertEqual(normalized.offsetX, 500)
        XCTAssertEqual(normalized.offsetY, -500)
        XCTAssertNil(storage.data(forKey: "library.v1.quarantined"))
        XCTAssertEqual(WindowLayoutsStore(storage: storage).customCommands, [normalized])
    }

    func testDuplicatePersistedCommandIDsAreQuarantined() throws {
        let storage = StoreMemoryStorage()
        let command = WindowCustomCommand(name: "One")
        let data = try JSONEncoder().encode(StoreLibraryEnvelope(
            formatVersion: 1,
            customCommands: [command, command]
        ))
        storage.set(data, forKey: "library.v1")

        let store = WindowLayoutsStore(storage: storage)

        XCTAssertTrue(store.customCommands.isEmpty)
        XCTAssertEqual(storage.data(forKey: "library.v1.quarantined"), data)
        XCTAssertNil(storage.data(forKey: "library.v1"))
    }

    func testNonfinitePersistedGeometryIsQuarantined() {
        let storage = StoreMemoryStorage()
        let id = UUID().uuidString
        let data = Data("""
        {"formatVersion":1,"customCommands":[{"id":"\(id)","name":"Bad","width":{"kind":"points","value":1e400},"height":{"kind":"current"},"anchor":"center","offsetX":0,"offsetY":0,"allowExternalInvocation":true}]}
        """.utf8)
        storage.set(data, forKey: "library.v1")

        let store = WindowLayoutsStore(storage: storage)

        XCTAssertTrue(store.customCommands.isEmpty)
        XCTAssertEqual(storage.data(forKey: "library.v1.quarantined"), data)
        XCTAssertNil(storage.data(forKey: "library.v1"))
    }
}

private struct StoreLibraryEnvelope: Codable {
    let formatVersion: Int
    let customCommands: [WindowCustomCommand]
}

@MainActor
private final class StoreMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
