import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

@MainActor
protocol WindowModifierDragSessionManaging: AnyObject {
    var onFailure: (WindowLayoutError) -> Void { get set }
    var onSuccess: () -> Void { get set }
    var isRunning: Bool { get }
    func configure(modifiers: ShortcutModifiers, showsIndicator: Bool)
    func configure(modifiers: ShortcutModifiers)
    func start() -> Result<Void, WindowModifierDragMonitorStartError>
    func stop()
}

extension WindowModifierDragSessionManaging {
    func configure(modifiers: ShortcutModifiers) {
        configure(modifiers: modifiers, showsIndicator: true)
    }
}

@MainActor
protocol WindowUnderPointerResolving {
    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle
}

@MainActor
final class SystemWindowUnderPointerResolver: WindowUnderPointerResolving {
    typealias WindowInfoProvider = () -> [[String: Any]]

    private let accessibilityTrusted: @MainActor () -> Bool
    private let windowInfoProvider: WindowInfoProvider
    private let hostWindow: @MainActor (Int) -> NSWindow?
    private let worker: any ExternalWindowResolving

    init(
        accessibilityTrusted: @escaping @MainActor () -> Bool = AXIsProcessTrusted,
        windowInfoProvider: @escaping WindowInfoProvider = {
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        },
        hostWindow: @escaping @MainActor (Int) -> NSWindow? = { windowNumber in
            NSApp.windows.first(where: {
                $0.windowNumber == windowNumber && $0.isVisible
            })
        },
        worker: any ExternalWindowResolving = WindowAccessibilityWorker()
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.windowInfoProvider = windowInfoProvider
        self.hostWindow = hostWindow
        self.worker = worker
    }

    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle {
        guard accessibilityTrusted() else {
            throw WindowLayoutError.accessibilityRequired
        }
        guard let target = Self.windowTarget(at: point, in: windowInfoProvider()) else {
            throw WindowLayoutError.noWindowUnderPointer
        }

        if target.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let window = hostWindow(target.windowNumber), window.isMovable else {
                throw WindowLayoutError.windowCannotMove
            }
            return AccessibilityWindowHandle(
                identity: WindowIdentity(
                    processIdentifier: target.processIdentifier,
                    token: "window-number:\(target.windowNumber)"
                ),
                bundleIdentifier: Bundle.main.bundleIdentifier,
                title: window.title,
                windowNumber: UInt32(exactly: target.windowNumber),
                canMove: window.isMovable,
                canResize: window.styleMask.contains(.resizable),
                hostWindow: window
            )
        }

        let application = NSRunningApplication(processIdentifier: target.processIdentifier)
        return try await worker.resolveFocusedWindow(target: ExternalFocusedWindowTarget(
            processIdentifier: target.processIdentifier,
            bundleIdentifier: application?.bundleIdentifier,
            preferredWindowNumber: target.windowNumber,
            pointerLocation: point
        ))
    }

    nonisolated static func windowTarget(
        at point: CGPoint,
        in windowInfo: [[String: Any]]
    ) -> (processIdentifier: pid_t, windowNumber: Int)? {
        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let processIdentifier = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processIdentifier > 0,
                  let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  windowNumber > 0,
                  let bounds = rect(from: info[kCGWindowBounds as String]),
                  bounds.width > 0,
                  bounds.height > 0,
                  bounds.contains(point)
            else {
                continue
            }
            return (processIdentifier, windowNumber)
        }
        return nil
    }

    nonisolated private static func rect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }
}

@MainActor
final class WindowModifierDragController {
    var onFailure: (WindowLayoutError) -> Void = { _ in }
    var onSuccess: () -> Void = {}

    private let resolver: any WindowUnderPointerResolving
    private let frameReader: any WindowFrameReading
    private let frameWriter: any WindowFrameWriting
    private let hudPresenter: (any WindowModifierDragHUDPresenting)?
    private let pointerLocation: () -> CGPoint
    private let localizedErrorMessage: (WindowLayoutError) -> String
    private let armDelay: TimeInterval
    private let activeDuration: TimeInterval
    private let failureDuration: TimeInterval

    var showsIndicator: Bool
    var requiredModifiers: ShortcutModifiers

    private var generation: UInt64?
    private var originPointer = CGPoint.zero
    private var pendingPointer = CGPoint.zero
    private var window: AccessibilityWindowHandle?
    private var originalFrame: CGRect?
    private var resolutionTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var armTask: Task<Void, Never>?
    private var activeDismissTask: Task<Void, Never>?
    private var failureDismissTask: Task<Void, Never>?
    private var isHUDPresented = false

