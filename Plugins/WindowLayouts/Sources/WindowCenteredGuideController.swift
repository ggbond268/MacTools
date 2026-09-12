import AppKit
import ApplicationServices
import MacToolsPluginKit

@MainActor
final class WindowCenteredGuideController {
    private let environment: any WindowCenteredGuideEnvironment
    private let cadence: Duration
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var pointer = CGPoint.zero
    private var hasDragEvent = false
    private var lastDragAt: ContinuousClock.Instant?
    private var released = false
    private var releasedAt: ContinuousClock.Instant?
    private var pointerHistory = WindowCenteredGuidePointerHistory()
    private var enabled = false
    private var workspaceObservers: [NSObjectProtocol] = []

    init(environment: any WindowCenteredGuideEnvironment, cadence: Duration = .milliseconds(16)) {
        self.environment = environment
        self.cadence = cadence
    }

    isolated deinit {
        task?.cancel()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func configure(enabled: Bool, respectsStageManager: Bool) {
        cancel()
        self.enabled = enabled
        (environment as? SystemWindowCenteredGuideEnvironment)?.respectsStageManager = respectsStageManager
        if enabled, workspaceObservers.isEmpty {
            workspaceObservers = [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification,
                                   NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map { name in
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                }
            }
        } else if !enabled {
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers.removeAll()
        }
    }

    func handle(_ event: WindowModifierDragMonitorEvent) {
        guard enabled else { return }
        switch event.type {
        case .leftMouseDown:
            cancel()
            guard environment.isTrusted,
                  let candidate = environment.candidate(at: event.location) else { return }
            pointer = event.location
            pointerHistory.record(pointer)
            hasDragEvent = false
            released = false
            let currentGeneration = generation
            let originalPointer = pointer
            // The CG baseline is captured synchronously on mouse down, before AX resolution.
            task = Task { [weak self] in
                guard let self else { return }
                await self.track(candidate, originalPointer: originalPointer, generation: currentGeneration)
            }
        case .leftMouseDragged:
            pointer = event.location
            pointerHistory.record(pointer)
            hasDragEvent = true
            lastDragAt = .now
        case .leftMouseUp:
            pointer = event.location
            released = true
            releasedAt = .now
            environment.hide()
        case .rightMouseDown, .otherMouseDown, .keyDown, .tapDisabledByTimeout, .tapDisabledByUserInput:
            cancel()
        default:
            break
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        hasDragEvent = false
        lastDragAt = nil
        released = false
        releasedAt = nil
        pointerHistory = WindowCenteredGuidePointerHistory()
        environment.hide()
    }

    private func track(
        _ candidate: WindowCenteredGuideCandidate,
        originalPointer: CGPoint,
        generation: UInt64
    ) async {
        defer {
            if self.generation == generation {
                environment.hide()
                task = nil
            }
        }
        do {
            let initialScreens = environment.screens()
            guard let initialScreen = WindowCenteredGuidePolicy.activeScreen(frame: candidate.frame, pointer: originalPointer, screens: initialScreens),
                  WindowCenteredGuideSnapshot(frame: candidate.frame).isEligible(in: environment.usableFrame(for: initialScreen))
            else { return }
            let window = try await environment.resolve(candidate)
            guard !Task.isCancelled, self.generation == generation else { return }
            var policy = WindowCenteredGuidePolicy(originalFrame: candidate.frame, originalPointer: originalPointer)
            var sampledInitialState = false
            var lastVerifiedAt: ContinuousClock.Instant?
            var verifiedFrame: CGRect?
            // Stage Manager discovery can enumerate other windows. Freeze its safe
            // area for display-only guides, then validate it freshly on release.
            var usableFrames: [String: CGRect] = [:]
            while !Task.isCancelled, self.generation == generation, environment.isTrusted {
                guard environment.screens() == initialScreens else { return }
                // A held click without dragging needs only its initial state read.
                if sampledInitialState, !released,
                   !hasDragEvent || (lastDragAt.map { ContinuousClock.now - $0 > WindowCenteredGuidePolicy.frameLagAllowance } == true
                                    && !policy.isAwaitingCorrelatedFrame) {
                    try await Task.sleep(for: cadence)
                    continue
                }
                let sampleReleased = released
                let sampleHasDrag = hasDragEvent
                let snapshot: WindowCenteredGuideSnapshot
                if !sampledInitialState || sampleReleased {
                    snapshot = try await environment.snapshot(window)
                } else if policy.hasMoved, let verifiedFrame, let lastVerifiedAt,
                          ContinuousClock.now - lastVerifiedAt < .milliseconds(80) {
                    // Once real window motion has been established, follow the
                    // pointer locally between bounded compositor verifications.
                    // Prediction only draws guides; release always reads fresh AX state.
                    snapshot = WindowCenteredGuideSnapshot(frame: CGRect(
                        origin: CGPoint(x: candidate.frame.minX + pointer.x - originalPointer.x,
                                        y: candidate.frame.minY + pointer.y - originalPointer.y),
                        size: verifiedFrame.size))
                } else {
                    snapshot = try await environment.trackingSnapshot(window)
                    verifiedFrame = snapshot.frame
                    lastVerifiedAt = .now
                }
                sampledInitialState = true
                guard !Task.isCancelled, self.generation == generation, environment.isTrusted,
                      environment.screens() == initialScreens
                else { return }
                // A release crossing an AX await requires a new read begun after release.
                // Pointer movement itself must not starve the sampling loop.
                if released != sampleReleased {
                    try await Task.sleep(for: cadence)
                    continue
                }
                let samplePointer = pointer
                guard let screen = WindowCenteredGuidePolicy.activeScreen(
                    frame: snapshot.frame, pointer: samplePointer, screens: initialScreens
                ) else { return }
                let usable: CGRect
                if sampleReleased {
                    usable = environment.usableFrame(for: screen)
                } else if let cached = usableFrames[screen.id] {
                    usable = cached
                } else {
                    usable = environment.usableFrame(for: screen)
                    usableFrames[screen.id] = usable
                }
                guard snapshot.isEligible(in: usable) else { return }
                if sampleHasDrag {
                    let result = policy.update(
                        snapshot: snapshot, pointer: samplePointer, usableFrame: usable, screenID: screen.id,
                        recentPointers: sampleReleased ? [] : pointerHistory.points()
                    )
                    guard !policy.isCancelled else { return }
                    if sampleReleased {
                        if result == nil, policy.isAwaitingCorrelatedFrame,
                           let releasedAt, ContinuousClock.now - releasedAt < WindowCenteredGuidePolicy.frameLagAllowance {
                            try await Task.sleep(for: cadence)
                            continue
                        }
                        if let result, result.isFullySnapped,
                           environment.usableFrame(for: screen) == usable {
                            try await environment.snap(window, expected: snapshot.frame, target: result.defaultFrame, usableFrame: usable)
                        }
                        return
                    }
                    if let result { environment.show(result, on: screen) }
                } else if sampleReleased {
                    return
                }
                try await Task.sleep(for: cadence)
            }
        } catch {
            // Lost permission, an unresponsive application, cancellation and vanished
            // windows all terminate quietly without retrying a move.
        }
    }
}

/// One queued main-actor drain, with only the newest consecutive drag sample retained.
struct WindowCenteredGuideEventQueue {
    private var events: [WindowModifierDragMonitorEvent] = []
    private var scheduled = false
    private var epoch: UInt64 = 0
    private var enabled = false

    mutating func configure(enabled: Bool) {
        self.enabled = enabled
        discardPending()
    }

    mutating func discardPending() {
        epoch &+= 1
        events.removeAll(keepingCapacity: true)
        scheduled = false
    }

    mutating func enqueue(_ event: WindowModifierDragMonitorEvent) -> UInt64? {
        guard enabled else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown,
             .keyDown, .tapDisabledByTimeout, .tapDisabledByUserInput:
            break
        default: return nil
        }
        if event.type == .leftMouseDragged, events.last?.type == .leftMouseDragged {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
        guard !scheduled else { return nil }
        scheduled = true
        return epoch
    }

    mutating func next(epoch: UInt64) -> WindowModifierDragMonitorEvent? {
        guard enabled, epoch == self.epoch else { return nil }
        guard !events.isEmpty else { scheduled = false; return nil }
        return events.removeFirst()
    }
}
