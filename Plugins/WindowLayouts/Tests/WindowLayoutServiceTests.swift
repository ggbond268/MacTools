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

    func testNonResizableWindowMovesBetweenEqualSizedDisplays() async {
        let window = makeWindow(canResize: false)
        let originalFrame = CGRect(x: 100, y: 100, width: 900.1, height: 400.25)
        let frameAdapter = MockWindowFrameAdapter(window: window, frame: originalFrame)
        let screens = [
            WindowScreen(
                id: "main",
                frame: CGRect(x: 0, y: 0, width: 1_440.5, height: 900.5),
                visibleFrame: CGRect(x: 0, y: 24.25, width: 1_440.5, height: 876.25)
            ),
            WindowScreen(
                id: "right",
                frame: CGRect(x: 1_440.5, y: 0, width: 1_440.5, height: 900.5),
                visibleFrame: CGRect(x: 1_440.5, y: 24.25, width: 1_440.5, height: 876.25)
            ),
        ]
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            screens: screens
        )

        assertSuccess(await service.execute(.moveToNextDisplay, options: options()))

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 1_540.5, y: 100, width: 900.1, height: 400.25)
        )
    }

    func testNonResizableWindowMovesBetweenDifferentSizedDisplaysWithoutResizing() async {
        let window = makeWindow(canResize: false)
        let originalFrame = CGRect(x: 720, y: 462, width: 720, height: 438)
        let frameAdapter = MockWindowFrameAdapter(window: window, frame: originalFrame)
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
            ),
        ]
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            screens: screens
        )

        assertSuccess(await service.execute(.moveToNextDisplay, options: options()))

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 3280, y: 702, width: 720, height: 438)
        )
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

    func testRestoreRemovesStaleHistoryEntry() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let history = InMemoryWindowFrameHistory()
        history.record(CGRect(x: 0, y: 24, width: 1440, height: 876), for: window)
        frameAdapter.validIdentities.remove(window.identity)
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            history: history
        )

        let error = await service.validationError(
            for: .restorePreviousFrame,
            options: options()
        )
        XCTAssertEqual(error, .noPreviousFrame)
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

    func testRestoreKeepsOversizedOffTopFrameReachableWithoutResizing() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let history = InMemoryWindowFrameHistory()
        history.record(
            CGRect(x: -300, y: -200, width: 2000, height: 1200),
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
            CGRect(x: -300, y: 24, width: 2000, height: 1200)
        )
    }

    func testRestoreKeepsNonResizableOversizedWindowReachable() async {
        let historicalFrame = CGRect(x: -300, y: -200, width: 2000, height: 1200)
        let window = makeWindow(canResize: false)
        let frameAdapter = MockWindowFrameAdapter(window: window, frame: historicalFrame)
        let history = InMemoryWindowFrameHistory()
        history.record(historicalFrame, for: window)
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            history: history
        )

        assertSuccess(await service.execute(.restorePreviousFrame, options: options()))

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: -300, y: 24, width: 2000, height: 1200)
        )
    }

    func testRestoreUsesStageManagerSafeVisibleFrame() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 300, y: 100, width: 600, height: 400)
        )
        let history = InMemoryWindowFrameHistory()
        history.record(CGRect(x: 0, y: 24, width: 600, height: 400), for: window)
        let safeFrame = CGRect(x: 200, y: 24, width: 1240, height: 876)
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            history: history,
            stageManagerSafeAreaProvider: FixedStageManagerSafeAreaProvider(
                safeFrame: safeFrame
            )
        )

        assertSuccess(await service.execute(
            .restorePreviousFrame,
            options: options(respectsStageManager: true)
        ))

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 200, y: 24, width: 600, height: 400)
        )
    }

    func testRestoreClampsFrameWithOnlySliverVisibleOnSurvivingDisplay() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400)
        )
        let history = InMemoryWindowFrameHistory()
        history.record(
            CGRect(x: 1439, y: 100, width: 600, height: 400),
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
            CGRect(x: 840, y: 100, width: 600, height: 400)
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

    func testTopHalfCyclesOnlyThroughVerticalSizes() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 0, y: 24, width: 1440, height: 438)
        )
        let service = makeService(window: window, frameAdapter: frameAdapter)
        let cycling = WindowLayoutExecutionOptions(
            gap: 0,
            cyclesHalves: true,
            respectsStageManager: false
        )

        assertSuccess(await service.execute(.topHalf, options: cycling))

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 0, y: 24, width: 1440, height: 584)
        )
    }

    func testRapidHalfCycleUsesLastRequestedStepWhileAXFrameIsSettling() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 0, y: 24, width: 720, height: 876),
            ignoredWrites: 1
        )
        let service = makeService(window: window, frameAdapter: frameAdapter)
        let cycling = WindowLayoutExecutionOptions(
            gap: 0,
            cyclesHalves: true,
            respectsStageManager: false
        )

        assertSuccess(await service.execute(.leftHalf, options: cycling))
        assertSuccess(await service.execute(.leftHalf, options: cycling))

        XCTAssertEqual(
            frameAdapter.writtenFrames,
            [
                CGRect(x: 0, y: 24, width: 960, height: 876),
                CGRect(x: 0, y: 24, width: 960, height: 876),
                CGRect(x: 0, y: 24, width: 480, height: 876),
            ]
        )
    }

    func testChangingHalfOrientationResetsToRequestedHalf() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 0, y: 24, width: 720, height: 876),
            ignoredWrites: 1
        )
        let service = makeService(window: window, frameAdapter: frameAdapter)
        let cycling = WindowLayoutExecutionOptions(
            gap: 0,
            cyclesHalves: true,
            respectsStageManager: false
        )

        assertSuccess(await service.execute(.leftHalf, options: cycling))
        assertSuccess(await service.execute(.topHalf, options: cycling))

        XCTAssertEqual(
            frameAdapter.writtenFrames.last,
            CGRect(x: 0, y: 24, width: 1440, height: 438)
        )
    }

    func testRapidDirectionChangesWaitForDelayedApplicationFrames() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400),
            defersWritesUntilSettlement: true
        )
        var settlementCount = 0
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            waitForFrameSettlement: { _ in
                settlementCount += 1
                frameAdapter.settlePendingWrite()
            }
        )

        for operation in [
            WindowLayoutOperation.topHalf,
            .bottomHalf,
            .leftHalf,
            .rightHalf,
        ] {
            assertSuccess(await service.execute(operation, options: options()))
        }

        XCTAssertEqual(settlementCount, 4)
        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 720, y: 24, width: 720, height: 876)
        )
        XCTAssertEqual(frameAdapter.writtenFrames.count, 4)
    }

    func testOverlappingDirectionChangesExecuteInOrder() async {
        let window = makeWindow()
        let frameAdapter = MockWindowFrameAdapter(
            window: window,
            frame: CGRect(x: 100, y: 100, width: 600, height: 400),
            defersWritesUntilSettlement: true
        )
        var settlementContinuations: [CheckedContinuation<Void, Never>] = []
        let service = makeService(
            window: window,
            frameAdapter: frameAdapter,
            waitForFrameSettlement: { _ in
                await withCheckedContinuation { continuation in
                    settlementContinuations.append(continuation)
                }
                frameAdapter.settlePendingWrite()
            }
        )

        let top = Task { @MainActor in
            await service.execute(.topHalf, options: options())
        }
        while settlementContinuations.isEmpty { await Task.yield() }

        let right = Task { @MainActor in
            await service.execute(.rightHalf, options: options())
        }
        for _ in 0 ..< 10 { await Task.yield() }

        XCTAssertEqual(frameAdapter.writtenFrames.count, 1)
        settlementContinuations.removeFirst().resume()
        assertSuccess(await top.value)

        while settlementContinuations.isEmpty { await Task.yield() }
        XCTAssertEqual(frameAdapter.writtenFrames.count, 2)
        settlementContinuations.removeFirst().resume()
        assertSuccess(await right.value)

        XCTAssertEqual(
            frameAdapter.frames[window.identity],
            CGRect(x: 720, y: 24, width: 720, height: 876)
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

    func testExecutionQueueRejectsRequestsBeyondBoundedCapacity() async {
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

        var queued: [Task<Result<Void, WindowLayoutError>, Never>] = []
        for _ in 0 ..< 9 {
            queued.append(Task { @MainActor in
                await service.execute(.leftHalf, options: options())
            })
            for _ in 0 ..< 5 { await Task.yield() }
        }

        assertFailure(await queued[8].value, equals: .executionQueueFull)
        for task in queued.prefix(8) { task.cancel() }
        for task in queued.prefix(8) {
            assertFailure(await task.value, equals: .executionCancelled)
        }
        fullScreenWriter.resume()
        assertSuccess(await active.value)
    }

    func testWindowFrameHistoryRetainsOnlyMostRecentEntries() {
        let history = InMemoryWindowFrameHistory()
        let windows = (0 ..< 65).map { makeWindow(token: "window-\($0)") }
        for (index, window) in windows.enumerated() {
            history.record(CGRect(x: index, y: 0, width: 100, height: 100), for: window)
        }

        XCTAssertEqual(history.entryCountForTesting, 64)
        XCTAssertNil(history.previousFrame(for: windows[0]))
        XCTAssertNotNil(history.previousFrame(for: windows[64]))
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

    func testFullScreenRejectsFocusChangeImmediatelyBeforeWrite() async {
        let originalWindow = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "fullscreen"),
            canMove: false,
            canResize: false,
            canToggleFullScreen: true
        )
        let replacementWindow = AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: "replacement"),
            canMove: false,
            canResize: false,
            canToggleFullScreen: true
        )
        let frameAdapter = MockWindowFrameAdapter(window: originalWindow, frame: .zero)
        let fullScreenWriter = MockFullScreenWriter()
        let service = makeService(
            window: originalWindow,
            frameAdapter: frameAdapter,
            fullScreenWriter: fullScreenWriter,
            focusedWindowResolver: MockFocusedWindowResolver(
                windows: [originalWindow, replacementWindow]
            )
        )

        assertFailure(
            await service.execute(.toggleFullScreen, options: options()),
            equals: .windowUnavailable
        )
        XCTAssertTrue(fullScreenWriter.values.isEmpty)
    }

    private func makeWindow(
        token: String = "window",
        windowNumber: UInt32? = nil,
        canResize: Bool = true
    ) -> AccessibilityWindowHandle {
        AccessibilityWindowHandle(
            identity: WindowIdentity(processIdentifier: 42, token: token),
            windowNumber: windowNumber,
            canMove: true,
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
private struct FixedStageManagerSafeAreaProvider: StageManagerSafeAreaProviding {
    let safeFrame: CGRect

    func safeVisibleFrame(for screen: WindowScreen) -> CGRect {
        safeFrame
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
        frames[window.identity] = frame
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
