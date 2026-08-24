import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

final class AccessibilityWindowHandle: @unchecked Sendable {
    let identity: WindowIdentity
    let bundleIdentifier: String?
    let title: String
    let windowNumber: UInt32?
    let canMove: Bool
    let canResize: Bool
    let canToggleFullScreen: Bool
    let isFullScreen: Bool
    let element: AXUIElement?
    let hostWindow: NSWindow?

    init(
        identity: WindowIdentity,
        bundleIdentifier: String? = nil,
        title: String = "",
        windowNumber: UInt32? = nil,
        canMove: Bool,
        canResize: Bool,
        canToggleFullScreen: Bool = false,
        isFullScreen: Bool = false,
        element: AXUIElement? = nil,
        hostWindow: NSWindow? = nil
    ) {
        self.identity = identity
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowNumber = windowNumber
        self.canMove = canMove
        self.canResize = canResize
        self.canToggleFullScreen = canToggleFullScreen
        self.isFullScreen = isFullScreen
        self.element = element
        self.hostWindow = hostWindow
    }
}

@MainActor
protocol FocusedWindowResolving {
    func resolveFocusedWindow() async throws -> AccessibilityWindowHandle
}

@MainActor
protocol WindowFrameReading {
    func frame(of window: AccessibilityWindowHandle) async throws -> CGRect
    func isValid(_ window: AccessibilityWindowHandle) async -> Bool
}

@MainActor
protocol WindowFrameWriting {
    func setFrame(
        _ frame: CGRect,
        of window: AccessibilityWindowHandle,
        resize: Bool
    ) async throws
}

@MainActor
protocol WindowFullScreenWriting {
    func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) async throws
}

struct ExternalFocusedWindowTarget: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let preferredWindowNumber: Int?
}

