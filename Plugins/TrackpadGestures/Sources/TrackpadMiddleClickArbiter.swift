import CoreGraphics
import Foundation
import MacToolsPluginKit

enum TrackpadNativeClickResolution: Equatable, Sendable {
    case consume
    case middleClick
}

struct TrackpadTipTapEpisodeID: Equatable, Hashable, Sendable {
    let deviceID: UInt64
    let fixedFingerCount: Int
    let sequence: UInt64
}

struct TrackpadTipTapEpisodeStart: Equatable, Sendable {
    let id: TrackpadTipTapEpisodeID
    let observedAt: TimeInterval
}

struct TrackpadMiddleClickFrameObservation: Equatable, Sendable {
    let shouldNotifyCoordinator: Bool
    let tipTapRecognitionIDs: [TrackpadGesture: TrackpadTipTapEpisodeID]
}

final class TrackpadMiddleClickCandidateTimeline: @unchecked Sendable {
    struct Candidate: Equatable, Sendable {
        let deviceID: UInt64
        let episodeID: UInt64
        let contactCount: Int
        let observedAt: TimeInterval
        let isAmbiguous: Bool
    }

    private struct CandidateEpisode {
        let id: UInt64
        var contactCount: Int
        var observedAt: TimeInterval
        var isAmbiguous: Bool
        // Tap recognition is delivered after the release frame, so a just-ended episode remains
        // available for the bounded candidate window without carrying into a later contact episode.
        var isActive: Bool
    }

    private struct TipTapEpisode {
        let id: TrackpadTipTapEpisodeID
        var isRejected: Bool
    }

    private struct RetainedTipTapEpisode {
        let id: TrackpadTipTapEpisodeID
        let deadline: TimeInterval
    }

    private struct TipTapGroupUpdate {
        var hasQualifiedEpisode = false
        var hasRejectedEpisode = false
        var isAwaitingAddedContact = false
        var didStartEpisode = false
        var didAddRejection = false
        var recognizedGestures: [TrackpadGesture] = []
    }

    private let candidateWindow: TimeInterval
    private let lock = NSLock()
    private var contactCounts = Set<Int>()
    private var tipTapGestures = Set<TrackpadGesture>()
    private var tipTapRecognizersByDevice: [UInt64: [TrackpadGesture: TipTapRecognizer]] = [:]
    private var tipTapSuppressionByDevice: [UInt64: TrackpadTipTapEpisodeID] = [:]
    private var tipTapRejectedDeviceIDs = Set<UInt64>()
    private var newTipTapEpisodeStarts: [TrackpadTipTapEpisodeStart] = []
    private var newTipTapRejectionIDs: [TrackpadTipTapEpisodeID] = []
    private var activeTipTapEpisodesByDevice: [UInt64: [Int: TipTapEpisode]] = [:]
    private var latestTipTapEpisodeIDsByDevice: [UInt64: TrackpadTipTapEpisodeID] = [:]
    private var rejectedEpisodeQuarantineByDevice:
        [UInt64: [Int: (id: TrackpadTipTapEpisodeID, deadline: TimeInterval)]] = [:]
    private var rejectedTipTapEpisodesByDevice:
        [UInt64: [Int: (id: TrackpadTipTapEpisodeID, deadline: TimeInterval)]] = [:]
    private var resolvedRejectedNativeClickEpisodeIDs = Set<TrackpadTipTapEpisodeID>()
    private var completedTipTapEpisodesByDevice: [UInt64: [RetainedTipTapEpisode]] = [:]
    private var zeroContactDeviceIDs = Set<UInt64>()
    private var episodesByDevice: [UInt64: CandidateEpisode] = [:]
    private var maximumContactCountsByDevice: [UInt64: Int] = [:]
    private var untrustedNativeEventDeadline: TimeInterval?
    private var uncorrelatedDeadlinesByDevice: [UInt64: TimeInterval] = [:]
    private var nextEpisodeID: UInt64 = 0
    private var nextTipTapSequenceByDevice: [UInt64: UInt64] = [:]
    private let rejectedEpisodeQuarantine: TimeInterval

    init(candidateWindow: TimeInterval = 0.32, rejectedEpisodeQuarantine: TimeInterval = 0.02) {
        self.candidateWindow = candidateWindow
        self.rejectedEpisodeQuarantine = rejectedEpisodeQuarantine
    }

    func update(gestures: Set<TrackpadGesture>) {
        let counts = Set(gestures.flatMap { gesture -> [Int] in
            if let tipTap = gesture.tipTapConfiguration {
                // Native mouse-down can arrive before the added-contact frame. Keep the armed
                // fixed-finger phase in the same candidate episode so that early delivery can be
                // buffered and later resolved by the TipTap recognizer.
                return [tipTap.fixedFingerCount, tipTap.fixedFingerCount + 1]
            }
            if let clickContactCount = gesture.middleClickContactCount {
                return [clickContactCount]
            }
            return []
        })
        let configuredTipTaps = Set(gestures.filter { $0.tipTapConfiguration != nil })
        lock.withLock {
            contactCounts = counts
            tipTapGestures = configuredTipTaps
            clearState()
        }
    }

