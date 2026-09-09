import Foundation
import MacToolsPluginKit

enum MouseEnhancerDevice: Equatable, Sendable {
    case mouse
    case trackpad
}

struct MouseEnhancerConfiguration: Equatable, Sendable {
    static let defaultScrollStep: Double = 0
    static let defaultScrollGain: Double = 1
    static let scrollStepRange: ClosedRange<Double> = 0...120
    static let scrollGainRange: ClosedRange<Double> = 0.1...5
    static let defaultScrollDuration: Double = 1.5
    static let scrollDurationRange: ClosedRange<Double> = 0.3...5

    var reverseMouseHorizontal: Bool
    var reverseMouseVertical: Bool
    var reverseTrackpadHorizontal: Bool
    var reverseTrackpadVertical: Bool
    var middleClickEnabled: Bool
    var middleClickFingerCount: Int
    var mouseScrollStep: Double
    var mouseScrollGain: Double
    var trackpadScrollStep: Double
    var trackpadScrollGain: Double
    var smoothScrollingEnabled: Bool
    var mouseScrollDuration: Double

    init(
        reverseMouseHorizontal: Bool,
        reverseMouseVertical: Bool,
        reverseTrackpadHorizontal: Bool,
        reverseTrackpadVertical: Bool,
        middleClickEnabled: Bool = false,
        middleClickFingerCount: Int = 3,
        mouseScrollStep: Double = MouseEnhancerConfiguration.defaultScrollStep,
        mouseScrollGain: Double = MouseEnhancerConfiguration.defaultScrollGain,
        trackpadScrollStep: Double = MouseEnhancerConfiguration.defaultScrollStep,
        trackpadScrollGain: Double = MouseEnhancerConfiguration.defaultScrollGain,
        smoothScrollingEnabled: Bool = false,
        mouseScrollDuration: Double = MouseEnhancerConfiguration.defaultScrollDuration
    ) {
        self.reverseMouseHorizontal = reverseMouseHorizontal
        self.reverseMouseVertical = reverseMouseVertical
        self.reverseTrackpadHorizontal = reverseTrackpadHorizontal
        self.reverseTrackpadVertical = reverseTrackpadVertical
        self.middleClickEnabled = middleClickEnabled
        self.middleClickFingerCount = middleClickFingerCount
        self.mouseScrollStep = mouseScrollStep
        self.mouseScrollGain = mouseScrollGain
        self.trackpadScrollStep = trackpadScrollStep
        self.trackpadScrollGain = trackpadScrollGain
        self.smoothScrollingEnabled = smoothScrollingEnabled
        self.mouseScrollDuration = mouseScrollDuration
    }

    static let `default` = MouseEnhancerConfiguration(
        reverseMouseHorizontal: false,
        reverseMouseVertical: false,
        reverseTrackpadHorizontal: false,
        reverseTrackpadVertical: false,
        middleClickEnabled: false,
        middleClickFingerCount: 3
    )

    var hasMouseReversing: Bool {
        reverseMouseHorizontal || reverseMouseVertical
    }

    var hasTrackpadReversing: Bool {
        reverseTrackpadHorizontal || reverseTrackpadVertical
    }

    var hasMouseScrollTuning: Bool {
        mouseScrollStep > Self.defaultScrollStep || mouseScrollGain != Self.defaultScrollGain
    }

    var hasMouseSmoothScrolling: Bool {
        smoothScrollingEnabled
    }

    var hasTrackpadScrollTuning: Bool {
        trackpadScrollStep > Self.defaultScrollStep || trackpadScrollGain != Self.defaultScrollGain
    }

    var hasMouseEnhancement: Bool {
        hasMouseReversing || hasMouseScrollTuning || hasMouseSmoothScrolling
    }

    var hasTrackpadEnhancement: Bool {
        hasTrackpadReversing || hasTrackpadScrollTuning
    }

    var hasAnyScrollTuning: Bool {
        hasMouseScrollTuning || hasTrackpadScrollTuning
    }

    var shouldInstallEventTap: Bool {
        hasMouseEnhancement || hasTrackpadEnhancement
    }

    static func normalizedScrollStep(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else {
            return defaultScrollStep
        }

        return min(value.rounded(), scrollStepRange.upperBound)
    }

    static func normalizedScrollGain(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultScrollGain
        }