actor WindowAccessibilityWorker {
    private let messagingTimeout: Float

    init(messagingTimeout: Float = 0.25) {
        self.messagingTimeout = messagingTimeout
    }

    func resolveFocusedWindow(
        target: ExternalFocusedWindowTarget
    ) throws -> AccessibilityWindowHandle {
        try Task.checkCancellation()
        let applicationElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)
        let resolvedWindow: AXUIElement?
        if let preferredWindowNumber = target.preferredWindowNumber {
            resolvedWindow = copyWindow(applicationElement, matching: preferredWindowNumber)
        } else {
            resolvedWindow = copyWindowAttribute(applicationElement, kAXFocusedWindowAttribute)
                ?? copyWindowAttribute(applicationElement, kAXMainWindowAttribute)
        }
        try Task.checkCancellation()
        guard let window = resolvedWindow else {
            throw WindowLayoutError.noFocusedWindow
        }
        AXUIElementSetMessagingTimeout(window, messagingTimeout)

        let isFullScreen = copyBooleanAttribute(window, "AXFullScreen") == true
            || copyStringAttribute(window, kAXSubroleAttribute) == "AXFullScreenWindow"

        guard hasAttribute(window, kAXPositionAttribute),
              hasAttribute(window, kAXSizeAttribute) else {
            throw WindowLayoutError.windowUnavailable
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success,
              processIdentifier == target.processIdentifier else {
            throw WindowLayoutError.windowUnavailable
        }
        let windowNumber = copyNumberAttribute(window, "AXWindowNumber")?.uint32Value
        if let preferredWindowNumber = target.preferredWindowNumber,
           windowNumber.map(Int.init) != preferredWindowNumber {
            throw WindowLayoutError.windowUnavailable
        }
        let token = windowNumber.map { "window-number:\($0)" }
            ?? "ax-hash:\(CFHash(window))"

        try Task.checkCancellation()
        return AccessibilityWindowHandle(
            identity: WindowIdentity(
                processIdentifier: processIdentifier,
                token: token
            ),
            bundleIdentifier: target.bundleIdentifier,
            title: copyStringAttribute(window, kAXTitleAttribute) ?? "",
            windowNumber: windowNumber,
            canMove: isAttributeSettable(window, kAXPositionAttribute),
            canResize: isAttributeSettable(window, kAXSizeAttribute),
            canToggleFullScreen: isAttributeSettable(window, "AXFullScreen"),
            isFullScreen: isFullScreen,
            element: window
        )
    }

    func frame(of window: AccessibilityWindowHandle) throws -> CGRect {
        try Task.checkCancellation()
        let element = try externalElement(for: window)
        let position = try pointAttribute(element, kAXPositionAttribute)
        let size = try sizeAttribute(element, kAXSizeAttribute)
        guard size.width > 0, size.height > 0 else {
            throw WindowLayoutError.frameReadFailed
        }
        try Task.checkCancellation()
        return CGRect(origin: position, size: size)
    }

    func isValid(_ window: AccessibilityWindowHandle) -> Bool {
        guard let element = window.element else { return false }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == window.identity.processIdentifier else {
            return false
        }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        ) == .success
    }

    func setFrame(
        _ frame: CGRect,
        of window: AccessibilityWindowHandle,
        resize: Bool
    ) throws {
        try Task.checkCancellation()
        let element = try externalElement(for: window)
        guard window.canMove else {
            throw WindowLayoutError.windowCannotMove
        }
        if resize, !window.canResize {
            throw WindowLayoutError.windowCannotResize
        }

        guard resize else {
            let originalPosition = try pointAttribute(element, kAXPositionAttribute)
            try Task.checkCancellation()
            try WindowFrameWriteTransaction.applyPosition(
                originalPosition: originalPosition,
                targetPosition: frame.origin,
                setPosition: { [self] in
                    try Task.checkCancellation()
                    try setPoint($0, on: element)
                },
                readPosition: { [self] in
                    try Task.checkCancellation()
                    return try pointAttribute(element, kAXPositionAttribute)
                }
            )
            return
        }

        let originalFrame = CGRect(
            origin: try pointAttribute(element, kAXPositionAttribute),
            size: try sizeAttribute(element, kAXSizeAttribute)
        )
        try Task.checkCancellation()
        try WindowFrameWriteTransaction.apply(
            originalFrame: originalFrame,
            targetFrame: frame,
            setPosition: { [self] in
                try Task.checkCancellation()
                try setPoint($0, on: element)
            },
            setSize: { [self] in
                try Task.checkCancellation()
                try setSize($0, on: element)
            },
            readFrame: { [self] in
                try Task.checkCancellation()
                return CGRect(
                    origin: try pointAttribute(element, kAXPositionAttribute),
                    size: try sizeAttribute(element, kAXSizeAttribute)
                )
            }
        )
    }

    func setFullScreen(
        _ isFullScreen: Bool,
        for window: AccessibilityWindowHandle
    ) throws {
        try Task.checkCancellation()
        let element = try externalElement(for: window)
        guard window.canToggleFullScreen else {
            throw WindowLayoutError.fullScreenUnsupported
        }
        let result = AXUIElementSetAttributeValue(
            element,
            "AXFullScreen" as CFString,
            isFullScreen as CFBoolean
        )
        guard result == .success else {
            throw mappedError(result, fallback: .fullScreenUnsupported)
        }
    }

    private func externalElement(for window: AccessibilityWindowHandle) throws -> AXUIElement {
        guard window.hostWindow == nil, let element = window.element else {
            throw WindowLayoutError.windowUnavailable
        }
        return element
    }

    private func copyWindowAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyWindow(_ application: AXUIElement, matching windowNumber: Int) -> AXUIElement? {
        guard windowNumber > 0 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
              let windows = value as? [AXUIElement] else {
            return nil
        }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, messagingTimeout)
            if copyNumberAttribute(window, "AXWindowNumber")?.intValue == windowNumber {
                return window
            }
        }
        return nil
    }

    private func hasAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            && value != nil
    }

    private func copyBooleanAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyNumberAttribute(_ element: AXUIElement, _ attribute: String) -> NSNumber? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? NSNumber
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        let value = try accessibilityValue(element, attribute: attribute)
        var point = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint,
              AXValueGetValue(value, .cgPoint, &point) else {
            throw WindowLayoutError.frameReadFailed
        }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) throws -> CGSize {
        let value = try accessibilityValue(element, attribute: attribute)
        var size = CGSize.zero
        guard AXValueGetType(value) == .cgSize,
              AXValueGetValue(value, .cgSize, &size) else {
            throw WindowLayoutError.frameReadFailed
        }
        return size
    }

    private func accessibilityValue(_ element: AXUIElement, attribute: String) throws -> AXValue {
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard result == .success, let rawValue else {
            throw mappedError(result, fallback: .frameReadFailed)
        }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            throw WindowLayoutError.frameReadFailed
        }
        return (rawValue as! AXValue)
    }

    private func setPoint(_ point: CGPoint, on element: AXUIElement) throws {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            throw WindowLayoutError.frameWriteFailed
        }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            value
        )
        guard result == .success else {
            throw mappedError(result, fallback: .windowCannotMove)
        }
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) throws {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            throw WindowLayoutError.frameWriteFailed
        }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            value
        )
        guard result == .success else {
            throw mappedError(result, fallback: .windowCannotResize)
        }
    }

    private func mappedError(_ error: AXError, fallback: WindowLayoutError) -> WindowLayoutError {
        switch error {
        case .apiDisabled:
            .accessibilityRequired
        case .invalidUIElement, .cannotComplete, .noValue:
            .windowUnavailable
        default:
            fallback
        }
    }
}

