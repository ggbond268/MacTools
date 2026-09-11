import Combine
import CoreGraphics
import Foundation
import MacToolsPluginKit

enum TrackpadGestureTestingMode: Equatable, Sendable {
    case allGestures
    case practice(TrackpadGesture)

    var practiceGesture: TrackpadGesture? {
        guard case let .practice(gesture) = self else { return nil }
        return gesture
    }
}

struct TrackpadGestureTestingModeAccessibilityState: Equatable, Sendable {
    let isAllGesturesSelected: Bool
    let selectedPracticeGesture: TrackpadGesture?

    init(mode: TrackpadGestureTestingMode?) {
        isAllGesturesSelected = mode == .allGestures
        selectedPracticeGesture = mode?.practiceGesture
    }

    func isPracticeSelected(_ gesture: TrackpadGesture) -> Bool {
        selectedPracticeGesture == gesture
    }
}

enum TrackpadContactRole: Equatable, Sendable {
    case fixed
    case added
    case contact
}

enum TrackpadContactRoleResolver {
    static func resolve(
        _ contact: TrackpadContactSnapshot,
        recognition: TrackpadGestureRecognitionSnapshot?
    ) -> TrackpadContactRole {
        if recognition?.anchorContacts.contains(where: {
            $0.identifier == contact.identifier
        }) == true {
            return .fixed
        }
        if recognition?.candidateContacts.contains(where: {
            $0.identifier == contact.identifier
        }) == true {
            return .added
        }
        return .contact
    }
}

enum TrackpadGestureRecognitionPhase: Equatable, Sendable {
    case waitingForReset
    case ready
    case acquiring
    case settling
    case armed
    case candidate
    case rejected(TipTapEpisodeRejectionReason)
    case tracking
    case waitingForSecondTap
    case holding
    case recognized
    case physicalClick
}

struct TrackpadGestureRecognitionSnapshot: Equatable, Sendable {
    let gesture: TrackpadGesture
    let phase: TrackpadGestureRecognitionPhase
    let anchorContacts: [TrackpadContactSnapshot]
    let candidateContacts: [TrackpadContactSnapshot]
    let requiredContactCount: Int
    let movementTolerance: Double
    let startedAt: TimeInterval?
    let deadline: TimeInterval?
    let thresholds: TrackpadGestureRecognitionThresholds
    let rejectionSequence: UInt64
}

struct TrackpadGestureTestSnapshot: Equatable, Sendable {
    let deviceID: UInt64
    let descriptor: MultitouchDeviceDescriptor?
    let timestamp: TimeInterval
    let contacts: [TrackpadContactSnapshot]
    let recognized: [TrackpadGesture]
    let recognition: TrackpadGestureRecognitionSnapshot?

    func withDescriptor(_ descriptor: MultitouchDeviceDescriptor?) -> Self {
        Self(
            deviceID: deviceID,
            descriptor: descriptor,
            timestamp: timestamp,
            contacts: contacts,
            recognized: recognized,
            recognition: recognition
        )
    }

    func withRecognized(_ recognized: [TrackpadGesture]) -> Self {
        Self(
            deviceID: deviceID,
            descriptor: descriptor,
            timestamp: timestamp,
            contacts: contacts,
            recognized: recognized,
            recognition: recognition
        )
    }

    /// Practice must not surface results from recognizers outside the selected gesture. TipTap
    /// contact-pattern matches remain visible here so Test Gestures can distinguish raw touch
    /// recognition from the native-click correlation required before a production action runs.
    func preparingForDisplay(mode: TrackpadGestureTestingMode) -> Self {
        let scopedRecognitions: [TrackpadGesture]
        switch mode {
        case .allGestures:
            scopedRecognitions = recognized
        case let .practice(gesture):
            scopedRecognitions = recognized.filter { $0 == gesture }
        }
        return withRecognized(scopedRecognitions)
    }
}

struct TrackpadGestureTestingToken: Equatable, Sendable {
    let generation: UInt64
    let mode: TrackpadGestureTestingMode
}

struct TrackpadGestureTestSnapshotEmission: Equatable, Sendable {
    let snapshot: TrackpadGestureTestSnapshot
    let token: TrackpadGestureTestingToken
    let recognitionGeneration: UInt64
    let recognitionDeviceGeneration: UInt64

