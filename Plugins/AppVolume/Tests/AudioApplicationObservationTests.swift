import CoreAudio
import XCTest
@testable import AppVolumePlugin

final class AudioApplicationObservationTests: XCTestCase {
    func testIdleDiscoveryUsesFallbackAndSubscribesBeforeReadingActivity() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }

        XCTAssertEqual(fixture.snapshotReads, 1)
        XCTAssertEqual(fixture.activeProperties,
                       [.processList, .defaultOutput, .serviceRestart, .runningOutput(42), .running(42), .outputDevices(42)])
        XCTAssertTrue(fixture.wasSubscribedAtSnapshot)
        fixture.advance(by: 9)
        XCTAssertEqual(fixture.snapshotReads, 1)
        fixture.advance(by: 1)
        XCTAssertEqual(fixture.snapshotReads, 2)
    }

    func testPlaybackBurstCoalescesWithoutWaitingForFallback() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        fixture.snapshot = fixture.playingSnapshot
        for _ in 0..<20 { fixture.emit(.running(42)) }
        fixture.advance(by: 0.04)
        XCTAssertEqual(fixture.snapshotReads, 1)
        fixture.advance(by: 0.02)
        XCTAssertEqual(fixture.snapshotReads, 2)
        XCTAssertEqual(fixture.deliveries.last, fixture.playingSnapshot)
        fixture.snapshot = .empty
        fixture.emit(.outputDevices(42))
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.deliveries.last, .empty)
    }

    func testProcessRemovalRetiresListenerAndDiscardsDeferredCallback() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        let removedCallback = fixture.callback(for: .runningOutput(42))
        fixture.processIDs = [99]
        fixture.emit(.processList)
        fixture.advance(by: 0.06)
        XCTAssertFalse(fixture.activeProperties.contains(.runningOutput(42)))
        XCTAssertFalse(fixture.activeProperties.contains(.running(42)))
        XCTAssertFalse(fixture.activeProperties.contains(.outputDevices(42)))
        XCTAssertTrue(fixture.activeProperties.contains(.runningOutput(99)))
        let reads = fixture.snapshotReads
        removedCallback()
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.snapshotReads, reads)
    }

    func testDefaultOutputChangeRefreshesRoutingSnapshot() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        fixture.snapshot = AudioApplicationSnapshot(applications: [], outputDeviceUID: "new-output")
        fixture.emit(.defaultOutput)
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.deliveries.last?.outputDeviceUID, "new-output")
    }

    func testServiceRestartReestablishesAllListenersAndRejectsOldObjectEvents() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        let oldCallback = fixture.callback(for: .runningOutput(42))
        fixture.emit(.serviceRestart)
        XCTAssertTrue(fixture.activeProperties.isEmpty)
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.registrationAttempts[.processList], 2)
        XCTAssertEqual(fixture.registrationAttempts[.defaultOutput], 2)
        XCTAssertEqual(fixture.registrationAttempts[.serviceRestart], 2)
        XCTAssertEqual(fixture.registrationAttempts[.runningOutput(42)], 2)
        XCTAssertEqual(fixture.registrationAttempts[.running(42)], 2)
        XCTAssertEqual(fixture.registrationAttempts[.outputDevices(42)], 2)
        oldCallback()
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.snapshotReads, 2)
        fixture.emit(.runningOutput(42))
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.snapshotReads, 3)
    }

    func testRegistrationFailureKeepsOneSecondFallbackUntilRetrySucceeds() {
        let fixture = AudioObservationFixture()
        fixture.failingProperties = [.runningOutput(42), .processList]
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        fixture.advance(by: 1)
        XCTAssertEqual(fixture.snapshotReads, 2)
        XCTAssertEqual(fixture.registrationAttempts[.runningOutput(42)], 2)
        fixture.failingProperties = []
        fixture.advance(by: 1)
        XCTAssertEqual(fixture.snapshotReads, 3)
        XCTAssertTrue(fixture.activeProperties.contains(.runningOutput(42)))
        fixture.advance(by: 9)
        XCTAssertEqual(fixture.snapshotReads, 3)
        fixture.advance(by: 1)
        XCTAssertEqual(fixture.snapshotReads, 4)
    }

    func testFailedProcessListReadRetainsRoutesAndListenersUntilRetry() {
        let fixture = AudioObservationFixture()
        fixture.snapshot = fixture.playingSnapshot
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        fixture.processIDs = nil
        observation.refresh()
        XCTAssertEqual(fixture.deliveries, [fixture.playingSnapshot])
        XCTAssertTrue(fixture.activeProperties.contains(.runningOutput(42)))
        fixture.processIDs = []
        fixture.snapshot = .empty
        fixture.advance(by: 1)
        XCTAssertEqual(fixture.deliveries.last, .empty)
        XCTAssertFalse(fixture.activeProperties.contains(.runningOutput(42)))
    }

    func testPartialPropertyReadRetriesAtOriginalPollingFrequency() {
        let fixture = AudioObservationFixture()
        fixture.isComplete = false
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        fixture.advance(by: 1)
        XCTAssertEqual(fixture.snapshotReads, 2)
        fixture.isComplete = true
        fixture.advance(by: 1)
        fixture.advance(by: 9)
        XCTAssertEqual(fixture.snapshotReads, 3)
    }

    func testExplicitRefreshConsumesPendingEventAndStopCancelsAllWork() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        fixture.emit(.runningOutput(42))
        observation.refresh()
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.snapshotReads, 2)
        let oldCallback = fixture.callback(for: .runningOutput(42))
        observation.stop()
        XCTAssertTrue(fixture.activeProperties.isEmpty)
        XCTAssertTrue(fixture.jobs.isEmpty)
        oldCallback()
        observation.refresh()
        fixture.advance(by: 20)
        XCTAssertEqual(fixture.snapshotReads, 2)
    }

    func testRestartDoesNotAcceptEarlierSubscriptionCallbacks() {
        let fixture = AudioObservationFixture()
        let observation = fixture.makeObservation()
        observation.start(delivery: fixture.deliver)
        let oldCallback = fixture.callback(for: .runningOutput(42))
        fixture.emit(.runningOutput(42))
        let oldTimers = fixture.jobs.values.map(\.callback)
        observation.stop()
        observation.start(delivery: fixture.deliver)
        defer { observation.stop() }
        oldCallback()
        for callback in oldTimers { callback() }
        fixture.advance(by: 0.06)
        XCTAssertEqual(fixture.snapshotReads, 2)
    }
}

