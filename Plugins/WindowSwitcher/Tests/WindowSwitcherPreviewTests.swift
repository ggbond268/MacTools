import AppKit
import XCTest
@testable import WindowSwitcherPlugin

@MainActor
final class WindowSwitcherPreviewTests: XCTestCase {
    func testExactCaptureWindowIDWins() {
        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99]
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: .zero, title: nil, layer: 0, windowID: 7),
            WindowSwitcherPreviewCandidate(processID: 42, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates), 0)
    }

    func testExactCaptureWindowIDRejectsUnrelatedProcess() {
        let entry = makeEntry(number: 7)
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 7),
        ]
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates))
    }

    func testCaptureFallsBackToUniqueOwnerGeometryWhenCompositorIDDiffers() {
        var entry = makeEntry(number: 7)
        entry.windowOwnerPID = 43
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 43, frame: entry.bounds, title: "Different capture title", layer: 0, windowID: 8),
            WindowSwitcherPreviewCandidate(processID: 43, frame: CGRect(x: 900, y: 20, width: 800, height: 600),
                                           title: "Other", layer: 0, windowID: 9),
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates), 0)
    }

    func testCaptureFallsBackToUniqueTitleForVerifiedHelperOwnedSurface() {
        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99, 100]
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
            WindowSwitcherPreviewCandidate(processID: 100, frame: entry.bounds, title: "Overlay", layer: 0, windowID: 9),
        ]
        XCTAssertEqual(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates), 0)
    }

    func testCaptureRejectsUnrelatedProcessWithSameTitleAndGeometry() {
        let entry = makeEntry(number: 7)
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
        ]
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates))
    }

    func testCaptureRejectsAmbiguousHelperSurfaces() {
        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99, 100]
        let candidates = [
            WindowSwitcherPreviewCandidate(processID: 99, frame: entry.bounds, title: "Steam", layer: 0, windowID: 8),
            WindowSwitcherPreviewCandidate(processID: 100, frame: entry.bounds, title: "Steam", layer: 0, windowID: 9),
        ]
        XCTAssertNil(WindowSwitcherPreview.matchingIndex(for: entry, candidates: candidates))
    }

    func testHelperAuthorizationChangeRejectsStaleCaptureAndRecapturesSelection() async throws {
        var capturedEntries: [WindowSwitcherAppEntry] = []
        var continuations: [CheckedContinuation<NSImage?, Never>] = []
        let preview = WindowSwitcherPreview(hasPermission: { true }, captureTimeout: .seconds(1),
            debounceDelay: .zero, capture: { entry in
                capturedEntries.append(entry)
                return await withCheckedContinuation { continuations.append($0) }
            })
        var receivedImages: [NSImage] = []
        preview.onChange = { image, _ in
            if let image { receivedImages.append(image) }
        }

        var entry = makeEntry(number: 7)
        entry.previewProcessIdentifiers = [99]
        preview.select(entry)
        try await waitUntil { continuations.count == 1 }

        entry.previewProcessIdentifiers = [100]
        preview.select(entry)
        let stale = NSImage(size: NSSize(width: 2, height: 2))
        continuations.removeFirst().resume(returning: stale)
        try await waitUntil { capturedEntries.count == 2 && continuations.count == 1 }

        let current = NSImage(size: NSSize(width: 3, height: 3))
        continuations.removeFirst().resume(returning: current)
        try await waitUntil { receivedImages.count == 1 }

        XCTAssertEqual(capturedEntries.map(\.previewProcessIdentifiers), [[99], [100]])
        XCTAssertTrue(receivedImages[0] === current)
        XCTAssertFalse(receivedImages.contains { $0 === stale })
    }

    private func makeEntry(number: CGWindowID) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(id: "steam", processIdentifier: 42,
            bundleIdentifier: "com.valvesoftware.steam", appName: "Steam", windowTitle: "Steam",
            icon: nil, windowElement: AXUIElementCreateApplication(42), isMinimized: false,
            windowNumber: number, shortcutToken: nil,
            bounds: CGRect(x: 20, y: 20, width: 800, height: 600))
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for preview state")
    }
}