    init(
        snapshot: TrackpadGestureTestSnapshot,
        token: TrackpadGestureTestingToken,
        recognitionGeneration: UInt64,
        recognitionDeviceGeneration: UInt64 = 0
    ) {
        self.snapshot = snapshot
        self.token = token
        self.recognitionGeneration = recognitionGeneration
        self.recognitionDeviceGeneration = recognitionDeviceGeneration
    }
}

struct TrackpadGestureSnapshotCoalescer: Sendable {
    static let maximumPendingTestingEventsPerDevice = 8

    struct Delivery: Equatable, Sendable {
        let snapshot: TrackpadGestureTestSnapshot?
        let recognitionGeneration: UInt64?
        let recognitionDeviceGeneration: UInt64?
        let delay: TimeInterval?

        init(
            snapshot: TrackpadGestureTestSnapshot?,
            recognitionGeneration: UInt64? = nil,
            recognitionDeviceGeneration: UInt64? = nil,
            delay: TimeInterval?
        ) {
            self.snapshot = snapshot
            self.recognitionGeneration = recognitionGeneration
            self.recognitionDeviceGeneration = recognitionDeviceGeneration
            self.delay = delay
        }
    }

    let minimumInterval: TimeInterval

    private struct PendingSnapshots: Sendable {
        struct Item: Sendable {
            let snapshot: TrackpadGestureTestSnapshot
            let recognitionGeneration: UInt64
            let recognitionDeviceGeneration: UInt64
        }

        var events: [Item] = []
        var live: Item?

        var isEmpty: Bool { events.isEmpty && live == nil }

        mutating func offer(
            _ item: Item,
            isTestingEvent: Bool,
            maximumTestingEvents: Int
        ) {
            let snapshot = item.snapshot
            if isTestingEvent {
                if events.count == maximumTestingEvents {
                    events.removeFirst()
                }
                events.append(item)
                if let live, live.snapshot.timestamp <= snapshot.timestamp {
                    self.live = nil
                }
            } else if live.map({ $0.snapshot.timestamp <= snapshot.timestamp }) != false {
                live = item
            }
        }

        mutating func takeNext() -> Item? {
            if !events.isEmpty {
                return events.removeFirst()
            }
            defer { live = nil }
            return live
        }
    }

    private var lastDeliveredAtByDevice: [UInt64: TimeInterval] = [:]
    private var pendingByDevice: [UInt64: PendingSnapshots] = [:]
    private var lastRejectionEventByDevice:
        [UInt64: TrackpadGestureTestSnapshot.RejectionEvent] = [:]

    init(maximumFramesPerSecond: Double = 30) {
        minimumInterval = 1 / maximumFramesPerSecond
    }

