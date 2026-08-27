import CoreGraphics
import XCTest
import MacToolsPluginKit
@testable import WindowLayoutsPlugin

final class WindowModifierDragGestureTests: XCTestCase {
    func testSkipsIdlePointerMovementWithoutExactModifiers() {
        var gesture = WindowModifierDragGesture(requiredModifiers: [.control, .option])

        XCTAssertFalse(gesture.shouldProcessPointerMovement(modifiers: []))
        XCTAssertFalse(gesture.shouldProcessPointerMovement(modifiers: [.shift]))
        XCTAssertTrue(gesture.shouldProcessPointerMovement(modifiers: [.control, .option]))

        _ = gesture.modifiersChanged([.control, .option], pointer: .zero)
        XCTAssertTrue(
            gesture.shouldProcessPointerMovement(modifiers: []),
            "An armed gesture must still observe release when a flags event is missed"
        )

        _ = gesture.modifiersChanged([.control, .option, .shift], pointer: .zero)
        XCTAssertFalse(gesture.shouldProcessPointerMovement(modifiers: []))
    }

    func testActivatesAfterDeadZoneAndKeepsOneGeneration() {
        var gesture = WindowModifierDragGesture(
            requiredModifiers: [.control, .option],
            activationDistance: 4
        )

        XCTAssertNil(gesture.modifiersChanged([.control], pointer: .zero))
        XCTAssertNil(gesture.modifiersChanged([.control, .option], pointer: .zero))
        XCTAssertNil(gesture.pointerMoved(
            to: CGPoint(x: 3, y: 0),
            modifiers: [.control, .option]
        ))
        XCTAssertEqual(
            gesture.pointerMoved(
                to: CGPoint(x: 5, y: 0),
                modifiers: [.control, .option]
            ),
            .begin(generation: 1, origin: .zero, pointer: CGPoint(x: 5, y: 0))
        )
        XCTAssertEqual(
            gesture.pointerMoved(
                to: CGPoint(x: 8, y: 2),
                modifiers: [.control, .option]
            ),
            .update(generation: 1, pointer: CGPoint(x: 8, y: 2))
        )
    }

    func testExtraModifierCancelsAndRequiresNeutralReleaseBeforeRearming() {
        var gesture = WindowModifierDragGesture(requiredModifiers: [.control, .option])
        _ = gesture.modifiersChanged([.control, .option], pointer: .zero)
        _ = gesture.pointerMoved(to: CGPoint(x: 5, y: 0), modifiers: [.control, .option])

        XCTAssertEqual(
            gesture.modifiersChanged([.control, .option, .shift], pointer: CGPoint(x: 5, y: 0)),
            .cancel(generation: 1)
        )
        XCTAssertNil(gesture.modifiersChanged(
            [.control, .option],
            pointer: CGPoint(x: 5, y: 0)
        ))
        XCTAssertNil(gesture.pointerMoved(
            to: CGPoint(x: 20, y: 0),
            modifiers: [.control, .option]
        ))

        XCTAssertNil(gesture.modifiersChanged([], pointer: CGPoint(x: 20, y: 0)))
        XCTAssertNil(gesture.modifiersChanged(
            [.control, .option],
            pointer: CGPoint(x: 20, y: 0)
        ))
        XCTAssertEqual(
            gesture.pointerMoved(
                to: CGPoint(x: 25, y: 0),
                modifiers: [.control, .option]
            ),
            .begin(
                generation: 2,
                origin: CGPoint(x: 20, y: 0),
                pointer: CGPoint(x: 25, y: 0)
            )
        )
    }

    func testMouseButtonCancelsActiveDrag() {
        var gesture = WindowModifierDragGesture(requiredModifiers: [.control, .option])
        _ = gesture.modifiersChanged([.control, .option], pointer: .zero)
        _ = gesture.pointerMoved(to: CGPoint(x: 5, y: 0), modifiers: [.control, .option])

        XCTAssertEqual(gesture.mouseButtonPressed(), .cancel(generation: 1))
        XCTAssertNil(gesture.pointerMoved(
            to: CGPoint(x: 20, y: 0),
            modifiers: [.control, .option]
        ))
    }

    func testRequiredModifierReleaseCancelsActiveDrag() {
        var gesture = WindowModifierDragGesture(requiredModifiers: [.control, .option])
        _ = gesture.modifiersChanged([.control, .option], pointer: .zero)
        _ = gesture.pointerMoved(to: CGPoint(x: 5, y: 0), modifiers: [.control, .option])

        XCTAssertEqual(
            gesture.modifiersChanged([.control], pointer: CGPoint(x: 5, y: 0)),
            .cancel(generation: 1)
        )
        XCTAssertNil(gesture.pointerMoved(
            to: CGPoint(x: 20, y: 0),
            modifiers: [.control]
        ))
    }
}

