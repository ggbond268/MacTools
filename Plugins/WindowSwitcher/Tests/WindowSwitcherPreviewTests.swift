import AppKit
import ApplicationServices
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherPreviewTests: XCTestCase {

    func testHungCaptureTimesOutWithoutStartingReplacementUntilItFinishes() async {
        var resumes: [CheckedContinuation<NSImage?, Never>] = []
        var captured: [String] = [], message: String?
        let preview = WindowSwitcherPreview(hasPermission: { true }, captureTimeout: .milliseconds(80), capture: { entry in
            captured.append(entry.id)
            return await withCheckedContinuation { resumes.append($0) }
        })
        preview.onChange = { _, value in message = value }
        preview.select(entry("a"))
        await eventually { message != nil }
        preview.cancel(); preview.select(entry("b"))
        XCTAssertNotNil(message)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(captured, ["a"])
        resumes.removeFirst().resume(returning: nil)
        await eventually { captured == ["a", "b"] }
        resumes.removeFirst().resume(returning: nil)
        preview.cancel()
    }

    func testSuspendedCaptureDoesNotRetainPreviewOwner() async {
        var resume: CheckedContinuation<NSImage?, Never>?
        var preview: WindowSwitcherPreview? = WindowSwitcherPreview(hasPermission: { true }, capture: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        weak var owner = preview
        preview?.select(entry("a"))
        await eventually { resume != nil }
        preview = nil
        XCTAssertNil(owner)
        resume?.resume(returning: nil)
    }

    func testIdleDismissedCacheExpiresWithoutAnotherSelection() async {
        weak var cachedImage: NSImage?
        let preview = WindowSwitcherPreview(hasPermission: { true }, cacheLifetime: 0.08, capture: { _ in
            let image = NSImage(size: NSSize(width: 20, height: 10))
            cachedImage = image
            return image
        })
        preview.select(entry("a"))
        await eventually { cachedImage != nil }
        preview.cancel()
        XCTAssertNotNil(cachedImage)
        await eventually { cachedImage == nil }
    }

    private func entry(_ id: String) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: id, processIdentifier: 100, bundleIdentifier: "fixture", appName: "Fixture",
            windowTitle: id, icon: nil, windowElement: AXUIElementCreateApplication(100), isMinimized: false, shortcutToken: nil)
    }

    private func eventually(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testCachedSelectionAppearsImmediatelyWithoutRecaptureAndMetadataDoesNotRestart() async {
        var captures = 0
        let image = NSImage(size: NSSize(width: 20, height: 10))
        let preview = WindowSwitcherPreview(hasPermission: { true }, capture: { _ in captures += 1; return image })
        var delivered: NSImage?
        preview.onChange = { image, _ in delivered = image }
        preview.select(entry("cached"))
        await eventually { delivered != nil }
        preview.cancel()
        preview.select(entry("cached"))
        XCTAssertTrue(delivered === image)
        var changed = entry("cached")
        changed.bounds = CGRect(x: 100, y: 100, width: 100, height: 100)
        preview.select(changed)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(delivered === image)
    }

    func testCachedPreviewIsClearedOnPermissionRevocation() async {
        var granted = true
        var captures = 0
        var delivered: NSImage?
        let preview = WindowSwitcherPreview(hasPermission: { granted }, capture: { _ in
            captures += 1
            return NSImage(size: NSSize(width: 20, height: 10))
        })
        preview.onChange = { image, _ in delivered = image }
        preview.select(entry("cached"))
        await eventually { delivered != nil }
        granted = false
        preview.select(entry("cached"))
        XCTAssertNil(delivered)
        granted = true
        preview.select(entry("cached"))
        XCTAssertNil(delivered)
        await eventually { captures == 2 }
        preview.cancel()
    }

    func testPreviewResolutionKeepsPortraitAndLandscapeAspectRatioWithinBudget() {
        for size in [CGSize(width: 1200, height: 800), CGSize(width: 600, height: 1200), CGSize(width: 500, height: 300)] {
            let pixels = WindowSwitcherPreview.captureSize(for: CGRect(origin: .zero, size: size))
            XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 1600)
            XCTAssertEqual(pixels.width / pixels.height, size.width / size.height, accuracy: 0.002)
            XCTAssertGreaterThan(max(pixels.width, pixels.height), 600)
        }
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
    func testExactIDSelectsOverlappingWindowAndRejectsStaleID() {
        var target = entry("same")
        target.windowNumber = 2
        let first = WindowSwitcherPreviewCandidate(processID: 100, frame: target.bounds, title: "same", layer: 0, windowID: 1)
        var second = first
        second.windowID = 2
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: target, candidates: [first, second]), 1)
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: target, candidates: [first]))
        second.processID = 200
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: target, candidates: [second]))
    }

    func testTransientFailureRetriesWithoutChangingSelection() async {
        var captures = 0
        var delivered: NSImage?
        let preview = WindowSwitcherPreview(hasPermission: { true }, capture: { _ in
            captures += 1
            return captures < 2 ? nil : NSImage(size: NSSize(width: 2, height: 2))
        })
        preview.onChange = { image, _ in delivered = image }
        preview.select(entry("retry"))
        await eventually { delivered != nil }
        XCTAssertEqual(captures, 2)
        preview.cancel()
    }

    func testPermanentFailureStopsAfterThreeAttempts() async {
        var captures = 0
        var message: String?
        let preview = WindowSwitcherPreview(hasPermission: { true }, capture: { _ in captures += 1; return nil })
        preview.onChange = { _, value in message = value }
        preview.select(entry("unavailable"))
        await eventually { message != nil }
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(captures, 3)
        preview.cancel()
    }

}
