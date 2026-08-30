import Darwin
import XCTest
@testable import MacTools

final class CLISignalCoordinatorTests: XCTestCase {
    func testCommandTaskStatePersistsCancellationAcrossInstallation() async {
        let cancelledBeforeInstall = CLICommandTaskState()
        cancelledBeforeInstall.cancel()
        let firstTask = Task<Int32, Error> {
            try Task.checkCancellation()
            return 0
        }
        cancelledBeforeInstall.install(firstTask)
        await assertCancellation(firstTask)

        let cancelledAfterInstall = CLICommandTaskState()
        let secondTask = Task<Int32, Error> {
            try await Task.sleep(for: .seconds(30))
            return 0
        }
        cancelledAfterInstall.install(secondTask)
        cancelledAfterInstall.cancel()
        await assertCancellation(secondTask)
    }

    func testSignalStateHandlesOnceAndStopsAfterFinish() {
        let state = CLISignalState()
        XCTAssertTrue(state.beginHandlingSignal())
        XCTAssertFalse(state.beginHandlingSignal())
        XCTAssertTrue(state.beginFinishing())
        XCTAssertFalse(state.beginHandlingSignal())
        XCTAssertFalse(state.beginFinishing())
    }

    func testCoordinatorRestoresEveryPreviousDispositionExactlyOnce() {
        let recorder = SignalInstallRecorder()
        let coordinator = CLISignalCoordinator(
            signalNumbers: [SIGINT, SIGTERM],
            installSignalHandler: { signalNumber, _ in
                recorder.record(signalNumber)
                return SIG_DFL
            },
            onSignal: {}
        )

        XCTAssertEqual(recorder.signalNumbers, [SIGINT, SIGTERM])
        coordinator.finish()
        coordinator.finish()
        XCTAssertEqual(recorder.signalNumbers, [SIGINT, SIGTERM, SIGINT, SIGTERM])
    }

    private func assertCancellation(_ task: Task<Int32, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            return
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}

private final class SignalInstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []

    var signalNumbers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ signalNumber: Int32) {
        lock.lock()
        values.append(signalNumber)
        lock.unlock()
    }
}
