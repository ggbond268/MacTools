import CoreAudio
import Foundation

struct AudioApplicationProperty: Hashable, Sendable {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope

    init(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.objectID = objectID
        self.selector = selector
        self.scope = scope
    }

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static let processList = Self(objectID: AudioObjectID(kAudioObjectSystemObject),
                                  selector: kAudioHardwarePropertyProcessObjectList)
    static let defaultOutput = Self(objectID: AudioObjectID(kAudioObjectSystemObject),
                                    selector: kAudioHardwarePropertyDefaultOutputDevice)
    static let serviceRestart = Self(objectID: AudioObjectID(kAudioObjectSystemObject),
                                     selector: kAudioHardwarePropertyServiceRestarted)

    static func runningOutput(_ objectID: AudioObjectID) -> Self {
        Self(objectID: objectID, selector: kAudioProcessPropertyIsRunningOutput)
    }

    static func running(_ objectID: AudioObjectID) -> Self {
        Self(objectID: objectID, selector: kAudioProcessPropertyIsRunning)
    }

    static func outputDevices(_ objectID: AudioObjectID) -> Self {
        Self(objectID: objectID, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
    }

    static func activityProperties(_ objectID: AudioObjectID) -> [Self] {
        // Some HAL versions notify IO state and output-device membership but
        // not IsRunningOutput itself. Read output activity after any of them.
        [.runningOutput(objectID), .running(objectID), .outputDevices(objectID)]
    }
}

struct AudioApplicationQueryResult {
    let snapshot: AudioApplicationSnapshot
    let isComplete: Bool
}

/// All entry points and dependency callbacks run on the owner's serial queue.
/// No audio properties or listener state are accessed from the main actor.
final class AudioApplicationObservation: @unchecked Sendable {
    typealias Cancellation = () -> Void
    typealias Delivery = @Sendable (AudioApplicationSnapshot) -> Void

    struct Dependencies {
        let processObjectIDs: () -> [AudioObjectID]?
        let snapshot: ([AudioObjectID]) -> AudioApplicationQueryResult
        let observe: (AudioApplicationProperty, @escaping @Sendable () -> Void) -> Cancellation?
        let schedule: (TimeInterval, @escaping @Sendable () -> Void) -> Cancellation
    }

    private struct Observation {
        let id: UUID
        let cancel: Cancellation
    }

    private let dependencies: Dependencies
    private var delivery: Delivery?
    private var observations: [AudioApplicationProperty: Observation] = [:]
    private var pendingRefresh: Observation?
    private var fallback: Observation?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func start(delivery: @escaping Delivery) {
        guard self.delivery == nil else { return }
        self.delivery = delivery
        reconcile()
    }

    func refresh() {
        guard delivery != nil else { return }
        cancelPendingRefresh()
        reconcile()
    }

    func stop() {
        delivery = nil
        cancelPendingRefresh()
        cancelFallback()
        removeObservations()
    }

    private func reconcile() {
        guard let delivery else { return }
        var isComplete = true
        let systemProperties: Set<AudioApplicationProperty> = [.serviceRestart, .processList, .defaultOutput]
        for property in systemProperties {
            if !observe(property) { isComplete = false }
        }

        guard let processIDs = dependencies.processObjectIDs() else {
            // A failed read is not an empty process list. Retain existing routes
            // and subscriptions until discovery succeeds or the monitor stops.
            scheduleFallback(after: 1)
            return
        }

        let processProperties = Set(processIDs.flatMap(AudioApplicationProperty.activityProperties))
        let desiredProperties = systemProperties.union(processProperties)
        let removed = observations.keys.filter { !desiredProperties.contains($0) }
        for property in removed {
            observations.removeValue(forKey: property)?.cancel()
        }
        for property in processProperties {
            if !observe(property) { isComplete = false }
        }

        // Subscribe before reading values so a playback transition during the
        // query schedules another reconciliation instead of being missed.
        let result = dependencies.snapshot(processIDs)
        delivery(result.snapshot)
        scheduleFallback(after: isComplete && result.isComplete ? 10 : 1)
    }

    private func observe(_ property: AudioApplicationProperty) -> Bool {
        if observations[property] != nil { return true }
        let id = UUID()
        guard let cancel = dependencies.observe(property, { [weak self] in
            self?.propertyDidChange(property, observationID: id)
        }) else { return false }
        observations[property] = Observation(id: id, cancel: cancel)
        return true
    }

    private func propertyDidChange(_ property: AudioApplicationProperty, observationID: UUID) {
        guard delivery != nil, observations[property]?.id == observationID else { return }
        if property == .serviceRestart {
            // Core Audio invalidates both object IDs and listeners on restart.
            // Retire every token before subscribing to the new service instance.
            removeObservations()
        }
        guard pendingRefresh == nil else { return }
        let id = UUID()
        let cancel = dependencies.schedule(0.05) { [weak self] in
            guard let self, pendingRefresh?.id == id else { return }
            cancelPendingRefresh()
            reconcile()
        }
        pendingRefresh = Observation(id: id, cancel: cancel)
    }

    private func scheduleFallback(after delay: TimeInterval) {
        cancelFallback()
        let id = UUID()
        let cancel = dependencies.schedule(delay) { [weak self] in
            guard let self, fallback?.id == id else { return }
            cancelFallback()
            refresh()
        }
        fallback = Observation(id: id, cancel: cancel)
    }

    private func cancelPendingRefresh() {
        let previous = pendingRefresh
        pendingRefresh = nil
        previous?.cancel()
    }

    private func cancelFallback() {
        let previous = fallback
        fallback = nil
        previous?.cancel()
    }

    private func removeObservations() {
        let previous = observations.values
        observations.removeAll()
        for observation in previous { observation.cancel() }
    }
}
