import Foundation
import MacToolsPluginKit

struct TrackpadContactSnapshot: Equatable, Sendable {
    let identifier: Int
    let x: Double
    let y: Double

    func distance(to other: TrackpadContactSnapshot) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

struct TrackpadContactFrame: Equatable, Sendable {
    let deviceID: UInt64
    let timestamp: TimeInterval
    let contacts: [TrackpadContactSnapshot]

    var contactsByID: [Int: TrackpadContactSnapshot] {
        Dictionary(uniqueKeysWithValues: contacts.map { ($0.identifier, $0) })
    }
}

struct TrackpadGestureRecognitionThresholds: Equatable, Sendable {
    var fixedFingerMovement: Double = 0.035
    var tappingFingerMovement: Double = 0.045
    var tipTapSeparation: Double = 0.04
    var tipTapMiddleMinimumSpan: Double = 0.04
    var tipTapMiddleInsetRatio: Double = 0.20
    var tipTapFixedMinimumDuration: TimeInterval = 0.08
    var tapMinimumDuration: TimeInterval = 0.015
    var tapMaximumDuration: TimeInterval = 0.22
    var acquisitionMaximumDuration: TimeInterval = 0.10
    var longTouchMinimumDuration: TimeInterval = 0.55
    var doubleTapMaximumInterval: TimeInterval = 0.32
    var cooldown: TimeInterval = 0.28

    static let `default` = TrackpadGestureRecognitionThresholds()
}

struct TipTapRecognizer: Sendable {
    private struct AddedContactEpisode: Sendable {
        let identifier: Int
        let initialContact: TrackpadContactSnapshot
        let startedAt: TimeInterval
    }

    private enum AddedContact: Sendable {
        case candidate(AddedContactEpisode)
        case ignored(AddedContactEpisode)
    }

