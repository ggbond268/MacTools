import CoreGraphics
import Foundation

@MainActor
private final class WindowLayoutExecutionGate {
    struct Reservation: Hashable {
        fileprivate let id = UUID()
    }

    enum Acquisition {
        case acquired
        case cancelled
    }

    private static let maximumReservationCount = 9
    private var reservations: [Reservation] = []
    private var waiters: [Reservation: CheckedContinuation<Bool, Never>] = [:]

    func reserve() -> Reservation? {
        guard reservations.count < Self.maximumReservationCount else { return nil }
        let reservation = Reservation()
        reservations.append(reservation)
        return reservation
    }

    func acquire(_ reservation: Reservation) async -> Acquisition {
        guard !Task.isCancelled,
              reservations.contains(reservation) else { return .cancelled }
        guard reservations.first != reservation else { return .acquired }
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      reservations.contains(reservation) else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[reservation] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(reservation)
            }
        }
        return acquired ? .acquired : .cancelled
    }

    func finish(_ reservation: Reservation) {
        remove(reservation, acquired: true)
    }

    private func cancel(_ reservation: Reservation) {
        remove(reservation, acquired: false)
    }

    private func remove(_ reservation: Reservation, acquired: Bool) {
        guard let index = reservations.firstIndex(of: reservation) else { return }
        let wasFirst = index == reservations.startIndex
        reservations.remove(at: index)
        waiters.removeValue(forKey: reservation)?.resume(returning: acquired)
        if wasFirst, let next = reservations.first {
            waiters.removeValue(forKey: next)?.resume(returning: true)
        }
    }
}

@MainActor
protocol WindowLayoutExecuting: AnyObject {
    func validationError(for operation: WindowLayoutOperation, options: WindowLayoutExecutionOptions) async -> WindowLayoutError?
    func execute(_ operation: WindowLayoutOperation, options: WindowLayoutExecutionOptions) async -> Result<Void, WindowLayoutError>
    func validationError(for command: WindowCustomCommand, options: WindowLayoutExecutionOptions) async -> WindowLayoutError?
    func execute(_ command: WindowCustomCommand, options: WindowLayoutExecutionOptions) async -> Result<Void, WindowLayoutError>
}

@MainActor
final class WindowLayoutService: WindowLayoutExecuting {
    private enum PreparedAction {
        case placement(PreparedPlacement)
        case fullScreen(AccessibilityWindowHandle)
    }

    private struct PreparedPlacement {
        let window: AccessibilityWindowHandle
        let targetFrame: CGRect
        let shouldResize: Bool
        let halfCyclePlan: HalfCyclePlan?
    }

    private struct HalfCyclePlan {
        let operation: WindowLayoutOperation
        let screenID: String
        let targetFrame: CGRect
        let targetIndex: Int
    }

    private struct HalfCycleState {
        let plan: HalfCyclePlan
        let observedFrame: CGRect
    }

    private struct CycledFrame {
        let frame: CGRect
        let plan: HalfCyclePlan?
    }

    private let focusedWindowResolver: FocusedWindowResolving
    private let frameReader: WindowFrameReading
    private let frameWriter: WindowFrameWriting
    private let screenProvider: WindowScreenProviding
    private let screenResolver: WindowScreenResolver
    private let calculator: WindowLayoutCalculator
    private let history: WindowFrameHistory
    private let fullScreenWriter: WindowFullScreenWriting
    private let stageManagerSafeAreaProvider: StageManagerSafeAreaProviding
    private let waitForFrameSettlement: @MainActor @Sendable (Duration) async throws -> Void
    private let executionGate = WindowLayoutExecutionGate()
    private var halfCycleStates: [WindowIdentity: HalfCycleState] = [:]

    init(
        focusedWindowResolver: FocusedWindowResolving = SystemFocusedWindowResolver(),
        frameReader: WindowFrameReading = AccessibilityWindowFrameAdapter(),
        frameWriter: WindowFrameWriting? = nil,
        screenProvider: WindowScreenProviding = SystemWindowScreenProvider(),
        screenResolver: WindowScreenResolver = WindowScreenResolver(),
        calculator: WindowLayoutCalculator = WindowLayoutCalculator(),
        history: WindowFrameHistory = InMemoryWindowFrameHistory(),
        fullScreenWriter: WindowFullScreenWriting? = nil,
        stageManagerSafeAreaProvider: StageManagerSafeAreaProviding = SystemStageManagerSafeAreaProvider(),
        waitForFrameSettlement: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.focusedWindowResolver = focusedWindowResolver
        self.frameReader = frameReader
        self.frameWriter = frameWriter ?? (frameReader as? WindowFrameWriting)
            ?? AccessibilityWindowFrameAdapter()
        self.screenProvider = screenProvider
        self.screenResolver = screenResolver
        self.calculator = calculator
        self.history = history
        self.fullScreenWriter = fullScreenWriter ?? (frameReader as? WindowFullScreenWriting)
            ?? AccessibilityWindowFrameAdapter()
        self.stageManagerSafeAreaProvider = stageManagerSafeAreaProvider
        self.waitForFrameSettlement = waitForFrameSettlement
    }

