import Darwin
import XCTest
@testable import MacTools

final class CLIExecutableTests: XCTestCase {
    func testHelpAndVersionDoNotRequireBroker() throws {
        let help = try runCLI(["help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.output.contains("actions run <provider/action>"))
        XCTAssertTrue(help.output.contains("plugins doctor"))

        let version = try runCLI(["version", "--json"])
        XCTAssertEqual(version.status, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(version.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNotNil((object["data"] as? [String: Any])?["cliVersion"])
    }

    func testInvalidCommandUsesStableExitCode() throws {
        let result = try runCLI(["actions", "run", "invalid-key"])
        XCTAssertEqual(result.status, CLIExitCode.invalidInput.rawValue)
        XCTAssertTrue(result.error.contains("Invalid command"))
    }

    func testInvalidCommandPreservesJSONEnvelope() throws {
        let result = try runCLI(["actions", "run", "invalid-key", "--json"])
        XCTAssertEqual(result.status, CLIExitCode.invalidInput.rawValue)
        XCTAssertTrue(result.error.isEmpty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "actions.run")
        XCTAssertEqual(object["outcome"] as? String, "invalidInput")
    }

    func testRequestSendStatePersistsCancellationAcrossAdmissionRace() {
        let cancelledBeforeSending = CLIRequestSendState()
        cancelledBeforeSending.cancel()
        XCTAssertFalse(cancelledBeforeSending.beginSending())
        XCTAssertFalse(cancelledBeforeSending.takeCancellationToForward())

        let cancelledAfterSending = CLIRequestSendState()
        XCTAssertTrue(cancelledAfterSending.beginSending())
        cancelledAfterSending.cancel()
        XCTAssertTrue(cancelledAfterSending.takeCancellationToForward())
        XCTAssertFalse(cancelledAfterSending.takeCancellationToForward())
    }

    func testCommandTaskStatePersistsSignalBeforeAndAfterTaskInstallation() async {
        let cancelledBeforeInstall = CLICommandTaskState()
        cancelledBeforeInstall.cancel()
        let firstTask = Task<Int32, Error> {
            try Task.checkCancellation()
            return 0
        }
        cancelledBeforeInstall.install(firstTask)
        await XCTAssertThrowsCancellation(firstTask)

        let cancelledAfterInstall = CLICommandTaskState()
        let secondTask = Task<Int32, Error> {
            try await Task.sleep(for: .seconds(30))
            return 0
        }
        cancelledAfterInstall.install(secondTask)
        cancelledAfterInstall.cancel()
        await XCTAssertThrowsCancellation(secondTask)
    }

    func testSignalStateHandlesOnceAndStopsAfterFinish() {
        let state = CLISignalState()
        XCTAssertTrue(state.beginHandlingSignal())
        XCTAssertFalse(state.beginHandlingSignal())
        XCTAssertTrue(state.beginFinishing())
        XCTAssertFalse(state.beginHandlingSignal())
        XCTAssertFalse(state.beginFinishing())
    }

    func testSignalCoordinatorRestoresEveryPreviousDispositionExactlyOnce() {
        let recorder = CLISignalInstallRecorder()
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

    func testSIGINTAndSIGTERMCancelRunningColdStartWithOneJSONResult() throws {
        for signalNumber in [SIGINT, SIGTERM] {
            let result = try runInterruptedCLI(signalNumber: signalNumber)
            XCTAssertEqual(result.status, CLIExitCode.cancellation.rawValue)
            XCTAssertTrue(result.error.isEmpty)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(result.output.utf8))
                    as? [String: Any]
            )
            XCTAssertEqual(object["schemaVersion"] as? Int, 1)
            XCTAssertEqual(object["command"] as? String, "doctor")
            XCTAssertEqual(object["outcome"] as? String, "cancelled")
            XCTAssertEqual(
                (object["rejection"] as? [String: Any])?["category"] as? String,
                "cancelled"
            )

            let subsequent = try runCLI(["help"])
            XCTAssertEqual(subsequent.status, CLIExitCode.success.rawValue)
            XCTAssertTrue(subsequent.output.contains("Usage: mactools"))
        }
    }

    func testHostCancellationRelayClosesRegistrationRaceAndBoundsLateState() {
        var state = CLIHostCancellationRelayState(maximumTrackedRequestCount: 2)
        let early = UUID()

        XCTAssertEqual(
            state.cancellationDisposition(requestID: early, hasActiveTask: false),
            .recordedBeforeRegistration
        )
        XCTAssertFalse(state.shouldBeginHandling(early))
        state.markCompleted(early)
        XCTAssertEqual(
            state.cancellationDisposition(requestID: early, hasActiveTask: false),
            .alreadyCompleted
        )

        let active = UUID()
        XCTAssertTrue(state.shouldBeginHandling(active))
        XCTAssertEqual(
            state.cancellationDisposition(requestID: active, hasActiveTask: true),
            .cancelActive
        )
        state.markCompleted(active)

        let newest = UUID()
        XCTAssertTrue(state.shouldBeginHandling(newest))
        state.markCompleted(newest)
        XCTAssertFalse(state.completedRequestIDs.contains(early))
        XCTAssertTrue(state.completedRequestIDs.contains(active))
        XCTAssertTrue(state.completedRequestIDs.contains(newest))
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mactools")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func runInterruptedCLI(
        signalNumber: Int32
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/mactools")
        process.arguments = ["doctor", "--json"]
        var environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        environment[CLIServiceConfiguration.testServiceNameEnvironmentKey] =
            "app.ggbond.MacTools.tests.\(UUID().uuidString).cli-broker"
        environment[CLIServiceConfiguration.testDisableHostLaunchEnvironmentKey] = "1"
        environment[CLIServiceConfiguration.testSignalReadyEnvironmentKey] = "1"
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        let ready = expectation(description: "CLI signal handlers installed")
        let readyData = CLIDataRecorder()
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if readyData.appendAndContainsReadyMarker(data) {
                ready.fulfill()
            }
        }
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let waitResult = XCTWaiter.wait(for: [ready], timeout: 3)
        error.fileHandleForReading.readabilityHandler = nil
        guard waitResult == .completed,
              process.isRunning,
              readyData.value == Data("MACTOOLS_CLI_SIGNAL_READY\n".utf8) else {
            process.terminate()
            process.waitUntilExit()
            throw CLIExecutableTestError.signalHandlerDidNotBecomeReady
        }

        XCTAssertEqual(kill(process.processIdentifier, signalNumber), 0)
        let exitDeadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw CLIExecutableTestError.interruptedProcessDidNotExit
        }
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private enum CLIExecutableTestError: Error {
    case signalHandlerDidNotBecomeReady
    case interruptedProcessDidNotExit
}

private final class CLIDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var didFindMarker = false

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func appendAndContainsReadyMarker(_ newData: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        guard !didFindMarker,
              data.range(of: Data("MACTOOLS_CLI_SIGNAL_READY\n".utf8)) != nil else {
            return false
        }
        didFindMarker = true
        return true
    }
}

private func XCTAssertThrowsCancellation(
    _ task: Task<Int32, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected task cancellation.", file: file, line: line)
    } catch is CancellationError {
        return
    } catch {
        XCTFail("Expected CancellationError, got \(error).", file: file, line: line)
    }
}

private final class CLISignalInstallRecorder: @unchecked Sendable {
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
