import Foundation
import MacToolsPluginKit

@MainActor
final class WindowLayoutStore {
    private enum Key {
        static let almostMaximizeInset = "almost-maximize-inset"
    }

    static let defaultInset: CGFloat = 8
    static let insetRange: ClosedRange<CGFloat> = 0...40

    private let storage: PluginStorage
    private(set) var almostMaximizeInset: CGFloat

    init(storage: PluginStorage) {
        self.storage = storage
        if let stored = storage.object(forKey: Key.almostMaximizeInset) as? Double {
            almostMaximizeInset = Self.clamp(CGFloat(stored))
        } else if let stored = storage.object(forKey: Key.almostMaximizeInset) as? Int {
            almostMaximizeInset = Self.clamp(CGFloat(stored))
        } else {
            almostMaximizeInset = Self.defaultInset
        }
    }

    func setAlmostMaximizeInset(_ value: CGFloat) {
        let clamped = Self.clamp(value)
        guard almostMaximizeInset != clamped else {
            return
        }
        almostMaximizeInset = clamped
        storage.set(Double(clamped), forKey: Key.almostMaximizeInset)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value.rounded(), insetRange.lowerBound), insetRange.upperBound)
    }
}
