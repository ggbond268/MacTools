import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherAllSpacesIntegrationTests: XCTestCase {
    private let bounds = CGRect(x: 10, y: 20, width: 800, height: 600)
    private func entry(_ id: String, element: AXUIElement? = nil, launch: Date? = Date(timeIntervalSince1970: 100)) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 42, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: "Window", icon: nil, windowElement: element, isMinimized: false,
            applicationLaunchDate: launch, shortcutToken: nil, bounds: bounds)
    }
    private func record(_ number: UInt32, onScreen: Bool = false) -> WindowSwitcherWindowRecord {
        WindowSwitcherWindowRecord(windowNumber: number, processIdentifier: 42, title: "Window", isOnScreen: onScreen, bounds: bounds)
    }

    func testMergeKeepsLiveAXIdentityAndOtherSpaceWindow() {
        let ax = AXUIElementCreateApplication(42)
        var live = entry("live-ax", element: ax)
        live.windowNumber = 1
        let entries = WindowSwitcherAppCatalog.mergeAllSpacesEntries([live],
            records: [record(1, onScreen: true), record(2)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.filter { $0.windowElement != nil }.map(\.id), ["live-ax"])
        let fallback = entries.first { $0.windowNumber == 2 }
        XCTAssertTrue(fallback?.isWindowEntry == true)
        XCTAssertEqual(fallback?.bounds, bounds)
    }

    func testFallbackIdentityDoesNotDependOnWindowOrderingOrInheritRestart() throws {
        let first = WindowSwitcherAppCatalog.mergeAllSpacesEntries([entry("app")], records: [record(1), record(2)])
        let reordered = WindowSwitcherAppCatalog.mergeAllSpacesEntries([entry("app")], records: [record(2), record(1)])
        XCTAssertEqual(Set(first.map(\.id)), Set(reordered.map(\.id)))
        let restarted = WindowSwitcherAppCatalog.mergeAllSpacesEntries([entry("app", launch: Date(timeIntervalSince1970: 200))], records: [record(1)])
        XCTAssertNotEqual(first.first?.id, restarted.first?.id)
        let noDateA = WindowSwitcherAppCatalog.mergeAllSpacesEntries([entry("lifetime-a", launch: nil)], records: [record(1)])
        let noDateB = WindowSwitcherAppCatalog.mergeAllSpacesEntries([entry("lifetime-b", launch: nil)], records: [record(1)])
        XCTAssertNotEqual(noDateA.first?.id, noDateB.first?.id)
    }

    func testFallbackResolutionRejectsAmbiguousAndUnavailableAXTargets() {
        let target = entry("fallback")
        let one = WindowSwitcherWindowSnapshot(id: "one", element: AXUIElementCreateApplication(42), title: "Window", minimized: false, bounds: bounds)
        let two = WindowSwitcherWindowSnapshot(id: "two", element: AXUIElementCreateApplication(43), title: "Window", minimized: false, bounds: bounds)
        XCTAssertEqual(WindowSwitcherAppCatalog.matchingFallbackWindowID(target, windows: [one]), "one")
        XCTAssertNil(WindowSwitcherAppCatalog.matchingFallbackWindowID(target, windows: [one, two]))
        var unavailable = one
        unavailable.unavailable = true
        XCTAssertNil(WindowSwitcherAppCatalog.matchingFallbackWindowID(target, windows: [unavailable]))
    }
    func testAmbiguousChromeGeometryNeverReplacesUsableAXIdentities() {
        let first = entry("first", element: AXUIElementCreateApplication(42))
        let second = entry("second", element: AXUIElementCreateApplication(43))
        let blankRecords = (1...3).map { WindowSwitcherWindowRecord(windowNumber: UInt32($0),
            processIdentifier: 42, title: "", isOnScreen: true, bounds: bounds) }
        let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries([first, second], records: blankRecords)
        XCTAssertEqual(merged.map(\.id), ["first", "second"])
        XCTAssertTrue(merged.allSatisfy { $0.windowElement != nil })
        XCTAssertTrue(merged.allSatisfy { $0.windowNumber == nil })
        var recency = WindowSwitcherRecency()
        recency.record("second")
        XCTAssertEqual(recency.sort(merged).first?.id, "second")
    }

    func testUniqueGeometryDoesNotBecomeAnAuthoritativeIdentity() {
        let original = entry("live", element: AXUIElementCreateApplication(42))
        let record = WindowSwitcherWindowRecord(windowNumber: 10, processIdentifier: 42,
            title: "Chrome exposes a different title", isOnScreen: true, bounds: bounds)
        let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries([original], records: [record])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, original.id)
        XCTAssertNil(merged.first?.windowNumber)
    }

    func testUnconfirmedGhosttySurfaceIsExcludedButUntitledAXWindowsRemain() {
        let terminal = entry("terminal", element: AXUIElementCreateApplication(42))
        let helper = WindowSwitcherWindowRecord(windowNumber: 99, processIdentifier: 42,
            title: "", isOnScreen: nil, bounds: CGRect(x: 0, y: 567, width: 500, height: 500))
        let untitled = WindowSwitcherAppEntry(id: "untitled", processIdentifier: 42, bundleIdentifier: "fixture",
            appName: "Fixture", windowTitle: "", icon: nil, windowElement: AXUIElementCreateApplication(43),
            isMinimized: true, shortcutToken: nil, bounds: helper.bounds)
        XCTAssertEqual(WindowSwitcherAppCatalog.mergeAllSpacesEntries([terminal], records: [helper]).map(\.id), ["terminal"])
        let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries([terminal, untitled], records: [helper])
        XCTAssertEqual(Set(merged.map(\.id)), ["terminal", "untitled"])
        XCTAssertTrue(merged.first { $0.id == "untitled" }?.isMinimized == true)
    }

    func testPreviouslyConfirmedUntitledWindowSurvivesAnotherSpaceWithStableIdentity() {
        let record = WindowSwitcherWindowRecord(windowNumber: 9, processIdentifier: 42, title: "", isOnScreen: false, bounds: bounds)
        let known = [UInt32(9): "original-ax"]
        let offspace = WindowSwitcherAppCatalog.mergeAllSpacesEntries([entry("app")], records: [record], knownWindowIDs: known, confirmedAXWindowNumbers: [9])
        XCTAssertEqual(offspace.map(\.id), ["original-ax"])
        XCTAssertNil(offspace.first?.windowElement)
        var rediscovered = entry("new-worker-id", element: AXUIElementCreateApplication(42))
        rediscovered.windowNumber = 9
        let returned = WindowSwitcherAppCatalog.mergeAllSpacesEntries([rediscovered], records: [record], knownWindowIDs: known, confirmedAXWindowNumbers: [9])
        XCTAssertEqual(returned.first?.id, "original-ax")
        XCTAssertEqual(returned.first?.workerWindowID, "new-worker-id")
    }

    func testExactFallbackIDCannotResolveToAnotherWindowAtSamePosition() {
        let target = WindowSwitcherAppEntry(id: "fallback", processIdentifier: 42, bundleIdentifier: "fixture",
            appName: "Fixture", windowTitle: "Window", icon: nil, windowElement: nil, isMinimized: false,
            windowNumber: 2, shortcutToken: nil, bounds: bounds)
        let window = WindowSwitcherWindowSnapshot(id: "one", element: AXUIElementCreateApplication(42), title: "Window", minimized: false, bounds: bounds)
        XCTAssertNil(WindowSwitcherAppCatalog.matchingFallbackWindowID(target, windows: [window], records: [record(1, onScreen: true)]))
        XCTAssertNil(WindowSwitcherAppCatalog.matchingFallbackWindowID(target, windows: [window], records: []))
    }

    func testFallbackWaitsForSpaceReadinessAndHonorsCancellation() async {
        let target = entry("fallback")
        let window = WindowSwitcherWindowSnapshot(id: "ready", element: AXUIElementCreateApplication(42), title: "Window", minimized: false, bounds: bounds)
        var reads = 0
        let result = await WindowSwitcherAppCatalog.waitForFallbackWindow(target, timeout: .milliseconds(400), scan: {
            reads += 1
            return WindowSwitcherScan(windows: reads < 3 ? [] : [window], unavailable: false)
        }, records: { [] })
        XCTAssertEqual(result, "ready")
        XCTAssertEqual(reads, 3)
        let task = Task {
            await WindowSwitcherAppCatalog.waitForFallbackWindow(target, scan: {
                WindowSwitcherScan(windows: [], unavailable: false)
            }, records: { [] })
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertNil(cancelled)
    }

    func testExactAXWindowNumbersDisambiguateIdenticalChromeWindows() {
        var first = entry("first", element: AXUIElementCreateApplication(42))
        var second = entry("second", element: AXUIElementCreateApplication(43))
        first.windowNumber = 1
        second.windowNumber = 2
        let records = (1...3).map { WindowSwitcherWindowRecord(windowNumber: UInt32($0),
            processIdentifier: 42, title: "", isOnScreen: $0 < 3, bounds: bounds) }
        let merged = WindowSwitcherAppCatalog.mergeAllSpacesEntries([first, second], records: records)
        XCTAssertEqual(merged.map(\.id), ["first", "second"])
        XCTAssertEqual(merged.map(\.windowNumber), [1, 2])
        let snapshots = [
            WindowSwitcherWindowSnapshot(id: "first", element: first.windowElement!, title: "Window", minimized: false, bounds: bounds, windowNumber: 1),
            WindowSwitcherWindowSnapshot(id: "second", element: second.windowElement!, title: "Window", minimized: false, bounds: bounds, windowNumber: 2)
        ]
        XCTAssertEqual(WindowSwitcherAppCatalog.matchingFallbackWindowID(second, windows: snapshots, records: records), "second")
    }

}
