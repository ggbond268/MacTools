import CoreGraphics
import XCTest
@testable import WindowLayoutsPlugin

@MainActor
final class WindowLayoutServiceTests: XCTestCase {
    func testPlacementWritesCalculatedFrameAndRestoreTogglesPreviousFrame() async throws {
        let window = makeWindow()
        let originalFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let frameAdapter = MockWindowFrameAdapter(window: window, frame: originalFrame)
        let history = InMemoryWindowFrameHistory()
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            history: history
        )

        assertSuccess(await service.execute(.leftHalf, options: options(gap: 10)))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 10, y: 34, width: 705, height: 856)
        )

        assertSuccess(await service.execute(.restorePreviousFrame, options: options(gap: 10)))
        XCTAssertEqual(frameAdapter.frames[window.identity], originalFrame)

        assertSuccess(await service.execute(.restorePreviousFrame, options: options(gap: 10)))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 10, y: 34, width: 705, height: 856)
        )
    }

    func testMoveToDisplayUsesCurrentVisibleFramesAndClampsDestination() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 720, y: 462, width: 720, height: 438)
        )
        let screens = [
            WindowScreen(
                id: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
            ),
            WindowScreen(
                id: "right",
                frame: CGRect(x: 1440, y: -300, width: 2560, height: 1440),
                visibleFrame: CGRect(x: 1440, y: -276, width: 2560, height: 1416)
            )
        ]
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            screens: screens
        )

        assertSuccess(await service.execute(.moveToNextDisplay, options: options()))

        let moved = frameAdapter.frames[window.identity]
        XCTAssertEqual(moved?.minX, 2720)
        XCTAssertEqual(moved?.maxX, 4000)
        XCTAssertEqual(moved?.minY, 432)
        XCTAssertEqual(moved?.maxY, 1140)
    }

    func testNonResizableWindowCanCenterButCannotTile() async {
        let window = makeWindow(canResize: false)
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let service = makeService(window: window, frameAdapter: frameAdapter)

        let centerError = await service.validationError(for: .center, options: options())
        let maximizeError = await service.validationError(for: .maximize, options: options())
        XCTAssertNil(centerError)
        XCTAssertEqual(maximizeError, .windowCannotResize)
    }

    func testSingleDisplayMoveReturnsSpecificError() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let service = makeService(window: window, frameAdapter: frameAdapter)

        let error = await service.validationError(
            for: .moveToNextDisplay,
            options: options()
        )
        XCTAssertEqual(error, .noOtherDisplay)
    }

    func testRestoreClampsFrameFromDisconnectedDisplayIntoCurrentVisibleFrame() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let history = InMemoryWindowFrameHistory()
        history.record(
            CGRect(x: -3000, y: -1000, width: 1800, height: 1200),
            for: window
        )
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            history: history
        )

        assertSuccess(await service.execute(.restorePreviousFrame, options: options()))

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: -360, y: 24, width: 1800, height: 1200)
        )
    }

    func testHalfCyclingAdvancesThroughSizesAndWrapsOnCurrentDisplay() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 0, y: 24, width: 720, height: 876)
        )
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            screens: [
                WindowScreen(
                    id: "main",
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
                ),
                WindowScreen(
                    id: "right",
                    frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 1440, y: 24, width: 1440, height: 876)
                ),
            ]
        )
        let cycling = WindowLayoutExecutionOptions(
            gap: 0,
            cyclesHalves: true,
            respectsStageManager: false
        )

        assertSuccess(await service.execute(.leftHalf, options: cycling))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 0, y: 24, width: 960, height: 876)
        )
        assertSuccess(await service.execute(.leftHalf, options: cycling))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 0, y: 24, width: 480, height: 876)
        )
        assertSuccess(await service.execute(.leftHalf, options: cycling))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 0, y: 24, width: 720, height: 876)
        )
    }

    func testCancelledQueuedExecutionNeverWritesAfterGateBecomesAvailable() async {
        let window = makeFullScreenWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let fullScreenWriter = BlockingFullScreenWriter()
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            fullScreenWriter: fullScreenWriter
        )

        let active = Task { @MainActor in
            await service.execute(.toggleFullScreen, options: options())
        }
        while !fullScreenWriter.isBlocked { await Task.yield() }

        let queued = Task { @MainActor in
            await service.execute(.leftHalf, options: options())
        }
        for _ in 0 ..< 10 { await Task.yield() }
        queued.cancel()

        assertFailure(await queued.value, equals: .executionCancelled)
        XCTAssertTrue(frameAdapter.writtenFrames.isEmpty)

        fullScreenWriter.resume()
        assertSuccess(await active.value)
        XCTAssertTrue(frameAdapter.writtenFrames.isEmpty)
    }

    func testQueuedExecutionRejectsFocusDriftInsteadOfUsingNewFrontmostWindow() async {
        let originalWindow = makeFullScreenWindow(token: "original")
        let replacementWindow = makeWindow(token: "replacement")
        let resolver = MutableFocusedWindowResolver(window: originalWindow)
        let frameAdapter = MockWindowFrameAdapter(
            window: replacementWindow,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let fullScreenWriter = BlockingFullScreenWriter()
        let service = makeService(
            window: originalWindow,
            frameAdapter: frameAdapter,
            fullScreenWriter: fullScreenWriter,
            focusedWindowResolver: resolver
        )

        let active = Task { @MainActor in
            await service.execute(.toggleFullScreen, options: options())
        }
        while !fullScreenWriter.isBlocked { await Task.yield() }

        let queued = Task { @MainActor in
            await service.execute(.leftHalf, options: options())
        }
        while resolver.resolveCount < 4 { await Task.yield() }
        resolver.window = replacementWindow
        fullScreenWriter.resume()

        assertSuccess(await active.value)
        assertFailure(await queued.value, equals: .windowUnavailable)
        XCTAssertTrue(frameAdapter.writtenFrames.isEmpty)
    }

    func testPlacementReportsWhenApplicationPermanentlyConstrainsSize() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 900, height: 700),
            appliesWrites: false
        )
        let service = makeService(window: window, frameAdapter: frameAdapter)

        assertFailure(
            await service.execute(.topRightQuarter, options: options()),
            equals: .windowSizeConstrained
        )
        XCTAssertEqual(frameAdapter.writtenFrames.count, 2)
    }

    func testToggleFullScreenUsesSettableAXFullScreenAttribute() async {
        let window = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "fullscreen"),
            canMove: false,
            canResize: false,
            canToggleFullScreen: true,
            isFullScreen: false
        )
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let fullScreenWriter = MockFullScreenWriter()
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            fullScreenWriter: fullScreenWriter
        )

        assertSuccess(await service.execute(.toggleFullScreen, options: options()))
        XCTAssertEqual(fullScreenWriter.values, [true])
    }

    func testPlacementRejectsFocusChangeImmediatelyBeforeFrameWrite() async {
        let originalWindow = makeWindow()
        let replacementWindow = makeWindow(token: "replacement")
        let frameAdapter = MockWindowFrameAdapter(
            window: originalWindow,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let service = makeService(
            window: originalWindow,
            frameAdapter: frameAdapter,
            focusedWindowResolver: MockFocusedWindowResolver(
                windows: [originalWindow, replacementWindow]
            )
        )

        assertFailure(
            await service.execute(.leftHalf, options: options()),
            equals: .windowUnavailable
        )
        XCTAssertEqual(
            frameAdapter.frames[originalWindow.identity],
            CGRect(x: 100, y: 100, width: 600, height: 400)
        )
    }

    func testIncrementalResizeExecutesAndUpdatesFrameSequentially() async {
        let window = makeWindow()
        let initialFrame = CGRect(x: 300, y: 200, width: 400, height: 300)
        let frameAdapter = MockWindowFrameAdapter(window: window, frame: initialFrame)
        let history = InMemoryWindowFrameHistory()
        let service = makeService(window: window, frameAdapter: frameAdapter, history: history)

        assertSuccess(await service.execute(.increaseWidth, options: options()))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 275, y: 200, width: 450, height: 300)
        )

        assertSuccess(await service.execute(.increaseHeight, options: options()))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 275, y: 175, width: 450, height: 350)
        )

        assertSuccess(await service.execute(.decreaseWidth, options: options()))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 300, y: 175, width: 400, height: 350)
        )

        assertSuccess(await service.execute(.decreaseHeight, options: options()))
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 300, y: 200, width: 400, height: 300)
        )
    }

    func testIncrementalResizeReportsAtLimitFailure() async {
        let window = makeWindow()
        let fullWidthFrame = CGRect(x: 0, y: 24, width: 1440, height: 400)
        let frameAdapter = MockWindowFrameAdapter(window: window, frame: fullWidthFrame)
        let service = makeService(window: window, frameAdapter: frameAdapter)

        let validationError = await service.validationError(for: .increaseWidth, options: options())
        XCTAssertEqual(validationError, .windowCannotResizeFurther)

        assertFailure(
            await service.execute(.increaseWidth, options: options()),
            equals: .windowCannotResizeFurther
        )
        XCTAssertEqual(frameAdapter.frames[window.identity], fullWidthFrame)

        frameAdapter.frames[window.identity] = CGRect(x: 200, y: 200, width: 100, height: 400)
        let shrinkValidationError = await service.validationError(for: .decreaseWidth, options: options())
        XCTAssertEqual(shrinkValidationError, .windowCannotResizeFurther)

        assertFailure(
            await service.execute(.decreaseWidth, options: options()),
            equals: .windowCannotResizeFurther
        )
    }

    private func makeWindow(
        token: String = "window",
        windowNumber: UInt32? = nil,
        canResize: Bool = true,
        canMove: Bool = true
    ) -> AccessibilityWindowHandle {
        AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: token),
            windowNumber: windowNumber,
            canMove: canMove,
            canResize: canResize
        )
    }

    private func makeFullScreenWindow(token: String = "fullscreen") -> AccessibilityWindowHandle {
        AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: token),
            canMove: true,
            canResize: true,
            canToggleFullScreen: true
        )
    }

    private func makeService(
        window: AccessibilityWindowHandle,
        frameAdapter: MockWindowFrameAdapter,
        screens: [WindowScreen] = [
            WindowScreen(
                id: "main",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
            )
        ],
        history: WindowFrameHistory = InMemoryWindowFrameHistory(),
        fullScreenWriter: WindowFullScreenWriting? = nil,
        focusedWindowResolver: FocusedWindowResolving? = nil,
        stageManagerSafeAreaProvider: StageManagerSafeAreaProviding? = nil,
        waitForFrameSettlement: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in }
    ) -> WindowLayoutService {
        WindowLayoutService(
            focusedWindowResolver: focusedWindowResolver ?? MockFocusedWindowResolver(window: window),
            frameReader: frameAdapter,
            screenProvider: MockWindowScreenProvider(screens: screens),
            history: history,
            fullScreenWriter: fullScreenWriter,
            stageManagerSafeAreaProvider: stageManagerSafeAreaProvider
                ?? SystemStageManagerSafeAreaProvider(),
            waitForFrameSettlement: waitForFrameSettlement
        )
    }

    private func assertSuccess(
        _ result: Result<Void, WindowLayoutError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case let .failure(error) = result {
            XCTFail("Expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertFailure(
        _ result: Result<Void, WindowLayoutError>,
        equals expectedError: WindowLayoutError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("Expected failure", file: file, line: line)
        }
        XCTAssertEqual(error, expectedError, file: file, line: line)
    }

    private func options(
        gap: CGFloat = 0,
        respectsStageManager: Bool = false
    ) -> WindowLayoutExecutionOptions {
        WindowLayoutExecutionOptions(
            gap: gap,
            cyclesHalves: false,
            respectsStageManager: respectsStageManager
        )
    }
}

