import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
private final class InventoryApplication {
    let identity = UUID()
    var application: WindowSwitcherAppCatalog.Application?
    var reads = 0
    var callbacks: [@MainActor @Sendable () -> Void] = []

    init(pid: pid_t) {
        application = .init(processIdentifier: pid, bundleIdentifier: "fixture", bundlePath: "/Fixture.app",
                            localizedName: "Fixture")
    }

    var source: WindowSwitcherApplicationInventory.Source {
        .init(identity: identity, load: { [self] in reads += 1; return application }, observe: { [self] callback in
            callbacks.append(callback)
            return []
        })
    }
}

@MainActor
final class WindowSwitcherApplicationInventoryTests: XCTestCase {
    func testApplicationIdentityAcceptsEqualWrappersAndRejectsReusedPID() {
        let original = InventoryIdentityObject(lifetime: 1)
        let sameApplication = InventoryIdentityObject(lifetime: 1)
        let replacement = InventoryIdentityObject(lifetime: 2)
        let key = WindowSwitcherApplicationIdentity(processIdentifier: 42, application: original)
        let equalKey = WindowSwitcherApplicationIdentity(processIdentifier: 42, application: sameApplication)
        let reusedPID = WindowSwitcherApplicationIdentity(processIdentifier: 42, application: replacement)
        XCTAssertEqual(key, equalKey)
        XCTAssertEqual(key.hashValue, equalKey.hashValue)
        XCTAssertNotEqual(key, reusedPID)
        let entries = [key: "original", reusedPID: "replacement"]
        XCTAssertEqual(entries[equalKey], "original")
        XCTAssertEqual(entries[reusedPID], "replacement")
    }

    func testApplicationIdentityAvoidsSharedObjectHashCollisionChain() {
        let objects = (1...200).map { InventoryIdentityObject(lifetime: $0) }
        XCTAssertEqual(Set(objects.map(\.hash)).count, 1)
        let keys = objects.enumerated().map {
            WindowSwitcherApplicationIdentity(processIdentifier: pid_t($0.offset + 1), application: $0.element)
        }
        XCTAssertEqual(Set(keys).count, objects.count)
        XCTAssertGreaterThan(Set(keys.map(\.hashValue)).count, objects.count / 2)
        // Different PIDs must be rejected before invoking Objective-C lifetime
        // equality, even if their internal object hashes all collide.
        XCTAssertEqual(objects.reduce(0) { $0 + $1.comparisons }, 0)
    }

    func testUnchangedInventoryDoesNotReloadApplicationProperties() {
        let app = InventoryApplication(pid: 42)
        let inventory = WindowSwitcherApplicationInventory(sourceProvider: { [app.source] })
        inventory.start()
        defer { inventory.stop() }
        let lifetime = inventory.applications.first?.lifetime
        for _ in 0..<100 {
            inventory.reconcile()
            XCTAssertEqual(inventory.applications.first?.lifetime, lifetime)
        }
        XCTAssertEqual(app.reads, 1)
        app.application?.isHidden = true
        app.callbacks[0]()
        XCTAssertEqual(app.reads, 2)
        XCTAssertEqual(inventory.applications.first?.isHidden, true)
        XCTAssertEqual(inventory.applications.first?.lifetime, lifetime)
    }

    func testPIDChangeCreatesNewLifetimeAndInvalidatesBothPIDs() {
        let app = InventoryApplication(pid: 42)
        let inventory = WindowSwitcherApplicationInventory(sourceProvider: { [app.source] })
        inventory.start()
        defer { inventory.stop() }
        let previous = inventory.applications.first?.lifetime
        var changed = Set<pid_t>()
        inventory.onChange = { changed.formUnion($0) }
        app.application?.processIdentifier = 43
        app.callbacks[0]()
        XCTAssertEqual(changed, [42, 43])
        XCTAssertNotEqual(inventory.applications.first?.lifetime, previous)
        app.application?.isActive = true
        app.callbacks[0]()
        XCTAssertEqual(inventory.applications.first?.isActive, true)
    }

    func testReplacementWithSamePIDAndMissingLaunchDateCannotReuseLifetime() {
        let first = InventoryApplication(pid: 42), second = InventoryApplication(pid: 42)
        var sources = [first.source]
        let inventory = WindowSwitcherApplicationInventory(sourceProvider: { sources })
        inventory.start()
        defer { inventory.stop() }
        let previous = inventory.applications.first?.lifetime
        sources = [second.source]
        inventory.reconcile()
        XCTAssertNotEqual(inventory.applications.first?.lifetime, previous)
        first.callbacks[0]()
        XCTAssertEqual(second.reads, 1)
        XCTAssertEqual(inventory.applications.count, 1)
    }

    func testStoppedAndRemovedObserversCannotReloadNewEntries() {
        let app = InventoryApplication(pid: 42)
        var sources = [app.source]
        let inventory = WindowSwitcherApplicationInventory(sourceProvider: { sources })
        inventory.start()
        let oldCallback = app.callbacks[0]
        sources = []
        inventory.reconcile()
        sources = [app.source]
        inventory.reconcile()
        oldCallback()
        XCTAssertEqual(app.reads, 2)
        inventory.stop()
        inventory.start()
        defer { inventory.stop() }
        app.callbacks[1]()
        XCTAssertEqual(app.reads, 3)
    }
}

private final class InventoryIdentityObject: NSObject {
    let lifetime: Int
    private(set) var comparisons = 0

    init(lifetime: Int) { self.lifetime = lifetime }
    override var hash: Int { 0 }
    override func isEqual(_ object: Any?) -> Bool {
        comparisons += 1
        return (object as? InventoryIdentityObject)?.lifetime == lifetime
    }
}
