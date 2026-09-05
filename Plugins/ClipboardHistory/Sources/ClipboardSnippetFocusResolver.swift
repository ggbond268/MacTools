@preconcurrency import ApplicationServices
import AppKit

@MainActor
protocol ClipboardSnippetFocusAccess {
    associatedtype Element

    var hasAccessibilityPermission: Bool { get }
    var frontmostProcessIdentifier: pid_t? { get }
    func applicationFocusedElement(processIdentifier: pid_t) -> Element?
    func systemFocusedElement() -> Element?
    func processIdentifier(of element: Element) -> pid_t?
    func window(of element: Element) -> Element?
    func focusedWindow(processIdentifier: pid_t) -> Element?
    func isSameElement(_ first: Element, _ second: Element) -> Bool
    func requestManualAccessibility(processIdentifier: pid_t)
}

enum ClipboardSnippetFocusFailure: Equatable {
    case unavailable
    case ownershipUnverified
}

/// Focus lookup never substitutes an arbitrary editable descendant. A fallback
/// must still identify the focused element belonging to the original foreground app.
@MainActor
struct ClipboardSnippetFocusResolver<Access: ClipboardSnippetFocusAccess> {
    let access: Access

    func resolve(
        processIdentifier: pid_t,
        requestManualAccessibilityIfNeeded: Bool = false,
        onFailure: (ClipboardSnippetFocusFailure) -> Void = { _ in }
    ) -> Access.Element? {
        guard canAccess(processIdentifier) else { return nil }
        var foundUnverifiedElement = false
        if let element = access.applicationFocusedElement(processIdentifier: processIdentifier) {
            if belongsToForegroundApp(element, processIdentifier: processIdentifier),
               canAccess(processIdentifier) { return element }
            foundUnverifiedElement = true
        }
        guard canAccess(processIdentifier) else { return nil }
        if let element = access.systemFocusedElement() {
            if belongsToForegroundApp(element, processIdentifier: processIdentifier),
               canAccess(processIdentifier) { return element }
            foundUnverifiedElement = true
        }
        if requestManualAccessibilityIfNeeded, canAccess(processIdentifier) {
            // Electron exposes this opt-in for assistive clients. Its tree may not
            // appear synchronously; the post-delivery scheduler performs the retry.
            access.requestManualAccessibility(processIdentifier: processIdentifier)
        }
        onFailure(foundUnverifiedElement ? .ownershipUnverified : .unavailable)
        return nil
    }

    private func belongsToForegroundApp(_ element: Access.Element, processIdentifier: pid_t) -> Bool {
        guard canAccess(processIdentifier),
              let owner = access.processIdentifier(of: element), owner > 0 else { return false }
        if owner == processIdentifier { return true }
        // WebKit's focused editor may live in a WebContent process. Verify its
        // AXWindow against the host app's focused window, rather than trusting a
        // process name, arbitrary descendant, or remote PID alone.
        guard let window = access.window(of: element),
              access.processIdentifier(of: window) == processIdentifier,
              let focusedWindow = access.focusedWindow(processIdentifier: processIdentifier),
              access.processIdentifier(of: focusedWindow) == processIdentifier,
              access.isSameElement(window, focusedWindow) else { return false }
        return canAccess(processIdentifier)
    }

    private func canAccess(_ processIdentifier: pid_t) -> Bool {
        processIdentifier > 0
            && access.hasAccessibilityPermission
            && access.frontmostProcessIdentifier == processIdentifier
    }
}

@MainActor
struct SystemClipboardSnippetFocusAccess: ClipboardSnippetFocusAccess {
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    var frontmostProcessIdentifier: pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func applicationFocusedElement(processIdentifier: pid_t) -> AXUIElement? {
        focusedElement(of: AXUIElementCreateApplication(processIdentifier))
    }

    func systemFocusedElement() -> AXUIElement? {
        focusedElement(of: AXUIElementCreateSystemWide())
    }

    func processIdentifier(of element: AXUIElement) -> pid_t? {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner > 0 ? owner : nil
    }

    func window(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXWindowAttribute as CFString, of: element)
    }

    func focusedWindow(processIdentifier: pid_t) -> AXUIElement? {
        elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            of: AXUIElementCreateApplication(processIdentifier)
        )
    }

    func isSameElement(_ first: AXUIElement, _ second: AXUIElement) -> Bool {
        CFEqual(first, second)
    }

    func requestManualAccessibility(processIdentifier: pid_t) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let attribute = "AXManualAccessibility" as CFString
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(application, attribute, &isSettable) == .success,
              isSettable.boolValue,
              hasAccessibilityPermission,
              frontmostProcessIdentifier == processIdentifier else { return }
        // Do not change unrelated apps or disable accessibility on teardown: other
        // assistive tools may also depend on an application's exposed tree.
        AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue)
    }

    private func focusedElement(of application: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute as CFString, of: application)
    }

    private func elementAttribute(_ attribute: CFString, of application: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }
}
