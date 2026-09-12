import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherPublicationTests: XCTestCase {

    func testImmediateAXReplacementDoesNotInheritReusedWindowNumber() {
        var state = WindowSwitcherPublishedWindows()
        state.update(snapshots: [42: [window("A", title: "Old", number: 1)]], records: [record(1, "Old")], recordsAreFresh: true)
        let old = state.entries[0].id
        state.recency.record(old)
        state.update(snapshots: [42: [window("B", title: "New", number: 1)]], records: [record(1, "New")], recordsAreFresh: true)
        XCTAssertNotEqual(state.entries[0].id, old)
        XCTAssertNotEqual(state.recency.focusedID, old)
        XCTAssertEqual(state.entries[0].workerWindowID, "B")
    }

    func testOrderedOutNamedSurfaceIsExcludedWithoutDroppingOtherSpaceOrAXWindows() {
        var hidden = record(10, "Hidden utility"); hidden.hasSpace = false
        hidden = WindowSwitcherWindowRecord(windowNumber: hidden.windowNumber, processIdentifier: 42, title: hidden.title, isOnScreen: false, bounds: bounds, hasSpace: false)
        let otherSpace = WindowSwitcherWindowRecord(windowNumber: 11, processIdentifier: 42, title: "Other Space", isOnScreen: false, bounds: bounds, hasSpace: true)
        let unknown = WindowSwitcherWindowRecord(windowNumber: 12, processIdentifier: 42, title: "Unknown", isOnScreen: false, bounds: bounds)
        let ax = window("A", title: "Live AX", number: 13)
        let axRecord = WindowSwitcherWindowRecord(windowNumber: 13, processIdentifier: 42, title: "Live AX", isOnScreen: false, bounds: bounds, hasSpace: false)
        let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries([application(), ax], records: [hidden, otherSpace, unknown, axRecord], confirmedAXWindowNumbers: [10])
        XCTAssertEqual(Set(merged.compactMap(\.windowNumber)), [11, 13])
    }

    func testWindowlessApplicationsNeverBecomeSelectableRows() {
        var state = WindowSwitcherPublishedWindows()
        let metadata: [pid_t: [WindowSwitcherAppEntry]] = [42: [application(confirmedWindowless: true)]]
        state.update(snapshots: metadata, records: [], recordsAreFresh: true)
        XCTAssertTrue(state.entries.isEmpty)
        // Metadata still permits discovery of real windows on another Space.
        let otherSpace = WindowSwitcherWindowRecord(windowNumber: 8, processIdentifier: 42,
            title: "Finder folder", isOnScreen: false, bounds: bounds, hasSpace: true)
        state.update(snapshots: metadata, records: [otherSpace], recordsAreFresh: true)
        XCTAssertEqual(state.entries.map(\.windowNumber), [8])
        state.update(snapshots: metadata, records: [], recordsAreFresh: true)
        XCTAssertTrue(state.entries.isEmpty)
    }

    func testHostWindowsBypassCGFallbackAndKeepRecencyAcrossRefresh() {
        var state = WindowSwitcherPublishedWindows()
        let host = WindowSwitcherAppEntry(id: "host", processIdentifier: 100,
            bundleIdentifier: "MacTools", appName: "MacTools", windowTitle: "Settings",
            icon: nil, windowElement: nil, isMinimized: false, windowNumber: 22, shortcutToken: nil)
        state.update(snapshots: [:], records: [], recordsAreFresh: false, localEntries: [host])
        state.recency.record(host.id)
        state.update(snapshots: [:], records: [], recordsAreFresh: true, localEntries: [host])
        XCTAssertEqual(state.entries.map(\.id), [host.id])
        XCTAssertFalse(state.entries[0].metadataUnavailable)
        XCTAssertEqual(state.recency.focusedID, host.id)
        state.update(snapshots: [:], records: [], recordsAreFresh: true)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertNil(state.recency.focusedID)
    }

    func testConfirmedWindowlessAppsRejectLeftoverVisibleSurfacesWithoutNameExceptions() {
        for bundle in ["com.google.Chrome", "com.apple.finder", "org.example.application"] {
            var state = WindowSwitcherPublishedWindows()
            let emptyApp = WindowSwitcherAppEntry(id: "app", processIdentifier: 42,
                bundleIdentifier: bundle, appName: "Fixture", windowTitle: nil, icon: nil,
                windowElement: nil, isMinimized: false, shortcutToken: nil)
            state.update(snapshots: [42: [emptyApp]], records: [record(9, "Leftover surface")], recordsAreFresh: true)
            XCTAssertTrue(state.entries.isEmpty, bundle)
        }
    }

    func testClosingLastAXWindowCannotResurrectItFromAVisibleCompositorSurface() {
        var state = WindowSwitcherPublishedWindows()
        let records = [record(1, "Document")]
        state.update(snapshots: [42: [window("A", title: "Document", number: 1)]], records: records, recordsAreFresh: true)
        let selected = state.entries[0].id
        state.recency.record(selected)
        // An empty AX list may also mean a Space transition. A failed CG read
        // must preserve the known row until fresh visibility evidence arrives.
        state.update(snapshots: [42: [application(confirmedWindowless: true)]], records: records, recordsAreFresh: false)
        XCTAssertEqual(state.entries.map(\.id), [selected])
        XCTAssertTrue(state.entries[0].metadataUnavailable)
        state.update(snapshots: [42: [application(confirmedWindowless: true)]], records: records, recordsAreFresh: true)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertNil(state.recency.focusedID)
    }

    func testNamedBackgroundSurfaceNeedsPositiveSpaceEvidence() {
        var state = WindowSwitcherPublishedWindows()
        let unknown = WindowSwitcherWindowRecord(windowNumber: 5, processIdentifier: 42,
            title: "Background helper", isOnScreen: false, bounds: bounds)
        state.update(snapshots: [42: [application()]], records: [unknown], recordsAreFresh: true)
        XCTAssertTrue(state.entries.isEmpty)
        var onSpace = unknown; onSpace.hasSpace = true
        state.update(snapshots: [42: [application(confirmedWindowless: true)]], records: [onSpace], recordsAreFresh: true)
        XCTAssertEqual(state.entries.map(\.windowNumber), [5])
        var removed = unknown; removed.hasSpace = false
        state.update(snapshots: [42: [application(confirmedWindowless: true)]], records: [removed], recordsAreFresh: true)
        XCTAssertTrue(state.entries.isEmpty)
    }

    func testIncompleteAXSnapshotPreservesKnownMinimizedAndUnavailableWindows() {
        var state = WindowSwitcherPublishedWindows()
        let minimized = WindowSwitcherAppEntry(id: "minimized", processIdentifier: 42,
            bundleIdentifier: "fixture", appName: "Fixture", windowTitle: "", icon: nil,
            windowElement: AXUIElementCreateApplication(900003), isMinimized: true, shortcutToken: nil)
        state.update(snapshots: [42: [minimized]], records: [], recordsAreFresh: true)
        XCTAssertEqual(state.entries.map(\.id), ["minimized"])
        var unreadable = minimized; unreadable.metadataUnavailable = true
        state.update(snapshots: [42: [unreadable]], records: [], recordsAreFresh: false)
        XCTAssertEqual(state.entries.map(\.id), ["minimized"])
        XCTAssertTrue(state.entries[0].metadataUnavailable)
    }

    private let bounds = CGRect(x: 0, y: 30, width: 1000, height: 800)
    private func window(_ id: String, title: String, number: CGWindowID? = nil) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 42, bundleIdentifier: "fixture", appName: "Fixture", windowTitle: title,
            icon: nil, windowElement: AXUIElementCreateApplication(id == "A" ? 900001 : 900002), isMinimized: false,
            windowNumber: number, applicationLaunchDate: Date(timeIntervalSince1970: 100), shortcutToken: nil, bounds: bounds)
    }
    private func application(confirmedWindowless: Bool = false) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: "app", processIdentifier: 42, bundleIdentifier: "fixture", appName: "Fixture", windowTitle: nil,
            icon: nil, windowElement: nil, isMinimized: false, applicationLaunchDate: Date(timeIntervalSince1970: 100), shortcutToken: nil,
            metadataUnavailable: !confirmedWindowless)
    }
    private func record(_ number: CGWindowID, _ title: String) -> WindowSwitcherWindowRecord {
        WindowSwitcherWindowRecord(windowNumber: number, processIdentifier: 42, title: title, isOnScreen: true, bounds: bounds)
    }

    func testUntitledSurfaceNeedsAXConfirmationEvenAfterBeingVisibleOrNamed() {
        var state = WindowSwitcherPublishedWindows()
        let snapshots: [pid_t: [WindowSwitcherAppEntry]] = [42: [application()]]
        state.update(snapshots: snapshots, records: [record(9, "Transient")], recordsAreFresh: true)
        XCTAssertTrue(state.entries.contains { $0.windowNumber == 9 })
        state.update(snapshots: snapshots, records: [record(9, "")], recordsAreFresh: true)
        XCTAssertFalse(state.entries.contains { $0.windowNumber == 9 })
        state.update(snapshots: [42: [window("real", title: "", number: 9)]], records: [record(9, "")], recordsAreFresh: true)
        let realID = state.entries[0].id
        let offspace = WindowSwitcherWindowRecord(windowNumber: 9, processIdentifier: 42, title: "", isOnScreen: false, bounds: bounds)
        state.update(snapshots: snapshots, records: [offspace], recordsAreFresh: true)
        XCTAssertEqual(state.entries[0].id, realID)
        XCTAssertEqual(state.entries[0].windowNumber, 9)
        state.update(snapshots: snapshots, records: [], recordsAreFresh: true)
        state.update(snapshots: snapshots, records: [record(9, "")], recordsAreFresh: true)
        XCTAssertFalse(state.entries.contains { $0.windowNumber == 9 }, "Closed window IDs must not authorize reused helper surfaces")
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
