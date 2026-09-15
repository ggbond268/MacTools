import AppKit
import XCTest
@testable import WindowSwitcherPlugin

private final class WindowRecordResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [WindowSwitcherWindowRecord]?
    init(_ value: [WindowSwitcherWindowRecord]?) { self.value = value }
    func set(_ value: [WindowSwitcherWindowRecord]?) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> [WindowSwitcherWindowRecord]? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class WindowSwitcherWindowRecordsTests: XCTestCase {
    func testActiveSpaceMembershipCoversSeparateDisplaysAndFullscreen() {
        let displays: [[String: Any]] = [
            ["Current Space": ["ManagedSpaceID": NSNumber(value: 1)]],
            ["Current Space": ["ManagedSpaceID": NSNumber(value: 223)]]
        ]
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([223], displays: displays), true)
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219], displays: displays), false)
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219, 1], displays: displays), true)
        XCTAssertNil(WindowSwitcherSpaceMembership.intersectsActiveSpaces([], displays: displays))
        XCTAssertNil(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219], displays: [[:]]))
        XCTAssertNil(WindowSwitcherSpaceMembership.intersectsActiveSpaces([219], displays: displays + [[:]]))
        XCTAssertEqual(WindowSwitcherSpaceMembership.intersectsActiveSpaces([223], displays: displays + [[:]]), true)
    }

    func testFocusEventsRemainBalancedWhenPostingFailsOrCancellationArrives() {
        let cancellation = WindowSwitcherActionCancellation()
        var packets: [[UInt8]] = []
        WindowSwitcherWindowServer.sendFocusEvents(3133) { bytes in
            packets.append(bytes)
            cancellation.cancel()
            return -1
        }
        XCTAssertEqual(packets.map { $0[8] }, [1, 2])
        for packet in packets {
            XCTAssertEqual(packet.count, 256)
            XCTAssertEqual(packet[4], 248)
            XCTAssertEqual(packet[58], 16)
            packet.withUnsafeBytes {
                XCTAssertEqual($0.loadUnaligned(fromByteOffset: 60, as: CGWindowID.self), 3133)
                let point = $0.loadUnaligned(fromByteOffset: 32, as: CGPoint.self)
                XCTAssertEqual(point, CGPoint(x: 300_000, y: 300_000))
            }
        }
    }

    func testRetainedAXWindowCanRevalidateUsingItsSystemIDAndBounds() async {
        let bounds = CGRect(x: 0, y: 30, width: 800, height: 600)
        let record = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "Other Space", isOnScreen: nil, bounds: bounds, hasSpace: true)
        let response = WindowRecordResponse([record])
        let reader = WindowSwitcherWindowRecords(windowRecordProvider: { response.get() })
        defer { reader.stop() }
        var entry = WindowSwitcherAppEntry(id: "retained", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "Other Space", icon: nil,
            windowElement: AXUIElementCreateApplication(42), isMinimized: false, windowNumber: 7, shortcutToken: nil)
        entry.bounds = bounds
        XCTAssertNil(entry.windowBounds)
        let valid = await reader.isCurrentFallback(entry)
        XCTAssertTrue(valid)
        let differentlyNamed = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "WindowServer title", isOnScreen: nil, bounds: bounds, hasSpace: true)
        response.set([differentlyNamed])
        let differentTitle = await reader.isCurrentFallback(entry)
        XCTAssertTrue(differentTitle)
        response.set([WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "Other Space", isOnScreen: nil, bounds: bounds, hasSpace: false)])
        let orderedOut = await reader.isCurrentFallback(entry)
        XCTAssertFalse(orderedOut)
        response.set([])
        let closed = await reader.isCurrentFallback(entry)
        XCTAssertFalse(closed)
    }

    func testNativeBridgeRequiresExactWindowOwner() {
        let record = WindowSwitcherWindowRecord(windowNumber: 7, processIdentifier: 42,
            title: "Fixture", isOnScreen: nil, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(WindowSwitcherWindowServer.matches(7, pid: 42, records: [record]))
        XCTAssertFalse(WindowSwitcherWindowServer.matches(7, pid: 43, records: [record]))
        XCTAssertFalse(WindowSwitcherWindowServer.matches(8, pid: 42, records: [record]))
        XCTAssertFalse(WindowSwitcherWindowServer.matches(0, pid: 42, records: [record]))
    }

    func testFailedReadKeepsSnapshotButCannotAuthorizeActionAndEmptyReadClearsIt() async {
        let record = WindowSwitcherWindowRecord(windowNumber: 1, processIdentifier: 42, title: "Fixture", isOnScreen: true,
            bounds: CGRect(x: 0, y: 30, width: 800, height: 600))
        let response = WindowRecordResponse([record])
        let reader = WindowSwitcherWindowRecords(windowRecordProvider: { response.get() })
        defer { reader.stop() }
        let first = await reader.freshWindowRecordSnapshot()
        XCTAssertTrue(first.isFresh)
        XCTAssertEqual(first.records, [record])
        response.set(nil)
        let failed = await reader.freshWindowRecordSnapshot()
        XCTAssertFalse(failed.isFresh)
        XCTAssertEqual(failed.records, [record])
        let actionRecords = await reader.freshRecordsForActivation()
        XCTAssertTrue(actionRecords.isEmpty)
        response.set([])
        let empty = await reader.freshWindowRecordSnapshot()
        XCTAssertTrue(empty.isFresh)
        XCTAssertTrue(empty.records.isEmpty)
    }
}
