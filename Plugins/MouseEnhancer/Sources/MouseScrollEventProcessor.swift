import AppKit
import CoreGraphics
import Foundation

struct MouseScrollEventSnapshot: Equatable, Sendable {
    var isContinuous: Bool
    var scrollPhase: Int64
    var momentumPhase: Int64
    var sourceProcessID: Int64

    static let discreteWheel = MouseScrollEventSnapshot(
        isContinuous: false,
        scrollPhase: 0,
        momentumPhase: 0
    )

    static let phaseLessContinuousWheel = MouseScrollEventSnapshot(
        isContinuous: true,
        scrollPhase: 0,
        momentumPhase: 0
    )

    init(
        isContinuous: Bool,
        scrollPhase: Int64,
        momentumPhase: Int64,
        sourceProcessID: Int64 = 0
    ) {
        self.isContinuous = isContinuous
        self.scrollPhase = scrollPhase
        self.momentumPhase = momentumPhase
        self.sourceProcessID = sourceProcessID
    }
}

struct MouseScrollDeltas: Equatable, Sendable {
    var deltaAxis1: Int64
    var deltaAxis2: Int64
    var pointDeltaAxis1: Int64
    var pointDeltaAxis2: Int64
    var fixedPointDeltaAxis1: Double
    var fixedPointDeltaAxis2: Double
}

struct MouseScrollProcessingResult: Equatable, Sendable {
    var source: MouseEnhancerDevice
    var shouldReverse: Bool
    var reverseHorizontal: Bool
    var reverseVertical: Bool
    var isTuned: Bool
    var deltas: MouseScrollDeltas
}

/// Scroll feel adjustments applied per event, following Mos's model: a minimum
/// step that lifts tiny wheel ticks up to a floor, and a gain multiplier on the
/// reported scroll distance.
struct MouseScrollTuning: Equatable, Sendable {
    var step: Double
    var gain: Double

    static let passthrough = MouseScrollTuning(step: 0, gain: 1)

    var isActive: Bool {
        step > 0 || gain != 1
    }

    func apply(_ deltas: MouseScrollDeltas) -> MouseScrollDeltas {
        var next = deltas

        (next.deltaAxis1, next.pointDeltaAxis1, next.fixedPointDeltaAxis1) = tunedAxis(
            line: deltas.deltaAxis1,
            point: deltas.pointDeltaAxis1,
            fixed: deltas.fixedPointDeltaAxis1
        )
        (next.deltaAxis2, next.pointDeltaAxis2, next.fixedPointDeltaAxis2) = tunedAxis(
            line: deltas.deltaAxis2,
            point: deltas.pointDeltaAxis2,
            fixed: deltas.fixedPointDeltaAxis2
        )
        return next
    }

    private func tunedAxis(
        line: Int64,
        point: Int64,
        fixed: Double
    ) -> (line: Int64, point: Int64, fixed: Double) {
        var nextLine = Double(line)
        var nextPoint = Double(point)
        var nextFixed = fixed

        if gain != 1 {
            nextLine = scaled(nextLine * gain, fallbackSignOf: line)
            nextPoint = scaled(nextPoint * gain, fallbackSignOf: point)
            nextFixed *= gain
        }

        // The step floor is defined in pixels, so it is anchored on the pixel
        // delta and the line/fixed-point fields are scaled proportionally to
        // keep the three representations consistent. Pixel-less axes carry no
        // pixel magnitude to floor against and stay untouched.
        if step > 0, nextPoint != 0, abs(nextPoint) < step {
            let scale = step / abs(nextPoint)
            nextPoint = nextPoint < 0 ? -step : step
            nextFixed *= scale
            nextLine = scaled(nextLine * scale, fallbackSignOf: Int64(nextLine))
        }

        return (Int64(nextLine), Int64(nextPoint), nextFixed)
    }

    /// Rounds a scaled delta while keeping nonzero sources nonzero, so coarse
    /// integer deltas do not collapse to zero under a gain below one.
    private func scaled(_ value: Double, fallbackSignOf original: Int64) -> Double {
        let rounded = value.rounded()
        if rounded == 0, original != 0 {
            return original < 0 ? -1 : 1
        }

        return rounded
    }
}

/// Remote-control software (screen sharing, VNC, remote desktop clients) injects
/// scroll events that the controlling side already smoothed and scaled. Running
/// reversal and tuning on them double-processes the stream, so those events pass
/// through untouched. Source list modeled on Mos's remote-desktop detection.
private enum MouseScrollRemoteSource {
    static let executableKeywords = [
        "screensharingd",
        "ScreensharingAgent",
        "ARDAgent",
    ]

