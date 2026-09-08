import Foundation
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsIconCacheTests: XCTestCase {
    func testStoresAndReturnsIconData() {
        let storage = ControlledIconCache()
        let cache = AppleShortcutsIconCache(cache: storage)
        let shortcutID = UUID()
        let iconData = Data([0x01, 0x02, 0x03])

        XCTAssertNil(cache.data(for: shortcutID))
        cache.store(iconData, for: shortcutID)

        XCTAssertEqual(cache.data(for: shortcutID), iconData)
        XCTAssertEqual(storage.cost(for: shortcutID), iconData.count)
    }

    func testRemoveAllDiscardsEveryCachedIcon() {
        let cache = AppleShortcutsIconCache(cache: ControlledIconCache())
        let firstID = UUID()
        let secondID = UUID()
        cache.store(Data([0x01]), for: firstID)
        cache.store(Data([0x02]), for: secondID)
        XCTAssertEqual(cache.data(for: firstID), Data([0x01]))
        XCTAssertEqual(cache.data(for: secondID), Data([0x02]))

        cache.removeAll()

        XCTAssertNil(cache.data(for: firstID))
        XCTAssertNil(cache.data(for: secondID))
    }

    func testEvictedIconsAreMissingAndCanBeStoredAgain() {
        let storage = ControlledIconCache()
        let cache = AppleShortcutsIconCache(cache: storage)
        let shortcutID = UUID()
        cache.store(Data([0x01]), for: shortcutID)
        XCTAssertEqual(cache.data(for: shortcutID), Data([0x01]))

        storage.removeObject(forKey: shortcutID as NSUUID)

        XCTAssertNil(cache.data(for: shortcutID))
        cache.store(Data([0x02, 0x03]), for: shortcutID)
        XCTAssertEqual(cache.data(for: shortcutID), Data([0x02, 0x03]))
        XCTAssertEqual(storage.cost(for: shortcutID), 2)
    }

    func testReplacingAnIconUpdatesBytesAndCost() {
        let storage = ControlledIconCache()
        let cache = AppleShortcutsIconCache(cache: storage)
        let shortcutID = UUID()
        cache.store(Data([0x01]), for: shortcutID)
        cache.store(Data([0x02, 0x03]), for: shortcutID)

        XCTAssertEqual(cache.data(for: shortcutID), Data([0x02, 0x03]))
        XCTAssertEqual(storage.cost(for: shortcutID), 2)
    }

    func testConfiguresDefaultAndCustomCostLimits() {
        let defaultStorage = ControlledIconCache()
        _ = AppleShortcutsIconCache(cache: defaultStorage)
        XCTAssertEqual(defaultStorage.totalCostLimit, AppleShortcutsIconCache.defaultTotalCostLimit)
        let customStorage = ControlledIconCache()
        _ = AppleShortcutsIconCache(totalCostLimit: 123, cache: customStorage)
        XCTAssertEqual(customStorage.totalCostLimit, 123)
    }
}

/// Only this test double retains entries until explicit eviction. Tests must not assume that
/// real NSCache retains a value between setObject and object(forKey:) under memory pressure.
nonisolated final class ControlledIconCache: NSCache<NSUUID, NSData>, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NSUUID: (data: NSData, cost: Int)] = [:]

    override func object(forKey key: NSUUID) -> NSData? {
        lock.withLock { entries[key]?.data }
    }

    override func setObject(_ obj: NSData, forKey key: NSUUID, cost: Int) {
        lock.withLock { entries[key] = (obj, cost) }
    }

    override func removeObject(forKey key: NSUUID) {
        lock.withLock { _ = entries.removeValue(forKey: key) }
    }

    override func removeAllObjects() {
        lock.withLock { entries.removeAll() }
    }

    func cost(for id: UUID) -> Int? {
        lock.withLock { entries[id as NSUUID]?.cost }
    }
}
