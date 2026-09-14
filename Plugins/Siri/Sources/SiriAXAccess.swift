import ApplicationServices
import Foundation

/// The synchronous messaging boundary is injectable without opening or changing another app.
protocol SiriAXMessaging: Sendable {
    func setTimeout(_ element: AXUIElement, seconds: Float) -> AXError
    func copyAttribute(_ element: AXUIElement, name: String) -> (AXError, CFTypeRef?)
    func isSettable(_ element: AXUIElement, name: String) -> (AXError, Bool)
    func actionNames(_ element: AXUIElement) -> (AXError, [String]?)
    func setValue(_ element: AXUIElement, name: String, value: CFTypeRef) -> AXError
    func perform(_ element: AXUIElement, action: String) -> AXError
}

struct NativeSiriAXMessaging: SiriAXMessaging {
    func setTimeout(_ element: AXUIElement, seconds: Float) -> AXError {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
    func copyAttribute(_ element: AXUIElement, name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }
    func isSettable(_ element: AXUIElement, name: String) -> (AXError, Bool) {
        var value: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, name as CFString, &value)
        return (error, value.boolValue)
    }
    func actionNames(_ element: AXUIElement) -> (AXError, [String]?) {
        var value: CFArray?
        let error = AXUIElementCopyActionNames(element, &value)
        return (error, value as? [String])
    }
    func setValue(_ element: AXUIElement, name: String, value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }
    func perform(_ element: AXUIElement, action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }
}

/// Apply the timeout to the exact object for every call: AX timeouts are not inherited by children.
struct SiriAXAccess {
    let messaging: any SiriAXMessaging
    let now: @Sendable () -> ContinuousClock.Instant

    init(messaging: any SiriAXMessaging = NativeSiriAXMessaging(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.messaging = messaging
        self.now = now
    }

    private func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard now() < deadline else { throw SiriFailure.timedOut }
    }

    private func call<T>(_ element: AXUIElement, deadline: ContinuousClock.Instant,
                         _ operation: () -> T) throws -> T {
        try check(deadline)
        let remaining = now().duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { throw SiriFailure.timedOut }
        guard messaging.setTimeout(element, seconds: Float(min(0.5, seconds))) == .success else {
            throw SiriFailure.missingControls
        }
        try check(deadline)
        let result = operation()
        try check(deadline)
        return result
    }

    func attribute(_ element: AXUIElement, _ name: String, deadline: ContinuousClock.Instant,
                   allowsMissing: Bool = false) throws -> CFTypeRef? {
        let (error, value) = try call(element, deadline: deadline) {
            messaging.copyAttribute(element, name: name)
        }
        if allowsMissing && (error == .attributeUnsupported || error == .noValue) { return nil }
        guard error == .success, let value else { throw SiriFailure.missingControls }
        return value
    }

    func string(_ element: AXUIElement, _ name: String,
                deadline: ContinuousClock.Instant) throws -> String {
        guard let value = try attribute(element, name, deadline: deadline) as? String else {
            throw SiriFailure.missingControls
        }
        return value
    }

    func children(_ element: AXUIElement, role: String,
                  deadline: ContinuousClock.Instant) throws -> [AXUIElement] {
        // AX leaf controls may omit AXChildren. A failed container read cannot prove an empty chat.
        let leafRoles: Set<String> = [kAXStaticTextRole, kAXTextFieldRole, kAXButtonRole, kAXImageRole,
            kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole, kAXProgressIndicatorRole,
            kAXValueIndicatorRole, kAXSplitterRole]
        let value = try attribute(element, kAXChildrenAttribute, deadline: deadline,
                                  allowsMissing: leafRoles.contains(role))
        guard let value else { return [] }
        guard let children = value as? [AXUIElement] else { throw SiriFailure.missingControls }
        return children
    }

    func requireWritableInput(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws {
        let (error, settable) = try call(element, deadline: deadline) {
            messaging.isSettable(element, name: kAXValueAttribute)
        }
        guard error == .success, settable else { throw SiriFailure.missingControls }
        let (actionsError, actions) = try call(element, deadline: deadline) { messaging.actionNames(element) }
        guard actionsError == .success, actions?.contains("AXConfirm") == true else {
            throw SiriFailure.missingControls
        }
    }

    func enterText(_ message: String, into element: AXUIElement,
                   deadline: ContinuousClock.Instant) throws {
        guard try string(element, kAXValueAttribute, deadline: deadline).isEmpty else {
            throw SiriFailure.existingDraft
        }
        let error = try call(element, deadline: deadline) {
            messaging.setValue(element, name: kAXValueAttribute, value: message as CFString)
        }
        guard error == .success else { throw SiriFailure.textMismatch }
    }

    func perform(_ action: String, on element: AXUIElement, deadline: ContinuousClock.Instant,
                 failure: SiriFailure) throws {
        let error = try call(element, deadline: deadline) { messaging.perform(element, action: action) }
        guard error == .success else { throw failure }
    }
}
