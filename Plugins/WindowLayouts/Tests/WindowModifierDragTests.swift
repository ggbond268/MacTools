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
        XCTAssertEqual(
            gesture.modifiersChanged([.control, .option], pointer: .zero),
            .arm(generation: 1, pointer: .zero)
        )
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
        XCTAssertEqual(
            gesture.modifiersChanged(
                [.control, .option],
                pointer: CGPoint(x: 20, y: 0)
            ),
            .arm(generation: 2, pointer: CGPoint(x: 20, y: 0))
        )
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

    func testKeyPressedCancelsAndBlocksGesture() {
        var gesture = WindowModifierDragGesture(requiredModifiers: [.control, .option])
        XCTAssertEqual(
            gesture.modifiersChanged([.control, .option], pointer: .zero),
            .arm(generation: 1, pointer: .zero)
        )
        XCTAssertEqual(gesture.keyPressed(), .cancel(generation: 1))
        XCTAssertNil(gesture.pointerMoved(
            to: CGPoint(x: 20, y: 0),
            modifiers: [.control, .option]
        ))
        XCTAssertNil(gesture.modifiersChanged([], pointer: .zero))
        XCTAssertEqual(
            gesture.modifiersChanged([.control, .option], pointer: .zero),
            .arm(generation: 2, pointer: .zero)
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

    func testArmsHUDAfterDelay() async throws {
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "win"),
            canMove: true,
            canResize: true
        )
        let resolver = StubWindowUnderPointerResolver(window: handle)
        let frameIO = RecordingWindowFrameIO(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let hud = SpyWindowModifierDragHUDPresenter()
        let armExpectation = expectation(description: "HUD armed")
        hud.onAction = {
            if case .present(.armed) = hud.actions.last {
                armExpectation.fulfill()
            }
        }
        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO,
            hudPresenter: hud,
            pointerLocation: { CGPoint(x: 50, y: 50) },
            armDelay: 0.05,
            showsIndicator: true,
            requiredModifiers: [.control, .option]
        )

        controller.arm(generation: 1, pointer: CGPoint(x: 50, y: 50))
        XCTAssertTrue(hud.actions.isEmpty, "HUD must not be presented immediately on arm")

        await fulfillment(of: [armExpectation], timeout: 1)
        XCTAssertEqual(hud.actions, [
            .present(.armed(modifiers: [.control, .option], pointer: CGPoint(x: 50, y: 50)))
        ])
    }

    func testCancelBeforeArmDelayPreventsHUD() async {
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "win"),
            canMove: true,
            canResize: true
        )
        let resolver = StubWindowUnderPointerResolver(window: handle)
        let frameIO = RecordingWindowFrameIO(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let hud = SpyWindowModifierDragHUDPresenter()
        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO,
            hudPresenter: hud,
            pointerLocation: { CGPoint(x: 50, y: 50) },
            armDelay: 0.05,
            showsIndicator: true,
            requiredModifiers: [.control, .option]
        )

        controller.arm(generation: 1, pointer: CGPoint(x: 50, y: 50))
        controller.cancel(generation: 1)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(hud.actions.contains(where: {
            if case .present = $0 { return true }
            return false
        }))
    }

    func testActiveTransitionPresentsActiveAndSchedulesDismiss() async throws {
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "win"),
            canMove: true,
            canResize: true
        )
        let resolver = StubWindowUnderPointerResolver(window: handle)
        let frameIO = RecordingWindowFrameIO(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let hud = SpyWindowModifierDragHUDPresenter()
        let activeExpectation = expectation(description: "HUD active")
        let dismissExpectation = expectation(description: "HUD dismissed")
        hud.onAction = {
            if case .present(.active) = hud.actions.last {
                activeExpectation.fulfill()
            } else if case .dismiss = hud.actions.last {
                dismissExpectation.fulfill()
            }
        }
        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO,
            hudPresenter: hud,
            pointerLocation: { CGPoint(x: 55, y: 55) },
            armDelay: 0.05,
            activeDuration: 0.05,
            showsIndicator: true,
            requiredModifiers: [.control, .option]
        )

        controller.begin(generation: 1, origin: CGPoint(x: 50, y: 50), pointer: CGPoint(x: 55, y: 55))
        await fulfillment(of: [activeExpectation, dismissExpectation], timeout: 1)
        XCTAssertEqual(hud.actions, [
            .present(.active(modifiers: [.control, .option], pointer: CGPoint(x: 55, y: 55))),
            .dismiss
        ])
    }

    func testFailsWithHUDWhenWindowCannotBeResolved() async throws {
        let resolver = FailingWindowUnderPointerResolver(error: .noWindowUnderPointer)
        let frameIO = RecordingWindowFrameIO(frame: .zero)
        let hud = SpyWindowModifierDragHUDPresenter()
        let failureExpectation = expectation(description: "HUD failure")
        hud.onAction = {
            if case .present(.failure) = hud.actions.last {
                failureExpectation.fulfill()
            }
        }
        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO,
            hudPresenter: hud,
            pointerLocation: { CGPoint(x: 50, y: 50) },
            localizedErrorMessage: { _ in "No movable window under pointer" },
            showsIndicator: true,
            requiredModifiers: [.control, .option]
        )

        controller.begin(generation: 1, origin: CGPoint(x: 50, y: 50), pointer: CGPoint(x: 55, y: 55))
        await fulfillment(of: [failureExpectation], timeout: 1)
        XCTAssertEqual(hud.actions, [
            .present(.failure(message: "No movable window under pointer", pointer: CGPoint(x: 50, y: 50)))
        ])
    }

    func testShowsIndicatorFalseSuppressesAllHUD() async throws {
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "win"),
            canMove: true,
            canResize: true
        )
        let resolver = StubWindowUnderPointerResolver(window: handle)
        let frameIO = RecordingWindowFrameIO(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let hud = SpyWindowModifierDragHUDPresenter()
        let writeExpectation = expectation(description: "write occurred")
        frameIO.onWrite = { writeExpectation.fulfill() }

        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO,
            hudPresenter: hud,
            armDelay: 0.01,
            showsIndicator: false,
            requiredModifiers: [.control, .option]
        )

        controller.arm(generation: 1, pointer: CGPoint(x: 50, y: 50))
        controller.begin(generation: 1, origin: CGPoint(x: 50, y: 50), pointer: CGPoint(x: 55, y: 55))
        await fulfillment(of: [writeExpectation], timeout: 1)

        XCTAssertTrue(hud.actions.isEmpty)
    }

    func testStaleGenerationDiscarded() async throws {
        let handle = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "win"),
            canMove: true,
            canResize: true
        )
        let resolver = DelayedWindowUnderPointerResolver(window: handle, delay: 0.05)
        let frameIO = RecordingWindowFrameIO(frame: CGRect(x: 100, y: 100, width: 200, height: 200))
        let hud = SpyWindowModifierDragHUDPresenter()
        let controller = WindowModifierDragController(
            resolver: resolver,
            frameReader: frameIO,
            frameWriter: frameIO,
            hudPresenter: hud,
            showsIndicator: true,
            requiredModifiers: [.control, .option]
        )

        controller.begin(generation: 1, origin: CGPoint(x: 50, y: 50), pointer: CGPoint(x: 55, y: 55))
        controller.cancel(generation: 1)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(frameIO.writes.isEmpty)
        XCTAssertFalse(hud.actions.contains(where: {
            if case .present(.active) = $0 { return true }
            return false
        }))
    }
}

