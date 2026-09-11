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
