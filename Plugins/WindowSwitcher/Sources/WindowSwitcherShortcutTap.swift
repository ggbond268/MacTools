import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MacToolsPluginKit

protocol WindowSwitcherShortcutListening: AnyObject {
    var onShortcutPressed: @MainActor (Bool, Bool, Bool) -> Void { get set }
    var onShortcutReleased: @MainActor () -> Void { get set }
    var onEscape: @MainActor () -> Void { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
    func configure(allBinding: ShortcutBinding?, currentAppBinding: ShortcutBinding?)
    func setEditing(_ value: Bool)
    func setSessionActive(_ value: Bool)
}

final class WindowSwitcherShortcutTap: WindowSwitcherShortcutListening, @unchecked Sendable {
    var onShortcutPressed: @MainActor (_ reversed: Bool, _ isRepeat: Bool, _ currentApp: Bool) -> Void = { _, _, _ in }
    var onShortcutReleased: @MainActor () -> Void = {}
    var onEscape: @MainActor () -> Void = {}

    private let lock = NSLock()
    private var currentBinding: ShortcutBinding?
    private var currentAppBinding: ShortcutBinding?
    private var activeModifiers: ShortcutModifiers?
    private var isEditing = false
    private var sessionActive = false
    private let accessibilityTrusted: @Sendable () -> Bool
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(accessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.accessibilityTrusted = accessibilityTrusted
    }

    var isRunning: Bool {
        lock.withLock { tap != nil }
    }

    func start() {
        lock.lock()
        let alreadyRunning = tap != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        lock.lock()
        tap = newTap
        runLoopSource = source
        lock.unlock()
    }

    func stop() {
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
            let state = (tap, runLoopSource)
            tap = nil
            runLoopSource = nil
            activeModifiers = nil
            sessionActive = false; isEditing = false
            return state
        }

        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = state.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func configure(allBinding: ShortcutBinding?, currentAppBinding: ShortcutBinding?) {
        lock.withLock {
            self.currentBinding = allBinding
            self.currentAppBinding = currentAppBinding
        }
    }

    func setEditing(_ value: Bool) { lock.withLock { isEditing = value } }
    func setSessionActive(_ value: Bool) { lock.withLock { sessionActive = value } }

    private func activeModifiersSnapshot() -> ShortcutModifiers? {
        lock.withLock { activeModifiers }
    }

    private func setActiveModifiers(_ modifiers: ShortcutModifiers?) {
        lock.withLock {
            activeModifiers = modifiers
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard accessibilityTrusted() else {
            setActiveModifiers(nil)
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            return handleFlagsChanged(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Leave all composing and editing keystrokes to the native text system.
        if lock.withLock({ isEditing }) { return Unmanaged.passUnretained(event) }
        if keyCode == UInt16(kVK_Escape), lock.withLock({ sessionActive || activeModifiers != nil }) {
            setActiveModifiers(nil)
            DispatchQueue.main.async { self.onEscape() }
            return nil
        }

        // Escape and text editing belong to the panel's native responder chain,
        // including marked-text cancellation by an input method.
        let bindings = lock.withLock { [(currentBinding, false), (currentAppBinding, true)] }
        // An explicitly configured chord wins over another binding's implicit
        // Shift-to-reverse variant, regardless of which scope owns it.
        let exact = bindings.first { binding, _ in
            binding.map { keyCode == $0.keyCode && $0.matches(eventFlags: event.flags, allowingExtraShift: false) } ?? false
        }
        guard let match = exact ?? bindings.first(where: { binding, _ in
            binding.map { keyCode == $0.keyCode && $0.matches(eventFlags: event.flags, allowingExtraShift: true) } ?? false
        }), let binding = match.0 else { return Unmanaged.passUnretained(event) }
        let currentApp = match.1

        setActiveModifiers(binding.modifiers)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let reversed = !binding.modifiers.contains(.shift) && event.flags.contains(.maskShift)

        DispatchQueue.main.async {
            self.onShortcutPressed(reversed, isRepeat, currentApp)
        }

        return nil
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let activeModifiers = activeModifiersSnapshot(),
              !activeModifiers.isHeld(in: event.flags)
        else {
            return Unmanaged.passUnretained(event)
        }

        setActiveModifiers(nil)
        DispatchQueue.main.async {
            self.onShortcutReleased()
        }
        return Unmanaged.passUnretained(event)
    }

    private nonisolated static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return nil
        }

        let tap = Unmanaged<WindowSwitcherShortcutTap>.fromOpaque(userInfo).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }
}

private extension ShortcutBinding {
    func matches(eventFlags: CGEventFlags, allowingExtraShift: Bool) -> Bool {
        let actual = eventFlags.significantShortcutFlags
        let required = modifiers.cgEventFlags

        if allowingExtraShift, !required.contains(.maskShift) {
            return actual == required || actual == required.union(.maskShift)
        }

        return actual == required
    }
}

private extension ShortcutModifiers {
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) {
            flags.insert(.maskCommand)
        }
        if contains(.control) {
            flags.insert(.maskControl)
        }
        if contains(.option) {
            flags.insert(.maskAlternate)
        }
        if contains(.shift) {
            flags.insert(.maskShift)
        }
        return flags
    }

    func isHeld(in eventFlags: CGEventFlags) -> Bool {
        let actual = eventFlags.significantShortcutFlags
        return actual.intersection(cgEventFlags) == cgEventFlags
    }
}

private extension CGEventFlags {
    var significantShortcutFlags: CGEventFlags {
        intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
