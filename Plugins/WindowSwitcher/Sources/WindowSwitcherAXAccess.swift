import ApplicationServices
import Foundation
import Darwin

/// This adapter is used only on a process worker's serial queue. A failed read is
/// nil, while a successful read of an empty window array remains an empty array.
protocol WindowSwitcherAXAccess: Sendable {
    var observesSystemNotifications: Bool { get }
    func windows(of application: AXUIElement) -> [AXUIElement]?
    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement?
    func windowAttributes(_ window: AXUIElement) -> [Any]?
    func windowNumber(_ window: AXUIElement) -> CGWindowID?
    func minimized(_ window: AXUIElement) -> Bool?
    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError
    func perform(_ element: AXUIElement, action: String) -> AXError
}

extension WindowSwitcherAXAccess {
    func windowNumber(_ window: AXUIElement) -> CGWindowID? { nil }
}

struct SystemWindowSwitcherAXAccess: WindowSwitcherAXAccess {
    let observesSystemNotifications = true

    func windows(of application: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success else { return nil }
        return raw as? [AXUIElement]
    }

    func element(_ owner: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func windowAttributes(_ window: AXUIElement) -> [Any]? {
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                          kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success else { return nil }
        return values as? [Any]
    }

    // macOS has no public AX-to-CG identity bridge. This optional read-only
    // symbol avoids guessing among identical windows; loading it dynamically
    // preserves ordinary AX switching if a future system removes the symbol.
    // Call only after confirming AXWindow role: descendants can return their
    // containing window's ID too. Never use this to initialize accessibility.
    private typealias WindowNumberLookup = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowNumberLookup: WindowNumberLookup? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowNumberLookup.self)
    }()

    func windowNumber(_ window: AXUIElement) -> CGWindowID? {
        guard let lookup = Self.windowNumberLookup else { return nil }
        var number: CGWindowID = 0
        guard lookup(window, &number) == .success, number != 0 else { return nil }
        return number
    }

    func minimized(_ window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    func set(_ element: AXUIElement, attribute: String, value: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    func perform(_ element: AXUIElement, action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }
}

/// Cancellation crosses the actor/dispatch-queue boundary without waiting behind
/// an application's pending AX calls. Already submitted actions cannot be undone.
final class WindowSwitcherActionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
