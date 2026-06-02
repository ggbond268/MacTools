import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Errors

enum MenuBarHiddenEventError: Error, LocalizedError {
    case notTrusted
    case eventCreationFailed
    case pidDead(pid_t)

    var errorDescription: String? {
        switch self {
        case .notTrusted: "辅助功能权限未授予"
        case .eventCreationFailed: "无法创建鼠标事件"
        case .pidDead(let pid): "目标进程 \(pid) 已退出"
        }
    }
}

// MARK: - MenuBarHiddenEventSynthesis
//
// Synthesises the CGEvents required to:
//   * Drag a menu bar item (Cmd+drag is the gesture macOS recognises).
//   * Click a menu bar item (left or right) so its menu opens.
//
// Accessibility permission (`AXIsProcessTrusted`) is mandatory for both.

@MainActor
final class MenuBarHiddenEventSynthesis {
    /// Cmd+drag as Thaw does it: send a targeted mouseDown to the destination
    /// edge, then a targeted mouseUp. Window Server treats this as moving the
    /// menu-bar item's window next to that edge.
    func move(item: MenuBarItem, to target: MenuBarHiddenResolvedMoveTarget) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarHiddenEventError.notTrusted }
        let pid = eventPID(for: item)
        guard kill(pid, 0) == 0 else { throw MenuBarHiddenEventError.pidDead(pid) }

        let source = try makeEventSource()

        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: target.point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: target.point,
                mouseButton: .left
            )
        else { throw MenuBarHiddenEventError.eventCreationFailed }

        down.flags = .maskCommand
        down.setMenuBarItemWindowID(item.windowID, includeWindowID: true)
        up.setMenuBarItemWindowID(target.windowID ?? item.windowID, includeWindowID: true)

        let savedCursor = MouseCursorHelper.locationCoreGraphics
        let shouldWarpToTarget = MouseCursorHelper.isOnActiveDisplay(target.point)
        if shouldWarpToTarget {
            MouseCursorHelper.warpCursor(to: target.point)
        }
        MouseCursorHelper.hideCursor()
        defer {
            if let savedCursor {
                MouseCursorHelper.warpCursor(to: savedCursor)
            }
            MouseCursorHelper.showCursor()
        }

        if shouldWarpToTarget {
            try await Task.sleep(for: .milliseconds(20))
        }
        down.post(tap: .cghidEventTap)
        down.postToPid(pid)

        try await Task.sleep(for: .milliseconds(50))
        up.post(tap: .cghidEventTap)
        up.postToPid(pid)
        // Double mouseUp prevents stuck drag state.
        up.post(tap: .cghidEventTap)
        up.postToPid(pid)

        try await Task.sleep(for: .milliseconds(50))
    }

    /// Sends a left or right click to a menu bar item at its current bounds.
    func click(item: MenuBarItem, button: CGMouseButton) async throws {
        guard AXIsProcessTrusted() else { throw MenuBarHiddenEventError.notTrusted }
        let pid = eventPID(for: item)
        guard kill(pid, 0) == 0 else { throw MenuBarHiddenEventError.pidDead(pid) }

        let source = try makeEventSource()
        let clickBounds = MenuBarHiddenWindowServer.screenRect(for: item.windowID) ?? item.bounds
        let clickPoint = clickBounds.center

        let (downType, upType): (CGEventType, CGEventType) = button == .left
            ? (.leftMouseDown, .leftMouseUp)
            : (.rightMouseDown, .rightMouseUp)

        guard
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: downType,
                mouseCursorPosition: clickPoint,
                mouseButton: button
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: upType,
                mouseCursorPosition: clickPoint,
                mouseButton: button
            )
        else { throw MenuBarHiddenEventError.eventCreationFailed }

        down.setMenuBarItemWindowID(item.windowID, includeWindowID: false)
        up.setMenuBarItemWindowID(item.windowID, includeWindowID: false)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        let savedCursor = MouseCursorHelper.locationCoreGraphics
        MouseCursorHelper.warpCursor(to: clickPoint)
        try await Task.sleep(for: .milliseconds(10))
        MouseCursorHelper.hideCursor()
        defer {
            if let savedCursor {
                MouseCursorHelper.warpCursor(to: savedCursor)
            }
            MouseCursorHelper.showCursor()
        }

        down.post(tap: .cghidEventTap)
        down.postToPid(pid)
        try await Task.sleep(for: .milliseconds(30))
        up.post(tap: .cghidEventTap)
        up.postToPid(pid)
        up.post(tap: .cghidEventTap)
        up.postToPid(pid)
        try await Task.sleep(for: .milliseconds(20))
    }

    /// Brief poll until the user's cursor sits still — avoids fighting active
    /// user input when synthesising drag events.
    func waitForUserInputPause() async {
        var stable = 0
        var previous = NSEvent.mouseLocation
        for _ in 0 ..< 20 {
            let current = NSEvent.mouseLocation
            if hypot(current.x - previous.x, current.y - previous.y) < 2 {
                stable += 1
                if stable >= 3 { return }
            } else {
                stable = 0
            }
            previous = current
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    // MARK: - Private

    private func eventPID(for item: MenuBarItem) -> pid_t {
        item.sourcePID ?? item.ownerPID
    }

    private func makeEventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MenuBarHiddenEventError.eventCreationFailed
        }
        source.setLocalEventsFilterDuringSuppressionState(
            CGEventFilterMask(rawValue: 0x7),
            state: .eventSuppressionStateRemoteMouseDrag
        )
        source.setLocalEventsFilterDuringSuppressionState(
            CGEventFilterMask(rawValue: 0x7),
            state: .eventSuppressionStateSuppressionInterval
        )
        source.localEventsSuppressionInterval = 0
        return source
    }
}