@MainActor
final class SystemFocusedWindowResolver: FocusedWindowResolving {
    private let accessibilityTrusted: @MainActor @Sendable () -> Bool
    private let frontmostTarget: @MainActor @Sendable () -> PluginFocusedWindowTarget?
    private let hostWindow: @MainActor @Sendable (Int) -> NSWindow?
    private let worker: WindowAccessibilityWorker

    init(
        accessibilityTrusted: @escaping @MainActor @Sendable () -> Bool = AXIsProcessTrusted,
        frontmostTarget: @escaping @MainActor @Sendable () -> PluginFocusedWindowTarget? = {
            guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
            return PluginFocusedWindowTarget(application: application)
        },
        hostWindow: @escaping @MainActor @Sendable (Int) -> NSWindow? = { windowNumber in
            NSApp.windows.first(where: {
                $0.windowNumber == windowNumber && $0.isVisible
            })
        },
        messagingTimeout: Float = 0.25,
        worker: WindowAccessibilityWorker? = nil
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.frontmostTarget = frontmostTarget
        self.hostWindow = hostWindow
        self.worker = worker ?? WindowAccessibilityWorker(messagingTimeout: messagingTimeout)
    }

    func resolveFocusedWindow() async throws -> AccessibilityWindowHandle {
        guard accessibilityTrusted() else {
            throw WindowLayoutError.accessibilityRequired
        }
        guard let target = frontmostTarget(), !target.application.isTerminated else {
            throw WindowLayoutError.noFocusedWindow
        }
        let application = target.application
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let preferredWindowNumber = target.preferredWindowNumber,
                  preferredWindowNumber > 0,
                  let window = hostWindow(preferredWindowNumber),
                  window.windowNumber == preferredWindowNumber,
                  window.isVisible
            else {
                throw WindowLayoutError.noFocusedWindow
            }
            return AccessibilityWindowHandle(
                identity: WindowIdentity(
                    processIdentifier: application.processIdentifier,
                    token: "window-number:\(preferredWindowNumber)"
                ),
                bundleIdentifier: application.bundleIdentifier,
                title: window.title,
                windowNumber: UInt32(exactly: preferredWindowNumber),
                canMove: window.isMovable,
                canResize: window.styleMask.contains(.resizable),
                canToggleFullScreen: window.styleMask.contains(.titled)
                    && window.styleMask.contains(.resizable),
                isFullScreen: window.styleMask.contains(.fullScreen),
                hostWindow: window
            )
        }

        return try await worker.resolveFocusedWindow(target: ExternalFocusedWindowTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            preferredWindowNumber: target.preferredWindowNumber
        ))
    }
}

@MainActor
final class AccessibilityWindowFrameAdapter: WindowFrameReading, WindowFrameWriting, WindowFullScreenWriting {
    private let worker: WindowAccessibilityWorker

    init(
        messagingTimeout: Float = 0.25,
        worker: WindowAccessibilityWorker? = nil
    ) {
        self.worker = worker ?? WindowAccessibilityWorker(messagingTimeout: messagingTimeout)
    }