    mutating func offer(
        _ snapshot: TrackpadGestureTestSnapshot,
        recognitionGeneration: UInt64 = 0,
        recognitionDeviceGeneration: UInt64 = 0,
        at time: TimeInterval
    ) -> Delivery {
        let item = PendingSnapshots.Item(
            snapshot: snapshot,
            recognitionGeneration: recognitionGeneration,
            recognitionDeviceGeneration: recognitionDeviceGeneration
        )
        let isTestingEvent: Bool
        if !snapshot.recognized.isEmpty {
            lastRejectionEventByDevice.removeValue(forKey: snapshot.deviceID)
            isTestingEvent = true
        } else if let rejectionEvent = snapshot.rejectionEvent {
            isTestingEvent = lastRejectionEventByDevice[snapshot.deviceID] != rejectionEvent
            lastRejectionEventByDevice[snapshot.deviceID] = rejectionEvent
        } else {
            lastRejectionEventByDevice.removeValue(forKey: snapshot.deviceID)
            isTestingEvent = false
        }
        guard let lastDeliveredAt = lastDeliveredAtByDevice[snapshot.deviceID] else {
            lastDeliveredAtByDevice[snapshot.deviceID] = time
            pendingByDevice.removeValue(forKey: snapshot.deviceID)
            return Delivery(
                snapshot: snapshot,
                recognitionGeneration: recognitionGeneration,
                recognitionDeviceGeneration: recognitionDeviceGeneration,
                delay: nil
            )
        }
        let elapsed = time - lastDeliveredAt
        if var pending = pendingByDevice[snapshot.deviceID] {
            pending.offer(
                item,
                isTestingEvent: isTestingEvent,
                maximumTestingEvents: Self.maximumPendingTestingEventsPerDevice
            )
            pendingByDevice[snapshot.deviceID] = pending
            guard elapsed >= minimumInterval else {
                return Delivery(snapshot: nil, delay: minimumInterval - elapsed)
            }
            lastDeliveredAtByDevice[snapshot.deviceID] = time
            let next = pendingByDevice[snapshot.deviceID]?.takeNext()
            let hasSuccessor = pendingByDevice[snapshot.deviceID]?.isEmpty == false
            if hasSuccessor {
                return Delivery(
                    snapshot: next?.snapshot,
                    recognitionGeneration: next?.recognitionGeneration,
                    recognitionDeviceGeneration: next?.recognitionDeviceGeneration,
                    delay: minimumInterval
                )
            }
            pendingByDevice.removeValue(forKey: snapshot.deviceID)
            return Delivery(
                snapshot: next?.snapshot,
                recognitionGeneration: next?.recognitionGeneration,
                recognitionDeviceGeneration: next?.recognitionDeviceGeneration,
                delay: nil
            )
        }
        guard elapsed < minimumInterval else {
            lastDeliveredAtByDevice[snapshot.deviceID] = time
            pendingByDevice.removeValue(forKey: snapshot.deviceID)
            return Delivery(
                snapshot: snapshot,
                recognitionGeneration: recognitionGeneration,
                recognitionDeviceGeneration: recognitionDeviceGeneration,
                delay: nil
            )
        }
        var pending = PendingSnapshots()
        pending.offer(
            item,
            isTestingEvent: isTestingEvent,
            maximumTestingEvents: Self.maximumPendingTestingEventsPerDevice
        )
        pendingByDevice[snapshot.deviceID] = pending
        return Delivery(snapshot: nil, delay: minimumInterval - elapsed)
    }

    mutating func takePending(deviceID: UInt64, at time: TimeInterval) -> Delivery {
        guard pendingByDevice[deviceID] != nil else {
            return Delivery(snapshot: nil, delay: nil)
        }
        if let lastDeliveredAt = lastDeliveredAtByDevice[deviceID] {
            let elapsed = time - lastDeliveredAt
            guard elapsed >= minimumInterval else {
                return Delivery(snapshot: nil, delay: minimumInterval - elapsed)
            }
        }
        lastDeliveredAtByDevice[deviceID] = time
        let next = pendingByDevice[deviceID]?.takeNext()
        let hasSuccessor = pendingByDevice[deviceID]?.isEmpty == false
        if hasSuccessor {
            return Delivery(
                snapshot: next?.snapshot,
                recognitionGeneration: next?.recognitionGeneration,
                recognitionDeviceGeneration: next?.recognitionDeviceGeneration,
                delay: minimumInterval
            )
        }
        pendingByDevice.removeValue(forKey: deviceID)
        return Delivery(
            snapshot: next?.snapshot,
            recognitionGeneration: next?.recognitionGeneration,
            recognitionDeviceGeneration: next?.recognitionDeviceGeneration,
            delay: nil
        )
    }

    mutating func reset() {
        lastDeliveredAtByDevice.removeAll()
        pendingByDevice.removeAll()
        lastRejectionEventByDevice.removeAll()
    }

    #if DEBUG
    func pendingTestingEventCountForTests(deviceID: UInt64) -> Int {
        pendingByDevice[deviceID]?.events.count ?? 0
    }
    #endif
}

private extension TrackpadGestureTestSnapshot {
    struct RejectionEvent: Equatable, Sendable {
        let gesture: TrackpadGesture
        let sequence: UInt64
    }

    var rejectionEvent: RejectionEvent? {
        guard let recognition,
              case .rejected = recognition.phase,
              recognition.rejectionSequence > 0 else {
            return nil
        }
        return RejectionEvent(
            gesture: recognition.gesture,
            sequence: recognition.rejectionSequence
        )
    }
}