@MainActor
final class WindowModifierDragHUDControllerTests: XCTestCase {
    func testPanelFrameClampsWithinVisibleFrameAndHandlesMultiScreen() {
        let displayFrames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        ]
        let visibleFrames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1055),
            CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        ]
        let panelSize = CGSize(width: 80, height: 28)

        // 1. Normal location on main screen
        let normalFrame = WindowModifierDragHUDController.panelFrame(
            at: CGPoint(x: 100, y: 500),
            panelSize: panelSize,
            displayFrames: displayFrames,
            visibleFrames: visibleFrames,
            offset: CGPoint(x: 14, y: 12)
        )
        XCTAssertEqual(normalFrame.origin.x, 114)
        XCTAssertEqual(normalFrame.origin.y, 500 - 28 - 12) // 460
        XCTAssertEqual(normalFrame.size, panelSize)

        // 2. Right edge clamp on main screen
        let rightEdgeFrame = WindowModifierDragHUDController.panelFrame(
            at: CGPoint(x: 1910, y: 500),
            panelSize: panelSize,
            displayFrames: displayFrames,
            visibleFrames: visibleFrames,
            offset: CGPoint(x: 14, y: 12)
        )
        XCTAssertEqual(rightEdgeFrame.maxX, 1920 - 8)

        // 3. Bottom edge flip on main screen (pointer near bottom)
        let bottomEdgeFrame = WindowModifierDragHUDController.panelFrame(
            at: CGPoint(x: 100, y: 10),
            panelSize: panelSize,
            displayFrames: displayFrames,
            visibleFrames: visibleFrames,
            offset: CGPoint(x: 14, y: 12)
        )
        // belowY = 10 - 28 - 12 = -30 < 0 (minY). So flips to above: 10 + 12 = 22
        XCTAssertEqual(bottomEdgeFrame.origin.y, 22)

        // 4. Secondary display with negative origin
        let secondaryFrame = WindowModifierDragHUDController.panelFrame(
            at: CGPoint(x: -500, y: 500),
            panelSize: panelSize,
            displayFrames: displayFrames,
            visibleFrames: visibleFrames,
            offset: CGPoint(x: 14, y: 12)
        )
        XCTAssertEqual(secondaryFrame.origin.x, -500 + 14)
        XCTAssertEqual(secondaryFrame.origin.y, 460)
        XCTAssertTrue(secondaryFrame.minX >= -1920 + 8)
        XCTAssertTrue(secondaryFrame.maxX <= -8)
    }

    func testAnnouncesAccessibilityOnFailure() {
        var announcement: String?
        let hud = WindowModifierDragHUDController(
            announceAccessibility: { message in
                announcement = message
            }
        )

        hud.present(.failure(message: "No movable window under pointer", pointer: .zero))
        XCTAssertEqual(announcement, "No movable window under pointer")
    }
}

@MainActor
private final class SpyWindowModifierDragHUDPresenter: WindowModifierDragHUDPresenting {
    enum Action: Equatable {
        case present(WindowModifierDragHUDState)
        case dismiss
    }

    var actions: [Action] = []
    var onAction: (() -> Void)?

    func present(_ state: WindowModifierDragHUDState) {
        actions.append(.present(state))
        onAction?()
    }

    func dismiss() {
        actions.append(.dismiss)
        onAction?()
    }
}

@MainActor
private final class FailingWindowUnderPointerResolver: WindowUnderPointerResolving {
    let error: WindowLayoutError

    init(error: WindowLayoutError) {
        self.error = error
    }

    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle {
        throw error
    }
}

@MainActor
private final class DelayedWindowUnderPointerResolver: WindowUnderPointerResolving {
    let window: AccessibilityWindowHandle
    let delay: TimeInterval

    init(window: AccessibilityWindowHandle, delay: TimeInterval) {
        self.window = window
        self.delay = delay
    }

    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return window
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
