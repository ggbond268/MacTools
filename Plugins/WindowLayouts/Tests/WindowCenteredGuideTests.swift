import AppKit
import XCTest
import MacToolsPluginKit
@testable import WindowLayoutsPlugin

final class WindowCenteredGuidePolicyTests: XCTestCase {
    private let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let initial = CGRect(x: 200, y: 200, width: 400, height: 300)

    func testExcludesUnsafeStatesAndInvalidGeometry() {
        let eligible = WindowCenteredGuideSnapshot(frame: initial)
        XCTAssertTrue(eligible.isEligible(in: usable))
        for keyPath in [\WindowCenteredGuideSnapshot.isFullScreen, \.isMinimized, \.isHidden] {
            var snapshot = eligible
            snapshot[keyPath: keyPath] = true
            XCTAssertFalse(snapshot.isEligible(in: usable))
        }
        for keyPath in [\WindowCenteredGuideSnapshot.canMove, \.isValid, \.isStandardWindow] {
            var snapshot = eligible
            snapshot[keyPath: keyPath] = false
            XCTAssertFalse(snapshot.isEligible(in: usable))
        }
        for frame in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 400, height: 300),
                      CGRect(x: 0, y: 0, width: 1001, height: 300)] {
            XCTAssertFalse(WindowCenteredGuideSnapshot(frame: frame).isEligible(in: usable))
        }
    }

    func testMaximizedUsesComponentToleranceAndStageManagerFrame() {
        XCTAssertFalse(WindowCenteredGuideSnapshot(frame: usable.insetBy(dx: 1, dy: 1)).isEligible(in: usable))
        XCTAssertTrue(WindowCenteredGuideSnapshot(frame: usable.insetBy(dx: 5, dy: 5)).isEligible(in: usable))
        let safe = CGRect(x: 120, y: 0, width: 880, height: 800)
        XCTAssertFalse(WindowCenteredGuideSnapshot(frame: safe).isEligible(in: safe))
        // Same size alone does not imply maximized: origin matters too.
        XCTAssertTrue(WindowCenteredGuideSnapshot(frame: usable.offsetBy(dx: 10, dy: 0)).isEligible(in: usable))
    }

    func testClickSelectionAndUncorrelatedMovementNeverActivate() {
        var policy = WindowCenteredGuidePolicy(originalFrame: initial, originalPointer: .zero)
        XCTAssertNil(policy.update(snapshot: .init(frame: initial), pointer: .zero, usableFrame: usable, screenID: "a"))
        XCTAssertNil(policy.update(snapshot: .init(frame: initial), pointer: CGPoint(x: 80, y: 50), usableFrame: usable, screenID: "a"))
        XCTAssertNil(policy.update(snapshot: .init(frame: initial.offsetBy(dx: 300, dy: 100)), pointer: CGPoint(x: 5, y: 0), usableFrame: usable, screenID: "a"))
        XCTAssertFalse(policy.hasMoved)
    }

    func testResizeCancelsEntireGesture() {
        var policy = WindowCenteredGuidePolicy(originalFrame: initial, originalPointer: .zero)
        XCTAssertNil(policy.update(snapshot: .init(frame: initial.insetBy(dx: -10, dy: 0)), pointer: CGPoint(x: -10, y: 0), usableFrame: usable, screenID: "a"))
        XCTAssertTrue(policy.isCancelled)
        XCTAssertNil(policy.update(snapshot: .init(frame: initial.offsetBy(dx: 100, dy: 50)), pointer: CGPoint(x: 100, y: 50), usableFrame: usable, screenID: "a"))
    }

    func testCenteredFeedbackThresholdHysteresisAndDisplayReset() throws {
        let center = WindowSnapGeometry.defaultFrame(contentSize: initial.size, visibleFrame: usable)
        var policy = WindowCenteredGuidePolicy(originalFrame: center, originalPointer: .zero)
        func update(_ x: CGFloat, screen: String = "a") -> WindowSnapResult? {
            policy.update(snapshot: .init(frame: center.offsetBy(dx: x, dy: 0)), pointer: CGPoint(x: x, y: 0), usableFrame: usable, screenID: screen)
        }
        XCTAssertTrue(try XCTUnwrap(update(4)).isFullySnapped)
        XCTAssertTrue(try XCTUnwrap(update(23)).isFullySnapped)
        XCTAssertFalse(try XCTUnwrap(update(23, screen: "b")).isFullySnapped)
        XCTAssertFalse(try XCTUnwrap(update(25)).isFullySnapped)
        XCTAssertTrue(try XCTUnwrap(update(20)).isFullySnapped)
    }

    func testGeometryUsesOffsetDisplayAndCurrentSize() throws {
        let safe = CGRect(x: -1500, y: -800, width: 1300, height: 900)
        let frame = CGRect(x: -1050, y: -500, width: 400, height: 300)
        var policy = WindowCenteredGuidePolicy(originalFrame: frame.offsetBy(dx: -10, dy: -10), originalPointer: .zero)
        let result = try XCTUnwrap(policy.update(snapshot: .init(frame: frame), pointer: CGPoint(x: 10, y: 10), usableFrame: safe, screenID: "external"))
        XCTAssertEqual(result.defaultFrame, frame)
        XCTAssertTrue(result.isFullySnapped)
    }

    func testActiveDisplayFollowsPointerAndGuidesConvertToAppKitTopEdge() throws {
        let left = WindowScreen(id: "left", frame: usable, visibleFrame: usable)
        let right = WindowScreen(id: "right", frame: usable.offsetBy(dx: 1000, dy: -300), visibleFrame: usable.offsetBy(dx: 1000, dy: -300))
        XCTAssertEqual(WindowCenteredGuidePolicy.activeScreen(frame: CGRect(x: 700, y: 0, width: 400, height: 300), pointer: CGPoint(x: 1050, y: 20), screens: [left, right])?.id, "right")
        let result = WindowSnapGeometry.calculate(proposedFrame: initial, contentSize: initial.size, visibleFrame: usable)
        let guides = WindowCenteredGuidePolicy.appKitGuides(for: result, anchorMaximumY: 900)
        let top = try XCTUnwrap(guides.first(where: { $0.role == .topEdge }))
        XCTAssertEqual(top.start.y, 650)
        XCTAssertEqual(top.end.y, 650)
        XCTAssertEqual(guides[0].start.y, 900)
        XCTAssertEqual(guides[0].end.y, 100)
    }

    func testReleaseRejectsChangedStateDriftAndNoncenterTarget() {
        let target = WindowSnapGeometry.defaultFrame(contentSize: initial.size, visibleFrame: usable)
        let expected = target.offsetBy(dx: 10, dy: 5)
        let snapshot = WindowCenteredGuideSnapshot(frame: expected)
        func accepts(_ snapshot: WindowCenteredGuideSnapshot, target: CGRect) -> Bool {
            WindowCenteredGuidePolicy.canReleaseSnap(snapshot: snapshot, expected: expected, target: target, usableFrame: usable)
        }
        XCTAssertTrue(accepts(snapshot, target: target))
        XCTAssertFalse(accepts(.init(frame: expected.offsetBy(dx: 5, dy: 0)), target: target))
        XCTAssertFalse(accepts(.init(frame: expected, isFullScreen: true), target: target))
        XCTAssertFalse(accepts(.init(frame: expected, isMinimized: true), target: target))
        XCTAssertFalse(accepts(.init(frame: expected, isHidden: true), target: target))
        XCTAssertFalse(accepts(.init(frame: expected, canMove: false), target: target))
        XCTAssertFalse(accepts(.init(frame: expected, isValid: false), target: target))
        XCTAssertFalse(accepts(snapshot, target: target.offsetBy(dx: 200, dy: 0)))
    }

    func testTransientLagRecoversButPersistentMismatchCancels() throws {
        let now = ContinuousClock.now
        var policy = WindowCenteredGuidePolicy(originalFrame: initial, originalPointer: .zero)
        let moved = initial.offsetBy(dx: 90, dy: 50)
        XCTAssertNotNil(policy.update(snapshot: .init(frame: moved), pointer: CGPoint(x: 90, y: 50), usableFrame: usable, screenID: "a", now: now))
        XCTAssertNil(policy.update(snapshot: .init(frame: moved), pointer: CGPoint(x: 100, y: 50), usableFrame: usable, screenID: "a", now: now))
        XCTAssertFalse(policy.isCancelled)
        XCTAssertTrue(policy.isAwaitingCorrelatedFrame)
        let center = initial.offsetBy(dx: 100, dy: 50)
        XCTAssertTrue(try XCTUnwrap(policy.update(snapshot: .init(frame: center), pointer: CGPoint(x: 100, y: 50), usableFrame: usable, screenID: "a", now: now + .milliseconds(30))).isFullySnapped)
        XCTAssertFalse(policy.isAwaitingCorrelatedFrame)
        XCTAssertNil(policy.update(snapshot: .init(frame: center), pointer: CGPoint(x: 150, y: 50), usableFrame: usable, screenID: "a", now: now + .milliseconds(40)))
        XCTAssertNil(policy.update(snapshot: .init(frame: center), pointer: CGPoint(x: 150, y: 50), usableFrame: usable, screenID: "a", now: now + .milliseconds(160)))
        XCTAssertTrue(policy.isCancelled)
    }

    func testPointerHistoryExpiresAndBoundsHighRateInput() {
        var history = WindowCenteredGuidePointerHistory()
        let now = ContinuousClock.now
        for x in 0..<1000 { history.record(CGPoint(x: x, y: 0), now: now) }
        XCTAssertEqual(history.points(now: now).count, 128)
        XCTAssertEqual(history.points(now: now).first?.x, 872)
        XCTAssertTrue(history.points(now: now + .milliseconds(121)).isEmpty)
        history.record(CGPoint(x: 1000, y: 0), now: now + .milliseconds(122))
        XCTAssertEqual(history.points(now: now + .milliseconds(123)), [CGPoint(x: 1000, y: 0)])
    }

    func testEventQueueCoalescesAndInvalidatesOldDrains() throws {
        var queue = WindowCenteredGuideEventQueue()
        func event(_ type: CGEventType, _ x: CGFloat = 0) -> WindowModifierDragMonitorEvent {
            .init(type: type, location: CGPoint(x: x, y: 0), flags: [])
        }
        XCTAssertNil(queue.enqueue(event(.leftMouseDown)))
        queue.configure(enabled: true)
        let epoch = try XCTUnwrap(queue.enqueue(event(.leftMouseDown)))
        for x in 1...1000 { XCTAssertNil(queue.enqueue(event(.leftMouseDragged, CGFloat(x)))) }
        XCTAssertNil(queue.enqueue(event(.leftMouseUp)))
        XCTAssertEqual(queue.next(epoch: epoch)?.type, .leftMouseDown)
        XCTAssertEqual(queue.next(epoch: epoch)?.location.x, 1000)
        XCTAssertEqual(queue.next(epoch: epoch)?.type, .leftMouseUp)
        XCTAssertNil(queue.next(epoch: epoch))
        _ = queue.enqueue(event(.leftMouseDown))
        queue.configure(enabled: false)
        queue.configure(enabled: true)
        XCTAssertNil(queue.next(epoch: epoch))
    }
}