final class TrackpadGestureTestSnapshotRelay: @unchecked Sendable {
    typealias Handler = @Sendable (TrackpadGestureTestSnapshotEmission) -> Void

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let handler: Handler
    private var mode: TrackpadGestureTestingMode?
    private var coalescer: TrackpadGestureSnapshotCoalescer
    private var scheduledDeviceIDs = Set<UInt64>()
    private var generation: UInt64 = 0

    init(
        maximumFramesPerSecond: Double = 30,
        clock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        handler: @escaping Handler
    ) {
        self.clock = clock
        self.handler = handler
        self.coalescer = TrackpadGestureSnapshotCoalescer(
            maximumFramesPerSecond: maximumFramesPerSecond
        )
    }

    func update(mode: TrackpadGestureTestingMode?) {
        lock.withLock {
            self.mode = mode
            generation &+= 1
            scheduledDeviceIDs.removeAll()
            coalescer.reset()
        }
    }

    func currentToken() -> TrackpadGestureTestingToken? {
        lock.withLock {
            mode.map { TrackpadGestureTestingToken(generation: generation, mode: $0) }
        }
    }

    func isCurrent(_ token: TrackpadGestureTestingToken) -> Bool {
        lock.withLock {
            generation == token.generation && mode == token.mode
        }
    }

    func offer(
        _ snapshot: TrackpadGestureTestSnapshot,
        token: TrackpadGestureTestingToken,
        recognitionGeneration: UInt64,
        recognitionDeviceGeneration: UInt64 = 0
    ) {
        let now = clock()
        var immediate: TrackpadGestureTestSnapshotEmission?
        var schedule: (deviceID: UInt64, delay: TimeInterval, generation: UInt64)?
        lock.withLock {
            guard generation == token.generation, mode == token.mode else { return }
            let scopedSnapshot: TrackpadGestureTestSnapshot
            switch token.mode {
            case .allGestures:
                guard snapshot.recognition == nil else { return }
                scopedSnapshot = snapshot
            case let .practice(gesture):
                guard snapshot.recognition?.gesture == gesture else { return }
                scopedSnapshot = snapshot.withRecognized(
                    snapshot.recognized.filter { $0 == gesture }
                )
            }
            let delivery = coalescer.offer(
                scopedSnapshot,
                recognitionGeneration: recognitionGeneration,
                recognitionDeviceGeneration: recognitionDeviceGeneration,
                at: now
            )
            immediate = delivery.snapshot.flatMap { snapshot in
                delivery.recognitionGeneration.map {
                TrackpadGestureTestSnapshotEmission(
                    snapshot: snapshot,
                    token: token,
                    recognitionGeneration: $0,
                    recognitionDeviceGeneration: delivery.recognitionDeviceGeneration ?? 0
                )
                }
            }
            if let delay = delivery.delay,
               scheduledDeviceIDs.insert(snapshot.deviceID).inserted {
                schedule = (snapshot.deviceID, delay, generation)
            }
        }
        if let immediate {
            handler(immediate)
        }
        if let schedule {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + schedule.delay
            ) { [weak self] in
                self?.flush(deviceID: schedule.deviceID, generation: schedule.generation)
            }
        }
    }

    private func flush(deviceID: UInt64, generation: UInt64) {
        let now = clock()
        var emission: TrackpadGestureTestSnapshotEmission?
        var retryDelay: TimeInterval?
        lock.withLock {
            guard self.generation == generation, let mode else { return }
            let delivery = coalescer.takePending(deviceID: deviceID, at: now)
            emission = delivery.snapshot.flatMap { snapshot in
                delivery.recognitionGeneration.map {
                    TrackpadGestureTestSnapshotEmission(
                        snapshot: snapshot,
                        token: TrackpadGestureTestingToken(generation: generation, mode: mode),
                        recognitionGeneration: $0,
                        recognitionDeviceGeneration: delivery.recognitionDeviceGeneration ?? 0
                    )
                }
            }
            retryDelay = delivery.delay
            if delivery.delay == nil {
                scheduledDeviceIDs.remove(deviceID)
            }
        }
        if let emission {
            handler(emission)
        }
        if let retryDelay {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(
                deadline: .now() + retryDelay
            ) { [weak self] in
                self?.flush(deviceID: deviceID, generation: generation)
            }
        }
    }
}