    private enum State: Sendable {
        case waitingForZero
        case ready
        case acquiring(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case settling(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case fixed(initial: [Int: TrackpadContactSnapshot], addedContact: AddedContact?)
        case cancelled
    }

    let fixedFingerCount: Int
    let region: TipTapRegion
    let thresholds: TrackpadGestureRecognitionThresholds

    private var state: State = .waitingForZero
    private var lastRecognitionAt: TimeInterval = -.infinity

    /// Whether the current contact episode contains an added finger that can complete this
    /// recognizer's configured TipTap. The native click correlator reads this synchronously so a
    /// click event emitted at the contact-count peak is not mistaken for a physical finger click.
    var hasQualifiedAddedContact: Bool {
        guard case let .fixed(_, addedContact) = state,
              case .candidate? = addedContact
        else {
            return false
        }
        return true
    }

    var isAwaitingAddedContact: Bool {
        guard case let .fixed(_, addedContact) = state else {
            return false
        }
        return addedContact == nil
    }

    init(
        fixedFingerCount: Int,
        region: TipTapRegion,
        thresholds: TrackpadGestureRecognitionThresholds = .default
    ) {
        self.fixedFingerCount = fixedFingerCount
        self.region = region
        self.thresholds = thresholds
    }

    mutating func process(_ frame: TrackpadContactFrame) -> Bool {
        let active = frame.contactsByID

        switch state {
        case .waitingForZero, .cancelled:
            if active.isEmpty {
                state = .ready
            }
            return false

        case .ready:
            guard frame.timestamp - lastRecognitionAt >= thresholds.cooldown else {
                if !active.isEmpty {
                    state = .waitingForZero
                }
                return false
            }
            guard !active.isEmpty else {
                return false
            }
            guard active.count <= fixedFingerCount else {
                state = .cancelled
                return false
            }
            if active.count == fixedFingerCount {
                state = .settling(initial: active, startedAt: frame.timestamp)
            } else {
                state = .acquiring(initial: active, startedAt: frame.timestamp)
            }
            return false

        case let .acquiring(initial, startedAt):
            guard !active.isEmpty,
                  active.count <= fixedFingerCount,
                  frame.timestamp - startedAt <= thresholds.acquisitionMaximumDuration,
                  fixedFingersRemainStable(initial: initial, active: active)
            else {
                state = active.isEmpty ? .ready : .cancelled
                return false
            }

            var accumulated = initial
            active.forEach { identifier, contact in
                if accumulated[identifier] == nil {
                    accumulated[identifier] = contact
                }
            }
            if accumulated.count == fixedFingerCount {
                state = .settling(initial: accumulated, startedAt: frame.timestamp)
            } else {
                state = .acquiring(initial: accumulated, startedAt: startedAt)
            }
            return false

        case let .settling(initial, startedAt):
            guard fixedFingersRemainStable(initial: initial, active: active) else {
                state = active.isEmpty ? .ready : .cancelled
                return false
            }

            guard frame.timestamp - startedAt >= thresholds.tipTapFixedMinimumDuration else {
                if active.count != fixedFingerCount {
                    state = .cancelled
                }
                return false
            }

            if active.count == fixedFingerCount {
                state = .fixed(initial: initial, addedContact: nil)
                return false
            }

            guard active.count == fixedFingerCount + 1,
                  let added = active.values.first(where: { initial[$0.identifier] == nil })
            else {
                state = .cancelled
                return false
            }
            guard classify(x: added.x, relativeTo: initial) == region else {
                // Another configured TipTap region may own this contact episode. Keep the
                // established fixed contacts armed so Left, Middle, and Right can alternate, but
                // never promote this same still-down contact into a target candidate later.
                state = .fixed(
                    initial: initial,
                    addedContact: .ignored(AddedContactEpisode(
                        identifier: added.identifier,
                        initialContact: added,
                        startedAt: frame.timestamp
                    ))
                )
                return false
            }
            state = .fixed(
                initial: initial,
                addedContact: .candidate(AddedContactEpisode(
                    identifier: added.identifier,
                    initialContact: added,
                    startedAt: frame.timestamp
                ))
            )
            return false

        case let .fixed(initial, addedContact):
            guard fixedFingersRemainStable(initial: initial, active: active) else {
                state = active.isEmpty ? .ready : .cancelled
                return false
            }

            guard let addedContact else {
                if active.count == fixedFingerCount {
                    return false
                }
                guard active.count == fixedFingerCount + 1,
                      let added = active.values.first(where: { initial[$0.identifier] == nil })
                else {
                    state = .cancelled
                    return false
                }
                guard classify(x: added.x, relativeTo: initial) == region else {
                    state = .fixed(
                        initial: initial,
                        addedContact: .ignored(AddedContactEpisode(
                            identifier: added.identifier,
                            initialContact: added,
                            startedAt: frame.timestamp
                        ))
                    )
                    return false
                }
                state = .fixed(
                    initial: initial,
                    addedContact: .candidate(AddedContactEpisode(
                        identifier: added.identifier,
                        initialContact: added,
                        startedAt: frame.timestamp
                    ))
                )
                return false
            }

            guard case let .candidate(tap) = addedContact else {
                guard case let .ignored(ignored) = addedContact else {
                    return false
                }
                let duration = frame.timestamp - ignored.startedAt
                guard duration <= thresholds.tapMaximumDuration else {
                    state = .cancelled
                    return false
                }
                if let current = active[ignored.identifier] {
                    let movement = current.distance(to: ignored.initialContact)
                    guard active.count == fixedFingerCount + 1,
                          movement <= thresholds.tappingFingerMovement
                    else {
                        state = .cancelled
                        return false
                    }
                    return false
                }
                guard active.count == fixedFingerCount,
                      duration >= thresholds.tapMinimumDuration
                else {
                    state = .cancelled
                    return false
                }
                state = .fixed(initial: initial, addedContact: nil)
                return false
            }

            let duration = frame.timestamp - tap.startedAt
            guard duration <= thresholds.tapMaximumDuration else {
                state = .cancelled
                return false
            }

            if let currentTap = active[tap.identifier] {
                guard active.count == fixedFingerCount + 1,
                      currentTap.distance(to: tap.initialContact) <= thresholds.tappingFingerMovement
                else {
                    state = .cancelled
                    return false
                }
                return false
            }

            guard active.count == fixedFingerCount,
                  duration >= thresholds.tapMinimumDuration
            else {
                state = .cancelled
                return false
            }

            lastRecognitionAt = frame.timestamp
            // The release frame still contains the original fixed contacts, so it is already a
            // safe boundary for the next distinct added-finger tap. The contact lifecycle itself
            // prevents duplicate recognition; the generic cooldown remains for brand-new sessions.
            state = .fixed(initial: initial, addedContact: nil)
            return true
        }
    }

    private func fixedFingersRemainStable(
        initial: [Int: TrackpadContactSnapshot],
        active: [Int: TrackpadContactSnapshot]
    ) -> Bool {
        initial.allSatisfy { identifier, initialContact in
            guard let current = active[identifier] else {
                return false
            }
            return current.distance(to: initialContact) <= thresholds.fixedFingerMovement
        }
    }

    private func classify(
        x: Double,
        relativeTo fixedContacts: [Int: TrackpadContactSnapshot]
    ) -> TipTapRegion? {
        let fixedX = fixedContacts.values.map(\.x)
        guard let minimumX = fixedX.min(), let maximumX = fixedX.max() else {
            return nil
        }
        if x <= minimumX - thresholds.tipTapSeparation {
            return .left
        }
        if x >= maximumX + thresholds.tipTapSeparation {
            return .right
        }
        let middleInset = (maximumX - minimumX) * thresholds.tipTapMiddleInsetRatio
        if fixedContacts.count >= 2,
           maximumX - minimumX >= thresholds.tipTapMiddleMinimumSpan,
           x >= minimumX + middleInset,
           x <= maximumX - middleInset {
            return .middle
        }
        return nil
    }
}

struct MultiFingerTapRecognizer: Sendable {
    private enum State: Sendable {
        case waitingForZero
        case ready
        case acquiring(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case tracking(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval, isReleasing: Bool)
        case cancelled
    }

