import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherPublicationTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 30, width: 1000, height: 800)
    private func window(_ id: String, title: String, number: CGWindowID? = nil) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 42, bundleIdentifier: "fixture", appName: "Fixture", windowTitle: title,
            icon: nil, windowElement: AXUIElementCreateApplication(id == "A" ? 900001 : 900002), isMinimized: false,
            windowNumber: number, applicationLaunchDate: Date(timeIntervalSince1970: 100), shortcutToken: nil, bounds: bounds)
    }
    private func application() -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: "app", processIdentifier: 42, bundleIdentifier: "fixture", appName: "Fixture", windowTitle: nil,
            icon: nil, windowElement: nil, isMinimized: false, applicationLaunchDate: Date(timeIntervalSince1970: 100), shortcutToken: nil)
    }
    private func record(_ number: CGWindowID, _ title: String) -> WindowSwitcherWindowRecord {
        WindowSwitcherWindowRecord(windowNumber: number, processIdentifier: 42, title: title, isOnScreen: true, bounds: bounds)
    }

    func testConflictingTitleNeverBorrowsAnotherWindowsIdentityInEitherOrder() {
        let a = window("A", title: "Alpha"), b = window("B", title: "Beta")
        for input in [[a, b], [b, a]] {
            let rows = WindowSwitcherAppCatalog.mergeAllSpacesEntries(input, records: [record(1, "Alpha")])
            XCTAssertTrue(rows.allSatisfy { $0.windowNumber == nil })
            XCTAssertEqual(Set(rows.map(\.id)), ["A", "B"])
        }
    }

    func testFirstAXDiscoveryPreservesSelectedFallbackRowAndUniqueIDs() {
        var state = WindowSwitcherPublishedWindows()
        let records = [record(1, "Alpha"), record(2, "Beta")]
        state.update(snapshots: [42: [application()]], records: records, recordsAreFresh: true)
        let selectedID = state.entries.first { $0.windowNumber == 2 }!.id
        var session = WindowSwitcherSession(entries: state.entries, selectedID: selectedID, isPersistent: true, originalWindowID: nil)
        state.update(snapshots: [42: [window("new-B", title: "Beta", number: 2)]], records: records, recordsAreFresh: true)
        session.reconcile(state.entries)
        XCTAssertEqual(session.selectedID, selectedID)
        XCTAssertEqual(session.selected?.windowTitle, "Beta")
        XCTAssertEqual(session.selected?.workerWindowID, "new-B")
        XCTAssertEqual(Set(state.entries.map(\.id)).count, state.entries.count)
    }

    func testRecencyRetainsPublishedIdentityAcrossWorkerChanges() {
        var state = WindowSwitcherPublishedWindows()
        let records = [record(1, "Alpha")]
        state.update(snapshots: [42: [window("A", title: "Alpha", number: 1)]], records: records, recordsAreFresh: true)
        state.recency.record("A")
        state.update(snapshots: [42: [application()]], records: records, recordsAreFresh: true)
        XCTAssertEqual(state.recency.focusedID, "A")
        state.update(snapshots: [42: [window("new-A", title: "Alpha", number: 1)]], records: records, recordsAreFresh: true)
        XCTAssertEqual(state.recency.focusedID, "A")
        XCTAssertEqual(state.entries.first?.workerWindowID, "new-A")
        // A later transient ID lookup failure must not change the row either.
        state.update(snapshots: [42: [window("new-A", title: "Alpha")]], records: records, recordsAreFresh: true)
        XCTAssertEqual(state.entries.first?.id, "A")
    }

    func testFailedScanPreservesFallbackIdentityAndConfirmedClosureRemovesIt() {
        var state = WindowSwitcherPublishedWindows()
        let snapshots: [pid_t: [WindowSwitcherAppEntry]] = [42: [application()]]
        let records = [record(1, "Alpha")]
        state.update(snapshots: snapshots, records: records, recordsAreFresh: true)
        let original = state.entries[0].id
        state.update(snapshots: snapshots, records: records, recordsAreFresh: false)
        XCTAssertEqual(state.entries[0].id, original)
        XCTAssertTrue(state.entries[0].metadataUnavailable)
        state.update(snapshots: snapshots, records: records, recordsAreFresh: true)
        XCTAssertEqual(state.entries[0].id, original)
        XCTAssertFalse(state.entries[0].metadataUnavailable)
        state.update(snapshots: snapshots, records: [], recordsAreFresh: true)
        XCTAssertFalse(state.entries.contains { $0.id == original })
        XCTAssertTrue(state.knownWindowIDs[42]?.isEmpty != false)
    }

    func testExactIDsTakePrecedenceOverGeometryAndAreNeverDuplicated() {
        let a = window("A", title: "Alpha", number: 1)
        let b = window("B", title: "Beta")
        for input in [[a, b], [b, a]] {
            let rows = WindowSwitcherAppCatalog.mergeAllSpacesEntries(input, records: [record(1, "Beta")])
            XCTAssertEqual(rows.first { $0.id == "A" }?.windowNumber, 1)
            XCTAssertNil(rows.first { $0.id == "B" }?.windowNumber)
        }
    }
}