        let clamped = min(max(value, scrollGainRange.lowerBound), scrollGainRange.upperBound)
        return (clamped * 10).rounded() / 10
    }

    static func normalizedScrollDuration(_ value: Double) -> Double {
        guard value.isFinite else {
            return defaultScrollDuration
        }

        let clamped = min(max(value, scrollDurationRange.lowerBound), scrollDurationRange.upperBound)
        return (clamped * 10).rounded() / 10
    }

    func shouldReverse(device: MouseEnhancerDevice) -> Bool {
        switch device {
        case .mouse:
            return hasMouseReversing
        case .trackpad:
            return hasTrackpadReversing
        }
    }

    func shouldReverseVertical(device: MouseEnhancerDevice) -> Bool {
        switch device {
        case .mouse:
            return reverseMouseVertical
        case .trackpad:
            return reverseTrackpadVertical
        }
    }

    func shouldReverseHorizontal(device: MouseEnhancerDevice) -> Bool {
        switch device {
        case .mouse:
            return reverseMouseHorizontal
        case .trackpad:
            return reverseTrackpadHorizontal
        }
    }

    func scrollStep(for device: MouseEnhancerDevice) -> Double {
        switch device {
        case .mouse:
            return mouseScrollStep
        case .trackpad:
            return trackpadScrollStep
        }
    }

    func scrollGain(for device: MouseEnhancerDevice) -> Double {
        switch device {
        case .mouse:
            return mouseScrollGain
        case .trackpad:
            return trackpadScrollGain
        }
    }
}

@MainActor
final class MouseEnhancerStore: ObservableObject {
    private enum StorageKey {
        static let reverseMouseHorizontal = "mouse-enhancer.scroll-reversing.mouse.horizontal"
        static let reverseMouseVertical = "mouse-enhancer.scroll-reversing.mouse.vertical"
        static let reverseTrackpadHorizontal = "mouse-enhancer.scroll-reversing.trackpad.horizontal"
        static let reverseTrackpadVertical = "mouse-enhancer.scroll-reversing.trackpad.vertical"
        static let middleClickEnabled = "mouse-enhancer.middle-click.enabled"
        static let middleClickFingerCount = "mouse-enhancer.middle-click.finger-count"
        static let mouseScrollStep = "mouse-enhancer.scroll-tuning.mouse.step"
        static let mouseScrollGain = "mouse-enhancer.scroll-tuning.mouse.gain"
        static let trackpadScrollStep = "mouse-enhancer.scroll-tuning.trackpad.step"
        static let trackpadScrollGain = "mouse-enhancer.scroll-tuning.trackpad.gain"
        static let smoothScrollingEnabled = "mouse-enhancer.smooth-scrolling.enabled"
        static let mouseScrollDuration = "mouse-enhancer.smooth-scrolling.duration"
    }

    @Published private(set) var configuration: MouseEnhancerConfiguration

    private let storage: any PluginStorage

    init(storage: any PluginStorage) {
        self.storage = storage
        self.configuration = MouseEnhancerConfiguration(
            reverseMouseHorizontal: Self.bool(
                forKey: StorageKey.reverseMouseHorizontal,
                defaultValue: MouseEnhancerConfiguration.default.reverseMouseHorizontal,
                storage: storage
            ),
            reverseMouseVertical: Self.bool(
                forKey: StorageKey.reverseMouseVertical,
                defaultValue: MouseEnhancerConfiguration.default.reverseMouseVertical,
                storage: storage
            ),
            reverseTrackpadHorizontal: Self.bool(
                forKey: StorageKey.reverseTrackpadHorizontal,
                defaultValue: MouseEnhancerConfiguration.default.reverseTrackpadHorizontal,
                storage: storage
            ),
            reverseTrackpadVertical: Self.bool(
                forKey: StorageKey.reverseTrackpadVertical,
                defaultValue: MouseEnhancerConfiguration.default.reverseTrackpadVertical,
                storage: storage
            ),
            middleClickEnabled: Self.bool(
                forKey: StorageKey.middleClickEnabled,
                defaultValue: MouseEnhancerConfiguration.default.middleClickEnabled,
                storage: storage
            ),
            middleClickFingerCount: Self.fingerCount(
                forKey: StorageKey.middleClickFingerCount,
                defaultValue: MouseEnhancerConfiguration.default.middleClickFingerCount,
                storage: storage
            ),
            mouseScrollStep: Self.double(
                forKey: StorageKey.mouseScrollStep,
                defaultValue: MouseEnhancerConfiguration.defaultScrollStep,
                storage: storage
            ),
            mouseScrollGain: Self.double(
                forKey: StorageKey.mouseScrollGain,
                defaultValue: MouseEnhancerConfiguration.defaultScrollGain,
                storage: storage
            ),
            trackpadScrollStep: Self.double(
                forKey: StorageKey.trackpadScrollStep,
                defaultValue: MouseEnhancerConfiguration.defaultScrollStep,
                storage: storage
            ),
            trackpadScrollGain: Self.double(
                forKey: StorageKey.trackpadScrollGain,
                defaultValue: MouseEnhancerConfiguration.defaultScrollGain,
                storage: storage
            ),
            smoothScrollingEnabled: Self.bool(
                forKey: StorageKey.smoothScrollingEnabled,
                defaultValue: false,
                storage: storage
            ),
            mouseScrollDuration: Self.double(
                forKey: StorageKey.mouseScrollDuration,
                defaultValue: MouseEnhancerConfiguration.defaultScrollDuration,
                storage: storage
            )
        )
    }