    static let bundleIdentifiers: Set<String> = [
        "com.teamviewer.TeamViewer",
        "com.teamviewer.TeamViewerHost",
        "com.anydesk.anydesk",
        "com.parsec.www",
        "com.rustdesk.RustDesk",
        "com.microsoft.rdc.macos",
        "com.realvnc.vncviewer",
        "com.tigervnc.vncviewer",
        "com.netease.uuremote",
    ]

    static func isRemoteSource(_ processID: Int64) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(processID)) else {
            return false
        }

        if let path = app.executableURL?.path,
           executableKeywords.contains(where: path.contains) {
            return true
        }
        if let bundleID = app.bundleIdentifier, bundleIdentifiers.contains(bundleID) {
            return true
        }
        return false
    }
}

final class MouseScrollEventProcessor: @unchecked Sendable {
    private enum Timing {
        static let touchRecentThreshold: UInt64 = 222_000_000
        static let touchStaleThreshold: UInt64 = 333_000_000
    }

    nonisolated(unsafe) var configuration: MouseEnhancerConfiguration
    nonisolated(unsafe) private var touchingCount = 0
    nonisolated(unsafe) private var lastTouchTime: UInt64 = 0
    nonisolated(unsafe) private var lastSource: MouseEnhancerDevice = .mouse
    nonisolated(unsafe) private var hasSeenTrackpadTouch = false
    nonisolated(unsafe) private var gestureMonitoringAvailable = false
    nonisolated(unsafe) private var remoteSourceCache: [Int64: Bool] = [:]
    private let remoteSourceEvaluator: (Int64) -> Bool

    init(
        configuration: MouseEnhancerConfiguration,
        remoteSourceEvaluator: ((Int64) -> Bool)? = nil
    ) {
        self.configuration = configuration
        self.remoteSourceEvaluator = remoteSourceEvaluator ?? MouseScrollRemoteSource.isRemoteSource
    }

    func resetClassificationState() {
        touchingCount = 0
        lastTouchTime = 0
        lastSource = .mouse
        hasSeenTrackpadTouch = false
        remoteSourceCache = [:]
    }

    /// Remote-control sessions deliver already-smoothed continuous events; leave
    /// them alone so reversal and tuning never double-process the stream.
    func isRemoteSmoothed(snapshot: MouseScrollEventSnapshot) -> Bool {
        guard snapshot.isContinuous, snapshot.sourceProcessID != 0 else {
            return false
        }

        if let cached = remoteSourceCache[snapshot.sourceProcessID] {
            return cached
        }

        let isRemote = remoteSourceEvaluator(snapshot.sourceProcessID)
        remoteSourceCache[snapshot.sourceProcessID] = isRemote
        return isRemote
    }

    func recordGestureTouchingCount(_ count: Int, timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard count >= 2 else {
            return
        }

        hasSeenTrackpadTouch = true
        lastTouchTime = timestamp
        touchingCount = max(touchingCount, count)
    }

    func setGestureMonitoringAvailable(_ isAvailable: Bool) {
        gestureMonitoringAvailable = isAvailable
        if !isAvailable {
            resetClassificationState()
        }
    }