    @discardableResult
    func observe(
        frame: TrackpadContactFrame,
        at time: TimeInterval
    ) -> TrackpadMiddleClickFrameObservation {
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            if frame.contacts.isEmpty {
                maximumContactCountsByDevice.removeValue(forKey: frame.deviceID)
            } else {
                maximumContactCountsByDevice[frame.deviceID] = max(
                    maximumContactCountsByDevice[frame.deviceID] ?? 0,
                    frame.contacts.count
                )
            }
            if !contactCounts.contains(frame.contacts.count) {
                if var episode = episodesByDevice[frame.deviceID], episode.isActive {
                    episode.isActive = false
                    episodesByDevice[frame.deviceID] = episode
                }
            } else {
                let startsAmbiguous = untrustedNativeEventDeadline.map { $0 > time } == true
                    || uncorrelatedDeadlinesByDevice[frame.deviceID].map { $0 > time } == true
                if var episode = episodesByDevice[frame.deviceID], episode.isActive {
                    episode.contactCount = frame.contacts.count
                    episode.observedAt = time
                    episode.isAmbiguous = episode.isAmbiguous || startsAmbiguous
                    episodesByDevice[frame.deviceID] = episode
                } else {
                    nextEpisodeID &+= 1
                    episodesByDevice[frame.deviceID] = CandidateEpisode(
                        id: nextEpisodeID,
                        contactCount: frame.contacts.count,
                        observedAt: time,
                        isAmbiguous: startsAmbiguous,
                        isActive: true
                    )
                }
            }
            let tipTapUpdate = observeTipTapCandidates(frame: frame, at: time)
            return TrackpadMiddleClickFrameObservation(
                shouldNotifyCoordinator: tipTapUpdate.didStart
                    || tipTapUpdate.didReject
                    || tipTapUpdate.didEndRejected,
                tipTapRecognitionIDs: tipTapUpdate.recognitionIDs
            )
        }
    }

    func takeCandidates() -> [Candidate] {
        lock.withLock {
            episodesByDevice.map { deviceID, episode in
                Candidate(
                    deviceID: deviceID,
                    episodeID: episode.id,
                    contactCount: episode.contactCount,
                    observedAt: episode.observedAt,
                    isAmbiguous: episode.isAmbiguous
                )
            }
        }
    }

    func inferredTrackpadOrigin(at time: TimeInterval) -> TrackpadMiddleClickArbiter.NativeEventOrigin? {
        inferredTrackpadCandidate(at: time).map { .trackpad(deviceID: $0.deviceID) }
    }

    func inferredTrackpadCandidate(at time: TimeInterval) -> Candidate? {
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            let candidates = episodesByDevice.filter {
                !$0.value.isAmbiguous
                    && (hasCorrelatableTipTapEpisode(deviceID: $0.key)
                        || (!tipTapRejectedDeviceIDs.contains($0.key)
                            && rejectedEpisodeQuarantineByDevice[$0.key] == nil))
            }
            guard candidates.count == 1,
                  let (deviceID, episode) = candidates.first
            else {
                return nil
            }
            return Candidate(
                deviceID: deviceID,
                episodeID: episode.id,
                contactCount: episode.contactCount,
                observedAt: episode.observedAt,
                isAmbiguous: false
            )
        }
    }

    func activePhysicalClickCandidate(at time: TimeInterval) -> Candidate? {
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            let candidates = episodesByDevice.filter { deviceID, episode in
                episode.isActive
                    && !episode.isAmbiguous
                    && tipTapSuppressionByDevice[deviceID] == nil
                    && rejectedEpisodeQuarantineByDevice[deviceID] == nil
                    && maximumContactCountsByDevice[deviceID] == episode.contactCount
            }
            guard candidates.count == 1,
                  let (deviceID, episode) = candidates.first
            else {
                return nil
            }
            return Candidate(
                deviceID: deviceID,
                episodeID: episode.id,
                contactCount: episode.contactCount,
                observedAt: episode.observedAt,
                isAmbiguous: false
            )
        }
    }

    func shouldDeferPhysicalClick(_ candidate: Candidate) -> Bool {
        lock.withLock {
            guard tipTapSuppressionByDevice[candidate.deviceID] == nil else {
                return false
            }
            return tipTapRecognizersByDevice[candidate.deviceID]?.values.contains {
                $0.fixedFingerCount == candidate.contactCount && $0.isAwaitingAddedContact
            } == true
        }
    }

    func suppressesPhysicalClick(deviceID: UInt64) -> Bool {
        lock.withLock {
            tipTapSuppressionByDevice[deviceID] != nil
        }
    }

    func completeTipTapRecognition(_ episodeID: TrackpadTipTapEpisodeID) {
        lock.withLock {
            if tipTapSuppressionByDevice[episodeID.deviceID] == episodeID {
                tipTapSuppressionByDevice.removeValue(forKey: episodeID.deviceID)
            }
            if tipTapSuppressionByDevice[episodeID.deviceID] == nil,
               let currentContactCount = episodesByDevice[episodeID.deviceID]?.contactCount {
                maximumContactCountsByDevice[episodeID.deviceID] = currentContactCount
            }
            if completedTipTapEpisodesByDevice[episodeID.deviceID]?.contains(where: {
                $0.id == episodeID
            }) == true {
                completedTipTapEpisodesByDevice[episodeID.deviceID]?.removeAll {
                    $0.id == episodeID
                }
                if completedTipTapEpisodesByDevice[episodeID.deviceID]?.isEmpty == true {
                    completedTipTapEpisodesByDevice.removeValue(forKey: episodeID.deviceID)
                }
            }
            if let rejectedByFixedCount = rejectedTipTapEpisodesByDevice[episodeID.deviceID],
               let rejected = rejectedByFixedCount[episodeID.fixedFingerCount],
               rejected.id.sequence < episodeID.sequence {
                rejectedTipTapEpisodesByDevice[episodeID.deviceID]?
                    .removeValue(forKey: episodeID.fixedFingerCount)
                if rejectedTipTapEpisodesByDevice[episodeID.deviceID]?.isEmpty == true {
                    rejectedTipTapEpisodesByDevice.removeValue(forKey: episodeID.deviceID)
                }
            }
        }
    }

    func retainAbandonedTipTapNativeClick(
        _ episodeID: TrackpadTipTapEpisodeID,
        at time: TimeInterval
    ) {
        lock.withLock {
            rejectedEpisodeQuarantineByDevice[episodeID.deviceID, default: [:]][
                episodeID.fixedFingerCount
            ] = (episodeID, time + rejectedEpisodeQuarantine)
            rejectedTipTapEpisodesByDevice[episodeID.deviceID, default: [:]][
                episodeID.fixedFingerCount
            ] = (episodeID, time + candidateWindow)
        }
    }

    func takeNewTipTapRejectionIDs() -> [TrackpadTipTapEpisodeID] {
        lock.withLock {
            defer { newTipTapRejectionIDs.removeAll() }
            return newTipTapRejectionIDs
        }
    }

    func takeNewTipTapEpisodeStarts() -> [TrackpadTipTapEpisodeStart] {
        lock.withLock {
            defer { newTipTapEpisodeStarts.removeAll() }
            return newTipTapEpisodeStarts
        }
    }

    func activeTipTapEpisodeID(deviceID: UInt64) -> TrackpadTipTapEpisodeID? {
        lock.withLock {
            nativeCorrelationTipTapEpisodeIDLocked(
                deviceID: deviceID,
                includeRejected: false
            )
        }
    }

    func nativeCorrelationTipTapEpisodeID(
        deviceID: UInt64,
        at time: TimeInterval
    ) -> TrackpadTipTapEpisodeID? {
        lock.withLock {
            pruneEpisodes(at: time)
            return nativeCorrelationTipTapEpisodeIDLocked(
                deviceID: deviceID,
                includeRejected: true
            )
        }
    }

    func hasNewerTipTapEpisode(than episodeID: TrackpadTipTapEpisodeID) -> Bool {
        lock.withLock {
            guard let latest = latestTipTapEpisodeIDsByDevice[episodeID.deviceID] else {
                return false
            }
            return latest.sequence > episodeID.sequence
        }
    }

    func isRetainingRejectedTipTapEpisode(
        _ episodeID: TrackpadTipTapEpisodeID,
        at time: TimeInterval
    ) -> Bool {
        lock.withLock {
            pruneEpisodes(at: time)
            return rejectedTipTapEpisodesByDevice[episodeID.deviceID]?[episodeID.fixedFingerCount]?.id
                == episodeID
        }
    }

    func completeRejectedNativeClick(_ episodeID: TrackpadTipTapEpisodeID) {
        lock.withLock {
            let wasRetained = rejectedTipTapEpisodesByDevice[episodeID.deviceID]?[
                episodeID.fixedFingerCount
            ]?.id == episodeID
            if wasRetained {
                rejectedTipTapEpisodesByDevice[episodeID.deviceID]?
                    .removeValue(forKey: episodeID.fixedFingerCount)
                if rejectedTipTapEpisodesByDevice[episodeID.deviceID]?.isEmpty == true {
                    rejectedTipTapEpisodesByDevice.removeValue(forKey: episodeID.deviceID)
                }
            }
            if rejectedEpisodeQuarantineByDevice[episodeID.deviceID]?[episodeID.fixedFingerCount]?.id
                == episodeID {
                rejectedEpisodeQuarantineByDevice[episodeID.deviceID]?
                    .removeValue(forKey: episodeID.fixedFingerCount)
                if rejectedEpisodeQuarantineByDevice[episodeID.deviceID]?.isEmpty == true {
                    rejectedEpisodeQuarantineByDevice.removeValue(forKey: episodeID.deviceID)
                }
            }
            if !wasRetained {
                // A native pair can be replayed as soon as the recognizer rejects, before the
                // added contact leaves and the episode is moved into retained ownership.
                resolvedRejectedNativeClickEpisodeIDs.insert(episodeID)
            }
        }
    }

    func isQuarantiningRejectedTipTap(deviceID: UInt64, at time: TimeInterval) -> Bool {
        lock.withLock {
            pruneEpisodes(at: time)
            return rejectedEpisodeQuarantineByDevice[deviceID]?.isEmpty == false
        }
    }

    func observeNativeEvent(
        origin: TrackpadMiddleClickArbiter.NativeEventOrigin,
        isDown: Bool,
        at time: TimeInterval
    ) {
        guard isDown else { return }
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            let deadline = time + candidateWindow
            switch origin {
            case .contactInferenceAllowed, .unknown, .external:
                untrustedNativeEventDeadline = deadline
                for deviceID in Array(episodesByDevice.keys) {
                    markEpisodeAmbiguous(deviceID: deviceID)
                }
            case let .trackpad(deviceID):
                if episodesByDevice[deviceID] == nil {
                    uncorrelatedDeadlinesByDevice[deviceID] = deadline
                }
                for otherDeviceID in Array(episodesByDevice.keys)
                    where otherDeviceID != deviceID {
                    markEpisodeAmbiguous(deviceID: otherDeviceID)
                }
            }
        }
    }

    func reset() {
        lock.withLock {
            clearState()
        }
    }

    private func pruneEventDeadlines(at time: TimeInterval) {
        if let deadline = untrustedNativeEventDeadline, deadline <= time {
            untrustedNativeEventDeadline = nil
        }
        uncorrelatedDeadlinesByDevice = uncorrelatedDeadlinesByDevice.filter {
            $0.value > time
        }
    }

    private func clearState() {
        tipTapRecognizersByDevice.removeAll()
        tipTapSuppressionByDevice.removeAll()
        tipTapRejectedDeviceIDs.removeAll()
        newTipTapEpisodeStarts.removeAll()
        newTipTapRejectionIDs.removeAll()
        activeTipTapEpisodesByDevice.removeAll()
        latestTipTapEpisodeIDsByDevice.removeAll()
        rejectedEpisodeQuarantineByDevice.removeAll()
        rejectedTipTapEpisodesByDevice.removeAll()
        resolvedRejectedNativeClickEpisodeIDs.removeAll()
        completedTipTapEpisodesByDevice.removeAll()
        zeroContactDeviceIDs.removeAll()
        episodesByDevice.removeAll()
        maximumContactCountsByDevice.removeAll()
        untrustedNativeEventDeadline = nil
        uncorrelatedDeadlinesByDevice.removeAll()
        nextTipTapSequenceByDevice.removeAll()
    }

    private func markEpisodeAmbiguous(deviceID: UInt64) {
        guard var episode = episodesByDevice[deviceID] else { return }
        episode.isAmbiguous = true
        episodesByDevice[deviceID] = episode
    }

    private func pruneEpisodes(at time: TimeInterval) {
        episodesByDevice = episodesByDevice.filter {
            $0.value.isActive || $0.value.observedAt + candidateWindow > time
        }
        rejectedEpisodeQuarantineByDevice = rejectedEpisodeQuarantineByDevice.reduce(
            into: [:]
        ) { result, entry in
            let unexpired = entry.value.filter { $0.value.deadline > time }
            if !unexpired.isEmpty {
                result[entry.key] = unexpired
            }
        }
        rejectedTipTapEpisodesByDevice = rejectedTipTapEpisodesByDevice.reduce(
            into: [:]
        ) { result, entry in
            let unexpired = entry.value.filter { $0.value.deadline > time }
            if !unexpired.isEmpty {
                result[entry.key] = unexpired
            }
        }
        completedTipTapEpisodesByDevice = completedTipTapEpisodesByDevice.reduce(into: [:]) {
            result, entry in
            let unexpired = entry.value.filter { $0.deadline > time }
            if !unexpired.isEmpty {
                result[entry.key] = unexpired
            }
        }
    }

    private func hasCorrelatableTipTapEpisode(deviceID: UInt64) -> Bool {
        nativeCorrelationTipTapEpisodeIDLocked(
            deviceID: deviceID,
            includeRejected: true
        ) != nil
    }

    private func nativeCorrelationTipTapEpisodeIDLocked(
        deviceID: UInt64,
        includeRejected: Bool
    ) -> TrackpadTipTapEpisodeID? {
        let active = activeTipTapEpisodesByDevice[deviceID]?.values.map { $0 } ?? []
        let qualifiedActiveEpisodeIDs = active.filter { !$0.isRejected }.map(\.id)
        guard Set(qualifiedActiveEpisodeIDs.map(\.fixedFingerCount)).count <= 1 else {
            return nil
        }
        var completedEpisodeIDs = completedTipTapEpisodesByDevice[deviceID]?.map(\.id) ?? []
        if let suppressed = tipTapSuppressionByDevice[deviceID] {
            completedEpisodeIDs.append(suppressed)
        }
        completedEpisodeIDs = Array(Set(completedEpisodeIDs))
        guard Set(completedEpisodeIDs.map(\.fixedFingerCount)).count <= 1 else { return nil }

        // A completed successful episode keeps FIFO ownership ahead of a newer active retry in
        // the same fixed-finger group. Competing fixed-finger groups are indistinguishable at the
        // native event tap and must fail open instead of borrowing each other's click.
        let successfulEpisodeIDs = completedEpisodeIDs + qualifiedActiveEpisodeIDs
        guard Set(successfulEpisodeIDs.map(\.fixedFingerCount)).count <= 1 else { return nil }
        let currentEpisodeID = successfulEpisodeIDs.min { $0.sequence < $1.sequence }
        guard includeRejected else { return currentEpisodeID }

        let activeRejectedEpisodeIDs = active.filter(\.isRejected).map(\.id)
        if !activeRejectedEpisodeIDs.isEmpty {
            guard Set(activeRejectedEpisodeIDs.map(\.fixedFingerCount)).count == 1,
                  let activeRejectedEpisodeID = activeRejectedEpisodeIDs.min(by: {
                      $0.sequence < $1.sequence
                  }) else {
                return nil
            }
            if let currentEpisodeID,
               currentEpisodeID.fixedFingerCount == activeRejectedEpisodeID.fixedFingerCount {
                // A failed added contact that is still down owns its native pair ahead of an
                // older completion in the same fixed-finger group.
                return activeRejectedEpisodeID
            }
            if currentEpisodeID == nil {
                return activeRejectedEpisodeID
            }
            // A rejected lower-count recognizer can linger while a higher-count TipTap succeeds.
            // The successful, unambiguous group owns the pair in that overlap.
        }

        let rejected = rejectedTipTapEpisodesByDevice[deviceID]?.values.map(\.id) ?? []
        guard !rejected.isEmpty else { return currentEpisodeID }
        guard rejected.count == 1, let rejectedEpisodeID = rejected.first else { return nil }
        guard let currentEpisodeID else { return rejectedEpisodeID }

        // A failed episode's delayed native click can arrive after a rapid retry has already
        // qualified. Preserve FIFO ownership within the same fixed-finger session: the first
        // native pair still belongs to the older rejected episode and must be replayed before
        // the retry can claim its own pair. Competing fixed-finger groups remain ambiguous.
        guard rejectedEpisodeID.fixedFingerCount == currentEpisodeID.fixedFingerCount,
              rejectedEpisodeID.sequence < currentEpisodeID.sequence else {
            return nil
        }
        if rejectedEpisodeQuarantineByDevice[deviceID]?[rejectedEpisodeID.fixedFingerCount]?.id
            != rejectedEpisodeID {
            // Rejected episodes own late native delivery only for their short pass-through
            // quarantine. After that boundary, a newer qualified episode owns its pair even when
            // worker recognition has not arrived yet; retaining the rejection for the full
            // candidate window would steal the retry's only native pair.
            return currentEpisodeID
        }
        return rejectedEpisodeID
    }

    private func observeTipTapCandidates(
        frame: TrackpadContactFrame,
        at time: TimeInterval
    ) -> (
        didStart: Bool,
        didReject: Bool,
        didEndRejected: Bool,
        recognitionIDs: [TrackpadGesture: TrackpadTipTapEpisodeID]
    ) {
        guard !tipTapGestures.isEmpty else { return (false, false, false, [:]) }
        if frame.contacts.isEmpty {
            zeroContactDeviceIDs.insert(frame.deviceID)
        } else if zeroContactDeviceIDs.remove(frame.deviceID) != nil {
            // Preserve suppression through the terminal zero frame so asynchronous recognition
            // wins any pending native click, then clear retained ownership at the next distinct
            // contact session. A later click cannot be assigned safely to the previous session.
            tipTapSuppressionByDevice.removeValue(forKey: frame.deviceID)
            completedTipTapEpisodesByDevice.removeValue(forKey: frame.deviceID)
            rejectedEpisodeQuarantineByDevice.removeValue(forKey: frame.deviceID)
            rejectedTipTapEpisodesByDevice.removeValue(forKey: frame.deviceID)
            resolvedRejectedNativeClickEpisodeIDs = resolvedRejectedNativeClickEpisodeIDs.filter {
                $0.deviceID != frame.deviceID
            }
        }

        var recognizers = tipTapRecognizersByDevice[frame.deviceID]
            ?? Dictionary(uniqueKeysWithValues: tipTapGestures.compactMap { gesture in
                gesture.tipTapConfiguration.map { configuration in
                    (
                        gesture,
                        TipTapRecognizer(
                            fixedFingerCount: configuration.fixedFingerCount,
                            region: configuration.region
                        )
                    )
                }
            })
        var groupUpdates: [Int: TipTapGroupUpdate] = [:]
        for gesture in tipTapGestures {
            guard var recognizer = recognizers[gesture] else { continue }
            let wasAwaitingAddedContact = recognizer.isAwaitingAddedContact
            let previousRejectionSequence = recognizer.rejectionSequence
            let recognized = recognizer.process(frame)
            var update = groupUpdates[recognizer.fixedFingerCount] ?? TipTapGroupUpdate()
            if recognized {
                update.recognizedGestures.append(gesture)
            }
            if recognizer.rejectionSequence != previousRejectionSequence {
                update.didAddRejection = true
            }
            if wasAwaitingAddedContact,
               recognizer.hasQualifiedAddedContact
                || recognizer.rejectionSequence != previousRejectionSequence {
                update.didStartEpisode = true
            }
            if recognizer.hasQualifiedAddedContact {
                update.hasQualifiedEpisode = true
            }
            update.hasRejectedEpisode = update.hasRejectedEpisode
                || recognizer.isRejectingAddedContactEpisode
            update.isAwaitingAddedContact = update.isAwaitingAddedContact
                || recognizer.isAwaitingAddedContact
            groupUpdates[recognizer.fixedFingerCount] = update
            recognizers[gesture] = recognizer
        }
        let hasQualifiedEpisode = groupUpdates.values.contains { $0.hasQualifiedEpisode }
        let hasRejectedEpisode = groupUpdates.values.contains { $0.hasRejectedEpisode }
        let hasViableGroup = groupUpdates.contains { fixedFingerCount, update in
            update.hasQualifiedEpisode
                || (update.isAwaitingAddedContact
                    && frame.contacts.count == fixedFingerCount)
        }
        let didRecognize = groupUpdates.values.contains { !$0.recognizedGestures.isEmpty }
        if hasRejectedEpisode,
           !hasQualifiedEpisode,
           !hasViableGroup,
           !didRecognize {
            tipTapRejectedDeviceIDs.insert(frame.deviceID)
        } else {
            tipTapRejectedDeviceIDs.remove(frame.deviceID)
        }
        var recognitionIDs: [TrackpadGesture: TrackpadTipTapEpisodeID] = [:]
        var episodesByFixedFingerCount = activeTipTapEpisodesByDevice[frame.deviceID] ?? [:]
        var qualifiedEpisodeIDs: [TrackpadTipTapEpisodeID] = []
        var didStartEpisode = false
        var didRejectTipTap = false
        var didEndRejectedEpisode = false
        for fixedFingerCount in groupUpdates.keys.sorted() {
            guard let update = groupUpdates[fixedFingerCount] else { continue }
            if update.didStartEpisode,
               episodesByFixedFingerCount[fixedFingerCount] == nil {
                let sequence = (nextTipTapSequenceByDevice[frame.deviceID] ?? 0) &+ 1
                nextTipTapSequenceByDevice[frame.deviceID] = sequence
                let episodeID = TrackpadTipTapEpisodeID(
                    deviceID: frame.deviceID,
                    fixedFingerCount: fixedFingerCount,
                    sequence: sequence
                )
                episodesByFixedFingerCount[fixedFingerCount] = TipTapEpisode(
                    id: episodeID,
                    isRejected: false
                )
                latestTipTapEpisodeIDsByDevice[frame.deviceID] = episodeID
                newTipTapEpisodeStarts.append(TrackpadTipTapEpisodeStart(
                    id: episodeID,
                    observedAt: time
                ))
                didStartEpisode = true
            }

            guard var episode = episodesByFixedFingerCount[fixedFingerCount] else {
                continue
            }
            if update.hasQualifiedEpisode {
                qualifiedEpisodeIDs.append(episode.id)
            }
            let didRejectGroup = update.didAddRejection
                && !update.hasQualifiedEpisode
                && update.recognizedGestures.isEmpty
            if didRejectGroup, !episode.isRejected {
                episode.isRejected = true
                episodesByFixedFingerCount[fixedFingerCount] = episode
                if tipTapSuppressionByDevice[frame.deviceID] == episode.id {
                    tipTapSuppressionByDevice.removeValue(forKey: frame.deviceID)
                }
                newTipTapRejectionIDs.append(episode.id)
                didRejectTipTap = true
            }
            for gesture in update.recognizedGestures {
                recognitionIDs[gesture] = episode.id
            }
            let episodeStillActive = update.hasQualifiedEpisode || update.hasRejectedEpisode
            if !episodeStillActive {
                if episode.isRejected {
                    didEndRejectedEpisode = true
                    if tipTapSuppressionByDevice[frame.deviceID] == episode.id {
                        tipTapSuppressionByDevice.removeValue(forKey: frame.deviceID)
                    }
                    if fixedFingerCount == frame.contacts.count,
                       !hasQualifiedEpisode {
                        maximumContactCountsByDevice[frame.deviceID] = frame.contacts.count
                    }
                    rejectedEpisodeQuarantineByDevice[frame.deviceID, default: [:]][
                        fixedFingerCount
                    ] = (
                        episode.id,
                        time + rejectedEpisodeQuarantine
                    )
                    // Keep exact ownership longer than the short pass-through quarantine. If the
                    // rejected native click arrives later, buffer it under the rejected ID so a
                    // new episode start replays it instead of adopting it as the retry's click.
                    if resolvedRejectedNativeClickEpisodeIDs.remove(episode.id) == nil {
                        rejectedTipTapEpisodesByDevice[frame.deviceID, default: [:]][
                            fixedFingerCount
                        ] = (
                            episode.id,
                            time + candidateWindow
                        )
                    }
                    newTipTapRejectionIDs.append(episode.id)
                } else if !update.recognizedGestures.isEmpty {
                    if completedTipTapEpisodesByDevice[frame.deviceID]?.contains(where: {
                        $0.id == episode.id
                    }) != true {
                        completedTipTapEpisodesByDevice[frame.deviceID, default: []].append(
                            RetainedTipTapEpisode(
                                id: episode.id,
                                deadline: time + candidateWindow
                            )
                        )
                    }
                }
                episodesByFixedFingerCount.removeValue(forKey: fixedFingerCount)
            }
        }
        if episodesByFixedFingerCount.isEmpty {
            activeTipTapEpisodesByDevice.removeValue(forKey: frame.deviceID)
        } else {
            activeTipTapEpisodesByDevice[frame.deviceID] = episodesByFixedFingerCount
        }
        if let qualifiedEpisodeID = qualifiedEpisodeIDs.max(by: {
            $0.sequence < $1.sequence
        }) {
            tipTapSuppressionByDevice[frame.deviceID] = qualifiedEpisodeID
        }
        tipTapRecognizersByDevice[frame.deviceID] = recognizers
        return (didStartEpisode, didRejectTipTap, didEndRejectedEpisode, recognitionIDs)
    }
}