final class WindowModifierDragActionQueueTests: XCTestCase {
    func testCoalescesPointerUpdatesAndPreservesBoundaryActions() {
        var queue = WindowModifierDragActionQueue()
        let epoch = queue.activate()
        let begin = WindowModifierDragGestureAction.begin(
            generation: 1,
            origin: .zero,
            pointer: CGPoint(x: 5, y: 0)
        )
        let latestUpdate = WindowModifierDragGestureAction.update(
            generation: 1,
            pointer: CGPoint(x: 30, y: 10)
        )
        let cancel = WindowModifierDragGestureAction.cancel(generation: 1)

        XCTAssertEqual(queue.enqueue(begin), epoch)
        XCTAssertNil(queue.enqueue(.update(
            generation: 1,
            pointer: CGPoint(x: 10, y: 5)
        )))
        XCTAssertNil(queue.enqueue(latestUpdate))
        XCTAssertNil(queue.enqueue(cancel))

        XCTAssertEqual(queue.nextAction(for: epoch), begin)
        XCTAssertEqual(queue.nextAction(for: epoch), latestUpdate)
        XCTAssertEqual(queue.nextAction(for: epoch), cancel)
        XCTAssertNil(queue.nextAction(for: epoch))
    }

    func testDeactivateInvalidatesQueuedActionsAcrossRestart() {
        var queue = WindowModifierDragActionQueue()
        let staleEpoch = queue.activate()
        XCTAssertEqual(
            queue.enqueue(.begin(generation: 1, origin: .zero, pointer: CGPoint(x: 5, y: 0))),
            staleEpoch
        )

        queue.deactivate()
        let currentEpoch = queue.activate()

        XCTAssertNotEqual(currentEpoch, staleEpoch)
        XCTAssertNil(queue.nextAction(for: staleEpoch))
        XCTAssertEqual(
            queue.enqueue(.begin(generation: 2, origin: .zero, pointer: CGPoint(x: 6, y: 0))),
            currentEpoch
        )
    }
}

@MainActor
final class WindowModifierDragSessionTests: XCTestCase {
    func testPropagatesMonitorStartupFailureAndLeavesSessionStopped() {
        let monitor = StubWindowModifierDragEventMonitor(
            startResult: .failure(.eventTapUnavailable)
        )
        let session = WindowModifierDragSession(eventMonitor: monitor)

        switch session.start() {
        case .success:
            XCTFail("Expected monitor startup to fail")
        case let .failure(error):
            XCTAssertEqual(error, .eventTapUnavailable)
        }
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(monitor.stopCount, 1)
    }
}

final class SystemWindowUnderPointerResolverTests: XCTestCase {
    func testSelectsFirstNormalVisibleWindowContainingPointer() {
        let behind = windowInfo(number: 2, ownerPID: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        let top = windowInfo(number: 1, ownerPID: 100, layer: 0, bounds: CGRect(x: 20, y: 20, width: 100, height: 100))

        let target = SystemWindowUnderPointerResolver.windowTarget(
            at: CGPoint(x: 50, y: 50),
            in: [top, behind]
        )

        XCTAssertEqual(target?.processIdentifier, 100)
        XCTAssertEqual(target?.windowNumber, 1)
    }

    func testSkipsNonwindowLayersAndTransparentWindows() {
        let overlay = windowInfo(number: 1, ownerPID: 100, layer: 10, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let transparent = windowInfo(number: 2, ownerPID: 200, layer: 0, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = windowInfo(number: 3, ownerPID: 300, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

        let target = SystemWindowUnderPointerResolver.windowTarget(
            at: CGPoint(x: 50, y: 50),
            in: [overlay, transparent, window]
        )

        XCTAssertEqual(target?.processIdentifier, 300)
        XCTAssertEqual(target?.windowNumber, 3)
    }

    @MainActor
    func testReportsNoWindowUnderPointerWhenNothingMatches() async {
        let resolver = SystemWindowUnderPointerResolver(
            accessibilityTrusted: { true },
            windowInfoProvider: { [] }
        )

        do {
            _ = try await resolver.resolveWindow(at: CGPoint(x: 50, y: 50))
            XCTFail("Expected the resolver to reject an empty pointer target")
        } catch {
            XCTAssertEqual(error as? WindowLayoutError, .noWindowUnderPointer)
        }
    }

    @MainActor
    func testPassesPointerLocationToExternalAccessibilityResolver() async throws {
        let expectedPoint = CGPoint(x: 50, y: 75)
        let window = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 123, token: "external-window"),
            canMove: true,
            canResize: true
        )
        let worker = StubExternalWindowResolver(window: window)
        let resolver = SystemWindowUnderPointerResolver(
            accessibilityTrusted: { true },
            windowInfoProvider: {
                [self.windowInfo(
                    number: 12,
                    ownerPID: 123,
                    layer: 0,
                    bounds: CGRect(x: 0, y: 0, width: 200, height: 200)
                )]
            },
            worker: worker
        )

        _ = try await resolver.resolveWindow(at: expectedPoint)
        let target = await worker.lastTarget()

        XCTAssertEqual(target?.processIdentifier, 123)
        XCTAssertEqual(target?.preferredWindowNumber, 12)
        XCTAssertEqual(target?.pointerLocation, expectedPoint)
    }

    private func windowInfo(
        number: Int,
        ownerPID: Int,
        layer: Int,
        alpha: Double = 1,
        bounds: CGRect
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: number,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds),
        ]
    }
}

