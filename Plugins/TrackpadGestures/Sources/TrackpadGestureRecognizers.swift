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

enum TipTapEpisodeRejectionReason: Equatable, Sendable {
    case fixedFingersNotSettled
    case fixedFingersBecameUnstable
    case tooBrief
    case tooLong
    case movedTooFar
    case wrongRegion
    case extraContact
}

struct TipTapGuideGeometry: Equatable, Sendable {
    let minimumFixedX: Double
    let maximumFixedX: Double
    let leftBoundaryX: Double
    let rightBoundaryX: Double
    let middleRange: ClosedRange<Double>?

    static func make(
        fixedContacts: [TrackpadContactSnapshot],
        thresholds: TrackpadGestureRecognitionThresholds = .default
    ) -> TipTapGuideGeometry? {
        let fixedX = fixedContacts.map(\.x)
        guard let minimumX = fixedX.min(), let maximumX = fixedX.max() else {
            return nil
        }
        let span = maximumX - minimumX
        let middleRange: ClosedRange<Double>?
        if fixedContacts.count >= 2, span >= thresholds.tipTapMiddleMinimumSpan {
            let inset = span * thresholds.tipTapMiddleInsetRatio
            middleRange = (minimumX + inset) ... (maximumX - inset)
        } else {
            middleRange = nil
        }
        return TipTapGuideGeometry(
            minimumFixedX: minimumX,
            maximumFixedX: maximumX,
            leftBoundaryX: minimumX - thresholds.tipTapSeparation,
            rightBoundaryX: maximumX + thresholds.tipTapSeparation,
            middleRange: middleRange
        )
    }

    func classify(x: Double) -> TipTapRegion? {
        if x <= leftBoundaryX {
            return .left
        }
        if x >= rightBoundaryX {
            return .right
        }
        if middleRange?.contains(x) == true {
            return .middle
        }
        return nil
    }
}

struct TipTapRecognizer: Sendable {
    private struct AddedContactEpisode: Sendable {
        let identifier: Int
        let initialContact: TrackpadContactSnapshot
        let startedAt: TimeInterval
    }

    private enum State: Sendable {
        case waitingForZero
        case ready
        case acquiring(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case settling(initial: [Int: TrackpadContactSnapshot], startedAt: TimeInterval)
        case fixed(
            initial: [Int: TrackpadContactSnapshot],
            startedAt: TimeInterval,
            addedContact: AddedContactEpisode?
        )
        case rejectedEpisode(
            initial: [Int: TrackpadContactSnapshot],
            startedAt: TimeInterval,
            contacts: [Int: TrackpadContactSnapshot],
            reason: TipTapEpisodeRejectionReason
        )
        case cancelled
    }

    private struct TestingRejectionContext: Sendable {
        let anchors: [TrackpadContactSnapshot]
        let candidates: [TrackpadContactSnapshot]
    }

    let fixedFingerCount: Int
    let region: TipTapRegion
    let thresholds: TrackpadGestureRecognitionThresholds

    private var state: State = .waitingForZero
    private var lastRecognitionAt: TimeInterval = -.infinity
    private(set) var lastRejectionReason: TipTapEpisodeRejectionReason?
    private(set) var rejectionSequence: UInt64 = 0
    private var surfacedTestingRejectionSequence: UInt64 = 0
    private var testingRejectionContext: TestingRejectionContext?

    /// Whether the current contact episode contains an added finger that can complete this
    /// recognizer's configured TipTap. The native click correlator reads this synchronously so a
    /// click event emitted at the contact-count peak is not mistaken for a physical finger click.
    var hasQualifiedAddedContact: Bool {
        guard case let .fixed(_, _, addedContact) = state, addedContact != nil else {
            return false
        }
        return true
    }

    var isAwaitingAddedContact: Bool {
        switch state {
        case .settling:
            return true
        case let .fixed(_, _, addedContact):
            return addedContact == nil
        default:
            return false
        }
    }

