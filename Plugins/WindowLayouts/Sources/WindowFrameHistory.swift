import CoreGraphics
import Foundation

@MainActor
protocol WindowFrameHistory: AnyObject {
    func previousFrame(for window: AccessibilityWindowHandle) -> CGRect?
    func record(_ frame: CGRect, for window: AccessibilityWindowHandle)
    func removeFrame(for window: AccessibilityWindowHandle)
}

@MainActor
final class InMemoryWindowFrameHistory: WindowFrameHistory {
    private static let maximumEntryCount = 64

    private struct Entry {
        let window: AccessibilityWindowHandle
        let frame: CGRect
    }

    private var entries: [WindowIdentity: Entry] = [:]
    private var recency: [WindowIdentity] = []

    func previousFrame(for window: AccessibilityWindowHandle) -> CGRect? {
        entries[window.identity]?.frame
    }

    func record(_ frame: CGRect, for window: AccessibilityWindowHandle) {
        entries[window.identity] = Entry(window: window, frame: frame)
        recency.removeAll { $0 == window.identity }
        recency.append(window.identity)
        while recency.count > Self.maximumEntryCount {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }

    func removeFrame(for window: AccessibilityWindowHandle) {
        entries.removeValue(forKey: window.identity)
        recency.removeAll { $0 == window.identity }
    }

    var entryCountForTesting: Int { entries.count }
}
