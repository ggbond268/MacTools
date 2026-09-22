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
