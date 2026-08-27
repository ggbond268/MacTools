import ApplicationServices
import Foundation
import MacToolsPluginKit

enum WindowModifierDragMonitorStartError: Error, Equatable, Sendable {
    case eventTapUnavailable
    case runLoopSourceUnavailable
    case eventLoopUnavailable
}

struct WindowModifierDragMonitorEvent: Sendable {
    let type: CGEventType
    let location: CGPoint
    let flags: CGEventFlags
}

/// Carries the callback across the Core Graphics event-thread boundary. The session receiving
/// events protects its gesture and action state with a lock before dispatching UI work.
nonisolated final class WindowModifierDragEventHandler: @unchecked Sendable {
    private let body: (WindowModifierDragMonitorEvent) -> Void

    init(_ body: @escaping (WindowModifierDragMonitorEvent) -> Void) {
        self.body = body
    }

    func handle(_ event: WindowModifierDragMonitorEvent) {
        body(event)
    }
}

protocol WindowModifierDragEventMonitoring: AnyObject, Sendable {
    var isRunning: Bool { get }

    func start(
        handler: WindowModifierDragEventHandler
    ) -> Result<Void, WindowModifierDragMonitorStartError>
    func stop()
}

nonisolated final class SystemWindowModifierDragEventMonitor: @unchecked Sendable,
    WindowModifierDragEventMonitoring
{
    private typealias CallbackContext = PluginCallbackContext<SystemWindowModifierDragEventMonitor>
    private let lock = NSLock()
    private let eventQueue = DispatchQueue(
        label: "com.mactools.window-layouts.modifier-drag-events",
        qos: .userInteractive
    )
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var callbackPointer: UnsafeMutableRawPointer?
    private var eventRunLoop: CFRunLoop?
    private var readySignal: DispatchSemaphore?
    private var finishedSignal: DispatchSemaphore?
    private var eventHandler: WindowModifierDragEventHandler?
    private var shouldRun = false

    var isRunning: Bool {
        lock.withLock {
            shouldRun && tap != nil && source != nil && eventRunLoop != nil
        }
    }

    func start(
        handler: WindowModifierDragEventHandler
    ) -> Result<Void, WindowModifierDragMonitorStartError> {
        if isRunning { return .success(()) }
        if lock.withLock({ tap != nil || callbackPointer != nil }) {
            stop()
        }

        let readySignal = DispatchSemaphore(value: 0)
        let finishedSignal = DispatchSemaphore(value: 0)
        switch prepareEventTap(handler: handler, readySignal: readySignal, finishedSignal: finishedSignal) {
        case .success:
            break
        case let .failure(error):
            return .failure(error)
        }

        eventQueue.async { [self] in
            runEventLoop()
        }
        readySignal.wait()

        guard isRunning else {
            stop()
            return .failure(.eventLoopUnavailable)
        }
        return .success(())
    }

    // Keep Core Foundation resource setup separate from queue startup to avoid a Swift 6.3.3
    // SendNonSendable compiler crash. Publish all startup state under the same lock.
    private func prepareEventTap(
        handler: WindowModifierDragEventHandler,
        readySignal: DispatchSemaphore,
        finishedSignal: DispatchSemaphore
    ) -> Result<Void, WindowModifierDragMonitorStartError> {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let callbackContext = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventCallback,
            userInfo: callbackPointer
        ) else {
            callbackContext.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return .failure(.eventTapUnavailable)
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            callbackContext.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            return .failure(.runLoopSourceUnavailable)
        }

        lock.withLock {
            self.tap = tap
            self.source = source
            self.callbackPointer = callbackPointer
            self.readySignal = readySignal
            self.finishedSignal = finishedSignal
            self.eventHandler = handler
            shouldRun = true
        }
        return .success(())
    }

    func stop() {
        let state = lock.withLock { () -> (
            CFMachPort?,
            UnsafeMutableRawPointer?,
            CFRunLoop?,
            DispatchSemaphore?
        ) in
            shouldRun = false
            eventHandler = nil
            return (tap, callbackPointer, eventRunLoop, finishedSignal)
        }
        guard state.0 != nil || state.1 != nil else { return }

        if let callbackPointer = state.1 {
            Unmanaged<CallbackContext>
                .fromOpaque(callbackPointer)
                .takeUnretainedValue()
                .invalidate()
        }
        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop = state.2 {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        state.3?.wait()

        if let callbackPointer = state.1 {
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
        }
        lock.withLock {
            tap = nil
            source = nil
            callbackPointer = nil
            eventRunLoop = nil
            readySignal = nil
            finishedSignal = nil
        }
    }

    private func runEventLoop() {
        let signals = lock.withLock { (readySignal, finishedSignal) }
        guard let state = lock.withLock({ () -> (
            CFMachPort,
            CFRunLoopSource,
            DispatchSemaphore,
            DispatchSemaphore
        )? in
            guard let tap, let source, let readySignal, let finishedSignal else {
                return nil
            }
            eventRunLoop = CFRunLoopGetCurrent()
            return (tap, source, readySignal, finishedSignal)
        }) else {
            signals.0?.signal()
            signals.1?.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, state.1, .defaultMode)
        CGEvent.tapEnable(tap: state.0, enable: true)
        state.2.signal()

        while lock.withLock({ shouldRun }) {
            _ = CFRunLoopRunInMode(.defaultMode, 60, true)
        }

        CFRunLoopRemoveSource(runLoop, state.1, .defaultMode)
        lock.withLock {
            eventRunLoop = nil
        }
        state.3.signal()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
           let tap = lock.withLock({ tap }) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        let handler = lock.withLock { eventHandler }
        handler?.handle(WindowModifierDragMonitorEvent(
            type: type,
            location: event.location,
            flags: event.flags
        ))
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
        context.withOwner { monitor in
            monitor.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