@MainActor
final class WindowCenteredGuideControllerTests: XCTestCase {
    private func event(_ type: CGEventType, x: CGFloat = 220, y: CGFloat = 210) -> WindowModifierDragMonitorEvent {
        .init(type: type, location: CGPoint(x: x, y: y), flags: [])
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for coordinator", file: file, line: line)
    }

    func testContinuousInputMakesProgressAcrossSuspendedAXReads() async throws {
        // Exercise both a frame captured at read start and one captured at completion.
        for capturesEarly in [false, true] {
            let environment = GuideTestEnvironment()
            environment.capturesFrameBeforeSuspension = capturesEarly
            let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
            controller.configure(enabled: true, respectsStageManager: true)
            defer { controller.configure(enabled: false, respectsStageManager: true) }
            controller.handle(event(.leftMouseDown))
            try await waitUntil { environment.reads > 0 }
            var dx: CGFloat = 20
            environment.current.frame = CGRect(x: 200 + dx, y: 200 + dx / 2, width: 400, height: 300)
            controller.handle(event(.leftMouseDragged, x: 220 + dx, y: 210 + dx / 2))
            environment.pausesSnapshots = true
            for _ in 0..<3 {
                try await waitUntil { environment.snapshotContinuation != nil }
                let presentations = environment.shown.count
                // Several physical updates arrive before this AX read completes.
                for _ in 0..<3 {
                    dx += 10
                    environment.current.frame = CGRect(x: 200 + dx, y: 200 + dx / 2, width: 400, height: 300)
                    controller.handle(event(.leftMouseDragged, x: 220 + dx, y: 210 + dx / 2))
                }
                environment.finishSnapshot()
                try await waitUntil { environment.shown.count > presentations }
                XCTAssertTrue(environment.writes.isEmpty)
            }
            environment.pausesSnapshots = false
            controller.handle(event(.leftMouseUp, x: 220 + dx, y: 210 + dx / 2))
            environment.finishSnapshot()
            try await waitUntil { environment.writes.count == 1 }
            XCTAssertEqual(environment.writes.first, CGRect(x: 300, y: 250, width: 400, height: 300))
        }
    }

