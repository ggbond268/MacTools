import CoreGraphics
import Foundation

struct WindowLayoutWindowKey: Hashable, Sendable {
    let pid: pid_t
    let windowID: String
}

final class WindowLayoutHistory: @unchecked Sendable {
    private var frames: [WindowLayoutWindowKey: CGRect] = [:]

    func snapshotIfNeeded(key: WindowLayoutWindowKey, frame: CGRect) {
        if frames[key] == nil {
            frames[key] = frame
        }
    }

    func frame(for key: WindowLayoutWindowKey) -> CGRect? {
        frames[key]
    }

    var isEmpty: Bool {
        frames.isEmpty
    }

    func clear(_ key: WindowLayoutWindowKey) {
        frames.removeValue(forKey: key)
    }

    func removeAll() {
        frames.removeAll()
    }
}