final class WindowAccessibilityCancellationTests: XCTestCase {
    func testWindowScanChecksCancellationBetweenCandidates() async {
        let result = await Task {
            try firstCancellableMatch(in: [1, 2, 3]) { candidate in
                if candidate == 1 {
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                }
                return false
            }
        }.result

        guard case let .failure(error) = result else {
            return XCTFail("Expected cancellation before inspecting the next candidate")
        }
        XCTAssertTrue(error is CancellationError)
    }
}

@MainActor
final class WindowModifierDragControllerTests: XCTestCase {
    func testMovesCapturedWindowByPointerDeltaWithoutResizing() async throws {
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "window-number:7"),
            windowNumber: 7,
            canMove: true,
            canResize: true
        )
        let resolver = StubWindowUnderPointerResolver(window: handle)
        let frameIO = RecordingWindowFrameIO(
            frame: CGRect(x: 100, y: 200, width: 800, height: 600)
        )
        let writeExpectation = expectation(description: "window moved")
        let successExpectation = expectation(description: "move succeeded")
        frameIO.onWrite = { writeExpectation.fulfill() }
        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO
        )
        controller.onSuccess = { successExpectation.fulfill() }

        controller.begin(
            generation: 1,
            origin: CGPoint(x: 25, y: 40),
            pointer: CGPoint(x: 35, y: 55)
        )
        await fulfillment(of: [writeExpectation, successExpectation], timeout: 1)

        let write = try XCTUnwrap(frameIO.writes.last)
        XCTAssertEqual(write.frame, CGRect(x: 110, y: 215, width: 800, height: 600))
        XCTAssertFalse(write.resize)
        XCTAssertTrue(write.window === handle)
    }
}

@MainActor
private final class StubWindowUnderPointerResolver: WindowUnderPointerResolving {
    let window: AccessibilityWindowHandle

    init(window: AccessibilityWindowHandle) {
        self.window = window
    }

    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle {
        window
    }
}

private actor StubExternalWindowResolver: ExternalWindowResolving {
    private let window: AccessibilityWindowHandle
    private var targets: [ExternalFocusedWindowTarget] = []

    init(window: AccessibilityWindowHandle) {
        self.window = window
    }

    func resolveFocusedWindow(
        target: ExternalFocusedWindowTarget
    ) throws -> AccessibilityWindowHandle {
        targets.append(target)
        return window
    }

    func lastTarget() -> ExternalFocusedWindowTarget? {
        targets.last
    }
}

@MainActor
private final class RecordingWindowFrameIO: WindowFrameReading, WindowFrameWriting {
    struct Write {
        let frame: CGRect
        let window: AccessibilityWindowHandle
        let resize: Bool
    }

    let frame: CGRect
    var onWrite: () -> Void = {}
    private(set) var writes: [Write] = []

    init(frame: CGRect) {
        self.frame = frame
    }

    func frame(of window: AccessibilityWindowHandle) async throws -> CGRect {
        frame
    }

    func isValid(_ window: AccessibilityWindowHandle) async -> Bool {
        true
    }

    func setFrame(
        _ frame: CGRect,
        of window: AccessibilityWindowHandle,
        resize: Bool
    ) async throws {
        writes.append(Write(frame: frame, window: window, resize: resize))
        onWrite()
    }
}

nonisolated private final class StubWindowModifierDragEventMonitor: @unchecked Sendable,
    WindowModifierDragEventMonitoring
{
    let startResult: Result<Void, WindowModifierDragMonitorStartError>
    private(set) var isRunning = false
    private(set) var stopCount = 0

    init(startResult: Result<Void, WindowModifierDragMonitorStartError>) {
        self.startResult = startResult
    }

    func start(
        handler: WindowModifierDragEventHandler
    ) -> Result<Void, WindowModifierDragMonitorStartError> {
        if case .success = startResult {
            isRunning = true
        }
        return startResult
    }

    func stop() {
        isRunning = false
        stopCount += 1
    }
}