    init(
        resolver: any WindowUnderPointerResolving,
        frameReader: any WindowFrameReading,
        frameWriter: any WindowFrameWriting,
        hudPresenter: (any WindowModifierDragHUDPresenting)? = nil,
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        localizedErrorMessage: @escaping (WindowLayoutError) -> String = { error in
            switch error {
            case .noWindowUnderPointer:
                return "No movable window under pointer"
            case .windowCannotMove:
                return "Window cannot move"
            case .accessibilityRequired:
                return "Accessibility required"
            case .windowUnavailable:
                return "Window unavailable"
            case .frameWriteFailed:
                return "Unable to move window"
            default:
                return "Unable to move window"
            }
        },
        armDelay: TimeInterval = 0.18,
        activeDuration: TimeInterval = 0.6,
        failureDuration: TimeInterval = 1.2,
        showsIndicator: Bool = true,
        requiredModifiers: ShortcutModifiers = WindowLayoutsStore.defaultModifierDragModifiers
    ) {
        self.resolver = resolver
        self.frameReader = frameReader
        self.frameWriter = frameWriter
        self.hudPresenter = hudPresenter
        self.pointerLocation = pointerLocation
        self.localizedErrorMessage = localizedErrorMessage
        self.armDelay = armDelay
        self.activeDuration = activeDuration
        self.failureDuration = failureDuration
        self.showsIndicator = showsIndicator
        self.requiredModifiers = requiredModifiers
    }

    func arm(generation: UInt64, pointer: CGPoint) {
        if self.generation == generation && armTask != nil {
            return
        }
        self.generation = generation
        originPointer = pointer
        pendingPointer = pointer

        armTask?.cancel()
        activeDismissTask?.cancel()
        failureDismissTask?.cancel()
        if isHUDPresented {
            isHUDPresented = false
            hudPresenter?.dismiss()
        }

        guard showsIndicator, hudPresenter != nil else { return }

        armTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.armDelay * 1_000_000_000))
                guard !Task.isCancelled, self.generation == generation, self.showsIndicator else { return }
                let location = self.pointerLocation()
                self.isHUDPresented = true
                self.hudPresenter?.present(.armed(modifiers: self.requiredModifiers, pointer: location))
            } catch {
                return
            }
        }
    }

    func begin(generation: UInt64, origin: CGPoint, pointer: CGPoint) {
        armTask?.cancel()
        armTask = nil
        activeDismissTask?.cancel()
        failureDismissTask?.cancel()

        if self.generation != generation {
            cancelAll(dismissHUD: false)
            self.generation = generation
        }
        originPointer = origin
        pendingPointer = pointer
        resolutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let window = try await resolver.resolveWindow(at: origin)
                guard window.canMove else { throw WindowLayoutError.windowCannotMove }
                let frame = try await frameReader.frame(of: window)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.window = window
                self.originalFrame = frame
                self.resolutionTask = nil
                if self.showsIndicator {
                    self.isHUDPresented = true
                    let location = self.pointerLocation()
                    self.hudPresenter?.present(.active(modifiers: self.requiredModifiers, pointer: location))
                    self.scheduleActiveDismiss(generation: generation)
                }
                self.flush(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.fail(error as? WindowLayoutError ?? .windowUnavailable)
            }
        }
    }

    func update(generation: UInt64, pointer: CGPoint) {
        guard self.generation == generation else { return }
        pendingPointer = pointer
        flush(generation: generation)
    }

    func cancel(generation: UInt64) {
        guard self.generation == generation || self.generation == nil else { return }
        cancelAll()
    }

    func stop() {
        cancelAll()
    }

    private func flush(generation: UInt64) {
        guard writeTask == nil,
              self.generation == generation,
              let window,
              let originalFrame
        else { return }

        let pointer = pendingPointer
        let targetFrame = CGRect(
            origin: CGPoint(
                x: originalFrame.minX + pointer.x - originPointer.x,
                y: originalFrame.minY + pointer.y - originPointer.y
            ),
            size: originalFrame.size
        )
        writeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await frameWriter.setFrame(targetFrame, of: window, resize: false)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.onSuccess()
                self.writeTask = nil
                if self.pendingPointer != pointer {
                    self.flush(generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.fail(error as? WindowLayoutError ?? .frameWriteFailed)
            }
        }
    }

    private func fail(_ error: WindowLayoutError) {
        cancelAll(dismissHUD: false)
        if showsIndicator {
            let message = localizedErrorMessage(error)
            let location = pointerLocation()
            isHUDPresented = true
            hudPresenter?.present(.failure(message: message, pointer: location))
            scheduleFailureDismiss()
        }
        onFailure(error)
    }

    private func scheduleActiveDismiss(generation: UInt64) {
        activeDismissTask?.cancel()
        activeDismissTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.activeDuration * 1_000_000_000))
                guard !Task.isCancelled, self.generation == generation else { return }
                if self.isHUDPresented {
                    self.isHUDPresented = false
                    self.hudPresenter?.dismiss()
                }
            } catch {
                return
            }
        }
    }

    private func scheduleFailureDismiss() {
        failureDismissTask?.cancel()
        failureDismissTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.failureDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self.isHUDPresented {
                    self.isHUDPresented = false
                    self.hudPresenter?.dismiss()
                }
            } catch {
                return
            }
        }
    }

    private func cancelAll(dismissHUD: Bool = true) {
        armTask?.cancel()
        activeDismissTask?.cancel()
        if dismissHUD {
            failureDismissTask?.cancel()
            failureDismissTask = nil
            if isHUDPresented {
                isHUDPresented = false
                hudPresenter?.dismiss()
            }
        }
        resolutionTask?.cancel()
        writeTask?.cancel()
        armTask = nil
        activeDismissTask = nil
        resolutionTask = nil
        writeTask = nil
        generation = nil
        window = nil
        originalFrame = nil
    }
}