    func setReverseMouseHorizontal(_ isEnabled: Bool) {
        update(StorageKey.reverseMouseHorizontal, value: isEnabled) {
            $0.reverseMouseHorizontal = isEnabled
        }
    }

    func setReverseMouseVertical(_ isEnabled: Bool) {
        update(StorageKey.reverseMouseVertical, value: isEnabled) {
            $0.reverseMouseVertical = isEnabled
        }
    }

    func setReverseTrackpadHorizontal(_ isEnabled: Bool) {
        update(StorageKey.reverseTrackpadHorizontal, value: isEnabled) {
            $0.reverseTrackpadHorizontal = isEnabled
        }
    }

    func setReverseTrackpadVertical(_ isEnabled: Bool) {
        update(StorageKey.reverseTrackpadVertical, value: isEnabled) {
            $0.reverseTrackpadVertical = isEnabled
        }
    }

    func setMiddleClickEnabled(_ isEnabled: Bool) {
        update(StorageKey.middleClickEnabled, value: isEnabled) {
            $0.middleClickEnabled = isEnabled
        }
    }

    func setMiddleClickFingerCount(_ count: Int) {
        let normalizedCount = Self.normalizedFingerCount(count)
        update(StorageKey.middleClickFingerCount, value: normalizedCount) {
            $0.middleClickFingerCount = normalizedCount
        }
    }

    func setMouseScrollStep(_ value: Double) {
        let normalizedValue = MouseEnhancerConfiguration.normalizedScrollStep(value)
        update(StorageKey.mouseScrollStep, value: normalizedValue) {
            $0.mouseScrollStep = normalizedValue
        }
    }

    func setMouseScrollGain(_ value: Double) {
        let normalizedValue = MouseEnhancerConfiguration.normalizedScrollGain(value)
        update(StorageKey.mouseScrollGain, value: normalizedValue) {
            $0.mouseScrollGain = normalizedValue
        }
    }

    func setTrackpadScrollStep(_ value: Double) {
        let normalizedValue = MouseEnhancerConfiguration.normalizedScrollStep(value)
        update(StorageKey.trackpadScrollStep, value: normalizedValue) {
            $0.trackpadScrollStep = normalizedValue
        }
    }

    func setTrackpadScrollGain(_ value: Double) {
        let normalizedValue = MouseEnhancerConfiguration.normalizedScrollGain(value)
        update(StorageKey.trackpadScrollGain, value: normalizedValue) {
            $0.trackpadScrollGain = normalizedValue
        }
    }

    func setSmoothScrollingEnabled(_ isEnabled: Bool) {
        update(StorageKey.smoothScrollingEnabled, value: isEnabled) {
            $0.smoothScrollingEnabled = isEnabled
        }
    }

    func setMouseScrollDuration(_ value: Double) {
        let normalizedValue = MouseEnhancerConfiguration.normalizedScrollDuration(value)
        update(StorageKey.mouseScrollDuration, value: normalizedValue) {
            $0.mouseScrollDuration = normalizedValue
        }
    }

    private func update(
        _ key: String,
        value: Any,
        mutate: (inout MouseEnhancerConfiguration) -> Void
    ) {
        var next = configuration
        mutate(&next)
        guard next != configuration else {
            return
        }

        storage.set(value, forKey: key)
        configuration = next
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        storage: any PluginStorage
    ) -> Bool {
        guard storage.object(forKey: key) != nil else {
            return defaultValue
        }

        return storage.bool(forKey: key)
    }

    private static func fingerCount(
        forKey key: String,
        defaultValue: Int,
        storage: any PluginStorage
    ) -> Int {
        guard storage.object(forKey: key) != nil else {
            return defaultValue
        }

        return normalizedFingerCount(storage.integer(forKey: key))
    }

    private static func double(
        forKey key: String,
        defaultValue: Double,
        storage: any PluginStorage
    ) -> Double {
        guard let value = storage.object(forKey: key) as? Double else {
            return defaultValue
        }

        return value
    }

    private static func normalizedFingerCount(_ count: Int) -> Int {
        [3, 4, 5].contains(count) ? count : MouseEnhancerConfiguration.default.middleClickFingerCount
    }
}