    func testLaggingAXFrameRecoversDuringDragAndReleaseRequiresFreshPosition() async throws {
        let environment = GuideTestEnvironment()
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: true)
        defer { controller.configure(enabled: false, respectsStageManager: true) }
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.reads > 0 }
        environment.current.frame = CGRect(x: 290, y: 250, width: 400, height: 300)
        controller.handle(event(.leftMouseDragged, x: 310, y: 260))
        try await waitUntil { environment.visible }
        let reads = environment.reads
        controller.handle(event(.leftMouseDragged, x: 320, y: 260))
        try await waitUntil { environment.reads >= reads + 1 }
        XCTAssertTrue(environment.visible)
        controller.handle(event(.leftMouseUp, x: 320, y: 260))
        let releaseReads = environment.reads
        try await waitUntil { environment.reads >= releaseReads + 2 }
        XCTAssertTrue(environment.writes.isEmpty, "Historical pointer matches must not authorize release snapping")
        XCTAssertFalse(environment.visible)
        environment.current.frame = CGRect(x: 300, y: 250, width: 400, height: 300)
        try await waitUntil { environment.writes.count == 1 }
    }

    func testReleaseWithPersistentFrameLagTimesOutWithoutSnapping() async throws {
        let environment = GuideTestEnvironment()
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: true)
        defer { controller.configure(enabled: false, respectsStageManager: true) }
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.reads > 0 }
        environment.current.frame = CGRect(x: 290, y: 250, width: 400, height: 300)
        controller.handle(event(.leftMouseDragged, x: 310, y: 260))
        try await waitUntil { environment.visible }
        controller.handle(event(.leftMouseUp, x: 350, y: 260))
        try await Task.sleep(for: .milliseconds(160))
        let reads = environment.reads
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(environment.reads, reads, "Release retries must be bounded")
        XCTAssertTrue(environment.writes.isEmpty)
        XCTAssertFalse(environment.visible)
    }

    func testCancellationDuringSuspendedAXReadCannotShowOrSnap() async throws {
        let environment = GuideTestEnvironment()
        environment.pausesSnapshots = true
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: true)
        defer { controller.configure(enabled: false, respectsStageManager: true) }
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.snapshotContinuation != nil }
        environment.current.frame = CGRect(x: 300, y: 250, width: 400, height: 300)
        controller.handle(event(.leftMouseDragged, x: 320, y: 260))
        controller.handle(event(.leftMouseUp, x: 320, y: 260))
        controller.cancel()
        environment.finishSnapshot()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(environment.shown.isEmpty)
        XCTAssertTrue(environment.writes.isEmpty)
    }

    func testDragUsesGeometryReadsAndReleaseRevalidatesAccessibility() async throws {
        let environment = GuideTestEnvironment()
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: true)
        defer { controller.configure(enabled: false, respectsStageManager: true) }
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.reads == 1 }
        environment.current.frame = CGRect(x: 300, y: 250, width: 400, height: 300)
        controller.handle(event(.leftMouseDragged, x: 320, y: 260))
        try await waitUntil { environment.trackingReads >= 1 }
        XCTAssertEqual(environment.reads - environment.trackingReads, 1, "Live tracking must not request full AX state")
        XCTAssertEqual(environment.usableFrameReads, 2, "Cache the display safe area during dragging")
        try await Task.sleep(for: .milliseconds(150))
        let pausedReads = environment.reads
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(environment.reads, pausedReads, "A settled pointer must stop geometry polling")
        environment.current.isFullScreen = true
        controller.handle(event(.leftMouseUp, x: 320, y: 260))
        try await waitUntil { environment.reads > pausedReads }
        XCTAssertGreaterThan(environment.reads - environment.trackingReads, 1)
        XCTAssertTrue(environment.writes.isEmpty, "Fresh eligibility must veto an unsafe release")
    }

    func testHeldClickDoesNotContinuouslyQueryAccessibility() async throws {
        let environment = GuideTestEnvironment()
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: false)
        defer { controller.configure(enabled: false, respectsStageManager: false) }
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.reads == 1 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(environment.reads, 1)
        controller.handle(event(.leftMouseUp))
        try await waitUntil { environment.reads == 2 }
        XCTAssertTrue(environment.writes.isEmpty)
    }

    func testHostWindowResolvesReadsAndRejectsHiddenWindow() async throws {
        let native = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.orderFrontRegardless()
        defer { native.close() }
        let environment = SystemWindowCenteredGuideEnvironment()
        let candidate = WindowCenteredGuideCandidate(processIdentifier: ProcessInfo.processInfo.processIdentifier,
            windowNumber: native.windowNumber, frame: native.frame)
        let handle = try await environment.resolve(candidate)
        XCTAssertTrue(handle.hostWindow === native)
        let first = try await environment.snapshot(handle)
        XCTAssertTrue(first.canMove)
        native.setFrameOrigin(native.frame.origin.applying(CGAffineTransform(translationX: 20, y: 0)))
        let moved = try await environment.snapshot(handle)
        XCTAssertEqual(moved.frame.minX, first.frame.minX + 20, accuracy: 0.1)
        native.orderOut(nil)
        do {
            _ = try await environment.snapshot(handle)
            XCTFail("Hidden host windows must not remain eligible")
        } catch {}
    }

    func testBackgroundResolverRejectsHostBeforeAccessibilityHitTesting() async {
        let worker = WindowAccessibilityWorker()
        for number in [nil, 123] as [Int?] {
            do {
                _ = try await worker.resolveFocusedWindow(target: ExternalFocusedWindowTarget(
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    bundleIdentifier: Bundle.main.bundleIdentifier,
                    preferredWindowNumber: number, pointerLocation: .zero))
                XCTFail("Host windows must never enter background Accessibility hit testing")
            } catch {
                XCTAssertEqual(error as? WindowLayoutError, .windowUnavailable)
            }
        }
    }

    func testHostPanelsAreExcluded() {
        let panel = NSPanel(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.close() }
        XCTAssertFalse(SystemWindowCenteredGuideEnvironment.eligibleHostWindow(panel))
    }

    func testCandidateMatchingSupportsMissingWindowNumberAndRejectsOtherTargets() {
        let frame = CGRect(x: 200, y: 200, width: 400, height: 300)
        let candidate = WindowCenteredGuideCandidate(processIdentifier: 42, windowNumber: 123, frame: frame)
        func handle(_ pid: pid_t = 42, number: UInt32? = nil) -> AccessibilityWindowHandle {
            .init(identity: .init(processIdentifier: pid, token: "test"), windowNumber: number, canMove: true, canResize: true)
        }
        XCTAssertTrue(SystemWindowCenteredGuideEnvironment.matchesCandidate(candidate, window: handle(), frame: frame))
        XCTAssertFalse(SystemWindowCenteredGuideEnvironment.matchesCandidate(candidate, window: handle(), frame: frame.offsetBy(dx: 20, dy: 0)))
        XCTAssertTrue(SystemWindowCenteredGuideEnvironment.matchesCandidate(candidate, window: handle(number: 123), frame: frame.offsetBy(dx: 20, dy: 0)))
        XCTAssertFalse(SystemWindowCenteredGuideEnvironment.matchesCandidate(candidate, window: handle(number: 456), frame: frame))
        XCTAssertFalse(SystemWindowCenteredGuideEnvironment.matchesCandidate(candidate, window: handle(43), frame: frame))
        let own = WindowCenteredGuideCandidate(processIdentifier: ProcessInfo.processInfo.processIdentifier, windowNumber: 123, frame: frame)
        XCTAssertFalse(SystemWindowCenteredGuideEnvironment.matchesCandidate(own, window: handle(own.processIdentifier, number: 123), frame: frame))
    }

    func testSharedMonitorRoutesCenteredDraggingWithoutModifierOwnership() async throws {
        let environment = GuideTestEnvironment()
        let monitor = GuideTestEventMonitor()
        let session = WindowModifierDragSession(eventMonitor: monitor, centeredEnvironment: environment)
        session.configureFeatures(modifierDragEnabled: false, centeredGuidesEnabled: true, respectsStageManager: true)
        _ = session.start()
        _ = session.start()
        defer { session.stop() }
        XCTAssertEqual(monitor.starts, 1)
        monitor.send(event(.leftMouseDown))
        try await waitUntil { environment.reads > 0 }
        environment.current.frame = CGRect(x: 310, y: 255, width: 400, height: 300)
        monitor.send(event(.leftMouseDragged, x: 330, y: 265))
        try await waitUntil { !environment.shown.isEmpty }
        session.cancelCenteredGuides()
        monitor.send(event(.leftMouseUp, x: 330, y: 265))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(environment.writes.isEmpty)
        XCTAssertFalse(environment.visible)
    }

    func testActualDragShowsAndSnapsOnlyCapturedWindowOnRelease() async throws {
        let environment = GuideTestEnvironment()
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: true)
        defer { controller.configure(enabled: false, respectsStageManager: true) }
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.reads > 0 }
        XCTAssertTrue(environment.shown.isEmpty)
        environment.current.frame = CGRect(x: 310, y: 255, width: 400, height: 300)
        controller.handle(event(.leftMouseDragged, x: 330, y: 265))
        try await waitUntil { !environment.shown.isEmpty }
        XCTAssertTrue(environment.shown.last?.isFullySnapped == true)
        XCTAssertTrue(environment.writes.isEmpty)
        controller.handle(event(.leftMouseUp, x: 330, y: 265))
        try await waitUntil { !environment.writes.isEmpty }
        XCTAssertEqual(environment.writes, [CGRect(x: 300, y: 250, width: 400, height: 300)])
        XCTAssertEqual(environment.resolves, 1)
        XCTAssertEqual(environment.writtenIdentity, environment.window.identity)
    }

    func testClicksSelectionProgrammaticMovementAndResizeNeverSnap() async throws {
        for mode in 0..<4 {
            let environment = GuideTestEnvironment()
            let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
            controller.configure(enabled: true, respectsStageManager: true)
            controller.handle(event(.leftMouseDown))
            try await waitUntil { environment.reads > 0 }
            if mode == 1 { controller.handle(event(.leftMouseDragged, x: 330, y: 265)) }
            if mode == 2 { environment.current.frame = CGRect(x: 310, y: 255, width: 400, height: 300) }
            if mode == 3 {
                environment.current.frame = CGRect(x: 310, y: 255, width: 450, height: 300)
                controller.handle(event(.leftMouseDragged, x: 330, y: 265))
            }
            controller.handle(event(.leftMouseUp, x: mode == 1 || mode == 3 ? 330 : 220, y: mode == 1 || mode == 3 ? 265 : 210))
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertTrue(environment.shown.isEmpty, "Mode \(mode)")
            XCTAssertTrue(environment.writes.isEmpty, "Mode \(mode)")
            controller.configure(enabled: false, respectsStageManager: true)
        }
    }

    func testReleaseRechecksFullscreenPermissionDisappearanceAndFrameDrift() async throws {
        for mode in 0..<4 {
            let environment = GuideTestEnvironment()
            let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
            controller.configure(enabled: true, respectsStageManager: true)
            controller.handle(event(.leftMouseDown))
            try await waitUntil { environment.reads > 0 }
            environment.current.frame = CGRect(x: 310, y: 255, width: 400, height: 300)
            controller.handle(event(.leftMouseDragged, x: 330, y: 265))
            try await waitUntil { !environment.shown.isEmpty }
            switch mode {
            case 0: environment.current.isFullScreen = true
            case 1: environment.isTrusted = false
            case 2: environment.disappeared = true
            default: environment.beforeWrite = { environment.current.frame.origin.x += 10 }
            }
            controller.handle(event(.leftMouseUp, x: 330, y: 265))
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertTrue(environment.writes.isEmpty, "Mode \(mode)")
            XCTAssertFalse(environment.visible)
            controller.configure(enabled: false, respectsStageManager: true)
        }
    }

    func testCancellationAndDisplayChangesPreventRelease() async throws {
        for mode in 0..<4 {
            let environment = GuideTestEnvironment()
            let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
            controller.configure(enabled: true, respectsStageManager: true)
            controller.handle(event(.leftMouseDown))
            try await waitUntil { environment.reads > 0 }
            environment.current.frame = CGRect(x: 310, y: 255, width: 400, height: 300)
            controller.handle(event(.leftMouseDragged, x: 330, y: 265))
            try await waitUntil { !environment.shown.isEmpty }
            switch mode {
            case 0: controller.handle(event(.keyDown))
            case 1: controller.handle(event(.tapDisabledByTimeout))
            case 2: environment.screenList = []
            default: controller.configure(enabled: false, respectsStageManager: true)
            }
            controller.handle(event(.leftMouseUp, x: 330, y: 265))
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertTrue(environment.writes.isEmpty)
            XCTAssertFalse(environment.visible)
            controller.configure(enabled: false, respectsStageManager: true)
        }
    }

    func testDelayedResolutionCannotResurrectCancelledDrag() async throws {
        let environment = GuideTestEnvironment()
        environment.delayResolution = true
        let controller = WindowCenteredGuideController(environment: environment, cadence: .milliseconds(1))
        controller.configure(enabled: true, respectsStageManager: true)
        controller.handle(event(.leftMouseDown))
        try await waitUntil { environment.resolution != nil }
        controller.cancel()
        environment.resolution?.resume()
        environment.resolution = nil
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(environment.reads, 0)
        XCTAssertTrue(environment.shown.isEmpty)
        XCTAssertTrue(environment.writes.isEmpty)
        controller.configure(enabled: false, respectsStageManager: true)
    }
}