    let fingerCount: Int
    let thresholds: TrackpadGestureRecognitionThresholds

    private var state: State = .waitingForZero
    private var lastRecognitionAt: TimeInterval = -.infinity

    init(
        fingerCount: Int,
        thresholds: TrackpadGestureRecognitionThresholds = .default
    ) {
        self.fingerCount = fingerCount
        self.thresholds = thresholds
    }

    mutating func process(_ frame: TrackpadContactFrame) -> Bool {
        let active = frame.contactsByID

        switch state {
        case .waitingForZero, .cancelled:
            if active.isEmpty {
                state = .ready
            }
            return false
        case .ready:
            guard frame.timestamp - lastRecognitionAt >= thresholds.cooldown else {
                if !active.isEmpty {
                    state = .waitingForZero
                }
                return false
            }
            guard !active.isEmpty else {
                return false
            }
            guard active.count <= fingerCount else {
                state = .cancelled
                return false
            }
            if active.count == fingerCount {
                state = .tracking(initial: active, startedAt: frame.timestamp, isReleasing: false)
            } else {
                state = .acquiring(initial: active, startedAt: frame.timestamp)
            }
            return false
        case let .acquiring(initial, startedAt):
            guard !active.isEmpty,
                  active.count <= fingerCount,
                  frame.timestamp - startedAt <= thresholds.acquisitionMaximumDuration,
                  initial.allSatisfy({ identifier, first in
                      guard let current = active[identifier] else { return false }
                      return current.distance(to: first) <= thresholds.tappingFingerMovement
                  })
            else {
                state = .cancelled
                return false
            }

            var accumulated = initial
            active.forEach { identifier, contact in
                if accumulated[identifier] == nil {
                    accumulated[identifier] = contact
                }
            }
            if accumulated.count == fingerCount {
                state = .tracking(initial: accumulated, startedAt: startedAt, isReleasing: false)
            } else {
                state = .acquiring(initial: accumulated, startedAt: startedAt)
            }
            return false
        case let .tracking(initial, startedAt, wasReleasing):
            let duration = frame.timestamp - startedAt
            guard duration <= thresholds.tapMaximumDuration,
                  active.keys.allSatisfy({ initial[$0] != nil }),
                  active.allSatisfy({ identifier, contact in
                      guard let first = initial[identifier] else { return false }
                      return contact.distance(to: first) <= thresholds.tappingFingerMovement
                  })
            else {
                state = .cancelled
                return false
            }

            if active.isEmpty {
                guard duration >= thresholds.tapMinimumDuration else {
                    state = .cancelled
                    return false
                }
                lastRecognitionAt = frame.timestamp
                state = .ready
                return true
            }

            let isReleasing = wasReleasing || active.count < fingerCount
            if isReleasing && active.count == fingerCount {
                state = .cancelled
                return false
            }
            state = .tracking(initial: initial, startedAt: startedAt, isReleasing: isReleasing)
            return false
        }
    }
}

struct MultiFingerDoubleTapRecognizer: Sendable {
    let fingerCount: Int
    let thresholds: TrackpadGestureRecognitionThresholds