struct WindowModifierDragActionQueue {
    private var epoch: UInt64 = 0
    private var isActive = false
    private var isDrainScheduled = false
    private var actions: [WindowModifierDragGestureAction] = []

    mutating func activate() -> UInt64 {
        epoch &+= 1
        isActive = true
        isDrainScheduled = false
        actions.removeAll(keepingCapacity: true)
        return epoch
    }

    mutating func deactivate() {
        epoch &+= 1
        isActive = false
        isDrainScheduled = false
        actions.removeAll(keepingCapacity: true)
    }

    mutating func enqueue(_ action: WindowModifierDragGestureAction) -> UInt64? {
        guard isActive else { return nil }

        if case let .update(generation, _) = action,
           let last = actions.last,
           case let .update(lastGeneration, _) = last,
           generation == lastGeneration {
            actions[actions.index(before: actions.endIndex)] = action
        } else {
            actions.append(action)
        }

        guard !isDrainScheduled else { return nil }
        isDrainScheduled = true
        return epoch
    }

    mutating func nextAction(for drainEpoch: UInt64) -> WindowModifierDragGestureAction? {
        guard isActive, epoch == drainEpoch else { return nil }
        guard !actions.isEmpty else {
            isDrainScheduled = false
            return nil
        }
        return actions.removeFirst()
    }
}