@MainActor
private final class GuideTestEnvironment: WindowCenteredGuideEnvironment {
    struct State {
        var frame = CGRect(x: 200, y: 200, width: 400, height: 300)
        var isFullScreen = false
    }
    var current = State()
    var isTrusted = true
    var disappeared = false
    var delayResolution = false
    var resolution: CheckedContinuation<Void, Never>?
    var beforeWrite: (() -> Void)?
    var pausesSnapshots = false
    var capturesFrameBeforeSuspension = false
    var snapshotContinuation: CheckedContinuation<Void, Never>?

    func finishSnapshot() {
        let continuation = snapshotContinuation
        snapshotContinuation = nil
        continuation?.resume()
    }
    var screenList = [WindowScreen(id: "main", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))]
    let window = AccessibilityWindowHandle(identity: .init(processIdentifier: 42, token: "captured"), canMove: true, canResize: true)
    var reads = 0
    var trackingReads = 0
    var usableFrameReads = 0
    var resolves = 0
    var shown: [WindowSnapResult] = []
    var writes: [CGRect] = []
    var writtenIdentity: WindowIdentity?
    var visible = false

    func candidate(at pointer: CGPoint) -> WindowCenteredGuideCandidate? {
        .init(processIdentifier: 42, windowNumber: 123, frame: current.frame)
    }
    func resolve(_ candidate: WindowCenteredGuideCandidate) async throws -> AccessibilityWindowHandle {
        resolves += 1
        if delayResolution { await withCheckedContinuation { resolution = $0 } }
        return window
    }
    func snapshot(_ window: AccessibilityWindowHandle) async throws -> WindowCenteredGuideSnapshot {
        reads += 1
        let captured = WindowCenteredGuideSnapshot(frame: current.frame, isFullScreen: current.isFullScreen)
        if pausesSnapshots { await withCheckedContinuation { snapshotContinuation = $0 } }
        if capturesFrameBeforeSuspension { return captured }
        if disappeared { throw WindowLayoutError.windowUnavailable }
        return .init(frame: current.frame, isFullScreen: current.isFullScreen)
    }
    func trackingSnapshot(_ window: AccessibilityWindowHandle) async throws -> WindowCenteredGuideSnapshot {
        trackingReads += 1
        return try await snapshot(window)
    }
    func screens() -> [WindowScreen] { screenList }
    func usableFrame(for screen: WindowScreen) -> CGRect { usableFrameReads += 1; return screen.visibleFrame }
    func show(_ result: WindowSnapResult, on screen: WindowScreen) { shown.append(result); visible = true }
    func hide() { visible = false }
    func snap(_ window: AccessibilityWindowHandle, expected: CGRect, target: CGRect, usableFrame: CGRect) async throws {
        beforeWrite?()
        guard isTrusted, WindowCenteredGuidePolicy.canReleaseSnap(snapshot: try await snapshot(window), expected: expected, target: target, usableFrame: usableFrame) else { return }
        writtenIdentity = window.identity
        writes.append(target)
    }
}

nonisolated private final class GuideTestEventMonitor: @unchecked Sendable, WindowModifierDragEventMonitoring {
    var isRunning = false
    var starts = 0
    var handler: WindowModifierDragEventHandler?
    func start(handler: WindowModifierDragEventHandler) -> Result<Void, WindowModifierDragMonitorStartError> {
        starts += 1
        self.handler = handler
        isRunning = true
        return .success(())
    }
    func stop() { isRunning = false; handler = nil }
    func send(_ event: WindowModifierDragMonitorEvent) { handler?.handle(event) }
}
