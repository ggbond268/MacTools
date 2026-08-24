import AppKit
import CoreGraphics
import MacToolsPluginKit
import XCTest
@testable import MacTools
@testable import WindowLayoutsPlugin

@MainActor
final class SystemFocusedWindowResolverTests: XCTestCase {
    func testResolvesExactVisibleHostWindowWithoutAXWindowNumber() async throws {
        let hostWindow = makeHostWindow()
        defer { hostWindow.close() }
        let application = try XCTUnwrap(NSRunningApplication.current)
        let resolver = SystemFocusedWindowResolver(
            accessibilityTrusted: { true },
            frontmostTarget: {
                PluginFocusedWindowTarget(
                    application: application,
                    preferredWindowNumber: hostWindow.windowNumber
                )
            },
            hostWindow: { number in
                number == hostWindow.windowNumber ? hostWindow : nil
            }
        )

        let resolved = try await resolver.resolveFocusedWindow()

        XCTAssertTrue(resolved.hostWindow === hostWindow)
        XCTAssertNil(resolved.element)
        XCTAssertEqual(resolved.windowNumber, UInt32(hostWindow.windowNumber))
        XCTAssertEqual(
            resolved.identity,
            WindowIdentity(
                processIdentifier: application.processIdentifier,
                token: "window-number:\(hostWindow.windowNumber)"
            )
        )
    }

    func testRejectsMissingPreferredHostWindow() async throws {
        let application = try XCTUnwrap(NSRunningApplication.current)
        let resolver = SystemFocusedWindowResolver(
            accessibilityTrusted: { true },
            frontmostTarget: {
                PluginFocusedWindowTarget(
                    application: application,
                    preferredWindowNumber: 42
                )
            },
            hostWindow: { _ in nil }
        )

        do {
            _ = try await resolver.resolveFocusedWindow()
            XCTFail("Expected no focused window")
        } catch {
            XCTAssertEqual(error as? WindowLayoutError, .noFocusedWindow)
        }
    }

    func testHostWindowFrameAdapterUsesAccessibilityCoordinates() async throws {
        let hostWindow = makeHostWindow()
        defer { hostWindow.close() }
        let application = try XCTUnwrap(NSRunningApplication.current)
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(
                processIdentifier: application.processIdentifier,
                token: "window-number:\(hostWindow.windowNumber)"
            ),
            windowNumber: UInt32(hostWindow.windowNumber),
            canMove: true,
            canResize: true,
            hostWindow: hostWindow
        )
        let adapter = AccessibilityWindowFrameAdapter()
        let originalFrame = try await adapter.frame(of: handle)
        let targetFrame = CGRect(
            x: originalFrame.minX + 20,
            y: originalFrame.minY + 30,
            width: originalFrame.width + 40,
            height: originalFrame.height + 50
        )

        try await adapter.setFrame(targetFrame, of: handle, resize: true)

        let updatedFrame = try await adapter.frame(of: handle)
        XCTAssertEqual(updatedFrame.origin.x, targetFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(updatedFrame.origin.y, targetFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(updatedFrame.width, targetFrame.width, accuracy: 0.5)
        XCTAssertEqual(updatedFrame.height, targetFrame.height, accuracy: 0.5)
    }

    private func makeHostWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        PluginPresentationSafety.prepareForWindowOrdering(window)
        window.orderFront(nil)
        return window
    }
}

final class WindowFrameWriteTransactionTests: XCTestCase {
    private enum TestError: Error {
        case rejectedPosition
    }

    func testRollsBackSizeAndPositionWhenFinalPositionWriteFails() {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        var position = original.origin
        var size = original.size
        var rejectsTargetPosition = true

        XCTAssertThrowsError(try WindowFrameWriteTransaction.apply(
            originalFrame: original,
            targetFrame: target,
            setPosition: { value in
                if value == target.origin && rejectsTargetPosition {
                    rejectsTargetPosition = false
                    throw TestError.rejectedPosition
                }
                position = value
            },
            setSize: { size = $0 }
        ))

        XCTAssertEqual(position, original.origin)
        XCTAssertEqual(size, original.size)
    }

    func testReappliesSizeAfterPositionBeforeFinishingAtTargetPosition() throws {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        var writes: [String] = []

        try WindowFrameWriteTransaction.apply(
            originalFrame: original,
            targetFrame: target,
            setPosition: { _ in writes.append("position") },
            setSize: { _ in writes.append("size") }
        )

        XCTAssertEqual(writes, ["size", "position", "size", "position"])
    }

    func testExpandingWindowCanAcceptSizeAfterMovingToTargetOrigin() throws {
        let original = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        var observed = original
        var writes: [String] = []

        try WindowFrameWriteTransaction.apply(
            originalFrame: original,
            targetFrame: target,
            setPosition: {
                writes.append("position")
                observed.origin = $0
            },
            setSize: {
                writes.append("size")
                if observed.origin == target.origin {
                    observed.size = $0
                }
            },
            readFrame: { observed }
        )

        XCTAssertEqual(observed, target)
        XCTAssertEqual(writes, ["size", "position", "size", "position"])
    }

    func testRetriesMoveOnlyPositionWhenFirstWriteHasNotSettled() throws {
        let original = CGPoint(x: 10, y: 20)
        let target = CGPoint(x: 700, y: 20)
        var observed = original
        var writeCount = 0

        try WindowFrameWriteTransaction.applyPosition(
            originalPosition: original,
            targetPosition: target,
            setPosition: {
                writeCount += 1
                if writeCount > 1 {
                    observed = $0
                }
            },
            readPosition: { observed }
        )

        XCTAssertEqual(observed, target)
        XCTAssertEqual(writeCount, 2)
    }
}