    func frame(of window: AccessibilityWindowHandle) async throws -> CGRect {
        if let hostWindow = window.hostWindow {
            guard isValidHostWindow(hostWindow, for: window),
                  let anchorMaximumY = WindowCoordinateSpace.anchorMaximumY(in: NSScreen.screens)
            else {
                throw WindowLayoutError.windowUnavailable
            }
            let frame = WindowCoordinateSpace.accessibilityRect(
                hostWindow.frame,
                anchorMaximumY: anchorMaximumY
            )
            guard frame.width > 0, frame.height > 0 else {
                throw WindowLayoutError.frameReadFailed
            }
            return frame
        }
        return try await worker.frame(of: window)
    }

    func isValid(_ window: AccessibilityWindowHandle) async -> Bool {
        if let hostWindow = window.hostWindow {
            return isValidHostWindow(hostWindow, for: window)
        }
        return await worker.isValid(window)
    }

    func setFrame(
        _ frame: CGRect,
        of window: AccessibilityWindowHandle,
        resize: Bool
    ) async throws {
        if let hostWindow = window.hostWindow {
            guard isValidHostWindow(hostWindow, for: window),
                  let anchorMaximumY = WindowCoordinateSpace.anchorMaximumY(in: NSScreen.screens)
            else {
                throw WindowLayoutError.windowUnavailable
            }
            guard window.canMove else {
                throw WindowLayoutError.windowCannotMove
            }
            if resize, !window.canResize {
                throw WindowLayoutError.windowCannotResize
            }
            let appKitFrame = WindowCoordinateSpace.appKitRect(
                frame,
                anchorMaximumY: anchorMaximumY
            )
            if resize {
                hostWindow.setFrame(appKitFrame, display: true)
            } else {
                hostWindow.setFrameOrigin(appKitFrame.origin)
            }
            return
        }
        try await worker.setFrame(frame, of: window, resize: resize)
    }

    func setFullScreen(_ isFullScreen: Bool, for window: AccessibilityWindowHandle) async throws {
        if let hostWindow = window.hostWindow {
            guard isValidHostWindow(hostWindow, for: window) else {
                throw WindowLayoutError.windowUnavailable
            }
            guard window.canToggleFullScreen else {
                throw WindowLayoutError.fullScreenUnsupported
            }
            if hostWindow.styleMask.contains(.fullScreen) != isFullScreen {
                hostWindow.toggleFullScreen(nil)
            }
            return
        }
        try await worker.setFullScreen(isFullScreen, for: window)
    }

    private func isValidHostWindow(
        _ hostWindow: NSWindow,
        for window: AccessibilityWindowHandle
    ) -> Bool {
        window.identity.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && hostWindow.isVisible
            && hostWindow.windowNumber > 0
            && window.windowNumber == UInt32(exactly: hostWindow.windowNumber)
    }

}

enum WindowFrameWriteTransaction {
    static func applyPosition(
        originalPosition: CGPoint,
        targetPosition: CGPoint,
        setPosition: (CGPoint) throws -> Void,
        readPosition: (() throws -> CGPoint)? = nil
    ) throws {
        do {
            try setPosition(targetPosition)
            if let readPosition,
               !approximatelyEqual(try readPosition(), targetPosition) {
                try setPosition(targetPosition)
            }
        } catch {
            try? setPosition(originalPosition)
            throw error
        }
    }

    static func apply(
        originalFrame: CGRect,
        targetFrame: CGRect,
        setPosition: (CGPoint) throws -> Void,
        setSize: (CGSize) throws -> Void,
        readFrame: (() throws -> CGRect)? = nil
    ) throws {
        do {
            // Some applications accept an expanded size only after the window has moved far
            // enough to fit it. Reapply both values so either app-specific ordering settles on
            // the requested frame while keeping the transaction bounded.
            try setSize(targetFrame.size)
            try setPosition(targetFrame.origin)
            try setSize(targetFrame.size)
            try setPosition(targetFrame.origin)
            if let readFrame {
                let observedFrame = try readFrame()
                if !approximatelyEqual(observedFrame.size, targetFrame.size) {
                    try setSize(targetFrame.size)
                    try setPosition(targetFrame.origin)
                } else if !approximatelyEqual(observedFrame.origin, targetFrame.origin) {
                    try setPosition(targetFrame.origin)
                }
            }
        } catch {
            // Either Accessibility write may have partially mutated the window.
            try? setSize(originalFrame.size)
            try? setPosition(originalFrame.origin)
            throw error
        }
    }

    private static func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private static func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
    }
}