    func validationError(
        for operation: WindowLayoutOperation,
        options: WindowLayoutExecutionOptions
    ) async -> WindowLayoutError? {
        do {
            let window = try await focusedWindowResolver.resolveFocusedWindow()
            _ = try await prepare(operation, for: window, options: options)
            return nil
        } catch is CancellationError {
            return .executionCancelled
        } catch let error as WindowLayoutError {
            return error
        } catch {
            return .windowUnavailable
        }
    }

    func execute(
        _ operation: WindowLayoutOperation,
        options: WindowLayoutExecutionOptions
    ) async -> Result<Void, WindowLayoutError> {
        guard let reservation = executionGate.reserve() else {
            return .failure(.executionQueueFull)
        }
        defer { executionGate.finish(reservation) }
        do {
            let intendedWindow = try await focusedWindowResolver.resolveFocusedWindow()
            switch await executionGate.acquire(reservation) {
            case .acquired:
                break
            case .cancelled:
                return .failure(.executionCancelled)
            }
            try Task.checkCancellation()
            let currentWindow = try await revalidatedWindow(matching: intendedWindow.identity)
            let action = try await prepare(operation, for: currentWindow, options: options)
            switch action {
            case let .placement(placement):
                try await apply(
                    placement,
                    to: try await revalidatedWindow(matching: placement.window.identity)
                )
            case let .fullScreen(window):
                let currentWindow = try await revalidatedWindow(matching: window.identity)
                guard currentWindow.canToggleFullScreen else {
                    throw WindowLayoutError.fullScreenUnsupported
                }
                try Task.checkCancellation()
                try await fullScreenWriter.setFullScreen(!currentWindow.isFullScreen, for: currentWindow)
                halfCycleStates.removeValue(forKey: currentWindow.identity)
            }
            return .success(())
        } catch is CancellationError {
            return .failure(.executionCancelled)
        } catch let error as WindowLayoutError {
            return .failure(error)
        } catch {
            return .failure(.frameWriteFailed)
        }
    }

    func validationError(
        for command: WindowCustomCommand,
        options: WindowLayoutExecutionOptions
    ) async -> WindowLayoutError? {
        do {
            let window = try await focusedWindowResolver.resolveFocusedWindow()
            _ = try await prepare(command, for: window, options: options)
            return nil
        } catch is CancellationError {
            return .executionCancelled
        } catch let error as WindowLayoutError {
            return error
        } catch {
            return .windowUnavailable
        }
    }

    func execute(
        _ command: WindowCustomCommand,
        options: WindowLayoutExecutionOptions
    ) async -> Result<Void, WindowLayoutError> {
        guard let reservation = executionGate.reserve() else {
            return .failure(.executionQueueFull)
        }
        defer { executionGate.finish(reservation) }
        do {
            let intendedWindow = try await focusedWindowResolver.resolveFocusedWindow()
            switch await executionGate.acquire(reservation) {
            case .acquired:
                break
            case .cancelled:
                return .failure(.executionCancelled)
            }
            try Task.checkCancellation()
            let currentWindow = try await revalidatedWindow(matching: intendedWindow.identity)
            let placement = try await prepare(command, for: currentWindow, options: options)
            try await apply(
                placement,
                to: try await revalidatedWindow(matching: placement.window.identity)
            )
            return .success(())
        } catch is CancellationError {
            return .failure(.executionCancelled)
        } catch let error as WindowLayoutError {
            return .failure(error)
        } catch {
            return .failure(.frameWriteFailed)
        }
    }