struct TrackpadGestureTestingRejection: Equatable, Sendable {
    let deviceID: UInt64
    let gesture: TrackpadGesture
    let reason: TipTapEpisodeRejectionReason
    let sequence: UInt64
}

enum TrackpadGestureTestingRejectionAnnouncementPolicy {
    static func shouldAnnounce(
        previous: TrackpadGestureTestingRejection?,
        current: TrackpadGestureTestingRejection?
    ) -> Bool {
        current != nil && current != previous
    }
}

@MainActor
final class TrackpadGestureTestingModel: ObservableObject {
    @Published private(set) var mode: TrackpadGestureTestingMode?
    @Published private(set) var snapshotsByDevice: [UInt64: TrackpadGestureTestSnapshot] = [:]
    @Published private(set) var recognizedGesturesByDevice: [UInt64: TrackpadGesture] = [:]
    @Published private(set) var contactPatternGesturesByDevice: [UInt64: TrackpadGesture] = [:]
    @Published private(set) var rejectionsByDevice:
        [UInt64: TrackpadGestureTestingRejection] = [:]
    @Published private(set) var latestRejectionAnnouncement:
        TrackpadGestureTestingRejection?
    @Published private(set) var selectedDeviceID: UInt64?
    private var isDeviceSelectionPinned = false
    private var recognizedAtByDevice: [UInt64: TimeInterval] = [:]
    private var recognizedContactIdentifiersByDevice: [UInt64: Set<Int>] = [:]
    private var contactPatternContactIdentifiersByDevice: [UInt64: Set<Int>] = [:]

    var selectedSnapshot: TrackpadGestureTestSnapshot? {
        selectedDeviceID.flatMap { snapshotsByDevice[$0] }
    }

    var selectedRecognizedGesture: TrackpadGesture? {
        selectedDeviceID.flatMap { recognizedGesturesByDevice[$0] }
    }

    var selectedContactPatternGesture: TrackpadGesture? {
        selectedDeviceID.flatMap { contactPatternGesturesByDevice[$0] }
    }

    var selectedRejection: TrackpadGestureTestingRejection? {
        selectedDeviceID.flatMap { rejectionsByDevice[$0] }
    }