    private var tapRecognizer: MultiFingerTapRecognizer
    private var firstTapRecognizedAt: TimeInterval?
    private var hasActiveEpisode = false

    init(
        fingerCount: Int,
        thresholds: TrackpadGestureRecognitionThresholds = .default
    ) {
        self.fingerCount = fingerCount
        self.thresholds = thresholds
        var episodeThresholds = thresholds
        episodeThresholds.cooldown = 0
        self.tapRecognizer = MultiFingerTapRecognizer(
            fingerCount: fingerCount,
            thresholds: episodeThresholds
        )
    }

    mutating func process(_ frame: TrackpadContactFrame) -> Bool {
        if let firstTapRecognizedAt,
           frame.timestamp - firstTapRecognizedAt > thresholds.doubleTapMaximumInterval {
            self.firstTapRecognizedAt = nil
        }

        let wasActiveEpisode = hasActiveEpisode
        if !frame.contacts.isEmpty {
            hasActiveEpisode = true
        }

        guard tapRecognizer.process(frame) else {
            if frame.contacts.isEmpty && wasActiveEpisode {
                // A contact episode occurred but failed the ordinary tap constraints. It must
                // break the pair instead of allowing the recognizer to skip over it.
                hasActiveEpisode = false
                firstTapRecognizedAt = nil
            }
            return false
        }

        hasActiveEpisode = false

        if let firstTapRecognizedAt,
           frame.timestamp - firstTapRecognizedAt <= thresholds.doubleTapMaximumInterval {
            self.firstTapRecognizedAt = nil
            return true
        }

        firstTapRecognizedAt = frame.timestamp
        return false
    }
}

struct LongTouchRecognizer: Sendable {
    private enum State: Sendable {
        case waitingForZero
        case ready
        case acquiring(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case tracking(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case recognized
        case cancelled
    }

    let fingerCount: Int
    let thresholds: TrackpadGestureRecognitionThresholds

    private var state: State = .waitingForZero

    init(
        fingerCount: Int,
        thresholds: TrackpadGestureRecognitionThresholds = .default
    ) {
        self.fingerCount = fingerCount
        self.thresholds = thresholds
    }

    mutating func process(_ frame: TrackpadContactFrame) -> Bool {
        let active = frame.contactsByID

        switch state {
        case .waitingForZero, .cancelled, .recognized:
            if active.isEmpty {
                state = .ready
            }
            return false
        case .ready:
            guard !active.isEmpty else {
                return false
            }
            guard active.count <= fingerCount else {
                state = .cancelled
                return false
            }
            if active.count == fingerCount {
                state = .tracking(initial: active, startedAt: frame.timestamp)
            } else {
                state = .acquiring(initial: active, startedAt: frame.timestamp)
            }
            return false
        case let .acquiring(initial, startedAt):
            guard !active.isEmpty,
                  active.count <= fingerCount,
                  frame.timestamp - startedAt <= thresholds.acquisitionMaximumDuration,
                  initial.allSatisfy({ identifier, first in
                      guard let current = active[identifier] else { return false }
                      return current.distance(to: first) <= thresholds.fixedFingerMovement
                  })
            else {
                state = .cancelled
                return false
            }

            var accumulated = initial
            active.forEach { identifier, contact in
                if accumulated[identifier] == nil {
                    accumulated[identifier] = contact
                }
            }
            if accumulated.count == fingerCount {
                state = .tracking(initial: accumulated, startedAt: frame.timestamp)
            } else {
                state = .acquiring(initial: accumulated, startedAt: startedAt)
            }
            return false
        case let .tracking(initial, startedAt):
            guard active.count == fingerCount,
                  Set(active.keys) == Set(initial.keys),
                  active.allSatisfy({ identifier, contact in
                      guard let first = initial[identifier] else { return false }
                      return contact.distance(to: first) <= thresholds.fixedFingerMovement
                  })
            else {
                state = .cancelled
                return false
            }

            guard frame.timestamp - startedAt >= thresholds.longTouchMinimumDuration else {
                return false
            }
            state = .recognized
            return true
        }
    }
}

private enum TrackpadGestureRecognizer: Sendable {
    case tipTap(TipTapRecognizer)
    case tap(MultiFingerTapRecognizer)
    case doubleTap(MultiFingerDoubleTapRecognizer)
    case longTouch(LongTouchRecognizer)
    case nativeClick

