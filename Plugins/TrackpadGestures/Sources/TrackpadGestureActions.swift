import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

@MainActor
protocol TrackpadGestureActionExecuting: AnyObject {
    func execute(_ action: TrackpadGestureAction)
}

final class TrackpadGestureActionExecutor: TrackpadGestureActionExecuting {
    nonisolated static let keyboardEventMarker = MacToolsSyntheticInputEvent.marker

    func execute(_ action: TrackpadGestureAction) {
        switch action {
        case .action:
            // Canonical MacTools actions are executed by the injected host
            // context so they share availability, confirmation, and logging.
            break
        case let .keyboardShortcut(binding):
            postShortcut(binding)
        case let .keyTap(keyTap):
            KeyboardKeyTapEventPoster.post(keyTap)
        case .middleClick:
            TrackpadMiddleClickEventPoster.postClick()
        }
    }

    private func postShortcut(_ binding: ShortcutBinding) {
        guard binding.isValid,
              let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: binding.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: binding.keyCode, keyDown: false)
        else {
            return
        }

        let flags = cgEventFlags(for: binding.modifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        MacToolsSyntheticInputEvent.mark(keyDown)
        MacToolsSyntheticInputEvent.mark(keyUp)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func cgEventFlags(for modifiers: ShortcutModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}

enum TrackpadMiddleClickEventPoster {
    static func postClick() {
        guard let mouseDown = makeEvent(type: .otherMouseDown),
              let mouseUp = makeEvent(type: .otherMouseUp)
        else {
            return
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    static func postButtonUp(eventSourceMarker: Int64? = nil) {
        guard let event = makeEvent(type: .otherMouseUp) else { return }
        if let eventSourceMarker {
            event.setIntegerValueField(.eventSourceUserData, value: eventSourceMarker)
        }
        event.post(tap: .cghidEventTap)
    }

    private static func makeEvent(type: CGEventType) -> CGEvent? {
        guard let location = CGEvent(source: nil)?.location,
              let event = CGEvent(
                  mouseEventSource: nil,
                  mouseType: type,
                  mouseCursorPosition: location,
                  mouseButton: .center
              )
        else {
            return nil
        }
        event.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(CGMouseButton.center.rawValue)
        )
        return event
    }
}

final class TrackpadGestureRecognitionGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func current() -> UInt64 {
        lock.withLock { value }
    }

    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            return value
        }
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock { value == candidate }
    }

    func withCurrentValue(_ body: (UInt64) -> Void) {
        lock.withLock {
            body(value)
        }
    }

    func advanceWithValue(_ body: (UInt64) -> Void) {
        lock.withLock {
            value &+= 1
            body(value)
        }
    }
}

final class TrackpadGestureRecognitionWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private var engine = TrackpadGestureEngine()
    private let generation: TrackpadGestureRecognitionGeneration
    private let beforeConfigurationEnqueue: (@Sendable () -> Void)?
    private let beforeFrameProcessing: (@Sendable () -> Void)?
    private let onRecognized: @Sendable (TrackpadGesture, UInt64, UInt64) -> Void

    init(
        generation: TrackpadGestureRecognitionGeneration,
        queue: DispatchQueue = DispatchQueue(
            label: "cc.ggbond.mactools.trackpad-gestures.recognition",
            qos: .userInteractive
        ),
        beforeConfigurationEnqueue: (@Sendable () -> Void)? = nil,
        beforeFrameProcessing: (@Sendable () -> Void)? = nil,
        onRecognized: @escaping @Sendable (TrackpadGesture, UInt64, UInt64) -> Void
    ) {
        self.generation = generation
        self.queue = queue
        self.beforeConfigurationEnqueue = beforeConfigurationEnqueue
        self.beforeFrameProcessing = beforeFrameProcessing
        self.onRecognized = onRecognized
    }

    func configure(gestures: Set<TrackpadGesture>, reset: Bool = false) {
        generation.advanceWithValue { configurationGeneration in
            beforeConfigurationEnqueue?()
            queue.async { [self] in
                guard isCurrent(configurationGeneration) else { return }
                if reset {
                    engine = TrackpadGestureEngine(gestures: gestures)
                } else {
                    engine.updateGestures(gestures)
                }
            }
        }
    }

    func process(_ frame: TrackpadContactFrame, suppressRecognition: Bool = false) {
        generation.withCurrentValue { frameGeneration in
            queue.async { [self] in
                beforeFrameProcessing?()
                guard isCurrent(frameGeneration) else { return }
                let result = engine.process(frame, suppressRecognition: suppressRecognition)
                guard isCurrent(frameGeneration) else { return }
                result.recognized.forEach {
                    onRecognized($0, frame.deviceID, frameGeneration)
                }
            }
        }
    }

    func beginSuppression(activeDeviceIDs: Set<UInt64>) {
        generation.advanceWithValue { suppressionGeneration in
            queue.async { [self] in
                guard isCurrent(suppressionGeneration) else { return }
                engine.beginSuppression(activeDeviceIDs: activeDeviceIDs)
            }
        }
    }

    func recognizeNativeClick(_ gesture: TrackpadGesture, deviceID: UInt64) {
        generation.advanceWithValue { recognitionGeneration in
            queue.async { [self] in
                guard isCurrent(recognitionGeneration) else { return }
                // A physical click can otherwise resemble a tap when the contacts lift. Keep
                // the rest of this contact episode suppressed, then deliver only the click.
                engine.beginSuppression(activeDeviceIDs: [deviceID])
                guard isCurrent(recognitionGeneration) else { return }
                onRecognized(gesture, deviceID, recognitionGeneration)
            }
        }
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        generation.isCurrent(candidate)
    }

    func waitUntilIdleForTests() {
        queue.sync {}
    }
}
