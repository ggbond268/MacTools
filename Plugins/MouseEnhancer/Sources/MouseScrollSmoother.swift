import AppKit
@preconcurrency import CoreGraphics
import CoreVideo
import Foundation
import MacToolsPluginKit
import OSLog

/// Pure scroll-glide state: accumulates wheel tick targets and emits
/// frame-rate-independent exponential decay toward them.
struct MouseScrollGlideAccumulator: Equatable, Sendable {
    static let drainEpsilon = 0.5

    private(set) var bufferY = 0.0
    private(set) var bufferX = 0.0
    private(set) var currentY = 0.0
    private(set) var currentX = 0.0

    var isDrained: Bool {
        abs(bufferY - currentY) < Self.drainEpsilon && abs(bufferX - currentX) < Self.drainEpsilon
    }

    /// Same-direction ticks extend the glide; a direction flip (or a zero tick on
    /// an axis) restarts that axis from the new target, mirroring Mos semantics.
    mutating func add(tickY: Double, tickX: Double) {
        if tickY == 0 || tickY * bufferY <= 0 {
            bufferY = tickY
            currentY = 0
        } else {
            bufferY += tickY
        }

        if tickX == 0 || tickX * bufferX <= 0 {
            bufferX = tickX
            currentX = 0
        } else {
            bufferX += tickX
        }
    }

    /// Emits the per-frame delta for each axis. The decay fraction is derived
    /// from the measured frame period, so the glide duration is identical on
    /// 60 Hz and high-refresh displays without refresh-rate self-correction.
    mutating func advance(framePeriod: TimeInterval, duration: TimeInterval) -> (y: Double, x: Double) {
        let tau = max(duration / 3, 0.05)
        let alpha = min(max(1 - exp(-min(max(framePeriod, 0), 1) / tau), 0.01), 1)

        let frameY = (bufferY - currentY) * alpha
        let frameX = (bufferX - currentX) * alpha
        currentY += frameY
        currentX += frameX

        if abs(bufferY - currentY) < Self.drainEpsilon { currentY = bufferY }
        if abs(bufferX - currentX) < Self.drainEpsilon { currentX = bufferX }
        return (frameY, frameX)
    }

    mutating func reset() {
        self = MouseScrollGlideAccumulator()
    }
}

/// Holds the posting template captured from the last intercepted wheel event.
/// Stale frames are dropped by generation and TTL, mirroring Mos's dispatch
/// context guards against focus changes and stopped glides.
final class MouseScrollGlideTemplateStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let event: CGEvent
        let targetProcessID: pid_t
        let isChromiumTarget: Bool
        let generation: UInt64
        let createdAt: TimeInterval
    }

    private let lock = NSLock()
    private var template: CGEvent?
    private var targetProcessID: pid_t = 0
    private var isChromiumTarget = false
    private var generation: UInt64 = 0
    private var createdAt: TimeInterval = 0
    private var chromiumCache: [pid_t: Bool] = [:]

    private let timeToLive: TimeInterval

    init(timeToLive: TimeInterval = 5) {
        self.timeToLive = timeToLive
    }

    func capture(event: CGEvent) {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        let isChromium = chromiumTarget(for: pid)

        lock.lock()
        defer { lock.unlock() }
        template = event.copy()
        targetProcessID = pid
        isChromiumTarget = isChromium
        createdAt = CFAbsoluteTimeGetCurrent()
    }

    func makeSnapshot(now: TimeInterval = CFAbsoluteTimeGetCurrent()) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let template,
              let clone = template.copy(),
              now - createdAt <= timeToLive,
              targetProcessID != 0 else {
            return nil
        }
        return Snapshot(
            event: clone,
            targetProcessID: targetProcessID,
            isChromiumTarget: isChromiumTarget,
            generation: generation,
            createdAt: now
        )
    }

    /// Bumps the generation so frames already queued for the previous glide are dropped.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    private func chromiumTarget(for pid: pid_t) -> Bool {
        guard pid != 0 else { return false }
        lock.lock()
        if let cached = chromiumCache[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Mos sends the terminal zero-delta event only to com.google.Chrome;
        // extend the family only if other targets demonstrate the same stuck-scroll.
        let isChromium = NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier == "com.google.Chrome"

        lock.lock()
        defer { lock.unlock() }
        if chromiumCache.count > 32 {
            chromiumCache.removeAll()
        }
        chromiumCache[pid] = isChromium
        return isChromium
    }
}

/// Re-emits intercepted mouse wheel ticks as a continuous, display-paced scroll
/// stream, modeled on Mos's smooth scrolling engine (GPLv3, same license).
final class MouseScrollSmoother: @unchecked Sendable {
    static let syntheticEventMarker: Int64 = 0x4D61_6354_6F6F_6C53 // "MacToolS"

