import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import LaunchControlPlugin

@MainActor
final class LaunchControlNotesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchControlNotesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> LaunchControlNotesStore {
        LaunchControlNotesStore(userDefaults: defaults)
    }

    func testNotesPersistIndependentlyAndCanBeCleared() {
        let store = makeStore()
        store.setNote("  a-note  ", for: "a")
        store.setNote("b-note", for: "b")
        XCTAssertEqual(makeStore().allNotes(), ["a": "a-note", "b": "b-note"])

        store.setNote("   \n  ", for: "a")
        XCTAssertEqual(makeStore().allNotes(), ["b": "b-note"])
        XCTAssertEqual(makeStore().note(for: "a"), "")

        store.setNote("", for: "b")
        XCTAssertTrue(makeStore().allNotes().isEmpty)
    }
}
