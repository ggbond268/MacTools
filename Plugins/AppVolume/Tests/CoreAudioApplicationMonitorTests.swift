import XCTest
@testable import AppVolumePlugin

@MainActor
final class CoreAudioApplicationMonitorTests: XCTestCase {
    func testRestartRejectsDeliveryAlreadyQueuedByPreviousWorkerSession() async {
        let worker = AudioObservationWorkerStub()
        let monitor = CoreAudioApplicationMonitor(worker: worker)
        let oldSnapshot = AudioApplicationSnapshot(applications: [], outputDeviceUID: "old")
        let newSnapshot = AudioApplicationSnapshot(applications: [], outputDeviceUID: "new")
        let fresh = expectation(description: "Current session delivered")
        let stale = expectation(description: "Previous session rejected")
        stale.isInverted = true
        monitor.onUpdate = { snapshot in
            if snapshot == newSnapshot { fresh.fulfill() } else { stale.fulfill() }
        }
        monitor.start()
        worker.deliveries[0](oldSnapshot)
        monitor.stop()
        monitor.start()
        worker.deliveries[1](newSnapshot)
        await fulfillment(of: [fresh, stale], timeout: 0.15)
        monitor.stop()
    }

    func testStartIsIdempotentAndStoppedRefreshDoesNoWork() {
        let worker = AudioObservationWorkerStub()
        let monitor = CoreAudioApplicationMonitor(worker: worker)
        monitor.refresh()
        XCTAssertEqual(worker.refreshCount, 0)
        monitor.start()
        monitor.start()
        XCTAssertEqual(worker.deliveries.count, 1)
        monitor.refresh()
        XCTAssertEqual(worker.refreshCount, 1)
        monitor.stop()
        monitor.refresh()
        XCTAssertEqual(worker.refreshCount, 1)
    }
}

/// Calls are made only by the main-actor test; delivery closures are Sendable.
private final class AudioObservationWorkerStub: AudioApplicationObservationWorking, @unchecked Sendable {
    var deliveries: [AudioApplicationObservation.Delivery] = []
    var refreshCount = 0
    func start(delivery: @escaping AudioApplicationObservation.Delivery) { deliveries.append(delivery) }
    func refresh() { refreshCount += 1 }
    func stop() {}
}