    var isRejectingAddedContactEpisode: Bool {
        if case .rejectedEpisode = state {
            return true
        }
        return false
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
                testingRejectionContext = nil
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

            let addedContacts = addedContacts(initial: initial, active: active)
            guard frame.timestamp - startedAt >= thresholds.tipTapFixedMinimumDuration else {
                if !addedContacts.isEmpty {
                    rejectEpisode(
                        initial: initial,
                        startedAt: startedAt,
                        addedContacts: addedContacts,
                        reason: .fixedFingersNotSettled
                    )
                }
                return false
            }

            if addedContacts.isEmpty {
                state = .fixed(initial: initial, startedAt: startedAt, addedContact: nil)
                return false
            }
            beginEpisode(
                initial: initial,
                startedAt: startedAt,
                addedContacts: addedContacts,
                timestamp: frame.timestamp
            )
            return false

        case let .fixed(initial, startedAt, addedContact):
            guard fixedFingersRemainStable(initial: initial, active: active) else {
                if let addedContact {
                    testingRejectionContext = TestingRejectionContext(
                        anchors: sorted(initial.values),
                        candidates: [addedContact.initialContact]
                    )
                    recordRejection(.fixedFingersBecameUnstable)
                }
                state = active.isEmpty ? .ready : .cancelled
                return false
            }

            guard let addedContact else {
                let addedContacts = addedContacts(initial: initial, active: active)
                if addedContacts.isEmpty {
                    return false
                }
                beginEpisode(
                    initial: initial,
                    startedAt: startedAt,
                    addedContacts: addedContacts,
                    timestamp: frame.timestamp
                )
                return false
            }

            let duration = frame.timestamp - addedContact.startedAt
            let currentAddedContacts = addedContacts(initial: initial, active: active)
            guard duration <= thresholds.tapMaximumDuration else {
                rejectOrRearm(
                    initial: initial,
                    startedAt: startedAt,
                    addedContacts: currentAddedContacts,
                    reason: .tooLong
                )
                return false
            }

            if let currentTap = active[addedContact.identifier] {
                guard currentAddedContacts.count == 1 else {
                    rejectEpisode(
                        initial: initial,
                        startedAt: startedAt,
                        addedContacts: currentAddedContacts,
                        reason: .extraContact
                    )
                    return false
                }
                guard currentTap.distance(to: addedContact.initialContact)
                    <= thresholds.tappingFingerMovement else {
                    rejectEpisode(
                        initial: initial,
                        startedAt: startedAt,
                        addedContacts: currentAddedContacts,
                        reason: .movedTooFar
                    )
                    return false
                }
                return false
            }

            guard currentAddedContacts.isEmpty else {
                rejectEpisode(
                    initial: initial,
                    startedAt: startedAt,
                    addedContacts: currentAddedContacts,
                    reason: .extraContact
                )
                return false
            }
            guard duration >= thresholds.tapMinimumDuration else {
                recordRejection(.tooBrief)
                state = .fixed(initial: initial, startedAt: startedAt, addedContact: nil)
                return false
            }

            lastRecognitionAt = frame.timestamp
            lastRejectionReason = nil
            // The release frame still contains the original fixed contacts, so it is already a
            // safe boundary for the next distinct added-finger tap. The contact lifecycle itself
            // prevents duplicate recognition; the generic cooldown remains for brand-new sessions.
            state = .fixed(initial: initial, startedAt: startedAt, addedContact: nil)
            return true

        case let .rejectedEpisode(initial, startedAt, _, reason):
            guard fixedFingersRemainStable(initial: initial, active: active) else {
                state = active.isEmpty ? .ready : .cancelled
                return false
            }
            let remainingAddedContacts = addedContacts(initial: initial, active: active)
            guard remainingAddedContacts.isEmpty else {
                state = .rejectedEpisode(
                    initial: initial,
                    startedAt: startedAt,
                    contacts: remainingAddedContacts,
                    reason: reason
                )
                return false
            }
            if frame.timestamp - startedAt >= thresholds.tipTapFixedMinimumDuration {
                state = .fixed(initial: initial, startedAt: startedAt, addedContact: nil)
            } else {
                state = .settling(initial: initial, startedAt: startedAt)
            }
            return false
        }
    }

