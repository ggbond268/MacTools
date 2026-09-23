import Foundation
import XCTest
@testable import DisplayBrightnessPlugin

@MainActor
final class UserDefaultsDisplayDisableStateStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UserDefaultsDisplayDisableStateStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A built-in display switched off by an earlier version must stay restorable after upgrade.
    func testMigratesLegacyBuiltInSnapshotToRecord() throws {
        let legacyJSON = """
        {
          "createdAt": 1,
          "builtInDisplayID": 1,
          "vendorNumber": 1552,
          "modelNumber": 41040,
          "serialNumber": 1,
          "survivorDisplayIDs": [2],
          "survivorIdentities": [{ "id": 2, "vendorNumber": 1552, "modelNumber": 41013, "serialNumber": 153 }],
          "originalMainDisplayID": 2
        }
        """
        userDefaults.set(Data(legacyJSON.utf8), forKey: "DisplayBrightness.DisplayDisableRecoverySnapshot")

        let store = UserDefaultsDisplayDisableStateStore(userDefaults: userDefaults)

        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(record.displayID, 1)
        XCTAssertTrue(record.isBuiltin)
        XCTAssertEqual(record.serialNumber, 1)
        XCTAssertEqual(record.survivorIdentities.map(\.serialNumber), [153])
        XCTAssertFalse(record.restoreRequested)
        XCTAssertNil(userDefaults.data(forKey: "DisplayBrightness.DisplayDisableRecoverySnapshot"))
    }
}