    func classify(
        snapshot: MouseScrollEventSnapshot,
        timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> MouseEnhancerDevice {
        let touching = touchingCount
        touchingCount = 0

        guard snapshot.isContinuous else {
            lastSource = .mouse
            return .mouse
        }

        let elapsed = lastTouchTime == 0 ? UInt64.max : timestamp &- lastTouchTime
        if touching >= 2, elapsed < Timing.touchRecentThreshold {
            lastSource = .trackpad
            return .trackpad
        }

        if snapshot.hasNoGesturePhase {
            lastSource = .mouse
            return .mouse
        }

        // A CGEvent tap can remain enabled while secure input, screen locking, or a display
        // topology transition has interrupted its gesture callbacks. Until a fresh two-finger
        // contact proves that gesture monitoring is healthy again, prefer the trackpad for a
        // phased continuous scroll. Discrete and phase-less wheels have already been classified
        // as mice above, so this conservative fallback does not affect normal mouse wheels.
        guard gestureMonitoringAvailable, hasSeenTrackpadTouch else {
            lastSource = .trackpad
            return .trackpad
        }

        if snapshot.isNormalScroll, elapsed > Timing.touchStaleThreshold {
            lastSource = .mouse
            return .mouse
        }

        return lastSource
    }

    func process(
        snapshot: MouseScrollEventSnapshot,
        deltas: MouseScrollDeltas,
        timestamp: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> MouseScrollProcessingResult {
        if isRemoteSmoothed(snapshot: snapshot) {
            return MouseScrollProcessingResult(
                source: .mouse,
                shouldReverse: false,
                reverseHorizontal: false,
                reverseVertical: false,
                isTuned: false,
                deltas: deltas
            )
        }

        let source = classify(snapshot: snapshot, timestamp: timestamp)
        let shouldReverse = configuration.shouldReverse(device: source)
        let tuning = MouseScrollTuning(
            step: configuration.scrollStep(for: source),
            gain: configuration.scrollGain(for: source)
        )

        guard shouldReverse || tuning.isActive else {
            return MouseScrollProcessingResult(
                source: source,
                shouldReverse: false,
                reverseHorizontal: false,
                reverseVertical: false,
                isTuned: false,
                deltas: deltas
            )
        }

        let reverseHorizontal = configuration.shouldReverseHorizontal(device: source)
        let reverseVertical = configuration.shouldReverseVertical(device: source)
        var tunedDeltas = shouldReverse
            ? Self.reversed(
                deltas: deltas,
                reverseHorizontal: reverseHorizontal,
                reverseVertical: reverseVertical
            )
            : deltas
        if tuning.isActive {
            // Tuning runs after reversing so the step floor applies to the
            // final per-event distance the system will scroll.
            tunedDeltas = tuning.apply(tunedDeltas)
        }
        return MouseScrollProcessingResult(
            source: source,
            shouldReverse: shouldReverse,
            reverseHorizontal: reverseHorizontal,
            reverseVertical: reverseVertical,
            isTuned: true,
            deltas: tunedDeltas
        )
    }

    @discardableResult
    func process(event: CGEvent) -> MouseScrollProcessingResult {
        let snapshot = MouseScrollEventSnapshot(event: event)
        let deltas = MouseScrollDeltas(event: event)
        let result = process(snapshot: snapshot, deltas: deltas)

        guard result.shouldReverse || result.isTuned else {
            return result
        }

        event.applyScrollDeltas(
            result.deltas,
            applyVertical: result.reverseVertical || result.isTuned,
            applyHorizontal: result.reverseHorizontal || result.isTuned
        )
        return result
    }

    private static func reversed(
        deltas: MouseScrollDeltas,
        reverseHorizontal: Bool,
        reverseVertical: Bool
    ) -> MouseScrollDeltas {
        var next = deltas
        if reverseVertical {
            next.deltaAxis1 = -next.deltaAxis1
            next.pointDeltaAxis1 = -next.pointDeltaAxis1
            next.fixedPointDeltaAxis1 = -next.fixedPointDeltaAxis1
        }
        if reverseHorizontal {
            next.deltaAxis2 = -next.deltaAxis2
            next.pointDeltaAxis2 = -next.pointDeltaAxis2
            next.fixedPointDeltaAxis2 = -next.fixedPointDeltaAxis2
        }
        return next
    }
}

private extension MouseScrollEventSnapshot {
    init(event: CGEvent) {
        self.init(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            sourceProcessID: event.getIntegerValueField(.eventSourceUnixProcessID)
        )
    }

    var hasNoGesturePhase: Bool {
        scrollPhase == 0 && momentumPhase == 0
    }

    var isNormalScroll: Bool {
        momentumPhase == 0
    }
}

private extension MouseScrollDeltas {
    init(event: CGEvent) {
        self.init(
            deltaAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            deltaAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            pointDeltaAxis1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            pointDeltaAxis2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixedPointDeltaAxis1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            fixedPointDeltaAxis2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
    }
}

private extension CGEvent {
    func applyScrollDeltas(
        _ deltas: MouseScrollDeltas,
        applyVertical: Bool,
        applyHorizontal: Bool
    ) {
        // Set line deltas first. macOS may derive point/fixed deltas from them,
        // so point and fixed values are restored afterwards to preserve smooth scrolling.
        if applyVertical {
            setIntegerValueField(.scrollWheelEventDeltaAxis1, value: deltas.deltaAxis1)
            setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltas.fixedPointDeltaAxis1)
            setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: deltas.pointDeltaAxis1)
        }

        if applyHorizontal {
            setIntegerValueField(.scrollWheelEventDeltaAxis2, value: deltas.deltaAxis2)
            setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: deltas.fixedPointDeltaAxis2)
            setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: deltas.pointDeltaAxis2)
        }
    }
}