@MainActor
private final class MockFullScreenWriter: WindowFullScreenWriting {
    private(set) var values: [Bool] = []

    func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) async throws {
        values.append(isFullScreen)
    }
}

@MainActor
private final class BlockingFullScreenWriter: WindowFullScreenWriting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var values: [Bool] = []
    var isBlocked: Bool { continuation != nil }

    func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        values.append(isFullScreen)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MockFocusedWindowResolver: FocusedWindowResolving {
    private let windows: [AccessibilityWindowHandle]
    private var nextIndex = 0

    init(window: AccessibilityWindowHandle) {
        self.windows = [window]
    }

    init(windows: [AccessibilityWindowHandle]) {
        self.windows = windows
    }

    func resolveFocusedWindow() async throws -> AccessibilityWindowHandle {
        guard let window = windows.indices.contains(nextIndex)
            ? windows[nextIndex]
            : windows.last
        else {
            throw WindowLayoutError.noFocusedWindow
        }
        nextIndex += 1
        return window
    }
}

@MainActor
private final class MutableFocusedWindowResolver: FocusedWindowResolving {
    var window: AccessibilityWindowHandle
    private(set) var resolveCount = 0

    init(window: AccessibilityWindowHandle) {
        self.window = window
    }

    func resolveFocusedWindow() async throws -> AccessibilityWindowHandle {
        resolveCount += 1
        return window
    }
}

