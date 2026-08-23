import Foundation
import MacToolsPluginKit
import XCTest
@testable import SavedScriptsPlugin

final class SavedScriptRunnerTests: XCTestCase {
    func testZshCapturesStandardOutputStandardErrorAndExitCode() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let runner = ProcessSavedScriptRunner(temporaryDirectory: temporaryDirectory)
        let script = SavedScript(
            name: "Output",
            kind: .zsh,
            source: "printf 'hello'; printf 'warning' >&2; exit 7"
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.standardOutput, "hello")
        XCTAssertEqual(result.standardError, "warning")
        XCTAssertFalse(result.outputWasTruncated)
    }

    func testCLIInvocationContextPropagatesOnlyOpaqueChildEnvironment() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let runner = ProcessSavedScriptRunner(temporaryDirectory: temporaryDirectory)
        let chainID = UUID()
        let script = SavedScript(
            name: "CLI Context",
            kind: .sh,
            source: "printf '%s\\n%s' \"$MACTOOLS_CLI_CHAIN_ID\" \"$MACTOOLS_CLI_CHAIN_DEPTH\""
        )

        let result = try await PluginActionExecutionContext.$cliInvocation.withValue(
            PluginCLIInvocationContext(chainID: chainID, depth: 0)
        ) {
            try await runner.run(script)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.standardOutput.split(separator: "\n").map(String.init),
            [chainID.uuidString, "1"]
        )
    }

    func testWorkingDirectoryWithSpacesIsPassedWithoutShellInterpolation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = root.appendingPathComponent("Folder With Spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessSavedScriptRunner(temporaryDirectory: root)
        let script = SavedScript(
            name: "Directory",
            kind: .sh,
            source: "pwd",
            workingDirectory: workingDirectory.path
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path,
            workingDirectory.resolvingSymlinksInPath().path
        )
    }

    func testInvalidWorkingDirectoryFailsBeforeLaunching() async {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Missing",
            kind: .zsh,
            source: "echo unreachable",
            workingDirectory: "/private/mactools-path-that-does-not-exist"
        )

        do {
            _ = try await runner.run(script)
            XCTFail("Expected invalid working directory")
        } catch {
            XCTAssertEqual(error as? SavedScriptProcessError, .invalidWorkingDirectory)
        }
    }

    func testTimeoutTerminatesLongRunningScript() async {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Timeout",
            kind: .sh,
            source: "sleep 10",
            timeoutSeconds: 1
        )

        let started = Date()
        do {
            _ = try await runner.run(script)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SavedScriptProcessError, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        }
    }

    func testTimeoutTerminatesTermIgnoringDescendants() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let runner = ProcessSavedScriptRunner(temporaryDirectory: root)
        let script = SavedScript(
            name: "Descendant Timeout",
            kind: .sh,
            source: "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & echo $! > child.pid; wait",
            workingDirectory: root.path,
            timeoutSeconds: 1
        )

        do {
            _ = try await runner.run(script)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SavedScriptProcessError, .timedOut)
        }

        let childPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        for _ in 0 ..< 50 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutCannotBeStarvedByContinuousTermIgnoringOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let runner = ProcessSavedScriptRunner(temporaryDirectory: root)
        let script = SavedScript(
            name: "Continuous Output Timeout",
            kind: .sh,
            source: "trap '' TERM; (trap '' TERM; echo $$ > child.pid; exec yes output) & wait",
            workingDirectory: root.path,
            timeoutSeconds: 1
        )

        let started = Date()
        do {
            _ = try await runner.run(script)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SavedScriptProcessError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)

        let childPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        for _ in 0 ..< 50 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testBackgroundChildCannotKeepInheritedOutputPipeOpen() async throws {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Inherited Pipe",
            kind: .sh,
            source: "(sleep 10) & printf done",
            timeoutSeconds: 5
        )

        let started = Date()
        let result = try await runner.run(script)

        XCTAssertEqual(result.standardOutput, "done")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testNaturalLeaderExitKillsTermIgnoringBackgroundDescendantBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let runner = ProcessSavedScriptRunner(temporaryDirectory: root)
        let script = SavedScript(
            name: "Background Descendant",
            kind: .sh,
            source: "(trap '' TERM; while :; do sleep 1; done) & echo $! > child.pid; exit 0",
            workingDirectory: root.path,
            timeoutSeconds: 5
        )

        let result = try await runner.run(script)
        let childPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { _ = kill(childPID, SIGKILL) }

        XCTAssertEqual(result.exitCode, 0)
        for _ in 0 ..< 50 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSuccessfulExitDuringPipeDrainDoesNotBecomeTimeout() async throws {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Near Timeout",
            kind: .sh,
            source: "sleep 0.75; printf done",
            timeoutSeconds: 1
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "done")
    }

    func testHighVolumeOutputKeepsItsOrderAtProcessExit() async throws {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Exit Ordering",
            kind: .sh,
            source: "i=0; while [ $i -lt 4000 ]; do printf '%04d\\n' $i; i=$((i + 1)); done",
            timeoutSeconds: 5
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.outputWasTruncated)
        XCTAssertEqual(
            result.standardOutput.split(separator: "\n").map(String.init),
            (0 ..< 4000).map { String(format: "%04d", $0) }
        )
    }

    func testInitializationRemovesOnlyAbandonedOwnedRunDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("SavedScripts", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dead = parent.appendingPathComponent("run-999999-dead", isDirectory: true)
        let live = parent.appendingPathComponent("run-\(getpid())-live", isDirectory: true)
        let reusedPID = parent.appendingPathComponent("run-\(getpid())-expired", isDirectory: true)
        let legacySource = parent.appendingPathComponent("\(UUID().uuidString).sh")
        let unrelatedFile = parent.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: reusedPID, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: dead.appendingPathComponent("source.sh"))
        try Data("expired secret".utf8).write(to: reusedPID.appendingPathComponent("source.sh"))
        try FileManager.default.setAttributes(
            [
                .modificationDate: Date(
                    timeIntervalSinceNow: -(ProcessSavedScriptRunner.maximumRunDirectoryLifetime + 60)
                ),
            ],
            ofItemAtPath: reusedPID.path
        )
        try Data("legacy secret".utf8).write(to: legacySource)
        try Data("keep me".utf8).write(to: unrelatedFile)

        _ = ProcessSavedScriptRunner(temporaryDirectory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reusedPID.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    func testCapturedOutputIsBounded() async throws {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Large Output",
            kind: .zsh,
            source: "printf '%*s' 70000 '' | tr ' ' x"
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, ProcessSavedScriptRunner.maximumCapturedByteCount)
        XCTAssertTrue(result.outputWasTruncated)
    }
}
