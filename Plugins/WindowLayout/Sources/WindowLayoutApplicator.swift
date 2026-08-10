import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum WindowLayoutApplyError: Error, Equatable {
    case accessibilityDenied
    case noResizableWindow
    case axFailure
    case nothingToRestore
}

struct WindowLayoutTargetWindow: Equatable {
    let key: WindowLayoutWindowKey
    let frame: CGRect
    let visibleFrame: CGRect
}

@MainActor
protocol WindowLayoutApplying: AnyObject {
    func resolveFrontmostResizableWindow() throws -> WindowLayoutTargetWindow
    func setFrame(_ frame: CGRect, for key: WindowLayoutWindowKey) throws
}

@MainActor
final class AXWindowLayoutApplicator: WindowLayoutApplying {
    private let axTimeout: Float = 0.35

    func resolveFrontmostResizableWindow() throws -> WindowLayoutTargetWindow {
        guard WindowLayoutAccessibilityCheck.isTrusted() else {
            throw WindowLayoutApplyError.accessibilityDenied
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowLayoutApplyError.noResizableWindow
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        guard let window = focusedWindow(in: appElement) ?? mainWindow(in: appElement) else {
            throw WindowLayoutApplyError.noResizableWindow
        }

        AXUIElementSetMessagingTimeout(window, axTimeout)

        guard let frame = readFrame(of: window) else {
            throw WindowLayoutApplyError.axFailure
        }

        if frame.width < WindowLayoutGeometry.minimumSize.width
            || frame.height < WindowLayoutGeometry.minimumSize.height {
            throw WindowLayoutApplyError.noResizableWindow
        }

        let windowID = identifier(for: window, pid: app.processIdentifier)
        let visibleFrame = screenVisibleFrame(containing: frame)

        return WindowLayoutTargetWindow(
            key: WindowLayoutWindowKey(pid: app.processIdentifier, windowID: windowID),
            frame: frame,
            visibleFrame: visibleFrame
        )
    }

    func setFrame(_ frame: CGRect, for key: WindowLayoutWindowKey) throws {
        guard WindowLayoutAccessibilityCheck.isTrusted() else {
            throw WindowLayoutApplyError.accessibilityDenied
        }

        let appElement = AXUIElementCreateApplication(key.pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        guard let window = windowMatching(key: key, in: appElement) else {
            throw WindowLayoutApplyError.noResizableWindow
        }

        AXUIElementSetMessagingTimeout(window, axTimeout)

        var position = CGPoint(x: frame.minX, y: frame.minY)
        var size = CGSize(width: frame.width, height: frame.height)

        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            throw WindowLayoutApplyError.axFailure
        }

        let positionStatus = AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
        let sizeStatus = AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )

        guard positionStatus == .success, sizeStatus == .success else {
            throw WindowLayoutApplyError.axFailure
        }
    }

    private func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
        copyWindowAttribute(appElement, kAXFocusedWindowAttribute as String)
    }

    private func mainWindow(in appElement: AXUIElement) -> AXUIElement? {
        copyWindowAttribute(appElement, kAXMainWindowAttribute as String)
    }

    private func windowMatching(key: WindowLayoutWindowKey, in appElement: AXUIElement) -> AXUIElement? {
        if let focused = focusedWindow(in: appElement),
           identifier(for: focused, pid: key.pid) == key.windowID {
            return focused
        }
        if let main = mainWindow(in: appElement),
           identifier(for: main, pid: key.pid) == key.windowID {
            return main
        }

        for (index, window) in copyWindows(from: appElement).enumerated() {
            if identifier(for: window, pid: key.pid, fallbackIndex: index) == key.windowID {
                return window
            }
        }
        return nil
    }

    private func copyWindows(from appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private func copyWindowAttribute(_ appElement: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func identifier(for window: AXUIElement, pid: pid_t, fallbackIndex: Int = 0) -> String {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXIdentifier" as CFString, &value) == .success,
           let string = value as? String,
           !string.isEmpty {
            return string
        }
        return "ax-\(pid)-\(fallbackIndex)"
    }

    private func readFrame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: point, size: size)
    }

    private func screenVisibleFrame(containing frame: CGRect) -> CGRect {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? frame
    }
}
