import CoreGraphics
import Foundation

@MainActor
protocol WindowFrameHistory: AnyObject {
    func previousFrame(for window: AccessibilityWindowHandle) -> CGRect?
    func record(_ frame: CGRect, for window: AccessibilityWindowHandle)
    func removeFrame(for window: AccessibilityWindowHandle)
    func removeInvalidEntries(using isValid: (AccessibilityWindowHandle) -> Bool)
}

@MainActor
final class InMemoryWindowFrameHistory: WindowFrameHistory {
    private struct Entry {
        let window: AccessibilityWindowHandle
        let frame: CGRect
    }

    private var entries: [WindowIdentity: Entry] = [:]

    func previousFrame(for window: AccessibilityWindowHandle) -> CGRect? {
        entries[window.identity]?.frame
    }

    func record(_ frame: CGRect, for window: AccessibilityWindowHandle) {
        entries[window.identity] = Entry(window: window, frame: frame)
    }

    func removeFrame(for window: AccessibilityWindowHandle) {
        entries.removeValue(forKey: window.identity)
    }

    func removeInvalidEntries(using isValid: (AccessibilityWindowHandle) -> Bool) {
        entries = entries.filter { isValid($0.value.window) }
    }
}
