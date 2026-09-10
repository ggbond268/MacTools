import AppKit
import CoreGraphics

struct ClipboardHistoryPanelPosition: Codable, Equatable {
    let left: CGFloat
    let top: CGFloat

    var isValid: Bool { left.isFinite && top.isFinite }
}

struct ClipboardHistoryPanelScreen: Equatable {
    let id: String
    let frame: NSRect
    let visibleFrame: NSRect

    @MainActor
    static func currentScreens() -> [Self] {
        NSScreen.screens.enumerated().map { index, screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let id: String
            if let displayID,
               let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            } else {
                id = displayID.map { "display:\($0)" } ?? "screen:\(index):\(screen.localizedName)"
            }
            return Self(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

enum ClipboardHistoryPanelPlacement {
    static func targetScreen(
        pointer: NSPoint,
        screens: [ClipboardHistoryPanelScreen]
    ) -> ClipboardHistoryPanelScreen? {
        screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? screens.first
    }

    static func screen(
        containing frame: NSRect,
        screens: [ClipboardHistoryPanelScreen]
    ) -> ClipboardHistoryPanelScreen? {
        screens.filter { $0.frame.intersects(frame) }.max {
            intersectionArea($0.frame, frame) < intersectionArea($1.frame, frame)
        }
    }

    static func frame(
        size: NSSize,
        on screen: ClipboardHistoryPanelScreen,
        savedPosition: ClipboardHistoryPanelPosition?
    ) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let size = NSSize(
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
        )
        let origin: NSPoint
        if let savedPosition, savedPosition.isValid {
            origin = NSPoint(
                x: visibleFrame.minX + savedPosition.left,
                y: visibleFrame.maxY - savedPosition.top - size.height
            )
        } else {
            origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        }
        return NSRect(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    static func position(of frame: NSRect, on screen: ClipboardHistoryPanelScreen) -> ClipboardHistoryPanelPosition {
        // Screen-local offsets survive changes to the arrangement of connected displays.
        ClipboardHistoryPanelPosition(
            left: frame.minX - screen.visibleFrame.minX,
            top: screen.visibleFrame.maxY - frame.maxY
        )
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