    private func prepare(
        _ operation: WindowLayoutOperation,
        for window: AccessibilityWindowHandle,
        options: WindowLayoutExecutionOptions
    ) async throws -> PreparedAction {
        try Task.checkCancellation()
        if operation == .toggleFullScreen {
            guard window.canToggleFullScreen else {
                throw WindowLayoutError.fullScreenUnsupported
            }
            return .fullScreen(window)
        }
        let currentFrame = try await frameReader.frame(of: window)
        guard window.canMove else {
            throw WindowLayoutError.windowCannotMove
        }

        let screens = screenProvider.currentScreens()
        guard let currentScreen = screenResolver.screen(for: currentFrame, among: screens) else {
            throw WindowLayoutError.noDisplay
        }

        let effectiveCurrentScreen = screen(
            currentScreen,
            respectingStageManager: options.respectsStageManager
        )
        let targetFrame: CGRect
        var halfCyclePlan: HalfCyclePlan? = nil
        switch operation {
        case .moveToNextDisplay, .moveToPreviousDisplay:
            guard let destination = screenResolver.adjacentScreen(
                to: currentScreen,
                direction: operation,
                among: screens
            ) else {
                throw WindowLayoutError.noOtherDisplay
            }
            targetFrame = calculator.movedFrame(
                currentFrame,
                from: effectiveCurrentScreen.visibleFrame,
                to: screen(destination, respectingStageManager: options.respectsStageManager).visibleFrame,
                preservingSize: !window.canResize
            )
        case .restorePreviousFrame:
            guard await frameReader.isValid(window) else {
                history.removeFrame(for: window)
                throw WindowLayoutError.noPreviousFrame
            }
            guard let previousFrame = history.previousFrame(for: window) else {
                throw WindowLayoutError.noPreviousFrame
            }
            guard let nearestScreen = screenResolver.screen(
                for: previousFrame,
                among: screens
            ) else {
                throw WindowLayoutError.noDisplay
            }
            let safeVisibleFrame = screen(
                nearestScreen,
                respectingStageManager: options.respectsStageManager
            ).visibleFrame
            let safePreviousFrame = calculator.restoreReachableFrame(
                previousFrame,
                inside: safeVisibleFrame
            )
            if safePreviousFrame.size != currentFrame.size, !window.canResize {
                throw WindowLayoutError.windowCannotResize
            }
            targetFrame = safePreviousFrame
        default:
            if operation.requiresResize, !window.canResize {
                throw WindowLayoutError.windowCannotResize
            }
            guard let cycledFrame = cycledFrame(
                for: operation,
                window: window,
                currentFrame: currentFrame,
                currentScreen: effectiveCurrentScreen,
                options: options
            ) else {
                throw WindowLayoutError.frameWriteFailed
            }
            targetFrame = cycledFrame.frame
            halfCyclePlan = cycledFrame.plan
        }

        if targetFrame.size != currentFrame.size, !window.canResize {
            throw WindowLayoutError.windowCannotResize
        }

        return .placement(PreparedPlacement(
            window: window,
            targetFrame: targetFrame,
            shouldResize: targetFrame.size != currentFrame.size,
            halfCyclePlan: halfCyclePlan
        ))
    }

    private func prepare(
        _ command: WindowCustomCommand,
        for window: AccessibilityWindowHandle,
        options: WindowLayoutExecutionOptions
    ) async throws -> PreparedPlacement {
        try Task.checkCancellation()
        guard window.canMove else { throw WindowLayoutError.windowCannotMove }
        let currentFrame = try await frameReader.frame(of: window)
        let screens = screenProvider.currentScreens()
        guard let rawScreen = screenResolver.screen(for: currentFrame, among: screens) else {
            throw WindowLayoutError.noDisplay
        }
        let currentScreen = screen(rawScreen, respectingStageManager: options.respectsStageManager)
        let targetFrame = calculator.customFrame(
            for: command,
            windowFrame: currentFrame,
            visibleFrame: currentScreen.visibleFrame,
            gap: options.gap
        )
        if targetFrame.size != currentFrame.size, !window.canResize {
            throw WindowLayoutError.windowCannotResize
        }
        return PreparedPlacement(
            window: window,
            targetFrame: targetFrame,
            shouldResize: targetFrame.size != currentFrame.size,
            halfCyclePlan: nil
        )
    }

    private func revalidatedWindow(
        matching expectedIdentity: WindowIdentity
    ) async throws -> AccessibilityWindowHandle {
        try Task.checkCancellation()
        let currentWindow = try await focusedWindowResolver.resolveFocusedWindow()
        guard currentWindow.identity == expectedIdentity else {
            throw WindowLayoutError.windowUnavailable
        }
        return currentWindow
    }