    var orderedSnapshots: [TrackpadGestureTestSnapshot] {
        snapshotsByDevice.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.deviceID < rhs.deviceID
        }
    }

    func begin(_ mode: TrackpadGestureTestingMode) {
        self.mode = mode
        clearSnapshots()
    }

    func updateMode(_ mode: TrackpadGestureTestingMode) {
        self.mode = mode
        clearSnapshots()
    }

    func apply(_ snapshot: TrackpadGestureTestSnapshot) {
        let deviceID = snapshot.deviceID
        let contactIdentifiers = Set(snapshot.contacts.map(\.identifier))
        if contactPatternGesturesByDevice[deviceID] != nil,
           contactPatternContactIdentifiersByDevice[deviceID] != contactIdentifiers {
            contactPatternGesturesByDevice.removeValue(forKey: deviceID)
            contactPatternContactIdentifiersByDevice.removeValue(forKey: deviceID)
        }
        if let recognizedAt = recognizedAtByDevice[deviceID],
           snapshot.timestamp == recognizedAt {
            // A recognition can reach the model before its coalesced recognition frame.
            // Rebase retention to that exact frame so the following idle frame is not
            // mistaken for a new attempt.
            recognizedContactIdentifiersByDevice[deviceID] = Set(
                snapshot.contacts.map(\.identifier)
            )
        }
        if let recognizedAt = recognizedAtByDevice[snapshot.deviceID],
           snapshot.timestamp > recognizedAt,
           beginsNewAttempt(snapshot) {
            recognizedAtByDevice.removeValue(forKey: deviceID)
            recognizedContactIdentifiersByDevice.removeValue(forKey: deviceID)
            recognizedGesturesByDevice.removeValue(forKey: deviceID)
        }
        if let recognition = snapshot.recognition,
           case let .rejected(reason) = recognition.phase {
            let rejection = TrackpadGestureTestingRejection(
                deviceID: deviceID,
                gesture: recognition.gesture,
                reason: reason,
                sequence: recognition.rejectionSequence
            )
            if rejectionsByDevice[deviceID] != rejection {
                rejectionsByDevice[deviceID] = rejection
                latestRejectionAnnouncement = rejection
            }
        } else if rejectionsByDevice[deviceID] != nil,
                  shouldClearRetainedRejection(snapshot) {
            rejectionsByDevice.removeValue(forKey: deviceID)
        }
        snapshotsByDevice[deviceID] = snapshot
        if let contactPattern = snapshot.recognized.last(where: {
            $0.tipTapConfiguration != nil
        }), recognizedGesturesByDevice[deviceID] != contactPattern {
            contactPatternGesturesByDevice[deviceID] = contactPattern
            contactPatternContactIdentifiersByDevice[deviceID] = contactIdentifiers
        }
        if !isDeviceSelectionPinned || selectedDeviceID == nil {
            selectedDeviceID = deviceID
        }
    }

    func recordRecognized(
        _ gesture: TrackpadGesture,
        deviceID: UInt64,
        at timestamp: TimeInterval? = nil
    ) {
        contactPatternGesturesByDevice.removeValue(forKey: deviceID)
        contactPatternContactIdentifiersByDevice.removeValue(forKey: deviceID)
        recognizedGesturesByDevice[deviceID] = gesture
        recognizedAtByDevice[deviceID] = timestamp
            ?? snapshotsByDevice[deviceID]?.timestamp
            ?? -.infinity
        let snapshot = snapshotsByDevice[deviceID]
        let contacts = if gesture.tipTapConfiguration != nil,
                          let anchors = snapshot?.recognition?.anchorContacts,
                          !anchors.isEmpty {
            anchors
        } else {
            snapshot?.contacts ?? []
        }
        recognizedContactIdentifiersByDevice[deviceID] = Set(contacts.map(\.identifier))
    }

    func selectDevice(_ deviceID: UInt64) {
        guard snapshotsByDevice[deviceID] != nil else { return }
        selectedDeviceID = deviceID
        isDeviceSelectionPinned = true
    }

    func clearSnapshots() {
        snapshotsByDevice.removeAll()
        recognizedGesturesByDevice.removeAll()
        contactPatternGesturesByDevice.removeAll()
        recognizedAtByDevice.removeAll()
        recognizedContactIdentifiersByDevice.removeAll()
        contactPatternContactIdentifiersByDevice.removeAll()
        rejectionsByDevice.removeAll()
        latestRejectionAnnouncement = nil
        selectedDeviceID = nil
        isDeviceSelectionPinned = false
    }

    func stop() {
        mode = nil
        clearSnapshots()
    }

    private func beginsNewAttempt(_ snapshot: TrackpadGestureTestSnapshot) -> Bool {
        if snapshot.recognition?.phase.supersedesRetainedRecognition == true {
            return true
        }
        // Lifting the last contact is the idle/reset portion of the gesture that just
        // succeeded, not a new attempt. Keep the success visible until a later contact starts
        // or the recognizer explicitly reports a new live phase.
        guard !snapshot.contacts.isEmpty else { return false }
        let currentIdentifiers = Set(snapshot.contacts.map(\.identifier))
        return currentIdentifiers != recognizedContactIdentifiersByDevice[snapshot.deviceID]
    }

    private func shouldClearRetainedRejection(
        _ snapshot: TrackpadGestureTestSnapshot
    ) -> Bool {
        guard !snapshot.contacts.isEmpty else { return true }
        guard let phase = snapshot.recognition?.phase else { return false }
        switch phase {
        case .acquiring, .settling, .candidate, .tracking, .waitingForSecondTap,
             .holding, .recognized, .physicalClick:
            return true
        case .waitingForReset, .ready, .armed, .rejected:
            return false
        }
    }
}

enum TrackpadGestureTestingStatus: Equatable {
    case recognized(TrackpadGesture)
    case contactPatternDetected(TrackpadGesture)
    case phase(TrackpadGestureRecognitionPhase, gesture: TrackpadGesture)
    case contactCount(Int)
    case noContacts
    case waiting
}

