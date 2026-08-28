import Darwin
import XCTest
@testable import MacTools

final class CLISignalCoordinatorTests: XCTestCase {
    func testCommandTaskStatePersistsCancellationAcrossInstallation() async {
        let cancelledBeforeInstall = CLICommandTaskState()
        cancelledBeforeInstall.cancel()
        let firstGate = CommandTaskGate()
        let firstTask = Task<Int32, Error> {
            // Task creation starts execution immediately. Keep this task pending
            // until install has delivered the previously recorded cancellation.
            await firstGate.wait()
            try Task.checkCancellation()
            return 0
        }
        cancelledBeforeInstall.install(firstTask)
        await firstGate.open()
        await assertCancellation(firstTask)

        let cancelledAfterInstall = CLICommandTaskState()
        let secondGate = CommandTaskGate()
        let secondTask = Task<Int32, Error> {
            await secondGate.wait()
            try Task.checkCancellation()
            return 0
        }
        cancelledAfterInstall.install(secondTask)
        cancelledAfterInstall.cancel()
        await secondGate.open()
        await assertCancellation(secondTask)
    }

    func testCommandTaskStateDoesNotCancelAnInstalledTaskWithoutARequest() async throws {
        let state = CLICommandTaskState()
        let gate = CommandTaskGate()
        let task = Task<Int32, Error> {
            await gate.wait()
            try Task.checkCancellation()
            return 42
        }
        state.install(task)
        await gate.open()
        let result = try await task.value
        XCTAssertEqual(result, 42)
    }

    func testCancellationDoesNotReplaceAnAlreadyCompletedTaskResult() async throws {
        let state = CLICommandTaskState()
        state.cancel()
        let task = Task<Int32, Error> {
            try Task.checkCancellation()
            return 42
        }
        let completedResult = try await task.value
        XCTAssertEqual(completedResult, 42)
        state.install(task)
        // Cancellation is cooperative and cannot undo an already returned value.
        let installedResult = try await task.value
        XCTAssertEqual(installedResult, 42)
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

private actor CommandTaskGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
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
