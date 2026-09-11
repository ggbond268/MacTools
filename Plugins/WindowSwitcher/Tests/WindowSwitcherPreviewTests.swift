import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherPreviewTests: XCTestCase {
    private func entry(_ id: String) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 100, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: id, icon: nil, windowElement: AXUIElementCreateApplication(100), isMinimized: false, shortcutToken: nil)
    }

    private func eventually(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testUniqueGeometryMatchesWhenChromeExposesDifferentTitles() {
        var target = entry("a")
        target.bounds = CGRect(x: 20, y: 50, width: 1200, height: 900)
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 200, frame: target.bounds, title: "a", layer: 0),
            WindowSwitcherPreviewCandidate(processID: 100, frame: target.bounds, title: "a — Browser", layer: 0)
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: target, candidates: candidates), 1)
    }

    func testOverlappingIdenticalWindowsNeverChooseArbitraryPreview() {
        var target = entry("a")
        target.bounds = CGRect(x: 20, y: 50, width: 1200, height: 900)
        let candidate = WindowSwitcherPreviewCandidate(processID: 100, frame: target.bounds, title: "a", layer: 0)
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: target, candidates: [candidate, candidate]))
        var different = candidate
        different.title = "other window"
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: target, candidates: [different, candidate]), 1)
        different.layer = 1
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: target, candidates: [different]))
    }

    func testDeniedPermissionNeverStartsCapture() async {
        var captures = 0
        let preview = WindowSwitcherPreview(hasPermission: { false }, capture: { _ in captures += 1; return nil })
        var message: String?
        preview.onChange = { _, value in message = value }
        preview.select(entry("a"))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(captures, 0)
        XCTAssertNotNil(message)
    }

    func testOnlyLatestSelectionCapturesAfterInFlightResultIsDiscarded() async {
        var captured: [String] = []
        var resumes: [String: CheckedContinuation<NSImage?, Never>] = [:]
        let preview = WindowSwitcherPreview(hasPermission: { true }, capture: { entry in
            captured.append(entry.id)
            return await withCheckedContinuation { resumes[entry.id] = $0 }
        })
        let stale = NSImage(size: NSSize(width: 1, height: 1))
        let latest = NSImage(size: NSSize(width: 2, height: 2))
        var delivered: [NSImage] = []
        preview.onChange = { image, _ in if let image { delivered.append(image) } }
        preview.select(entry("a"))
        await eventually { captured == ["a"] }
        preview.select(entry("b")); preview.select(entry("c"))
        XCTAssertEqual(captured, ["a"])
        resumes.removeValue(forKey: "a")?.resume(returning: stale)
        await eventually { captured == ["a", "c"] }
        XCTAssertTrue(delivered.isEmpty)
        resumes.removeValue(forKey: "c")?.resume(returning: latest)
        await eventually { delivered.count == 1 }
        XCTAssertTrue(delivered.first === latest)
        preview.cancel()
    }

    func testPermissionRevokedDuringCaptureSuppressesCompletedImage() async {
        var granted = true
        var resume: CheckedContinuation<NSImage?, Never>?
        let preview = WindowSwitcherPreview(hasPermission: { granted }, capture: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        var image: NSImage?, message: String?
        preview.onChange = { image = $0; message = $1 }
        preview.select(entry("a"))
        await eventually { resume != nil }
        granted = false
        resume?.resume(returning: NSImage(size: NSSize(width: 2, height: 2)))
        await eventually { message != nil }
        XCTAssertNil(image)
        preview.cancel()
    }

    func testClosingChooserDiscardsPendingAndInFlightCaptures() async {
        var captured = 0
        var resume: CheckedContinuation<NSImage?, Never>?
        let preview = WindowSwitcherPreview(hasPermission: { true }, capture: { _ in
            captured += 1
            return await withCheckedContinuation { resume = $0 }
        })
        var image: NSImage?
        preview.onChange = { value, _ in image = value }
        preview.select(entry("a"))
        await eventually { resume != nil }
        preview.select(entry("b")); preview.cancel()
        resume?.resume(returning: NSImage(size: NSSize(width: 2, height: 2)))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(image)
        XCTAssertEqual(captured, 1)
    }
}
