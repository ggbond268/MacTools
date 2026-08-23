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
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertNotEqual(data["cliVersion"] as? String, "unknown")
        XCTAssertNotEqual(data["cliBuild"] as? String, "unknown")
    }

    func testVersionIgnoresUnrelatedContainingAppBundle() throws {
        let original = try runCLI(["version", "--json"])
        let originalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(original.output.utf8)) as? [String: Any]
        )
        let originalData = try XCTUnwrap(originalObject["data"] as? [String: Any])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let appURL = root.appendingPathComponent("Unrelated.app")
        let executableURL = appURL.appendingPathComponent("Tools/MacToolsCLI")
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: infoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: cliExecutableURL, to: executableURL)
        let foreignInfo: [String: Any] = [
            "CFBundleIdentifier": "example.Unrelated",
            "CFBundleExecutable": "Unrelated",
            "CFBundleShortVersionString": "99.0",
            "CFBundleVersion": "999",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: foreignInfo,
            format: .xml,
            options: 0
        ).write(to: infoURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = try runCLI(["version", "--json"], executableURL: executableURL)
        XCTAssertEqual(nested.status, 0)
        let nestedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(nested.output.utf8)) as? [String: Any]
        )
        let nestedData = try XCTUnwrap(nestedObject["data"] as? [String: Any])
        XCTAssertEqual(nestedData["cliVersion"] as? String, originalData["cliVersion"] as? String)
        XCTAssertEqual(nestedData["cliBuild"] as? String, originalData["cliBuild"] as? String)
        XCTAssertNotEqual(nestedData["cliVersion"] as? String, "99.0")
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

    func testInvalidPeerResponsesUseProtocolExitCodeForTextAndJSON() throws {
        for fixture in [
            "empty", "malformed", "mismatched", "malformedPayload",
            "missingPayload", "schemaInvalidPayload",
        ] {
            let environment = [
                CLIServiceConfiguration.testPeerResponseEnvironmentKey: fixture,
            ]
            let text = try runCLI(["actions", "list"], environment: environment)
            XCTAssertEqual(
                text.status,
                CLIExitCode.protocolIncompatible.rawValue,
                fixture
            )
            XCTAssertTrue(text.output.isEmpty, fixture)
            XCTAssertTrue(text.error.contains("invalid response"), fixture)

            let json = try runCLI(
                ["actions", "list", "--json"],
                environment: environment
            )
            XCTAssertEqual(
                json.status,
                CLIExitCode.protocolIncompatible.rawValue,
                fixture
            )
            XCTAssertTrue(json.error.isEmpty, fixture)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["outcome"] as? String, "protocolIncompatible", fixture)
            XCTAssertEqual(
                (object["rejection"] as? [String: Any])?["category"] as? String,
                "invalidPeerResponse",
                fixture
            )
        }
    }

    func testRunCommandsRejectForbiddenPayloadForTextAndJSON() throws {
        let environment = [
            CLIServiceConfiguration.testPeerResponseEnvironmentKey: "malformedPayload",
        ]
        for arguments in [
            ["actions", "run", "fixture/action"],
            ["workflows", "run", "fixture"],
        ] {
            let command = arguments.joined(separator: " ")
            let text = try runCLI(arguments, environment: environment)
            XCTAssertEqual(text.status, CLIExitCode.protocolIncompatible.rawValue, command)
            XCTAssertTrue(text.output.isEmpty, command)
            XCTAssertTrue(text.error.contains("invalid response"), command)

            let json = try runCLI(arguments + ["--json"], environment: environment)
            XCTAssertEqual(json.status, CLIExitCode.protocolIncompatible.rawValue, command)
            XCTAssertTrue(json.error.isEmpty, command)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["outcome"] as? String, "protocolIncompatible", command)
            XCTAssertEqual(
                (object["rejection"] as? [String: Any])?["category"] as? String,
                "invalidPeerResponse",
                command
            )
        }
    }

    func testDiscoveryCommandsRejectNestedSchemaMutationsForTextAndJSON() throws {
        for fixture in ["nestedUnknownPayload", "nestedDuplicatePayload"] {
            let environment = [
                CLIServiceConfiguration.testPeerResponseEnvironmentKey: fixture,
            ]
            for arguments in [
                ["actions", "list"],
                ["workflows", "list"],
                ["plugins", "list"],
            ] {
                let command = arguments.joined(separator: " ")
                let text = try runCLI(arguments, environment: environment)
                XCTAssertEqual(text.status, CLIExitCode.protocolIncompatible.rawValue, command)
                XCTAssertTrue(text.output.isEmpty, command)
                XCTAssertTrue(text.error.contains("invalid response"), command)

                let json = try runCLI(arguments + ["--json"], environment: environment)
                XCTAssertEqual(json.status, CLIExitCode.protocolIncompatible.rawValue, command)
                XCTAssertTrue(json.error.isEmpty, command)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(json.output.utf8))
                        as? [String: Any]
                )
                XCTAssertEqual(object["outcome"] as? String, "protocolIncompatible", command)
                XCTAssertEqual(
                    (object["rejection"] as? [String: Any])?["category"] as? String,
                    "invalidPeerResponse",
                    command
                )
            }
        }
    }

    func testUncertainPeerTimeoutUsesTransportExitCodeForTextAndJSON() throws {
        let environment = [
            CLIServiceConfiguration.testPeerResponseEnvironmentKey: "timeout",
        ]
        let text = try runCLI(["actions", "list"], environment: environment)
        XCTAssertEqual(text.status, CLIExitCode.transportFailure.rawValue)
        XCTAssertTrue(text.output.isEmpty)
        XCTAssertTrue(text.error.contains("delivery state is unknown"))

        let json = try runCLI(
            ["actions", "list", "--json"],
            environment: environment
        )
        XCTAssertEqual(json.status, CLIExitCode.transportFailure.rawValue)
        XCTAssertTrue(json.error.isEmpty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["outcome"] as? String, "hostUnavailable")
        XCTAssertEqual(
            (object["rejection"] as? [String: Any])?["category"] as? String,
            "hostTransportFailure"
        )

        let doctorText = try runCLI(["doctor"], environment: environment)
        XCTAssertEqual(doctorText.status, CLIExitCode.transportFailure.rawValue)
        XCTAssertTrue(doctorText.output.isEmpty)
        XCTAssertTrue(doctorText.error.contains("delivery state is unknown"))

        let doctorJSON = try runCLI(["doctor", "--json"], environment: environment)
        XCTAssertEqual(doctorJSON.status, CLIExitCode.transportFailure.rawValue)
        XCTAssertTrue(doctorJSON.error.isEmpty)
        let doctorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(doctorJSON.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(doctorObject["outcome"] as? String, "hostUnavailable")
        XCTAssertEqual(
            (doctorObject["rejection"] as? [String: Any])?["category"] as? String,
            "hostTransportFailure"
        )
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

    private func runCLI(
        _ arguments: [String],
        executableURL: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executableURL ?? cliExecutableURL
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, override in override }
            )
        }
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
        process.executableURL = cliExecutableURL
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

    private var cliExecutableURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("MacToolsCLI")
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
