import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MacToolsPluginKit

final class WindowSwitcherShortcutTap: @unchecked Sendable {
    var onShortcutPressed: @MainActor (_ reversed: Bool, _ isRepeat: Bool) -> Void = { _, _ in }
    var onShortcutReleased: @MainActor () -> Void = {}
    var onEscape: @MainActor () -> Void = {}
    var onAccessibilityRevoked: @MainActor () -> Void = {}

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let accessibilityTrusted: @Sendable () -> Bool
    private var currentBinding: ShortcutBinding?
    private var activeModifiers: ShortcutModifiers?
    private var didReportAccessibilityRevocation = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var defaultsObserver: NSObjectProtocol?

    init(
        userDefaults: UserDefaults = .standard,
        accessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.userDefaults = userDefaults
        self.accessibilityTrusted = accessibilityTrusted
        self.currentBinding = WindowSwitcherShortcutBindingStore.resolvedBinding(userDefaults: userDefaults)
    }

    var isRunning: Bool {
        lock.withLock { tap != nil }
    }

    func start() {
        lock.lock()
        let alreadyRunning = tap != nil
        lock.unlock()
        guard !alreadyRunning else {
            reloadBinding()
            return
        }

        reloadBinding()
        installDefaultsObserver()

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
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?, NSObjectProtocol?) in
            let state = (tap, runLoopSource, defaultsObserver)
            tap = nil
            runLoopSource = nil
            defaultsObserver = nil
            activeModifiers = nil
            didReportAccessibilityRevocation = false
            return state
        }

        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = state.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let observer = state.2 {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reloadBinding() {
        let binding = WindowSwitcherShortcutBindingStore.resolvedBinding(userDefaults: userDefaults)
        lock.withLock {
            currentBinding = binding
        }
    }

    private func installDefaultsObserver() {
        lock.lock()
        let hasObserver = defaultsObserver != nil
        lock.unlock()
        guard !hasObserver else {
            return
        }

        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: userDefaults,
            queue: nil
        ) { [weak self] _ in
            self?.reloadBinding()
        }

        lock.withLock {
            defaultsObserver = observer
        }
    }

    private func bindingSnapshot() -> ShortcutBinding? {
        lock.withLock { currentBinding }
    }

    private func activeModifiersSnapshot() -> ShortcutModifiers? {
        lock.withLock { activeModifiers }
    }

    private func setActiveModifiers(_ modifiers: ShortcutModifiers?) {
        lock.withLock {
            activeModifiers = modifiers
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard accessibilityTrusted() else {
            let shouldNotify = lock.withLock {
                activeModifiers = nil
                guard !didReportAccessibilityRevocation else {
                    return false
                }

                didReportAccessibilityRevocation = true
                return true
            }
            if shouldNotify {
                Task { @MainActor in
                    self.onAccessibilityRevoked()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        lock.withLock {
            didReportAccessibilityRevocation = false
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

        if keyCode == UInt16(kVK_Escape), activeModifiersSnapshot() != nil {
            setActiveModifiers(nil)
            Task { @MainActor in
                self.onEscape()
            }
            return nil
        }

        guard let binding = bindingSnapshot(),
              keyCode == binding.keyCode,
              binding.matches(eventFlags: event.flags, allowingExtraShift: true)
        else {
            return Unmanaged.passUnretained(event)
        }

        setActiveModifiers(binding.modifiers)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let reversed = !binding.modifiers.contains(.shift) && event.flags.contains(.maskShift)

        Task { @MainActor in
            self.onShortcutPressed(reversed, isRepeat)
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
        Task { @MainActor in
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