struct TrackpadMiddleClickArbiter: Sendable {
    enum Button: Equatable, Hashable, Sendable {
        case left
        case right
    }

    enum NativeEvent: Equatable, Sendable {
        case down(Button)
        case up(Button)
    }

    enum NativeEventOrigin: Equatable, Sendable {
        case trackpad(deviceID: UInt64)
        case contactInferenceAllowed
        case external
        case unknown
    }

    enum CurrentEventDecision: Equatable, Sendable {
        case passThrough
        case suppressAndBuffer
        case suppress
        case rewriteAsMiddle
    }

    enum DeferredAction: Equatable, Sendable {
        case replayBuffered
        case discardBuffered
        case convertBuffered
        case synthesizeMiddleClick
        case releaseConvertedMiddleButton
        case abandonTipTapRecognition(TrackpadTipTapEpisodeID)
    }

    enum RecognitionDisposition: Equatable, Sendable {
        case rejected
        case pending
        case committed
    }

    struct NativeEventOutcome: Equatable, Sendable {
        let decision: CurrentEventDecision
        let deferredActions: [DeferredAction]
        let committedTipTapEpisodeID: TrackpadTipTapEpisodeID?

        init(
            decision: CurrentEventDecision,
            deferredActions: [DeferredAction],
            committedTipTapEpisodeID: TrackpadTipTapEpisodeID? = nil
        ) {
            self.decision = decision
            self.deferredActions = deferredActions
            self.committedTipTapEpisodeID = committedTipTapEpisodeID
        }
    }