// MARK: - Helpers

enum MouseCursorHelper {
    static var locationCoreGraphics: CGPoint? {
        CGEvent(source: nil)?.location
    }

    static func warpCursor(to point: CGPoint) {
        let result = CGWarpMouseCursorPosition(point)
        guard result != .success,
              let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  mouseEventSource: source,
                  mouseType: .mouseMoved,
                  mouseCursorPosition: point,
                  mouseButton: .left
              )
        else {
            return
        }
        event.post(tap: .cghidEventTap)
    }

    static func hideCursor() { CGDisplayHideCursor(kCGNullDirectDisplay) }
    static func showCursor() { CGDisplayShowCursor(kCGNullDirectDisplay) }

    static func isOnActiveDisplay(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, nil) == .success else { return false }
        return displays.contains { CGDisplayBounds($0).contains(point) }
    }

    static func isButtonPressed() -> Bool {
        for rawButton in 0 ... 31 {
            guard let button = CGMouseButton(rawValue: UInt32(rawButton)) else { continue }
            if CGEventSource.buttonState(.combinedSessionState, button: button) {
                return true
            }
        }
        return false
    }

    static func lastMovementOccurred(within duration: TimeInterval) -> Bool {
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        return seconds <= duration
    }

    static func lastScrollWheelOccurred(within duration: TimeInterval) -> Bool {
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        return seconds <= duration
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGEventField {
    static let menuBarHiddenWindowID = CGEventField(rawValue: 0x33)
}

private extension CGEvent {
    func setMenuBarItemWindowID(_ windowID: CGWindowID, includeWindowID: Bool) {
        let value = Int64(windowID)
        setIntegerValueField(.eventSourceUserData, value: Int64(Int(bitPattern: ObjectIdentifier(self))))
        setIntegerValueField(.mouseEventWindowUnderMousePointer, value: value)
        setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: value)
        if includeWindowID, let windowIDField = CGEventField.menuBarHiddenWindowID {
            setIntegerValueField(windowIDField, value: value)
        }
    }
}