    mutating func process(_ frame: TrackpadContactFrame) -> Bool {
        switch self {
        case .tipTap(var recognizer):
            let recognized = recognizer.process(frame)
            self = .tipTap(recognizer)
            return recognized
        case .tap(var recognizer):
            let recognized = recognizer.process(frame)
            self = .tap(recognizer)
            return recognized
        case .doubleTap(var recognizer):
            let recognized = recognizer.process(frame)
            self = .doubleTap(recognizer)
            return recognized
        case .longTouch(var recognizer):
            let recognized = recognizer.process(frame)
            self = .longTouch(recognizer)
            return recognized
        case .nativeClick:
            // Physical clicks are correlated with native mouse events by the session's
            // click coordinator. Contact frames only establish the originating trackpad.
            return false
        }
    }
}

struct TrackpadGestureProcessingResult: Equatable, Sendable {
    let recognized: [TrackpadGesture]
}

struct TrackpadGestureEngine: Sendable {
    private var configuredGestures = Set<TrackpadGesture>()
    private var recognizersByDevice: [UInt64: [TrackpadGesture: TrackpadGestureRecognizer]] = [:]
    private var devicesWithActiveContacts = Set<UInt64>()
    private var devicesWaitingForContactReset = Set<UInt64>()
    private var devicesReadyAfterSuppression = Set<UInt64>()
    private var requiresInitialContactReset = false
    private let thresholds: TrackpadGestureRecognitionThresholds

    init(
        gestures: Set<TrackpadGesture> = [],
        thresholds: TrackpadGestureRecognitionThresholds = .default
    ) {
        self.configuredGestures = gestures
        self.thresholds = thresholds
    }

    mutating func updateGestures(_ gestures: Set<TrackpadGesture>) {
        guard configuredGestures != gestures else {
            return
        }
        configuredGestures = gestures
        recognizersByDevice.removeAll()
        devicesWithActiveContacts.removeAll()
        devicesWaitingForContactReset.removeAll()
        devicesReadyAfterSuppression.removeAll()
        requiresInitialContactReset = false
    }

    mutating func beginSuppression(activeDeviceIDs: Set<UInt64>? = nil) {
        if let activeDeviceIDs {
            devicesWithActiveContacts = activeDeviceIDs
            devicesWaitingForContactReset = activeDeviceIDs
        }
        let knownDevices = Set(recognizersByDevice.keys)
        if activeDeviceIDs == nil {
            devicesWaitingForContactReset.formUnion(devicesWithActiveContacts)
        }
        devicesReadyAfterSuppression.formUnion(knownDevices.subtracting(devicesWithActiveContacts))
        devicesReadyAfterSuppression.subtract(devicesWithActiveContacts)
        recognizersByDevice.removeAll()
        requiresInitialContactReset = !devicesWaitingForContactReset.isEmpty
    }