@MainActor
private final class MockWindowFrameAdapter: WindowFrameReading, WindowFrameWriting {
    var frames: [WindowIdentity: CGRect]
    var validIdentities: Set<WindowIdentity>
    private(set) var writtenFrames: [CGRect] = []
    var failsEnhancedUIRestoration = false
    private let appliesWrites: Bool
    private var ignoredWritesRemaining: Int
    private let defersWritesUntilSettlement: Bool
    private var pendingWrite: (identity: WindowIdentity, frame: CGRect)?

    init(
        window: AccessibilityWindowHandle,
        frame: CGRect,
        appliesWrites: Bool = true,
        ignoredWrites: Int = 0,
        defersWritesUntilSettlement: Bool = false
    ) {
        self.frames = [window.identity: frame]
        self.validIdentities = [window.identity]
        self.appliesWrites = appliesWrites
        self.ignoredWritesRemaining = ignoredWrites
        self.defersWritesUntilSettlement = defersWritesUntilSettlement
    }

    func frame(of window: AccessibilityWindowHandle) async throws -> CGRect {
        guard let frame = frames[window.identity] else {
            throw WindowLayoutError.windowUnavailable
        }
        return frame
    }

    func isValid(_ window: AccessibilityWindowHandle) async -> Bool {
        validIdentities.contains(window.identity)
    }

    func setFrame(
        _ frame: CGRect,
        of window: AccessibilityWindowHandle,
        resize: Bool
    ) async throws {
        writtenFrames.append(frame)
        guard appliesWrites else { return }
        if ignoredWritesRemaining > 0 {
            ignoredWritesRemaining -= 1
            return
        }
        if defersWritesUntilSettlement {
            pendingWrite = (window.identity, frame)
            return
        }
        if failsEnhancedUIRestoration {
            var enabled = true
            try WindowEnhancedUIFrameGuard.perform(
                preserveEnhancedUI: false,
                readEnabled: { enabled },
                setEnabled: { value in
                    if value { return false }
                    enabled = false
                    return true
                }
            ) { frames[window.identity] = frame }
        } else {
            frames[window.identity] = frame
        }
    }

    func settlePendingWrite() {
        guard let pendingWrite else { return }
        frames[pendingWrite.identity] = pendingWrite.frame
        self.pendingWrite = nil
    }
}

@MainActor
private struct MockWindowScreenProvider: WindowScreenProviding {
    let screens: [WindowScreen]

    func currentScreens() -> [WindowScreen] {
        screens
    }
}