    private mutating func beginEpisode(
        initial: [Int: TrackpadContactSnapshot],
        startedAt: TimeInterval,
        addedContacts: [Int: TrackpadContactSnapshot],
        timestamp: TimeInterval
    ) {
        guard addedContacts.count == 1, let added = addedContacts.values.first else {
            rejectEpisode(
                initial: initial,
                startedAt: startedAt,
                addedContacts: addedContacts,
                reason: .extraContact
            )
            return
        }
        guard classify(x: added.x, relativeTo: initial) == region else {
            rejectEpisode(
                initial: initial,
                startedAt: startedAt,
                addedContacts: addedContacts,
                reason: .wrongRegion
            )
            return
        }
        lastRejectionReason = nil
        state = .fixed(
            initial: initial,
            startedAt: startedAt,
            addedContact: AddedContactEpisode(
                identifier: added.identifier,
                initialContact: added,
                startedAt: timestamp
            )
        )
    }

    private mutating func rejectOrRearm(
        initial: [Int: TrackpadContactSnapshot],
        startedAt: TimeInterval,
        addedContacts: [Int: TrackpadContactSnapshot],
        reason: TipTapEpisodeRejectionReason
    ) {
        if addedContacts.isEmpty {
            recordRejection(reason)
            state = .fixed(initial: initial, startedAt: startedAt, addedContact: nil)
        } else {
            rejectEpisode(
                initial: initial,
                startedAt: startedAt,
                addedContacts: addedContacts,
                reason: reason
            )
        }
    }

    private mutating func rejectEpisode(
        initial: [Int: TrackpadContactSnapshot],
        startedAt: TimeInterval,
        addedContacts: [Int: TrackpadContactSnapshot],
        reason: TipTapEpisodeRejectionReason
    ) {
        recordRejection(reason)
        state = .rejectedEpisode(
            initial: initial,
            startedAt: startedAt,
            contacts: addedContacts,
            reason: reason
        )
    }

    private mutating func recordRejection(_ reason: TipTapEpisodeRejectionReason) {
        lastRejectionReason = reason
        rejectionSequence &+= 1
    }

    private func addedContacts(
        initial: [Int: TrackpadContactSnapshot],
        active: [Int: TrackpadContactSnapshot]
    ) -> [Int: TrackpadContactSnapshot] {
        Dictionary(uniqueKeysWithValues: active.filter { initial[$0.key] == nil })
    }

    mutating func testingSnapshot(
        for gesture: TrackpadGesture
    ) -> TrackpadGestureRecognitionSnapshot {
        let pendingRejectionReason = rejectionSequence > surfacedTestingRejectionSequence
            ? lastRejectionReason
            : nil
        let pendingRejectionContext = pendingRejectionReason == nil
            ? nil
            : testingRejectionContext
        if pendingRejectionReason != nil {
            surfacedTestingRejectionSequence = rejectionSequence
            testingRejectionContext = nil
        }
        var phase: TrackpadGestureRecognitionPhase
        var anchors: [TrackpadContactSnapshot]
        var candidates: [TrackpadContactSnapshot]
        let startedAt: TimeInterval?
        let deadline: TimeInterval?
        switch state {
        case .waitingForZero, .cancelled:
            phase = .waitingForReset
            anchors = []
            candidates = []
            startedAt = nil
            deadline = nil
        case .ready:
            phase = .ready
            anchors = []
            candidates = []
            startedAt = nil
            deadline = nil
        case let .acquiring(initial, start):
            phase = .acquiring
            anchors = sorted(initial.values)
            candidates = []
            startedAt = start
            deadline = start + thresholds.acquisitionMaximumDuration
        case let .settling(initial, start):
            phase = .settling
            anchors = sorted(initial.values)
            candidates = []
            startedAt = start
            deadline = start + thresholds.tipTapFixedMinimumDuration
        case let .fixed(initial, _, addedContact):
            phase = addedContact == nil ? .armed : .candidate
            anchors = sorted(initial.values)
            candidates = addedContact.map { [$0.initialContact] } ?? []
            startedAt = addedContact?.startedAt
            deadline = addedContact.map { $0.startedAt + thresholds.tapMaximumDuration }
        case let .rejectedEpisode(initial, _, contacts, reason):
            phase = .rejected(reason)
            anchors = sorted(initial.values)
            candidates = sorted(contacts.values)
            startedAt = nil
            deadline = nil
        }
        if let pendingRejectionReason {
            phase = .rejected(pendingRejectionReason)
            if let pendingRejectionContext {
                anchors = pendingRejectionContext.anchors
                candidates = pendingRejectionContext.candidates
            }
        }
        return TrackpadGestureRecognitionSnapshot(
            gesture: gesture,
            phase: phase,
            anchorContacts: anchors,
            candidateContacts: candidates,
            requiredContactCount: fixedFingerCount + 1,
            movementTolerance: thresholds.tappingFingerMovement,
            startedAt: startedAt,
            deadline: deadline,
            thresholds: thresholds,
            rejectionSequence: rejectionSequence
        )
    }