    mutating func process(
        _ frame: TrackpadContactFrame,
        suppressRecognition: Bool = false
    ) -> TrackpadGestureProcessingResult {
        if frame.contacts.isEmpty {
            devicesWithActiveContacts.remove(frame.deviceID)
        } else {
            devicesWithActiveContacts.insert(frame.deviceID)
        }
        guard !configuredGestures.isEmpty else {
            return TrackpadGestureProcessingResult(recognized: [])
        }

        if suppressRecognition {
            beginSuppression()
            if frame.contacts.isEmpty {
                devicesWaitingForContactReset.remove(frame.deviceID)
                devicesReadyAfterSuppression.insert(frame.deviceID)
            } else {
                devicesWaitingForContactReset.insert(frame.deviceID)
                devicesReadyAfterSuppression.remove(frame.deviceID)
            }
            requiresInitialContactReset = !devicesWaitingForContactReset.isEmpty
            return TrackpadGestureProcessingResult(recognized: [])
        }

        if requiresInitialContactReset {
            if frame.contacts.isEmpty {
                devicesWaitingForContactReset.remove(frame.deviceID)
                devicesReadyAfterSuppression.insert(frame.deviceID)
                guard devicesWaitingForContactReset.isEmpty else {
                    return TrackpadGestureProcessingResult(recognized: [])
                }
                requiresInitialContactReset = false
            } else {
                devicesWaitingForContactReset.insert(frame.deviceID)
                devicesReadyAfterSuppression.remove(frame.deviceID)
                return TrackpadGestureProcessingResult(recognized: [])
            }
        }

        if devicesWaitingForContactReset.contains(frame.deviceID) {
            guard frame.contacts.isEmpty else {
                return TrackpadGestureProcessingResult(recognized: [])
            }
            devicesWaitingForContactReset.remove(frame.deviceID)
        }

        var deviceRecognizers = recognizersByDevice[frame.deviceID] ?? Dictionary(
            uniqueKeysWithValues: configuredGestures.map { ($0, makeRecognizer(for: $0)) }
        )
        if devicesReadyAfterSuppression.remove(frame.deviceID) != nil {
            let emptyFrame = TrackpadContactFrame(
                deviceID: frame.deviceID,
                timestamp: frame.timestamp,
                contacts: []
            )
            for gesture in configuredGestures {
                guard var recognizer = deviceRecognizers[gesture] else { continue }
                _ = recognizer.process(emptyFrame)
                deviceRecognizers[gesture] = recognizer
            }
        }
        var recognized: [TrackpadGesture] = []

        for gesture in configuredGestures.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var recognizer = deviceRecognizers[gesture] else {
                continue
            }
            if recognizer.process(frame) {
                recognized.append(gesture)
            }
            deviceRecognizers[gesture] = recognizer
        }

        let consumedFingerCounts = Set(recognized.compactMap { gesture in
            gesture.tipTapConfiguration.map { $0.fixedFingerCount + 1 }
        })
        if !consumedFingerCounts.isEmpty {
            recognized.removeAll { gesture in
                gesture.fingerTapCount.map(consumedFingerCounts.contains) ?? false
            }
            for gesture in configuredGestures where gesture.fingerTapCount.map(consumedFingerCounts.contains) == true {
                // TipTap is the more specific interpretation. Reset the overlapping tap recognizer
                // until the remaining fixed contacts reach zero, so one sequence cannot double-fire.
                deviceRecognizers[gesture] = makeRecognizer(for: gesture)
            }
        }


        let consumedDoubleTapFingerCounts = Set(recognized.compactMap(\.doubleFingerTapCount))
        if !consumedDoubleTapFingerCounts.isEmpty {
            recognized.removeAll { gesture in
                gesture.fingerTapCount.map(consumedDoubleTapFingerCounts.contains) ?? false
            }
        }

        recognizersByDevice[frame.deviceID] = deviceRecognizers
        return TrackpadGestureProcessingResult(recognized: recognized)
    }

    mutating func removeDevice(_ deviceID: UInt64) {
        recognizersByDevice.removeValue(forKey: deviceID)
        devicesWithActiveContacts.remove(deviceID)
        let wasWaiting = devicesWaitingForContactReset.remove(deviceID) != nil
        devicesReadyAfterSuppression.remove(deviceID)
        if wasWaiting && devicesWaitingForContactReset.isEmpty {
            requiresInitialContactReset = false
        }
    }

    private func makeRecognizer(for gesture: TrackpadGesture) -> TrackpadGestureRecognizer {
        if gesture.physicalClickFingerCount != nil {
            return .nativeClick
        }
        if let tipTap = gesture.tipTapConfiguration {
            return .tipTap(TipTapRecognizer(
                fixedFingerCount: tipTap.fixedFingerCount,
                region: tipTap.region,
                thresholds: thresholds
            ))
        }
        if let count = gesture.fingerTapCount {
            return .tap(MultiFingerTapRecognizer(fingerCount: count, thresholds: thresholds))
        }
        if let count = gesture.doubleFingerTapCount {
            return .doubleTap(MultiFingerDoubleTapRecognizer(
                fingerCount: count,
                thresholds: thresholds
            ))
        }
        return .longTouch(LongTouchRecognizer(
            fingerCount: gesture.longTouchFingerCount ?? 3,
            thresholds: thresholds
        ))
    }
}