    private let lock = NSLock()
    private let templates = MouseScrollGlideTemplateStore()
    private let postQueue = DispatchQueue(label: "mactools.mouse-enhancer.smoother.post", qos: .userInteractive)
    private var accumulator = MouseScrollGlideAccumulator()
    private var isEnabled = false
    private var duration: TimeInterval
    private var displayLink: CVDisplayLink?
    private var linkCallbackPointer: UnsafeMutableRawPointer?
    private var lastFrameTime: TimeInterval = 0

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MouseScrollSmoother"
    )

    init(defaultDuration: TimeInterval) {
        self.duration = defaultDuration
    }

    deinit {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        if let linkCallbackPointer {
            Unmanaged<PluginCallbackContext<MouseScrollSmoother>>
                .fromOpaque(linkCallbackPointer)
                .release()
        }
    }

    /// Called from the event tap on the main run loop. Returns true when the
    /// event is absorbed and re-emitted; the caller must then swallow it.
    func ingest(event: CGEvent, tickY: Double, tickX: Double) -> Bool {
        lock.lock()
        guard isEnabled else {
            lock.unlock()
            return false
        }

        if tickY == 0 && tickX == 0 {
            lock.unlock()
            return false
        }

        accumulator.add(tickY: tickY, tickX: tickX)
        lock.unlock()

        templates.capture(event: event)
        startDisplayLinkIfNeeded()
        return true
    }

    func updateConfiguration(isEnabled: Bool, duration: TimeInterval) {
        lock.lock()
        self.duration = duration

        guard isEnabled != self.isEnabled else {
            lock.unlock()
            return
        }

        self.isEnabled = isEnabled
        if isEnabled {
            lock.unlock()
        } else {
            accumulator.reset()
            lastFrameTime = 0
            lock.unlock()
            templates.invalidate()
            stopDisplayLink()
        }
    }

    /// Drops any in-flight glide; called from session recovery and teardown so a
    /// stale glide never survives wake, secure input, or tap restarts.
    func reset() {
        lock.lock()
        accumulator.reset()
        lastFrameTime = 0
        lock.unlock()
        templates.invalidate()
        stopDisplayLink()
    }

    private func startDisplayLinkIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
                logger.error("failed to create display link for smooth scrolling")
                return
            }

            let context = PluginCallbackContext(owner: self)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
                guard let userInfo else { return kCVReturnSuccess }
                let callbackContext = Unmanaged<PluginCallbackContext<MouseScrollSmoother>>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                _ = callbackContext.withOwner { $0.frame() }
                return kCVReturnSuccess
            }

            guard CVDisplayLinkSetOutputCallback(link, callback, pointer) == kCVReturnSuccess else {
                Unmanaged<PluginCallbackContext<MouseScrollSmoother>>.fromOpaque(pointer).release()
                logger.error("failed to install display link callback")
                return
            }

            displayLink = link
            linkCallbackPointer = pointer
        }

        // ponytail: no zombie-link health check; a silent link recovers on the
        // next wheel tick, add a Mos-style keeper timer if stalls are reported.
        if let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            lastFrameTime = 0
            CVDisplayLinkStart(displayLink)
        }
    }

    private func stopDisplayLink() {
        lock.lock()
        defer { lock.unlock() }
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        lastFrameTime = 0
    }

    private func frame() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let framePeriod = lastFrameTime > 0 ? min(max(now - lastFrameTime, 0), 1) : (1.0 / 60.0)
        lastFrameTime = now

        let glideDuration = duration
        let deltas = accumulator.advance(framePeriod: framePeriod, duration: glideDuration)
        let drained = accumulator.isDrained

        var frameSnapshot: MouseScrollGlideTemplateStore.Snapshot?
        var terminalSnapshot: MouseScrollGlideTemplateStore.Snapshot?
        if let snapshot = templates.makeSnapshot(now: now) {
            frameSnapshot = snapshot
            if drained {
                // Bump first so regular frames from this glide are dropped, then
                // snapshot again so the terminal event itself survives the check.
                templates.invalidate()
                terminalSnapshot = templates.makeSnapshot(now: now)
            }
        }

        if drained {
            accumulator.reset()
            lastFrameTime = 0
            if let displayLink {
                CVDisplayLinkStop(displayLink)
            }
        }
        lock.unlock()

        if let frameSnapshot {
            post(frameSnapshot, deltaY: deltas.y, deltaX: deltas.x)
        }
        if let terminalSnapshot {
            post(terminalSnapshot, deltaY: 0, deltaX: 0)
        }
    }

    private func post(_ snapshot: MouseScrollGlideTemplateStore.Snapshot, deltaY: Double, deltaX: Double) {
        let generation = snapshot.generation
        let createdAt = snapshot.createdAt
        let timeToLive = 5.0
        nonisolated(unsafe) let event = snapshot.event
        let targetProcessID = snapshot.targetProcessID

        postQueue.async { [templates] in
            // A newer generation (new glide, config change, or reset) or an expired
            // template cancels this frame; posting it would scroll a stale target.
            guard templates.makeSnapshot(now: createdAt)?.generation == generation,
                  CFAbsoluteTimeGetCurrent() - createdAt <= timeToLive else {
                return
            }

            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
            event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            event.postToPid(targetProcessID)
        }
    }
}
