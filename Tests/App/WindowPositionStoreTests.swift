import XCTest
@testable import MacTools

@MainActor
final class WindowPositionStoreTests: XCTestCase {
    func testDefaultPositionIsDefaultAnchor() throws {
        let suiteName = "WindowPositionStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WindowPositionStore(userDefaults: defaults)
        XCTAssertEqual(store.position(for: .commandPalette), .defaultAnchor)
    }

    func testSaveAndRestoreCustomPosition() throws {
        let suiteName = "WindowPositionStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WindowPositionStore(userDefaults: defaults)
        let customPoint = CGPoint(x: 0.35, y: 0.82)
        store.savePosition(.custom(normalizedPoint: customPoint), for: .commandPalette)

        let loaded = store.position(for: .commandPalette)
        XCTAssertEqual(loaded, .custom(normalizedPoint: customPoint))
    }

    func testResetPositionRestoresDefaultAnchor() throws {
        let suiteName = "WindowPositionStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WindowPositionStore(userDefaults: defaults)
        store.savePosition(.custom(normalizedPoint: CGPoint(x: 0.1, y: 0.9)), for: .commandPalette)
        XCTAssertNotEqual(store.position(for: .commandPalette), .defaultAnchor)

        store.resetPosition(for: .commandPalette)
        XCTAssertEqual(store.position(for: .commandPalette), .defaultAnchor)
    }

    func testSavingDefaultAnchorCleansUpStoredKey() throws {
        let suiteName = "WindowPositionStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = WindowPositionStore(userDefaults: defaults)
        store.savePosition(.custom(normalizedPoint: CGPoint(x: 0.5, y: 0.5)), for: .commandPalette)
        XCTAssertNotNil(defaults.data(forKey: store.key(for: .commandPalette)))

        store.savePosition(.defaultAnchor, for: .commandPalette)
        XCTAssertNil(defaults.data(forKey: store.key(for: .commandPalette)))
        XCTAssertEqual(store.position(for: .commandPalette), .defaultAnchor)
    }
}