    struct RecognitionAttempt: Equatable, Sendable {
        let deferredActions: [DeferredAction]
        let disposition: RecognitionDisposition

        var wasAccepted: Bool { disposition != .rejected }
    }

    private struct PendingRecognition: Equatable, Sendable {
        let deviceID: UInt64
        let tipTapEpisodeID: TrackpadTipTapEpisodeID?
        let resolution: TrackpadNativeClickResolution
        let deadline: TimeInterval
    }

    private let candidateWindow: TimeInterval
    private let postRecognitionWindow: TimeInterval
    private let convertedReleaseWindow: TimeInterval
    private var candidateDeadlinesByDevice: [UInt64: TimeInterval] = [:]
    private var ambiguousDeadlinesByDevice: [UInt64: TimeInterval] = [:]
    private var bufferedEvents: [NativeEvent] = []
    private var bufferedDeviceID: UInt64?
    private var bufferedTipTapEpisodeID: TrackpadTipTapEpisodeID?
    private var bufferedDeadline: TimeInterval?
    private var pendingRecognitions: [PendingRecognition] = []
    private var convertedButton: Button?
    private var convertedDeviceID: UInt64?
    private var convertedReleaseDeadline: TimeInterval?
    private var consumedButton: Button?
    private var consumedDeviceID: UInt64?
    private var consumedReleaseDeadline: TimeInterval?
    private var uncorrelatableNativeEventDeadline: TimeInterval?
    private var uncorrelatedTrackpadDeadlinesByDevice: [UInt64: TimeInterval] = [:]

    init(
        candidateWindow: TimeInterval = 0.32,
        postRecognitionWindow: TimeInterval = 0.08,
        convertedReleaseWindow: TimeInterval = 5
    ) {
        self.candidateWindow = candidateWindow
        self.postRecognitionWindow = postRecognitionWindow
        self.convertedReleaseWindow = convertedReleaseWindow
    }

    var nextDeadline: TimeInterval? {
        // Candidate-only state is pruned by the next contact/native/recognition input and has no
        // externally visible timeout action. Schedule work only when an event must be replayed or
        // a recognized gesture may need synthesis.
        let deadlines = [
            bufferedDeadline,
            pendingRecognitions.map(\.deadline).min(),
            convertedReleaseDeadline,
            consumedReleaseDeadline,
        ].compactMap { $0 }
        return deadlines.min()
    }

    var pendingBufferedTipTapEpisodeID: TrackpadTipTapEpisodeID? {
        bufferedTipTapEpisodeID
    }

    var pendingRecognizedTipTapEpisodeID: TrackpadTipTapEpisodeID? {
        pendingRecognitions.compactMap(\.tipTapEpisodeID).first
    }

    func pendingRecognizedTipTapEpisodeID(deviceID: UInt64) -> TrackpadTipTapEpisodeID? {
        pendingRecognitions.first {
            $0.deviceID == deviceID && $0.tipTapEpisodeID != nil
        }?.tipTapEpisodeID
    }

    @discardableResult
    mutating func observeCandidate(
        deviceID: UInt64,
        at time: TimeInterval,
        isAmbiguous: Bool = false
    ) -> [DeferredAction] {
        let actions = expire(at: time)
        let deadline = time + candidateWindow
        candidateDeadlinesByDevice[deviceID] = deadline
        if isAmbiguous
            || ambiguousDeadlinesByDevice[deviceID] != nil
            || uncorrelatableNativeEventDeadline.map({ $0 > time }) == true
            || uncorrelatedTrackpadDeadlinesByDevice[deviceID].map({ $0 > time }) == true {
            ambiguousDeadlinesByDevice[deviceID] = deadline
        }
        return actions
    }

    mutating func recognize(
        deviceID: UInt64,
        tipTapEpisodeID: TrackpadTipTapEpisodeID? = nil,
        resolution: TrackpadNativeClickResolution = .middleClick,
        at time: TimeInterval
    ) -> [DeferredAction] {
        attemptRecognition(
            deviceID: deviceID,
            tipTapEpisodeID: tipTapEpisodeID,
            resolution: resolution,
            at: time
        )
            .deferredActions
    }

    mutating func attemptRecognition(
        deviceID: UInt64,
        tipTapEpisodeID: TrackpadTipTapEpisodeID? = nil,
        resolution: TrackpadNativeClickResolution = .middleClick,
        at time: TimeInterval,
        hasNewerTipTapEpisode: Bool = false
    ) -> RecognitionAttempt {
        var actions = expire(at: time)
        let activeCandidateIDs = Set(candidateDeadlinesByDevice.keys)
        guard activeCandidateIDs == [deviceID],
              ambiguousDeadlinesByDevice[deviceID] == nil
        else {
            if !bufferedEvents.isEmpty {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
            }
            clearBufferedState()
            if let tipTapEpisodeID {
                actions.append(contentsOf: abandonRecognition(
                    tipTapEpisodeID: tipTapEpisodeID
                ))
            } else {
                actions.append(contentsOf: abandonRecognitionState())
            }
            return RecognitionAttempt(deferredActions: actions, disposition: .rejected)
        }

        if tipTapEpisodeID != nil, hasNewerTipTapEpisode, !bufferedEvents.isEmpty,
           bufferedTipTapEpisodeID != tipTapEpisodeID {
            if let tipTapEpisodeID {
                actions.append(contentsOf: abandonRecognition(
                    tipTapEpisodeID: tipTapEpisodeID
                ))
            }
            return RecognitionAttempt(deferredActions: actions, disposition: .rejected)
        }

        if !bufferedEvents.isEmpty {
            guard bufferedDeviceID == deviceID,
                  let downButton = validBufferedDownButton()
            else {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
                if let tipTapEpisodeID {
                    actions.append(contentsOf: abandonRecognition(
                        tipTapEpisodeID: tipTapEpisodeID
                    ))
                } else {
                    actions.append(contentsOf: abandonRecognitionState())
                }
                return RecognitionAttempt(deferredActions: actions, disposition: .rejected)
            }
            if let tipTapEpisodeID,
               bufferedTipTapEpisodeID != tipTapEpisodeID {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
                actions.append(contentsOf: abandonRecognition(
                    tipTapEpisodeID: tipTapEpisodeID
                ))
                return RecognitionAttempt(deferredActions: actions, disposition: .rejected)
            }
            actions.append(resolution == .middleClick ? .convertBuffered : .discardBuffered)
            if bufferedEvents.count == 1 {
                if resolution == .middleClick {
                    beginConvertedClick(button: downButton, deviceID: deviceID, at: time)
                } else {
                    beginConsumedClick(button: downButton, deviceID: deviceID, at: time)
                }
            }
            clearBufferedState()
            if let tipTapEpisodeID {
                removeRecognition(tipTapEpisodeID: tipTapEpisodeID)
            } else {
                clearRecognitionState()
            }
            return RecognitionAttempt(deferredActions: actions, disposition: .committed)
        }

        // Native click delivery can lag recognition. Keep the fallback pending until both the
        // short post-recognition grace period and the complete candidate ambiguity window have
        // elapsed, so a late unknown/external click can still cancel synthesis.
        let deadline = max(
            time + postRecognitionWindow,
            candidateDeadlinesByDevice[deviceID] ?? time
        )
        if let tipTapEpisodeID {
            removeRecognition(tipTapEpisodeID: tipTapEpisodeID)
        } else {
            pendingRecognitions.removeAll { $0.tipTapEpisodeID == nil }
        }
        pendingRecognitions.append(PendingRecognition(
            deviceID: deviceID,
            tipTapEpisodeID: tipTapEpisodeID,
            resolution: resolution,
            deadline: deadline
        ))
        pendingRecognitions.sort {
            switch ($0.tipTapEpisodeID, $1.tipTapEpisodeID) {
            case let (lhs?, rhs?):
                lhs.sequence < rhs.sequence
            case (nil, nil):
                $0.deadline < $1.deadline
            case (nil, _):
                true
            case (_, nil):
                false
            }
        }
        return RecognitionAttempt(deferredActions: actions, disposition: .pending)
    }

    mutating func rejectBufferedCandidate(
        tipTapEpisodeID: TrackpadTipTapEpisodeID,
        at time: TimeInterval
    ) -> [DeferredAction] {
        var actions = cancelPendingRecognition(
            tipTapEpisodeID: tipTapEpisodeID,
            at: time
        )
        guard !bufferedEvents.isEmpty,
              bufferedDeviceID == tipTapEpisodeID.deviceID,
              bufferedTipTapEpisodeID == tipTapEpisodeID else {
            return actions
        }
        actions.append(.replayBuffered)
        clearBufferedState()
        return actions
    }

    mutating func cancelPendingRecognition(
        tipTapEpisodeID: TrackpadTipTapEpisodeID,
        at time: TimeInterval
    ) -> [DeferredAction] {
        var actions = expire(at: time)
        actions.append(contentsOf: abandonRecognition(tipTapEpisodeID: tipTapEpisodeID))
        return actions
    }