enum TrackpadGestureTestingStatusResolver {
    static func resolve(
        snapshot: TrackpadGestureTestSnapshot?,
        retainedRecognition: TrackpadGesture?,
        retainedContactPattern: TrackpadGesture? = nil,
        retainedRejection: TrackpadGestureTestingRejection? = nil
    ) -> TrackpadGestureTestingStatus {
        guard let snapshot else { return .waiting }
        if let recognized = snapshot.recognized.last,
           recognized.tipTapConfiguration == nil {
            return .recognized(recognized)
        }
        if let recognition = snapshot.recognition,
           recognition.phase.supersedesRetainedRecognition {
            return .phase(recognition.phase, gesture: recognition.gesture)
        }
        if let retainedRecognition {
            return .recognized(retainedRecognition)
        }
        if let contactPattern = snapshot.recognized.last,
           contactPattern.tipTapConfiguration != nil {
            return .contactPatternDetected(contactPattern)
        }
        if let retainedContactPattern {
            return .contactPatternDetected(retainedContactPattern)
        }
        if let retainedRejection {
            return .phase(
                .rejected(retainedRejection.reason),
                gesture: retainedRejection.gesture
            )
        }
        if !snapshot.contacts.isEmpty {
            if let recognition = snapshot.recognition {
                return .phase(recognition.phase, gesture: recognition.gesture)
            }
            return .contactCount(snapshot.contacts.count)
        }
        if let recognition = snapshot.recognition {
            return .phase(recognition.phase, gesture: recognition.gesture)
        }
        return .noContacts
    }
}

enum TrackpadGestureTestingStatusPresentation: Equatable {
    case status(TrackpadGestureTestingStatus)
    case guide(TrackpadPracticeGuideAvailability)
}

enum TrackpadGestureTestingStatusPresentationResolver {
    static func resolve(
        snapshot: TrackpadGestureTestSnapshot?,
        retainedRecognition: TrackpadGesture?,
        retainedContactPattern: TrackpadGesture? = nil,
        retainedRejection: TrackpadGestureTestingRejection? = nil
    ) -> TrackpadGestureTestingStatusPresentation {
        let status = TrackpadGestureTestingStatusResolver.resolve(
            snapshot: snapshot,
            retainedRecognition: retainedRecognition,
            retainedContactPattern: retainedContactPattern,
            retainedRejection: retainedRejection
        )
        if status.takesPriorityOverPracticeGuide {
            return .status(status)
        }
        if let recognition = snapshot?.recognition,
           recognition.gesture.tipTapConfiguration != nil {
            let availability = TrackpadPracticeGuideGeometry.make(
                snapshot: recognition
            ).availability
            if availability != .targetAvailable, availability != .notApplicable {
                return .guide(availability)
            }
        }
        return .status(status)
    }
}

private extension TrackpadGestureRecognitionPhase {
    var supersedesRetainedRecognition: Bool {
        switch self {
        case .waitingForReset, .acquiring, .settling, .candidate, .rejected,
             .tracking, .waitingForSecondTap, .holding:
            true
        case .ready, .armed, .recognized, .physicalClick:
            false
        }
    }
}

private extension TrackpadGestureTestingStatus {
    var takesPriorityOverPracticeGuide: Bool {
        switch self {
        case .recognized, .contactPatternDetected:
            true
        case let .phase(phase, _):
            switch phase {
            case .waitingForReset, .rejected:
                true
            default:
                false
            }
        case .contactCount, .noContacts, .waiting:
            false
        }
    }
}

struct TrackpadGestureTimingProgress: Equatable, Sendable {
    let fraction: Double
    let remaining: TimeInterval

    static func make(
        startedAt: TimeInterval,
        deadline: TimeInterval,
        now: TimeInterval
    ) -> Self {
        let duration = max(deadline - startedAt, 0.001)
        return Self(
            fraction: min(max((now - startedAt) / duration, 0), 1),
            remaining: max(deadline - now, 0)
        )
    }
}