/// The fixture and all callbacks are driven synchronously by the test clock.
private final class AudioObservationFixture: @unchecked Sendable {
    struct Job {
        let deadline: TimeInterval
        let callback: @Sendable () -> Void
    }
    var processIDs: [AudioObjectID]? = [42]
    var snapshot = AudioApplicationSnapshot.empty
    var isComplete = true
    var failingProperties: Set<AudioApplicationProperty> = []
    var registrationAttempts: [AudioApplicationProperty: Int] = [:]
    var callbacks: [AudioApplicationProperty: @Sendable () -> Void] = [:]
    var jobs: [UUID: Job] = [:]
    var deliveries: [AudioApplicationSnapshot] = []
    var snapshotReads = 0
    var wasSubscribedAtSnapshot = false
    private var time: TimeInterval = 0
    var activeProperties: Set<AudioApplicationProperty> { Set(callbacks.keys) }
    var playingSnapshot: AudioApplicationSnapshot {
        AudioApplicationSnapshot(applications: [AudioApplication(id: "player", displayName: "Player",
                                  bundleIdentifier: "player", processObjectIDs: [42])], outputDeviceUID: "output")
    }

    func makeObservation() -> AudioApplicationObservation {
        AudioApplicationObservation(dependencies: .init(
            processObjectIDs: { [self] in processIDs },
            snapshot: { [self] processIDs in
                snapshotReads += 1
                wasSubscribedAtSnapshot = processIDs.allSatisfy { callbacks[.runningOutput($0)] != nil }
                return AudioApplicationQueryResult(snapshot: snapshot, isComplete: isComplete)
            },
            observe: { [self] property, callback in
                registrationAttempts[property, default: 0] += 1
                guard !failingProperties.contains(property) else { return nil }
                callbacks[property] = callback
                return { [self] in callbacks.removeValue(forKey: property) }
            },
            schedule: { [self] delay, callback in
                let id = UUID()
                jobs[id] = Job(deadline: time + delay, callback: callback)
                return { [self] in jobs.removeValue(forKey: id) }
            }
        ))
    }

    var deliver: AudioApplicationObservation.Delivery {
        { [self] in deliveries.append($0) }
    }
    func callback(for property: AudioApplicationProperty) -> @Sendable () -> Void { callbacks[property]! }
    func emit(_ property: AudioApplicationProperty) { callbacks[property]?() }
    func advance(by duration: TimeInterval) {
        let end = time + duration
        while let next = jobs.min(by: { $0.value.deadline < $1.value.deadline }), next.value.deadline <= end {
            time = next.value.deadline
            jobs.removeValue(forKey: next.key)
            next.value.callback()
        }
        time = end
    }
}