nonisolated final class WindowModifierDragSession: @unchecked Sendable,
    WindowModifierDragSessionManaging
{
    @MainActor var onFailure: (WindowLayoutError) -> Void {
        get { controller.onFailure }
        set { controller.onFailure = newValue }
    }
    @MainActor var onSuccess: () -> Void {
        get { controller.onSuccess }
        set { controller.onSuccess = newValue }
    }

    private let lock = NSLock()
    private let controller: WindowModifierDragController
    private let eventMonitor: any WindowModifierDragEventMonitoring
    private var gesture: WindowModifierDragGesture
    private var actionQueue = WindowModifierDragActionQueue()

    @MainActor var isRunning: Bool { eventMonitor.isRunning }

    @MainActor
    init(
        modifiers: ShortcutModifiers = WindowLayoutsStore.defaultModifierDragModifiers,
        showsIndicator: Bool = true,
        resolver: (any WindowUnderPointerResolving)? = nil,
        frameAdapter: AccessibilityWindowFrameAdapter? = nil,
        eventMonitor: (any WindowModifierDragEventMonitoring)? = nil,
        hudPresenter: (any WindowModifierDragHUDPresenting)? = nil,
        pointerLocation: (() -> CGPoint)? = nil,
        localizedErrorMessage: ((WindowLayoutError) -> String)? = nil,
        armDelay: TimeInterval = 0.18,
        activeDuration: TimeInterval = 0.6,
        failureDuration: TimeInterval = 1.2
    ) {
        let adapter = frameAdapter ?? AccessibilityWindowFrameAdapter()
        let resolvedHUDPresenter = hudPresenter ?? WindowModifierDragHUDController()
        self.controller = WindowModifierDragController(
            resolver: resolver ?? SystemWindowUnderPointerResolver(),
            frameReader: adapter,
            frameWriter: adapter,
            hudPresenter: resolvedHUDPresenter,
            pointerLocation: pointerLocation ?? { NSEvent.mouseLocation },
            localizedErrorMessage: localizedErrorMessage ?? { error in
                switch error {
                case .noWindowUnderPointer:
                    return "No movable window under pointer"
                case .windowCannotMove:
                    return "Window cannot move"
                case .accessibilityRequired:
                    return "Accessibility required"
                case .windowUnavailable:
                    return "Window unavailable"
                case .frameWriteFailed:
                    return "Unable to move window"
                default:
                    return "Unable to move window"
                }
            },
            armDelay: armDelay,
            activeDuration: activeDuration,
            failureDuration: failureDuration,
            showsIndicator: showsIndicator,
            requiredModifiers: modifiers
        )
        self.eventMonitor = eventMonitor ?? SystemWindowModifierDragEventMonitor()
        self.gesture = WindowModifierDragGesture(requiredModifiers: modifiers)
    }

    @MainActor
    func configure(modifiers: ShortcutModifiers, showsIndicator: Bool) {
        controller.showsIndicator = showsIndicator
        controller.requiredModifiers = modifiers
        if !showsIndicator {
            controller.cancel(generation: 0)
        }
        let cancellation = lock.withLock { () -> WindowModifierDragGestureAction? in
            let cancellation = gesture.reset()
            gesture.requiredModifiers = modifiers
            return cancellation
        }
        dispatch(cancellation)
    }

    @MainActor
    func configure(modifiers: ShortcutModifiers) {
        configure(modifiers: modifiers, showsIndicator: controller.showsIndicator)
    }

    @MainActor
    func start() -> Result<Void, WindowModifierDragMonitorStartError> {
        if eventMonitor.isRunning { return .success(()) }
        lock.withLock {
            _ = actionQueue.activate()
        }
        let eventHandler = WindowModifierDragEventHandler { [weak self] event in
            self?.handle(event)
        }
        let result = eventMonitor.start(handler: eventHandler)
        if case .failure = result {
            eventMonitor.stop()
            lock.withLock {
                _ = gesture.reset()
                actionQueue.deactivate()
            }
            controller.stop()
        }
        return result
    }

    @MainActor
    func stop() {
        eventMonitor.stop()
        lock.withLock {
            _ = gesture.reset()
            actionQueue.deactivate()
        }
        controller.stop()
    }

    private func handle(_ event: WindowModifierDragMonitorEvent) {
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            let cancellation = lock.withLock { gesture.reset() }
            dispatch(cancellation)
            return
        }

        let modifiers = ShortcutModifiers.from(event.flags)
        let action = lock.withLock { () -> WindowModifierDragGestureAction? in
            switch event.type {
            case .flagsChanged:
                return gesture.modifiersChanged(modifiers, pointer: event.location)
            case .mouseMoved:
                guard gesture.shouldProcessPointerMovement(modifiers: modifiers) else {
                    return nil
                }
                return gesture.pointerMoved(to: event.location, modifiers: modifiers)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return gesture.mouseButtonPressed()
            case .keyDown:
                return gesture.keyPressed()
            default:
                return nil
            }
        }
        dispatch(action)
    }

    private func dispatch(_ action: WindowModifierDragGestureAction?) {
        guard let action else { return }
        let drainEpoch = lock.withLock { actionQueue.enqueue(action) }
        guard let drainEpoch else { return }
        Task { @MainActor [weak self] in
            self?.drainActions(epoch: drainEpoch)
        }
    }

    @MainActor
    private func drainActions(epoch: UInt64) {
        while let action = lock.withLock({ actionQueue.nextAction(for: epoch) }) {
            switch action {
            case let .arm(generation, pointer):
                controller.arm(generation: generation, pointer: pointer)
            case let .begin(generation, origin, pointer):
                controller.begin(generation: generation, origin: origin, pointer: pointer)
            case let .update(generation, pointer):
                controller.update(generation: generation, pointer: pointer)
            case let .cancel(generation):
                controller.cancel(generation: generation)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