enum TrackpadMovementHaloGeometry {
    static func size(normalizedRadius: Double, surfaceSize: CGSize) -> CGSize {
        CGSize(
            width: max(normalizedRadius, 0) * 2 * surfaceSize.width,
            height: max(normalizedRadius, 0) * 2 * surfaceSize.height
        )
    }
}

enum TrackpadCoordinateProjector {
    static func project(
        _ contact: TrackpadContactSnapshot,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: min(max(contact.x, 0), 1) * size.width,
            y: (1 - min(max(contact.y, 0), 1)) * size.height
        )
    }
}

struct TrackpadPracticeGuideRegion: Equatable, Sendable {
    let xRange: ClosedRange<Double>
    let region: TipTapRegion
}

enum TrackpadPracticeGuideAvailability: Equatable, Sendable {
    case notApplicable
    case waitingForAnchors(required: Int, current: Int)
    case targetAvailable
    case middleRequiresWiderSpan
    case targetOutsideSurface
}

struct TrackpadPracticeGuideGeometry: Equatable, Sendable {
    let regions: [TrackpadPracticeGuideRegion]
    let unavailableRanges: [ClosedRange<Double>]
    let availability: TrackpadPracticeGuideAvailability
    let anchorToleranceRadius: Double
    let candidateToleranceRadius: Double

    static func make(
        snapshot: TrackpadGestureRecognitionSnapshot
    ) -> TrackpadPracticeGuideGeometry {
        guard let tipTap = snapshot.gesture.tipTapConfiguration else {
            return TrackpadPracticeGuideGeometry(
                regions: [],
                unavailableRanges: [],
                availability: .notApplicable,
                anchorToleranceRadius: snapshot.movementTolerance,
                candidateToleranceRadius: snapshot.movementTolerance
            )
        }
        let hasStableAnchorGeometry: Bool
        switch snapshot.phase {
        case .armed, .candidate, .rejected(.tooBrief), .rejected(.tooLong),
             .rejected(.movedTooFar), .rejected(.wrongRegion), .rejected(.extraContact):
            hasStableAnchorGeometry = true
        default:
            hasStableAnchorGeometry = false
        }
        guard hasStableAnchorGeometry,
              snapshot.anchorContacts.count == tipTap.fixedFingerCount,
              let geometry = TipTapGuideGeometry.make(
                  fixedContacts: snapshot.anchorContacts,
                  thresholds: snapshot.thresholds
              ) else {
            return TrackpadPracticeGuideGeometry(
                regions: [],
                unavailableRanges: [0 ... 1],
                availability: .waitingForAnchors(
                    required: tipTap.fixedFingerCount,
                    current: snapshot.anchorContacts.count
                ),
                anchorToleranceRadius: snapshot.movementTolerance,
                candidateToleranceRadius: snapshot.movementTolerance
            )
        }
        let range: ClosedRange<Double>?
        switch tipTap.region {
        case .left:
            range = 0 ... max(0, geometry.leftBoundaryX)
        case .middle:
            range = geometry.middleRange
        case .right:
            range = min(1, geometry.rightBoundaryX) ... 1
        }
        let availability: TrackpadPracticeGuideAvailability
        if tipTap.region == .middle, range == nil {
            availability = .middleRequiresWiderSpan
        } else if let range, range.lowerBound < range.upperBound {
            availability = .targetAvailable
        } else {
            availability = .targetOutsideSurface
        }
        let unavailableRanges: [ClosedRange<Double>]
        if let range, availability == .targetAvailable {
            unavailableRanges = [
                range.lowerBound > 0 ? 0 ... range.lowerBound : nil,
                range.upperBound < 1 ? range.upperBound ... 1 : nil,
            ].compactMap { $0 }
        } else {
            unavailableRanges = [0 ... 1]
        }
        return TrackpadPracticeGuideGeometry(
            regions: availability == .targetAvailable
                ? range.map { [TrackpadPracticeGuideRegion(xRange: $0, region: tipTap.region)] } ?? []
                : [],
            unavailableRanges: unavailableRanges,
            availability: availability,
            anchorToleranceRadius: snapshot.thresholds.fixedFingerMovement,
            candidateToleranceRadius: snapshot.thresholds.tappingFingerMovement
        )
    }
}