    private func sorted<S: Sequence>(_ contacts: S) -> [TrackpadContactSnapshot]
        where S.Element == TrackpadContactSnapshot {
        contacts.sorted { $0.identifier < $1.identifier }
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
        TipTapGuideGeometry.make(
            fixedContacts: Array(fixedContacts.values),
            thresholds: thresholds
        )?.classify(x: x)
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

    func testingSnapshot(for gesture: TrackpadGesture) -> TrackpadGestureRecognitionSnapshot {
        let phase: TrackpadGestureRecognitionPhase
        let anchors: [TrackpadContactSnapshot]
        let startedAt: TimeInterval?
        let deadline: TimeInterval?
        switch state {
        case .waitingForZero, .cancelled:
            phase = .waitingForReset
            anchors = []
            startedAt = nil
            deadline = nil
        case .ready:
            phase = .ready
            anchors = []
            startedAt = nil
            deadline = nil
        case let .acquiring(initial, start):
            phase = .acquiring
            anchors = initial.values.sorted { $0.identifier < $1.identifier }
            startedAt = start
            deadline = start + thresholds.acquisitionMaximumDuration
        case let .tracking(initial, start, _):
            phase = .tracking
            anchors = initial.values.sorted { $0.identifier < $1.identifier }
            startedAt = start
            deadline = start + thresholds.tapMaximumDuration
        }
        return TrackpadGestureRecognitionSnapshot(
            gesture: gesture,
            phase: phase,
            anchorContacts: anchors,
            candidateContacts: [],
            requiredContactCount: fingerCount,
            movementTolerance: thresholds.tappingFingerMovement,
            startedAt: startedAt,
            deadline: deadline,
            thresholds: thresholds,
            rejectionSequence: 0
        )
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

    func testingSnapshot(for gesture: TrackpadGesture) -> TrackpadGestureRecognitionSnapshot {
        let tapSnapshot = tapRecognizer.testingSnapshot(for: gesture)
        guard let firstTapRecognizedAt, !hasActiveEpisode else {
            return tapSnapshot
        }
        return TrackpadGestureRecognitionSnapshot(
            gesture: gesture,
            phase: .waitingForSecondTap,
            anchorContacts: [],
            candidateContacts: [],
            requiredContactCount: fingerCount,
            movementTolerance: thresholds.tappingFingerMovement,
            startedAt: firstTapRecognizedAt,
            deadline: firstTapRecognizedAt + thresholds.doubleTapMaximumInterval,
            thresholds: thresholds,
            rejectionSequence: 0
        )
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

    func testingSnapshot(for gesture: TrackpadGesture) -> TrackpadGestureRecognitionSnapshot {
        let phase: TrackpadGestureRecognitionPhase
        let anchors: [TrackpadContactSnapshot]
        let startedAt: TimeInterval?
        let deadline: TimeInterval?
        switch state {
        case .waitingForZero, .cancelled:
            phase = .waitingForReset
            anchors = []
            startedAt = nil
            deadline = nil
        case .ready:
            phase = .ready
            anchors = []
            startedAt = nil
            deadline = nil
        case let .acquiring(initial, start):
            phase = .acquiring
            anchors = initial.values.sorted { $0.identifier < $1.identifier }
            startedAt = start
            deadline = start + thresholds.acquisitionMaximumDuration
        case let .tracking(initial, start):
            phase = .holding
            anchors = initial.values.sorted { $0.identifier < $1.identifier }
            startedAt = start
            deadline = start + thresholds.longTouchMinimumDuration
        case .recognized:
            phase = .recognized
            anchors = []
            startedAt = nil
            deadline = nil
        }
        return TrackpadGestureRecognitionSnapshot(
            gesture: gesture,
            phase: phase,
            anchorContacts: anchors,
            candidateContacts: [],
            requiredContactCount: fingerCount,
            movementTolerance: thresholds.fixedFingerMovement,
            startedAt: startedAt,
            deadline: deadline,
            thresholds: thresholds,
            rejectionSequence: 0
        )
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

    mutating func testingSnapshot(
        for gesture: TrackpadGesture
    ) -> TrackpadGestureRecognitionSnapshot {
        switch self {
        case .tipTap(var recognizer):
            let snapshot = recognizer.testingSnapshot(for: gesture)
            self = .tipTap(recognizer)
            return snapshot
        case let .tap(recognizer):
            return recognizer.testingSnapshot(for: gesture)
        case let .doubleTap(recognizer):
            return recognizer.testingSnapshot(for: gesture)
        case let .longTouch(recognizer):
            return recognizer.testingSnapshot(for: gesture)
        case .nativeClick:
            return TrackpadGestureRecognitionSnapshot(
                gesture: gesture,
                phase: .physicalClick,
                anchorContacts: [],
                candidateContacts: [],
                requiredContactCount: gesture.physicalClickFingerCount ?? 0,
                movementTolerance: 0,
                startedAt: nil,
                deadline: nil,
                thresholds: .default,
                rejectionSequence: 0
            )
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
    private var devicesReadyAfterLifecycleSuppression = Set<UInt64>()
    private var requiresInitialContactReset = false
    private var requiresLifecycleContactReset = false
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
        devicesWaitingForContactReset.formUnion(devicesWithActiveContacts)
        devicesReadyAfterSuppression.subtract(devicesWithActiveContacts)
        requiresInitialContactReset = !devicesWaitingForContactReset.isEmpty
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

    mutating func beginSuppression(deviceID: UInt64) {
        recognizersByDevice.removeValue(forKey: deviceID)
        if devicesWithActiveContacts.contains(deviceID) {
            devicesWaitingForContactReset.insert(deviceID)
            devicesReadyAfterSuppression.remove(deviceID)
        } else {
            devicesWaitingForContactReset.remove(deviceID)
            devicesReadyAfterSuppression.insert(deviceID)
        }
    }

    mutating func beginLifecycleSuppression() {
        recognizersByDevice.removeAll()
        devicesWithActiveContacts.removeAll()
        devicesWaitingForContactReset.removeAll()
        devicesReadyAfterSuppression.removeAll()
        devicesReadyAfterLifecycleSuppression.removeAll()
        requiresInitialContactReset = false
        requiresLifecycleContactReset = true
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
                if requiresLifecycleContactReset {
                    devicesReadyAfterLifecycleSuppression.insert(frame.deviceID)
                }
            } else {
                devicesWaitingForContactReset.insert(frame.deviceID)
                devicesReadyAfterSuppression.remove(frame.deviceID)
                if requiresLifecycleContactReset {
                    devicesReadyAfterLifecycleSuppression.remove(frame.deviceID)
                }
            }
            requiresInitialContactReset = !devicesWaitingForContactReset.isEmpty
            return TrackpadGestureProcessingResult(recognized: [])
        }

        if requiresLifecycleContactReset,
           !devicesReadyAfterLifecycleSuppression.contains(frame.deviceID) {
            if frame.contacts.isEmpty {
                devicesWaitingForContactReset.remove(frame.deviceID)
                devicesReadyAfterSuppression.insert(frame.deviceID)
                devicesReadyAfterLifecycleSuppression.insert(frame.deviceID)
            } else {
                devicesWaitingForContactReset.insert(frame.deviceID)
            }
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
        devicesReadyAfterLifecycleSuppression.remove(deviceID)
        if wasWaiting && devicesWaitingForContactReset.isEmpty {
            requiresInitialContactReset = false
        }
    }

    mutating func testingSnapshot(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadGestureRecognitionSnapshot? {
        if var recognizer = recognizersByDevice[deviceID]?[gesture] {
            let snapshot = recognizer.testingSnapshot(for: gesture)
            recognizersByDevice[deviceID]?[gesture] = recognizer
            return snapshot
        }
        var recognizer = makeRecognizer(for: gesture)
        return recognizer.testingSnapshot(for: gesture)
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