    mutating func beginTipTapEpisode(
        _ start: TrackpadTipTapEpisodeStart,
        at time: TimeInterval
    ) -> [DeferredAction] {
        let tipTapEpisodeID = start.id
        if !bufferedEvents.isEmpty,
           bufferedDeviceID == tipTapEpisodeID.deviceID,
           bufferedTipTapEpisodeID == nil,
           bufferedDeadline.map({ $0 >= start.observedAt }) == true {
            bufferedTipTapEpisodeID = tipTapEpisodeID
            bufferedDeadline = start.observedAt + candidateWindow
        }
        var actions = expire(at: time)
        if !bufferedEvents.isEmpty,
           bufferedDeviceID == tipTapEpisodeID.deviceID {
            if bufferedTipTapEpisodeID != tipTapEpisodeID {
                actions.append(.replayBuffered)
                clearBufferedState()
            }
        }
        return actions
    }

    mutating func handleNativeEvent(
        _ event: NativeEvent,
        origin: NativeEventOrigin,
        at time: TimeInterval,
        tipTapEpisodeID: TrackpadTipTapEpisodeID? = nil,
        bufferingWindow: TimeInterval? = nil
    ) -> NativeEventOutcome {
        var actions = expire(at: time)

        if let convertedButton, let convertedDeviceID {
            if event == .up(convertedButton), origin == .trackpad(deviceID: convertedDeviceID) {
                clearConvertedState()
                return NativeEventOutcome(
                    decision: .rewriteAsMiddle,
                    deferredActions: actions
                )
            }
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        if let consumedButton, let consumedDeviceID {
            if event == .up(consumedButton), origin == .trackpad(deviceID: consumedDeviceID) {
                clearConsumedState()
                return NativeEventOutcome(decision: .suppress, deferredActions: actions)
            }
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        guard case let .trackpad(originDeviceID) = origin else {
            if !bufferedEvents.isEmpty {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
            }
            if event.isDown {
                markNativeEventUncorrelatable(at: time)
            }
            actions.append(contentsOf: abandonRecognitionState())
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        if let recognition = pendingRecognitions.first(where: {
            $0.deviceID == originDeviceID && $0.tipTapEpisodeID == tipTapEpisodeID
        }) {
            // The native source and retained episode already identify this device exactly. A
            // simultaneous candidate on another trackpad must not invalidate that ownership;
            // same-device ambiguity remains fail-open.
            guard candidateDeadlinesByDevice[recognition.deviceID] != nil,
                  ambiguousDeadlinesByDevice[recognition.deviceID] == nil else {
                actions.append(contentsOf: abandonRecognition(recognition))
                return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
            }
            switch event {
            case let .down(button):
                let committedTipTapEpisodeID = recognition.tipTapEpisodeID
                if recognition.resolution == .middleClick {
                    beginConvertedClick(button: button, deviceID: recognition.deviceID, at: time)
                } else {
                    beginConsumedClick(button: button, deviceID: recognition.deviceID, at: time)
                }
                removeRecognition(recognition)
                return NativeEventOutcome(
                    decision: recognition.resolution == .middleClick ? .rewriteAsMiddle : .suppress,
                    deferredActions: actions,
                    committedTipTapEpisodeID: committedTipTapEpisodeID
                )
            case .up:
                // Seeing an Up without its Down means correlation is ambiguous. Preserve the
                // native event and do not add a synthetic middle click.
                actions.append(contentsOf: abandonRecognition(recognition))
                return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
            }
        }

        if !bufferedEvents.isEmpty {
            guard let downButton = validBufferedDownButton() else {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
                return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
            }
            if event == .up(downButton), bufferedEvents.count == 1 {
                bufferedEvents.append(event)
                return NativeEventOutcome(
                    decision: .suppressAndBuffer,
                    deferredActions: actions
                )
            }
            actions.append(.replayBuffered)
            markBufferedDeviceAmbiguous()
            clearBufferedState()
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        guard case .down = event else {
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }
        guard candidateDeadlinesByDevice.count == 1,
              let candidateDeviceID = candidateDeadlinesByDevice.keys.first,
              originDeviceID == candidateDeviceID,
              ambiguousDeadlinesByDevice[candidateDeviceID] == nil
        else {
            markTrackpadEventUncorrelated(deviceID: originDeviceID, at: time)
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        bufferedEvents = [event]
        bufferedDeviceID = candidateDeviceID
        bufferedTipTapEpisodeID = tipTapEpisodeID
        bufferedDeadline = time + (bufferingWindow ?? candidateWindow)
        return NativeEventOutcome(
            decision: .suppressAndBuffer,
            deferredActions: actions
        )
    }

    mutating func expire(at time: TimeInterval) -> [DeferredAction] {
        candidateDeadlinesByDevice = candidateDeadlinesByDevice.filter { $0.value > time }
        ambiguousDeadlinesByDevice = ambiguousDeadlinesByDevice.filter { $0.value > time }
        uncorrelatedTrackpadDeadlinesByDevice = uncorrelatedTrackpadDeadlinesByDevice.filter {
            $0.value > time
        }
        if let deadline = uncorrelatableNativeEventDeadline, deadline <= time {
            uncorrelatableNativeEventDeadline = nil
        }
        var actions: [DeferredAction] = []

        if let bufferedDeadline, bufferedDeadline <= time, !bufferedEvents.isEmpty {
            actions.append(.replayBuffered)
            markBufferedDeviceAmbiguous()
            clearBufferedState()
        }
        let expiredRecognitions = pendingRecognitions.filter { $0.deadline <= time }
        for recognition in expiredRecognitions {
            if recognition.tipTapEpisodeID == nil, recognition.resolution == .middleClick {
                actions.append(.synthesizeMiddleClick)
            } else if let episodeID = recognition.tipTapEpisodeID {
                actions.append(.abandonTipTapRecognition(episodeID))
            }
        }
        pendingRecognitions.removeAll { $0.deadline <= time }
        if let convertedReleaseDeadline, convertedReleaseDeadline <= time, convertedButton != nil {
            actions.append(.releaseConvertedMiddleButton)
            clearConvertedState()
        }
        if let consumedReleaseDeadline, consumedReleaseDeadline <= time {
            clearConsumedState()
        }
        return actions
    }

    mutating func reset() -> [DeferredAction] {
        var actions: [DeferredAction] = bufferedEvents.isEmpty ? [] : [.replayBuffered]
        if convertedButton != nil {
            actions.append(.releaseConvertedMiddleButton)
        }
        actions.append(contentsOf: pendingRecognitions.compactMap { recognition in
            recognition.tipTapEpisodeID.map(DeferredAction.abandonTipTapRecognition)
        })
        candidateDeadlinesByDevice.removeAll()
        ambiguousDeadlinesByDevice.removeAll()
        uncorrelatableNativeEventDeadline = nil
        uncorrelatedTrackpadDeadlinesByDevice.removeAll()
        clearBufferedState()
        clearRecognitionState()
        clearConvertedState()
        clearConsumedState()
        return actions
    }

    /// Cancels work whose action mapping may have changed while preserving the disposition of
    /// native Down events that have already been consumed or converted. Their matching Up events
    /// must still follow the original decision even after a configuration edit.
    mutating func invalidatePendingRecognitionsForConfigurationChange() -> [DeferredAction] {
        var actions: [DeferredAction] = bufferedEvents.isEmpty ? [] : [.replayBuffered]
        actions.append(contentsOf: pendingRecognitions.compactMap { recognition in
            recognition.tipTapEpisodeID.map(DeferredAction.abandonTipTapRecognition)
        })
        candidateDeadlinesByDevice.removeAll()
        ambiguousDeadlinesByDevice.removeAll()
        uncorrelatableNativeEventDeadline = nil
        uncorrelatedTrackpadDeadlinesByDevice.removeAll()
        clearBufferedState()
        clearRecognitionState()
        return actions
    }

    private func validBufferedDownButton() -> Button? {
        guard case let .down(button)? = bufferedEvents.first,
              bufferedEvents.count <= 2
        else {
            return nil
        }
        if bufferedEvents.count == 2, bufferedEvents[1] != .up(button) {
            return nil
        }
        return button
    }

    private mutating func clearBufferedState() {
        bufferedEvents.removeAll()
        bufferedDeviceID = nil
        bufferedTipTapEpisodeID = nil
        bufferedDeadline = nil
    }

    private mutating func clearRecognitionState() {
        pendingRecognitions.removeAll()
    }

    private mutating func abandonRecognitionState() -> [DeferredAction] {
        let actions = pendingRecognitions.compactMap { recognition in
            recognition.tipTapEpisodeID.map(DeferredAction.abandonTipTapRecognition)
        }
        clearRecognitionState()
        return actions
    }

    private mutating func removeRecognition(tipTapEpisodeID: TrackpadTipTapEpisodeID) {
        pendingRecognitions.removeAll { $0.tipTapEpisodeID == tipTapEpisodeID }
    }

    private mutating func abandonRecognition(
        tipTapEpisodeID: TrackpadTipTapEpisodeID
    ) -> [DeferredAction] {
        let wasPending = pendingRecognitions.contains {
            $0.tipTapEpisodeID == tipTapEpisodeID
        }
        removeRecognition(tipTapEpisodeID: tipTapEpisodeID)
        return wasPending ? [.abandonTipTapRecognition(tipTapEpisodeID)] : []
    }

    private mutating func removeRecognition(_ recognition: PendingRecognition) {
        pendingRecognitions.removeAll { $0 == recognition }
    }

    private mutating func abandonRecognition(
        _ recognition: PendingRecognition
    ) -> [DeferredAction] {
        removeRecognition(recognition)
        return recognition.tipTapEpisodeID.map {
            [.abandonTipTapRecognition($0)]
        } ?? []
    }

    private mutating func beginConvertedClick(
        button: Button,
        deviceID: UInt64,
        at time: TimeInterval
    ) {
        convertedButton = button
        convertedDeviceID = deviceID
        convertedReleaseDeadline = time + convertedReleaseWindow
    }

    private mutating func clearConvertedState() {
        convertedButton = nil
        convertedDeviceID = nil
        convertedReleaseDeadline = nil
    }

    private mutating func beginConsumedClick(
        button: Button,
        deviceID: UInt64,
        at time: TimeInterval
    ) {
        consumedButton = button
        consumedDeviceID = deviceID
        consumedReleaseDeadline = time + convertedReleaseWindow
    }

    private mutating func clearConsumedState() {
        consumedButton = nil
        consumedDeviceID = nil
        consumedReleaseDeadline = nil
    }

    private mutating func markNativeEventUncorrelatable(at time: TimeInterval) {
        let deadline = time + candidateWindow
        uncorrelatableNativeEventDeadline = deadline
        for deviceID in candidateDeadlinesByDevice.keys {
            ambiguousDeadlinesByDevice[deviceID] = candidateDeadlinesByDevice[deviceID]
        }
    }

    private mutating func markTrackpadEventUncorrelated(
        deviceID: UInt64,
        at time: TimeInterval
    ) {
        let deadline = time + candidateWindow
        uncorrelatedTrackpadDeadlinesByDevice[deviceID] = deadline
        if candidateDeadlinesByDevice[deviceID] != nil {
            ambiguousDeadlinesByDevice[deviceID] = deadline
        }
    }

    private mutating func markBufferedDeviceAmbiguous() {
        guard let bufferedDeviceID,
              let candidateDeadline = candidateDeadlinesByDevice[bufferedDeviceID]
        else {
            return
        }
        ambiguousDeadlinesByDevice[bufferedDeviceID] = candidateDeadline
    }
}

/// Synchronously processes events delivered by a CGEvent tap installed on the
/// main CFRunLoop. Its methods are called only from the main thread, including
/// expiration work scheduled on DispatchQueue.main, but it intentionally does
/// not use MainActor isolation because CFRunLoop callbacks do not carry Swift
/// executor metadata.
final class TrackpadMiddleClickCoordinator: @unchecked Sendable {
    static let replayMarker: Int64 = 0x4D_54_4D_49_44_44_4C_45

    private var arbiter = TrackpadMiddleClickArbiter()
    private var clickResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = [:]
    private var physicalClicksByFingerCount: [Int: TrackpadGesture] = [:]
    private var bufferedEvents: [CGEvent] = []
    private var expirationWorkItem: DispatchWorkItem?
    private var pendingPhysicalClick: PendingPhysicalClick?
    private var observedTipTapRecognitionIDs:
        [TrackpadGesture: [UInt64: TrackpadTipTapEpisodeID]] = [:]
    private struct NativeClickKey: Hashable {
        let button: TrackpadMiddleClickArbiter.Button
        let eventNumber: Int64
    }

    private enum NativeClickTerminalDisposition {
        case converted
        case consumed
    }

    private struct NativeClickOwnership {
        let origin: TrackpadMiddleClickArbiter.NativeEventOrigin
        let tipTapEpisodeID: TrackpadTipTapEpisodeID?
        let beganAt: TimeInterval
        let terminalDisposition: NativeClickTerminalDisposition?
        let suppressOriginalUpAfterReset: Bool
    }

    private struct AmbiguousNativeClickState {
        var outstandingDownCount: Int
        let beganAt: TimeInterval
    }

    private var nativeOriginsByClick:
        [NativeClickKey: NativeClickOwnership] = [:]
    private var ambiguousNativeDownDepthByButton:
        [TrackpadMiddleClickArbiter.Button: AmbiguousNativeClickState] = [:]
    static let nativeClickOwnershipWindow: TimeInterval = 5
    private let maximumOutstandingNativeClicksPerButton = 16
    // A native click can precede its added-contact frame. One short frame-ordering window is used
    // only while the same fixed contacts are already armed for a configured TipTap.
    private let tipTapOrderingWindow: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let synthesizeMiddleClick: () -> Void
    private let releaseMiddleButton: () -> Void
    private let postEvent: (CGEvent) -> Void
    private let candidateTimeline: TrackpadMiddleClickCandidateTimeline
    private let eventOrigin: (CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin
    private let allowsContactInference: @Sendable () -> Bool
    private let recognizePhysicalClick: @Sendable (TrackpadGesture, UInt64) -> Void
    private let commitTipTapRecognition: @Sendable (TrackpadTipTapEpisodeID) -> Void
    private let abandonTipTapRecognition: @Sendable (TrackpadTipTapEpisodeID) -> Void

    private struct PendingPhysicalClick {
        let gesture: TrackpadGesture
        let deviceID: UInt64
        let episodeID: UInt64
        let resolution: TrackpadNativeClickResolution
        let deadline: TimeInterval
    }

    init(
        clock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        synthesizeMiddleClick: @escaping () -> Void = {
            TrackpadMiddleClickEventPoster.postClick()
        },
        releaseMiddleButton: @escaping () -> Void = {
            TrackpadMiddleClickEventPoster.postButtonUp(
                eventSourceMarker: TrackpadMiddleClickCoordinator.replayMarker
            )
        },
        postEvent: @escaping (CGEvent) -> Void = {
            $0.post(tap: .cghidEventTap)
        },
        tipTapOrderingWindow: TimeInterval = 0.02,
        candidateTimeline: TrackpadMiddleClickCandidateTimeline = .init(),
        recognizePhysicalClick: @escaping @Sendable (TrackpadGesture, UInt64) -> Void = { _, _ in },
        commitTipTapRecognition: @escaping @Sendable (TrackpadTipTapEpisodeID) -> Void = { _ in },
        abandonTipTapRecognition: @escaping @Sendable (TrackpadTipTapEpisodeID) -> Void = { _ in },
        // Direct coordinator construction is a unit-test seam. The production session always
        // injects the exhaustive live HID inventory check.
        allowsContactInference: @escaping @Sendable () -> Bool = { true },
        eventOrigin: @escaping (CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin = { _ in
            // Unknown is deliberately fail-open. Production explicitly authorizes contact
            // inference only after checking that every live mouse-capable HID service belongs to
            // a Multitouch trackpad.
            .unknown
        }
    ) {
        self.clock = clock
        self.synthesizeMiddleClick = synthesizeMiddleClick
        self.releaseMiddleButton = releaseMiddleButton
        self.postEvent = postEvent
        self.tipTapOrderingWindow = tipTapOrderingWindow
        self.candidateTimeline = candidateTimeline
        self.recognizePhysicalClick = recognizePhysicalClick
        self.commitTipTapRecognition = commitTipTapRecognition
        self.abandonTipTapRecognition = abandonTipTapRecognition
        self.allowsContactInference = allowsContactInference
        self.eventOrigin = eventOrigin
    }

    func updateClickResolutions(_ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]) {
        guard resolutions != clickResolutions else { return }
        invalidatePendingRecognitionsForConfigurationChange()
        let gestures = Set(resolutions.keys)
        let gestureShapeChanged = gestures != Set(clickResolutions.keys)
        clickResolutions = resolutions
        physicalClicksByFingerCount = Dictionary(uniqueKeysWithValues: resolutions.keys.compactMap {
            gesture in
            gesture.physicalClickFingerCount.map { ($0, gesture) }
        })
        if gestureShapeChanged {
            candidateTimeline.update(gestures: gestures)
        }
        scheduleExpiration()
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        updateClickResolutions(Dictionary(uniqueKeysWithValues: gestures.map { ($0, .middleClick) }))
    }

    func observe(frame: TrackpadContactFrame) {
        let now = clock()
        pruneNativeClickOwnership(at: now)
        let observation = candidateTimeline.observe(frame: frame, at: now)
        for (gesture, episodeID) in observation.tipTapRecognitionIDs {
            observedTipTapRecognitionIDs[gesture, default: [:]][frame.deviceID] = episodeID
        }
        candidateTimelineDidUpdate(at: now)
    }

    /// Drains state recorded synchronously by the raw Multitouch callback. Production frame
    /// ingestion updates the shared, locked timeline directly so the CGEvent tap can observe the
    /// newest candidate before a native click arrives; coordinator mutations remain on main.
    func candidateTimelineDidUpdate() {
        candidateTimelineDidUpdate(at: clock())
    }

    @discardableResult
    func recognize(
        gesture: TrackpadGesture? = nil,
        deviceID: UInt64,
        tipTapEpisodeID: TrackpadTipTapEpisodeID? = nil,
        resolution: TrackpadNativeClickResolution = .middleClick
    ) -> Bool {
        let now = clock()
        drainTipTapStateChanges(at: now)
        if pendingPhysicalClick?.deviceID == deviceID {
            pendingPhysicalClick = nil
        }
        let resolvedTipTapEpisodeID = tipTapEpisodeID
            ?? gesture.flatMap { observedTipTapRecognitionIDs[$0]?[deviceID] }
        if let gesture, gesture.tipTapConfiguration != nil, resolvedTipTapEpisodeID == nil {
            return false
        }
        // An ordinary tap or long touch can request a synthesized middle click without a
        // correlated native event. When another pointer makes native-click ownership
        // ambiguous, fail open before creating that pending synthesis just as TipTap does.
        if resolvedTipTapEpisodeID == nil,
           resolution == .middleClick,
           !allowsContactInference() {
            synchronizeCandidates(at: now)
            scheduleExpiration()
            return false
        }
        if let resolvedTipTapEpisodeID, !allowsContactInference() {
            process(arbiter.rejectBufferedCandidate(
                tipTapEpisodeID: resolvedTipTapEpisodeID,
                at: now
            ))
            candidateTimeline.completeTipTapRecognition(resolvedTipTapEpisodeID)
            removeObservedTipTapRecognitionID(resolvedTipTapEpisodeID)
            scheduleExpiration()
            return false
        }
        synchronizeCandidates(at: now)
        let attempt = arbiter.attemptRecognition(
            deviceID: deviceID,
            tipTapEpisodeID: resolvedTipTapEpisodeID,
            resolution: resolution,
            at: now,
            hasNewerTipTapEpisode: resolvedTipTapEpisodeID.map {
                candidateTimeline.hasNewerTipTapEpisode(than: $0)
            } ?? false
        )
        process(attempt.deferredActions)
        if attempt.disposition == .committed, let resolvedTipTapEpisodeID {
            candidateTimeline.completeTipTapRecognition(resolvedTipTapEpisodeID)
            removeObservedTipTapRecognitionID(resolvedTipTapEpisodeID)
            commitTipTapRecognition(resolvedTipTapEpisodeID)
        }
        scheduleExpiration()
        return attempt.wasAccepted
    }

    func handleNativeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        guard let nativeEvent = nativeEvent(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        let now = clock()
        pruneNativeClickOwnership(at: now)
        // A retrying native Down can overtake the main-queue notification posted by the frame
        // callback. Drain first so a failed episode's buffered click cannot taint this event.
        drainTipTapStateChanges(at: now)
        let clickKey = NativeClickKey(
            button: nativeEvent.button,
            eventNumber: event.getIntegerValueField(.mouseEventNumber)
        )
        let origin: TrackpadMiddleClickArbiter.NativeEventOrigin
        var ownedTipTapEpisodeID: TrackpadTipTapEpisodeID?
        var suppressOriginalUpAfterReset = false
        var suppressExpiredTerminalUp = false
        if nativeEvent.isDown,
           var ambiguous = ambiguousNativeDownDepthByButton[nativeEvent.button] {
            ambiguous.outstandingDownCount += 1
            ambiguousNativeDownDepthByButton[nativeEvent.button] = ambiguous
            origin = .unknown
        } else if nativeEvent.isDown,
                  nativeOriginsByClick[clickKey] != nil
                    || nativeOriginsByClick.keys.filter({
                        $0.button == nativeEvent.button
                    }).count >= maximumOutstandingNativeClicksPerButton {
            let outstandingCount = nativeOriginsByClick.keys.filter {
                $0.button == nativeEvent.button
            }.count
            nativeOriginsByClick = nativeOriginsByClick.filter {
                $0.key.button != nativeEvent.button
            }
            ambiguousNativeDownDepthByButton[nativeEvent.button] = AmbiguousNativeClickState(
                outstandingDownCount: outstandingCount + 1,
                beganAt: now
            )
            pendingPhysicalClick = nil
            process(arbiter.reset())
            origin = .unknown
        } else if !nativeEvent.isDown,
                  var ambiguous = ambiguousNativeDownDepthByButton[nativeEvent.button] {
            if ambiguous.outstandingDownCount <= 1 {
                ambiguousNativeDownDepthByButton.removeValue(forKey: nativeEvent.button)
            } else {
                ambiguous.outstandingDownCount -= 1
                ambiguousNativeDownDepthByButton[nativeEvent.button] = ambiguous
            }
            origin = .unknown
        } else if !nativeEvent.isDown,
                  let ownership = nativeOriginsByClick.removeValue(forKey: clickKey) {
            origin = ownership.origin
            ownedTipTapEpisodeID = ownership.tipTapEpisodeID
            suppressOriginalUpAfterReset = ownership.suppressOriginalUpAfterReset
            suppressExpiredTerminalUp = ownership.terminalDisposition != nil
                && !ownership.suppressOriginalUpAfterReset
                && now - ownership.beganAt >= Self.nativeClickOwnershipWindow
        } else if !nativeEvent.isDown {
            // An unmatched Up must not borrow current contact state from another click.
            origin = .unknown
        } else {
            let reportedOrigin = eventOrigin(event)
            if reportedOrigin == .contactInferenceAllowed,
               let inferredOrigin = candidateTimeline.inferredTrackpadOrigin(at: now) {
                origin = inferredOrigin
            } else {
                origin = reportedOrigin
            }
            nativeOriginsByClick[clickKey] = NativeClickOwnership(
                origin: origin,
                tipTapEpisodeID: nil,
                beganAt: now,
                terminalDisposition: nil,
                suppressOriginalUpAfterReset: false
            )
        }
        if suppressOriginalUpAfterReset {
            scheduleExpiration()
            return nil
        }
        if suppressExpiredTerminalUp {
            // The watchdog may already have balanced a converted middle-button Down,
            // but the exact original Up must still follow the consumed disposition.
            synchronizeCandidates(at: now)
            scheduleExpiration()
            return nil
        }
        candidateTimeline.observeNativeEvent(
            origin: origin,
            isDown: nativeEvent.isDown,
            at: now
        )
        if let deviceID = origin.trackpadDeviceID,
           candidateTimeline.activeTipTapEpisodeID(deviceID: deviceID) == nil,
           candidateTimeline.isQuarantiningRejectedTipTap(deviceID: deviceID, at: now) {
            let rejectedEpisodeID = ownedTipTapEpisodeID
                ?? candidateTimeline.nativeCorrelationTipTapEpisodeID(
                    deviceID: deviceID,
                    at: now
                )
            if nativeEvent.isDown, let ownership = nativeOriginsByClick[clickKey] {
                nativeOriginsByClick[clickKey] = NativeClickOwnership(
                    origin: ownership.origin,
                    tipTapEpisodeID: rejectedEpisodeID,
                    beganAt: ownership.beganAt,
                    terminalDisposition: ownership.terminalDisposition,
                    suppressOriginalUpAfterReset: ownership.suppressOriginalUpAfterReset
                )
            } else if let rejectedEpisodeID {
                candidateTimeline.completeRejectedNativeClick(rejectedEpisodeID)
            }
            scheduleExpiration()
            return Unmanaged.passUnretained(event)
        }
        if nativeEvent.isDown,
           pendingPhysicalClick?.deviceID != origin.trackpadDeviceID {
            pendingPhysicalClick = nil
        }
        synchronizeCandidates(at: now)
        let currentTipTapEpisodeID = origin.trackpadDeviceID.flatMap { deviceID in
            candidateTimeline.nativeCorrelationTipTapEpisodeID(
                deviceID: deviceID,
                at: now
            )
        }
        let activeTipTapEpisodeID = ownedTipTapEpisodeID ?? currentTipTapEpisodeID
        if nativeEvent.isDown, var ownership = nativeOriginsByClick[clickKey] {
            ownership = NativeClickOwnership(
                origin: ownership.origin,
                tipTapEpisodeID: activeTipTapEpisodeID,
                beganAt: ownership.beganAt,
                terminalDisposition: ownership.terminalDisposition,
                suppressOriginalUpAfterReset: ownership.suppressOriginalUpAfterReset
            )
            nativeOriginsByClick[clickKey] = ownership
        }
        let isRetainedRejectedTipTapOwnership = activeTipTapEpisodeID.map {
            candidateTimeline.isRetainingRejectedTipTapEpisode($0, at: now)
        } ?? false
        let physicalCandidate = nativeEvent.isDown
            ? candidateTimeline.activePhysicalClickCandidate(at: now)
            : nil
        var recognizedPhysicalClick: (gesture: TrackpadGesture, deviceID: UInt64)?
        let isAwaitingTipTapAddedContact = physicalCandidate.map {
            candidateTimeline.shouldDeferPhysicalClick($0)
        } ?? false
        var hasDeferredPhysicalClick = false
        if nativeEvent.isDown,
           case let .trackpad(deviceID) = origin,
           let candidate = physicalCandidate,
           candidate.deviceID == deviceID,
           let gesture = physicalClicksByFingerCount[candidate.contactCount],
           let resolution = clickResolutions[gesture] {
            if isAwaitingTipTapAddedContact {
                pendingPhysicalClick = PendingPhysicalClick(
                    gesture: gesture,
                    deviceID: deviceID,
                    episodeID: candidate.episodeID,
                    resolution: resolution,
                    deadline: now + tipTapOrderingWindow
                )
                hasDeferredPhysicalClick = true
            } else {
                let attempt = arbiter.attemptRecognition(
                    deviceID: deviceID,
                    resolution: resolution,
                    at: now
                )
                process(attempt.deferredActions)
                if attempt.wasAccepted {
                    recognizedPhysicalClick = (gesture, deviceID)
                }
            }
        }
        let outcome = arbiter.handleNativeEvent(
            nativeEvent,
            origin: origin,
            at: now,
            tipTapEpisodeID: activeTipTapEpisodeID,
            bufferingWindow: activeTipTapEpisodeID == nil
                && isAwaitingTipTapAddedContact
                && !hasDeferredPhysicalClick
                ? tipTapOrderingWindow
                : nil
        )
        if nativeEvent.isDown {
            switch outcome.decision {
            case .rewriteAsMiddle:
                markTerminalDisposition(.converted, for: clickKey)
            case .suppress:
                markTerminalDisposition(.consumed, for: clickKey)
            case .passThrough, .suppressAndBuffer:
                break
            }
        }
        process(outcome.deferredActions)
        if let committedTipTapEpisodeID = outcome.committedTipTapEpisodeID {
            candidateTimeline.completeTipTapRecognition(committedTipTapEpisodeID)
            removeObservedTipTapRecognitionID(committedTipTapEpisodeID)
            commitTipTapRecognition(committedTipTapEpisodeID)
        }
        defer { scheduleExpiration() }

        switch outcome.decision {
        case .passThrough:
            if !nativeEvent.isDown,
               isRetainedRejectedTipTapOwnership,
               let activeTipTapEpisodeID {
                candidateTimeline.completeRejectedNativeClick(activeTipTapEpisodeID)
            }
            return Unmanaged.passUnretained(event)
        case .rewriteAsMiddle:
            if let recognizedPhysicalClick {
                recognizePhysicalClick(
                    recognizedPhysicalClick.gesture,
                    recognizedPhysicalClick.deviceID
                )
            }
            rewriteAsMiddle(event, isDown: nativeEvent.isDown)
            if !nativeEvent.isDown,
               isRetainedRejectedTipTapOwnership,
               let activeTipTapEpisodeID {
                candidateTimeline.completeRejectedNativeClick(activeTipTapEpisodeID)
            }
            return Unmanaged.passUnretained(event)
        case .suppress:
            if let recognizedPhysicalClick {
                recognizePhysicalClick(
                    recognizedPhysicalClick.gesture,
                    recognizedPhysicalClick.deviceID
                )
            }
            if !nativeEvent.isDown,
               isRetainedRejectedTipTapOwnership,
               let activeTipTapEpisodeID {
                candidateTimeline.completeRejectedNativeClick(activeTipTapEpisodeID)
            }
            return nil
        case .suppressAndBuffer:
            guard let eventCopy = event.copy() else {
                pendingPhysicalClick = nil
                process(arbiter.reset())
                if isRetainedRejectedTipTapOwnership, let activeTipTapEpisodeID {
                    candidateTimeline.completeRejectedNativeClick(activeTipTapEpisodeID)
                }
                return Unmanaged.passUnretained(event)
            }
            bufferedEvents.append(eventCopy)
            if !nativeEvent.isDown,
               isRetainedRejectedTipTapOwnership,
               let activeTipTapEpisodeID {
                process(arbiter.rejectBufferedCandidate(
                    tipTapEpisodeID: activeTipTapEpisodeID,
                    at: now
                ))
                candidateTimeline.completeRejectedNativeClick(activeTipTapEpisodeID)
            }
            return nil
        }
    }

    func handleLifecycleSuppressedNativeEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.replayMarker,
              let nativeEvent = nativeEvent(for: type),
              !nativeEvent.isDown else {
            return Unmanaged.passUnretained(event)
        }
        let clickKey = NativeClickKey(
            button: nativeEvent.button,
            eventNumber: event.getIntegerValueField(.mouseEventNumber)
        )
        guard let ownership = nativeOriginsByClick[clickKey],
              ownership.suppressOriginalUpAfterReset else {
            return Unmanaged.passUnretained(event)
        }
        nativeOriginsByClick.removeValue(forKey: clickKey)
        scheduleExpiration()
        return nil
    }

    func reset(preservingTerminalNativePairs: Bool = false) {
        expirationWorkItem?.cancel()
        expirationWorkItem = nil
        pendingPhysicalClick = nil
        observedTipTapRecognitionIDs.removeAll()
        if preservingTerminalNativePairs {
            nativeOriginsByClick = nativeOriginsByClick.compactMapValues { ownership in
                guard ownership.terminalDisposition != nil else { return nil }
                return NativeClickOwnership(
                    origin: ownership.origin,
                    tipTapEpisodeID: ownership.tipTapEpisodeID,
                    beganAt: ownership.beganAt,
                    terminalDisposition: ownership.terminalDisposition,
                    suppressOriginalUpAfterReset: true
                )
            }
        } else {
            nativeOriginsByClick.removeAll()
        }
        ambiguousNativeDownDepthByButton.removeAll()
        process(arbiter.reset())
        candidateTimeline.reset()
        scheduleExpiration()
    }

    var hasTerminalNativePairsAwaitingUp: Bool {
        nativeOriginsByClick.values.contains { $0.suppressOriginalUpAfterReset }
    }

    func invalidatePendingRecognitionsForConfigurationChange(
        episodeIDs: Set<TrackpadTipTapEpisodeID> = []
    ) {
        expirationWorkItem?.cancel()
        expirationWorkItem = nil
        pendingPhysicalClick = nil
        let recognizedEpisodeIDs = episodeIDs.union(
            observedTipTapRecognitionIDs.values.flatMap { $0.values }
        )
        process(arbiter.invalidatePendingRecognitionsForConfigurationChange())
        let now = clock()
        for episodeID in recognizedEpisodeIDs {
            candidateTimeline.retainAbandonedTipTapNativeClick(episodeID, at: now)
        }
        observedTipTapRecognitionIDs.removeAll()
        scheduleExpiration()
    }

    #if DEBUG
    func nativeClickOwnershipEpisodeIDForTests(
        button: TrackpadMiddleClickArbiter.Button,
        eventNumber: Int64
    ) -> TrackpadTipTapEpisodeID? {
        nativeOriginsByClick[NativeClickKey(
            button: button,
            eventNumber: eventNumber
        )]?.tipTapEpisodeID
    }

    func nativeClickOwnershipCountForTests(
        button: TrackpadMiddleClickArbiter.Button
    ) -> Int {
        nativeOriginsByClick.keys.filter { $0.button == button }.count
    }
    #endif

    private func process(_ actions: [TrackpadMiddleClickArbiter.DeferredAction]) {
        for action in actions {
            switch action {
            case .replayBuffered:
                bufferedEvents.forEach(post)
                bufferedEvents.removeAll()
            case .discardBuffered:
                markBufferedNativeDownTerminalDisposition(.consumed)
                bufferedEvents.removeAll()
            case .convertBuffered:
                markBufferedNativeDownTerminalDisposition(.converted)
                bufferedEvents.forEach { event in
                    rewriteAsMiddle(event, isDown: nativeEvent(for: event.type)?.isDown == true)
                    post(event)
                }
                bufferedEvents.removeAll()
            case .synthesizeMiddleClick:
                // Inventory can become unsafe after recognition admission but before this
                // deferred fallback expires. Recheck at the execution boundary and fail open.
                if allowsContactInference() {
                    synthesizeMiddleClick()
                }
            case .releaseConvertedMiddleButton:
                releaseMiddleButton()
            case let .abandonTipTapRecognition(episodeID):
                candidateTimeline.completeTipTapRecognition(episodeID)
                removeObservedTipTapRecognitionID(episodeID)
                abandonTipTapRecognition(episodeID)
            }
        }
    }

    private func removeObservedTipTapRecognitionID(_ episodeID: TrackpadTipTapEpisodeID) {
        for gesture in observedTipTapRecognitionIDs.keys {
            if observedTipTapRecognitionIDs[gesture]?[episodeID.deviceID] == episodeID {
                observedTipTapRecognitionIDs[gesture]?.removeValue(forKey: episodeID.deviceID)
            }
        }
    }

    private func pruneNativeClickOwnership(at time: TimeInterval) {
        nativeOriginsByClick = nativeOriginsByClick.filter {
            if $0.value.terminalDisposition != nil {
                // Exact terminal pairs are bounded by the per-button capacity and must
                // outlive watchdog balancing and resets until their matching Up arrives.
                return true
            }
            return time - $0.value.beganAt <= Self.nativeClickOwnershipWindow
        }
        ambiguousNativeDownDepthByButton = ambiguousNativeDownDepthByButton.filter {
            time - $0.value.beganAt <= Self.nativeClickOwnershipWindow
        }
    }

    private func markBufferedNativeDownTerminalDisposition(
        _ disposition: NativeClickTerminalDisposition
    ) {
        guard let event = bufferedEvents.first,
              let nativeEvent = nativeEvent(for: event.type),
              nativeEvent.isDown else {
            return
        }
        markTerminalDisposition(
            disposition,
            for: NativeClickKey(
                button: nativeEvent.button,
                eventNumber: event.getIntegerValueField(.mouseEventNumber)
            )
        )
    }

    private func markTerminalDisposition(
        _ disposition: NativeClickTerminalDisposition,
        for clickKey: NativeClickKey
    ) {
        guard let ownership = nativeOriginsByClick[clickKey] else { return }
        nativeOriginsByClick[clickKey] = NativeClickOwnership(
            origin: ownership.origin,
            tipTapEpisodeID: ownership.tipTapEpisodeID,
            beganAt: ownership.beganAt,
            terminalDisposition: disposition,
            suppressOriginalUpAfterReset: ownership.suppressOriginalUpAfterReset
        )
    }

    private func synchronizeCandidates(at time: TimeInterval) {
        for candidate in candidateTimeline.takeCandidates() {
            process(arbiter.observeCandidate(
                deviceID: candidate.deviceID,
                at: candidate.observedAt,
                isAmbiguous: candidate.isAmbiguous
            ))
        }
        process(arbiter.expire(at: time))
    }

    private func candidateTimelineDidUpdate(at time: TimeInterval) {
        drainTipTapStateChanges(at: time)
        synchronizeCandidates(at: time)
        resolvePendingPhysicalClick(at: time)
        scheduleExpiration()
    }

    private func drainTipTapStateChanges(at time: TimeInterval) {
        for start in candidateTimeline.takeNewTipTapEpisodeStarts() {
            let bufferedEpisodeID = arbiter.pendingBufferedTipTapEpisodeID
            let actions = arbiter.beginTipTapEpisode(start, at: time)
            process(actions)
            if actions.contains(.replayBuffered),
               let bufferedEpisodeID,
               candidateTimeline.isRetainingRejectedTipTapEpisode(
                   bufferedEpisodeID,
                   at: time
               ) {
                candidateTimeline.completeRejectedNativeClick(bufferedEpisodeID)
            }
        }
        for episodeID in candidateTimeline.takeNewTipTapRejectionIDs() {
            if pendingPhysicalClick?.deviceID == episodeID.deviceID {
                pendingPhysicalClick = nil
            }
            let bufferedEpisodeID = arbiter.pendingBufferedTipTapEpisodeID
            let actions = arbiter.rejectBufferedCandidate(
                tipTapEpisodeID: episodeID,
                at: time
            )
            process(actions)
            if actions.contains(.replayBuffered), bufferedEpisodeID == episodeID {
                candidateTimeline.completeRejectedNativeClick(episodeID)
            }
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        postEvent(event)
    }

    private func rewriteAsMiddle(_ event: CGEvent, isDown: Bool) {
        event.type = isDown ? .otherMouseDown : .otherMouseUp
        event.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(CGMouseButton.center.rawValue)
        )
    }

    private func nativeEvent(for type: CGEventType) -> TrackpadMiddleClickArbiter.NativeEvent? {
        switch type {
        case .leftMouseDown: .down(.left)
        case .leftMouseUp: .up(.left)
        case .rightMouseDown: .down(.right)
        case .rightMouseUp: .up(.right)
        default: nil
        }
    }

    private func scheduleExpiration() {
        expirationWorkItem?.cancel()
        expirationWorkItem = nil
        let deadline = [
            arbiter.nextDeadline,
            pendingPhysicalClick?.deadline,
        ]
            .compactMap { $0 }
            .min()
        guard let deadline else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expirationWorkItem = nil
            let now = self.clock()
            self.pruneNativeClickOwnership(at: now)
            self.synchronizeCandidates(at: now)
            self.resolvePendingPhysicalClick(at: now)
            self.scheduleExpiration()
        }
        expirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline - clock()),
            execute: workItem
        )
    }

    private func resolvePendingPhysicalClick(at time: TimeInterval) {
        guard let pendingPhysicalClick else { return }
        if candidateTimeline.suppressesPhysicalClick(deviceID: pendingPhysicalClick.deviceID) {
            self.pendingPhysicalClick = nil
            return
        }
        guard time >= pendingPhysicalClick.deadline else { return }
        guard let candidate = candidateTimeline.inferredTrackpadCandidate(at: time),
              candidate.deviceID == pendingPhysicalClick.deviceID,
              candidate.episodeID == pendingPhysicalClick.episodeID,
              candidate.contactCount == pendingPhysicalClick.gesture.physicalClickFingerCount
        else {
            self.pendingPhysicalClick = nil
            return
        }
        self.pendingPhysicalClick = nil
        let attempt = arbiter.attemptRecognition(
            deviceID: pendingPhysicalClick.deviceID,
            resolution: pendingPhysicalClick.resolution,
            at: time
        )
        process(attempt.deferredActions)
        guard attempt.wasAccepted else { return }
        recognizePhysicalClick(
            pendingPhysicalClick.gesture,
            pendingPhysicalClick.deviceID
        )
    }
}

private extension TrackpadMiddleClickArbiter.NativeEvent {
    var isDown: Bool {
        if case .down = self { return true }
        return false
    }

    var button: TrackpadMiddleClickArbiter.Button {
        switch self {
        case let .down(button), let .up(button):
            return button
        }
    }
}

private extension TrackpadMiddleClickArbiter.NativeEventOrigin {
    var trackpadDeviceID: UInt64? {
        guard case let .trackpad(deviceID) = self else { return nil }
        return deviceID
    }
}

private extension TrackpadGesture {
    var middleClickContactCount: Int? {
        if let count = physicalClickFingerCount ?? fingerTapCount ?? longTouchFingerCount {
            return count
        }
        return tipTapConfiguration.map { $0.fixedFingerCount + 1 }
    }
}
