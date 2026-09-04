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
    private var deviceValues: [UInt64: UInt64] = [:]

    func current() -> UInt64 {
        lock.withLock { value }
    }

    func advance() -> UInt64 {
        lock.withLock {
            value &+= 1
            deviceValues.removeAll()
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

    func withCurrentFrameValue(
        deviceID: UInt64,
        _ body: (UInt64, UInt64) -> Void
    ) {
        lock.withLock {
            body(value, deviceValues[deviceID, default: 0])
        }
    }

    func advanceDeviceWithValue(
        deviceID: UInt64,
        _ body: (UInt64, UInt64) -> Void
    ) {
        lock.withLock {
            deviceValues[deviceID, default: 0] &+= 1
            body(value, deviceValues[deviceID, default: 0])
        }
    }

    func isCurrent(
        global candidate: UInt64,
        deviceID: UInt64,
        device candidateDevice: UInt64
    ) -> Bool {
        lock.withLock {
            value == candidate
                && deviceValues[deviceID, default: 0] == candidateDevice
        }
    }

    func advanceWithValue(_ body: (UInt64) -> Void) {
        lock.withLock {
            value &+= 1
            deviceValues.removeAll()
            body(value)
        }
    }
}

enum TrackpadGestureRecognitionDeliveryToken: Equatable, Sendable {
    case frame(globalGeneration: UInt64, deviceID: UInt64, deviceGeneration: UInt64)
    case nativeClick(UInt64)

    var frameGeneration: UInt64? {
        guard case let .frame(generation, _, _) = self else { return nil }
        return generation
    }

    var frameDeviceGeneration: UInt64? {
        guard case let .frame(_, _, generation) = self else { return nil }
        return generation
    }
}

final class TrackpadGestureRecognitionWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private var engine = TrackpadGestureEngine()
    private let generation: TrackpadGestureRecognitionGeneration
    private let nativeClickDeliveryGeneration = TrackpadGestureRecognitionGeneration()
    private let beforeConfigurationEnqueue: (@Sendable () -> Void)?
    private let beforeFrameProcessing: (@Sendable () -> Void)?
    private let testingSnapshotRelay: TrackpadGestureTestSnapshotRelay?
    private let onRecognized: @Sendable (
        TrackpadGesture,
        UInt64,
        TrackpadGestureRecognitionDeliveryToken,
        TrackpadGestureRecognitionEvidence?,
        TimeInterval?
    ) -> Void

    init(
        generation: TrackpadGestureRecognitionGeneration,
        queue: DispatchQueue = DispatchQueue(
            label: "cc.ggbond.mactools.trackpad-gestures.recognition",
            qos: .userInteractive
        ),
        beforeConfigurationEnqueue: (@Sendable () -> Void)? = nil,
        beforeFrameProcessing: (@Sendable () -> Void)? = nil,
        testingSnapshotRelay: TrackpadGestureTestSnapshotRelay? = nil,
        onRecognized: @escaping @Sendable (
            TrackpadGesture,
            UInt64,
            TrackpadGestureRecognitionDeliveryToken,
            TrackpadGestureRecognitionEvidence?,
            TimeInterval?
        ) -> Void
    ) {
        self.generation = generation
        self.queue = queue
        self.beforeConfigurationEnqueue = beforeConfigurationEnqueue
        self.beforeFrameProcessing = beforeFrameProcessing
        self.testingSnapshotRelay = testingSnapshotRelay
        self.onRecognized = onRecognized
    }

    func configure(gestures: Set<TrackpadGesture>, reset: Bool = false) {
        _ = nativeClickDeliveryGeneration.advance()
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

    /// Invalidates work admitted under an old action mapping without rebuilding the recognizers.
    /// Gesture-shape updates still go through `configure(gestures:)`.
    func invalidateDeliveriesPreservingRecognizerState() {
        _ = nativeClickDeliveryGeneration.advance()
        _ = generation.advance()
    }

    func process(
        _ frame: TrackpadContactFrame,
        suppressRecognition: Bool = false,
        contactEpisodeID: TrackpadContactEpisodeID? = nil,
        tipTapRecognitionIDs: [TrackpadGesture: TrackpadTipTapEpisodeID] = [:]
    ) {
        generation.withCurrentFrameValue(deviceID: frame.deviceID) {
            frameGeneration, frameDeviceGeneration in
            let deliveryToken = TrackpadGestureRecognitionDeliveryToken.frame(
                globalGeneration: frameGeneration,
                deviceID: frame.deviceID,
                deviceGeneration: frameDeviceGeneration
            )
            queue.async { [self] in
                beforeFrameProcessing?()
                guard isCurrent(deliveryToken) else { return }
                let result = engine.process(frame, suppressRecognition: suppressRecognition)
                guard isCurrent(deliveryToken) else { return }
                if let testingSnapshotRelay,
                   let testingToken = testingSnapshotRelay.currentToken() {
                    testingSnapshotRelay.offer(TrackpadGestureTestSnapshot(
                        deviceID: frame.deviceID,
                        descriptor: nil,
                        timestamp: frame.timestamp,
                        contacts: frame.contacts,
                        recognized: result.recognized,
                        recognition: testingToken.mode.practiceGesture.flatMap {
                            engine.testingSnapshot(for: $0, deviceID: frame.deviceID)
                        }
                    ),
                    token: testingToken,
                    recognitionGeneration: frameGeneration,
                    recognitionDeviceGeneration: frameDeviceGeneration)
                }
                result.recognized.forEach {
                    let evidence = tipTapRecognitionIDs[$0]
                        .map(TrackpadGestureRecognitionEvidence.tipTapEpisode)
                        ?? contactEpisodeID.map(TrackpadGestureRecognitionEvidence.contactEpisode)
                    onRecognized(
                        $0,
                        frame.deviceID,
                        deliveryToken,
                        evidence,
                        frame.timestamp
                    )
                }
            }
        }
    }

    func beginSuppression(activeDeviceIDs: Set<UInt64>) {
        _ = nativeClickDeliveryGeneration.advance()
        generation.advanceWithValue { suppressionGeneration in
            queue.async { [self] in
                guard isCurrent(suppressionGeneration) else { return }
                engine.beginSuppression(activeDeviceIDs: activeDeviceIDs)
            }
        }
    }

    func beginLifecycleSuppression() {
        _ = nativeClickDeliveryGeneration.advance()
        generation.advanceWithValue { suppressionGeneration in
            queue.async { [self] in
                guard isCurrent(suppressionGeneration) else { return }
                engine.beginLifecycleSuppression()
            }
        }
    }

    func prepareLifecycleRestart(gestures: Set<TrackpadGesture>) {
        _ = nativeClickDeliveryGeneration.advance()
        generation.advanceWithValue { suppressionGeneration in
            queue.async { [self] in
                guard isCurrent(suppressionGeneration) else { return }
                engine = TrackpadGestureEngine(gestures: gestures)
                engine.beginLifecycleSuppression()
            }
        }
    }

    func recognizeNativeClick(_ gesture: TrackpadGesture, deviceID: UInt64) {
        generation.advanceDeviceWithValue(deviceID: deviceID) { _, _ in
            nativeClickDeliveryGeneration.withCurrentValue { deliveryGeneration in
                queue.async { [self] in
                    guard nativeClickDeliveryGeneration.isCurrent(deliveryGeneration) else {
                        return
                    }
                    // A physical click can otherwise resemble a tap when the contacts lift.
                    // Suppress only the originating device so another trackpad keeps its own
                    // recognition epoch and contact state.
                    engine.beginSuppression(deviceID: deviceID)
                    guard nativeClickDeliveryGeneration.isCurrent(deliveryGeneration) else {
                        return
                    }
                    onRecognized(gesture, deviceID, .nativeClick(deliveryGeneration), nil, nil)
                }
            }
        }
    }

    func isCurrent(_ token: TrackpadGestureRecognitionDeliveryToken) -> Bool {
        switch token {
        case let .frame(globalGeneration, deviceID, deviceGeneration):
            generation.isCurrent(
                global: globalGeneration,
                deviceID: deviceID,
                device: deviceGeneration
            )
        case let .nativeClick(candidate):
            nativeClickDeliveryGeneration.isCurrent(candidate)
        }
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        generation.isCurrent(candidate)
    }

    func waitUntilIdleForTests() {
        queue.sync {}
    }
}