    private func apply(
        _ placement: PreparedPlacement,
        to currentWindow: AccessibilityWindowHandle
    ) async throws {
        guard currentWindow.canMove else {
            throw WindowLayoutError.windowCannotMove
        }
        if placement.shouldResize, !currentWindow.canResize {
            throw WindowLayoutError.windowCannotResize
        }
        try Task.checkCancellation()
        let currentFrame = try await frameReader.frame(of: currentWindow)
        try await frameWriter.setFrame(
            placement.targetFrame,
            of: currentWindow,
            resize: placement.shouldResize
        )
        var observedFrame = try await frameReader.frame(of: currentWindow)
        var didRetryWrite = false
        let settlementDelays: [Duration] = [
            .milliseconds(16),
            .milliseconds(34),
            .milliseconds(75),
            .milliseconds(125),
        ]
        for delay in settlementDelays where !approximatelyEqual(
            observedFrame,
            placement.targetFrame
        ) {
            try await waitForFrameSettlement(delay)
            let settledWindow = try await revalidatedWindow(matching: currentWindow.identity)
            observedFrame = try await frameReader.frame(of: settledWindow)
            if !approximatelyEqual(observedFrame, placement.targetFrame), !didRetryWrite {
                try Task.checkCancellation()
                try await frameWriter.setFrame(
                    placement.targetFrame,
                    of: settledWindow,
                    resize: placement.shouldResize
                )
                didRetryWrite = true
                observedFrame = try await frameReader.frame(of: settledWindow)
            }
        }
        history.record(currentFrame, for: currentWindow)
        if let plan = placement.halfCyclePlan {
            halfCycleStates[currentWindow.identity] = HalfCycleState(
                plan: plan,
                observedFrame: observedFrame
            )
        } else {
            halfCycleStates.removeValue(forKey: currentWindow.identity)
        }
        if !approximatelyEqual(observedFrame.size, placement.targetFrame.size) {
            throw WindowLayoutError.windowSizeConstrained
        }
        if !approximatelyEqual(observedFrame.origin, placement.targetFrame.origin) {
            throw WindowLayoutError.frameWriteFailed
        }
    }

    private func screen(
        _ screen: WindowScreen,
        respectingStageManager: Bool
    ) -> WindowScreen {
        guard respectingStageManager else { return screen }
        return WindowScreen(
            id: screen.id,
            directDisplayID: screen.directDisplayID,
            frame: screen.frame,
            visibleFrame: stageManagerSafeAreaProvider.safeVisibleFrame(for: screen)
        )
    }

    private func cycledFrame(
        for operation: WindowLayoutOperation,
        window: AccessibilityWindowHandle,
        currentFrame: CGRect,
        currentScreen: WindowScreen,
        options: WindowLayoutExecutionOptions
    ) -> CycledFrame? {
        guard options.cyclesHalves else {
            return calculator.placementFrame(
                for: operation,
                windowFrame: currentFrame,
                visibleFrame: currentScreen.visibleFrame,
                gap: options.gap
            ).map { CycledFrame(frame: $0, plan: nil) }
        }

        let frames = calculator.halfCycleFrames(
            for: operation,
            windowFrame: currentFrame,
            visibleFrame: currentScreen.visibleFrame,
            gap: options.gap
        )
        guard !frames.isEmpty else {
            return calculator.placementFrame(
                for: operation,
                windowFrame: currentFrame,
                visibleFrame: currentScreen.visibleFrame,
                gap: options.gap
            ).map { CycledFrame(frame: $0, plan: nil) }
        }

        var currentIndex = frames.firstIndex(where: {
            approximatelyEqual($0, currentFrame)
        })
        if let previous = halfCycleStates[window.identity],
           previous.plan.operation == operation,
           previous.plan.screenID == currentScreen.id {
            if approximatelyEqual(previous.plan.targetFrame, currentFrame) {
                currentIndex = previous.plan.targetIndex
            } else if approximatelyEqual(previous.observedFrame, currentFrame) {
                // Some windows publish a delayed frame or clamp requested dimensions. Continue
                // from the step we requested while the observed frame remains unchanged.
                currentIndex = previous.plan.targetIndex
            }
        }

        let targetIndex = currentIndex.map { ($0 + 1) % frames.count } ?? 0
        let targetFrame = frames[targetIndex]
        return CycledFrame(
            frame: targetFrame,
            plan: HalfCyclePlan(
                operation: operation,
                screenID: currentScreen.id,
                targetFrame: targetFrame,
                targetIndex: targetIndex
            )
        )
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2
            && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull ? 0 : width * height
    }
}
