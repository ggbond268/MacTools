import Darwin
import Foundation
import XCTest
@testable import AppleShortcutsPlugin

final class AppleShortcutsCommandRunnerTests: XCTestCase {
    func testBuildsExactRunArgumentsWithoutShellInterpolation() async throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        printf '%s\\n' "$@"
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(commandURL: executable)
        let id = UUID()

        let result = try await runner.runShortcut(id: id)

        XCTAssertEqual(result.standardOutput, "run\n\(id.uuidString)\n")
    }

    func testListCommandsParseIdentifiersAndFolderArgument() async throws {
        let shortcutID = UUID()
        let executable = try makeExecutable("""
        #!/bin/sh
        if [ "$2" = "--folder-name" ]; then
          printf 'Inside (\(shortcutID.uuidString))\\n'
        else
          printf 'All (\(shortcutID.uuidString))\\n'
        fi
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(commandURL: executable)

        let allIDs = try await runner.listShortcuts().map(\.id)
        let folderIDs = try await runner.listShortcuts(inFolder: UUID()).map(\.id)
        XCTAssertEqual(allIDs, [shortcutID])
        XCTAssertEqual(folderIDs, [shortcutID])
    }

    func testNonzeroExitUsesBoundedStandardError() async throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        printf 'failure detail' >&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(
            commandURL: executable,
            maximumCapturedByteCount: 7
        )

        do {
            _ = try await runner.runShortcut(id: UUID())
            XCTFail("Expected nonzero exit")
        } catch {
            XCTAssertEqual(
                error as? AppleShortcutsCommandError,
                .nonzeroExit(AppleShortcutsCommandResult(
                    exitCode: 7,
                    standardOutput: "",
                    standardError: "failure",
                    outputWasTruncated: true
                ))
            )
        }
    }

    func testEverySupportedOperationUsesTheExactArgumentVector() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("arguments.log")
        let itemID = UUID()
        let folderID = UUID()
        let escapedLog = log.path.replacingOccurrences(of: "'", with: "'\\''")
        let executable = try makeExecutable("""
        #!/bin/sh
        printf '%s' "$1" >> '\(escapedLog)'
        shift
        for argument in "$@"; do printf '|%s' "$argument" >> '\(escapedLog)'; done
        printf '\\n' >> '\(escapedLog)'
        printf 'Fixture (\(itemID.uuidString))\\n'
        """, in: directory)
        let runner = ProcessAppleShortcutsCommandRunner(commandURL: executable)

        _ = try await runner.listShortcuts()
        _ = try await runner.listFolders()
        _ = try await runner.listShortcuts(inFolder: folderID)
        _ = try await runner.runShortcut(id: itemID)
        try await runner.viewShortcut(name: "--help")

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "list|--show-identifiers",
            "list|--folders|--show-identifiers",
            "list|--folder-name|\(folderID.uuidString)|--show-identifiers",
            "run|\(itemID.uuidString)",
            "view|--|--help",
        ])
    }

    func testTruncatedDiscoveryFailsClosed() async throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        printf 'A very long shortcut name (\(UUID().uuidString))\\n'
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(
            commandURL: executable,
            maximumCapturedByteCount: 8
        )

        do {
            _ = try await runner.listShortcuts()
            XCTFail("Expected malformed truncated output")
        } catch {
            XCTAssertEqual(error as? AppleShortcutsCommandError, .malformedOutput)
        }
    }

    func testDuplicateDiscoveryIdentifierFailsClosed() async throws {
        let id = UUID()
        let executable = try makeExecutable("""
        #!/bin/sh
        printf 'Original (\(id.uuidString))\nRenamed (\(id.uuidString))\n'
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(commandURL: executable)

        do {
            _ = try await runner.listShortcuts()
            XCTFail("Expected malformed duplicate output")
        } catch {
            XCTAssertEqual(error as? AppleShortcutsCommandError, .malformedOutput)
        }
    }

    func testTimeoutTerminatesCommand() async throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        trap '' TERM
        sleep 10
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(
            commandURL: executable,
            runTimeout: 0.1
        )

        do {
            _ = try await runner.runShortcut(id: UUID())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AppleShortcutsCommandError, .timedOut)
        }
    }

    func testTimeoutForceKillsTermIgnoringDescendantAndDrainsPipes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let escapedPIDFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let executable = try makeExecutable("""
        #!/bin/sh
        trap '' TERM
        (trap '' TERM; exec yes output) &
        echo $! > '\(escapedPIDFile)'
        wait
        """, in: directory)
        let runner = ProcessAppleShortcutsCommandRunner(
            commandURL: executable,
            runTimeout: 1,
            maximumCapturedByteCount: 1_024
        )

        do {
            _ = try await runner.runShortcut(id: UUID())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AppleShortcutsCommandError, .timedOut)
        }

        let childPID = try XCTUnwrap(Int32(
            try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        for _ in 0 ..< 50 where kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellationTerminatesCommand() async throws {
        let executable = try makeExecutable("""
        #!/bin/sh
        sleep 10
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(commandURL: executable)
        let task = Task { try await runner.runShortcut(id: UUID()) }
        try await Task.sleep(for: .milliseconds(100))

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationBeforeLaunchClaimDoesNotSpawnCommand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let escapedMarker = marker.path.replacingOccurrences(of: "'", with: "'\\''")
        let executable = try makeExecutable("""
        #!/bin/sh
        printf launched > '\(escapedMarker)'
        """, in: directory)
        let gate = AppleShortcutsLaunchGate()
        let runner = ProcessAppleShortcutsCommandRunner(
            commandURL: executable,
            beforeProcessLaunch: { gate.pauseBeforeLaunch() },
            onProcessStopRequested: { gate.recordStop() }
        )
        let task = Task { try await runner.runShortcut(id: UUID()) }
        XCTAssertTrue(gate.waitUntilLaunchPaused())

        task.cancel()
        XCTAssertTrue(gate.waitUntilStopRecorded())
        gate.resumeLaunch()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before launch")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUnavailableExecutableFailsBeforeLaunch() async {
        let runner = ProcessAppleShortcutsCommandRunner(
            commandURL: URL(fileURLWithPath: "/private/mactools-missing-shortcuts")
        )
        do {
            _ = try await runner.listShortcuts()
            XCTFail("Expected unavailable executable")
        } catch {
            XCTAssertEqual(error as? AppleShortcutsCommandError, .executableUnavailable)
        }
    }

    func testPostCheckSpawnFailureIsTyped() async throws {
        let executable = try makeExecutable("not a Mach-O or script")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ProcessAppleShortcutsCommandRunner(commandURL: executable)

        do {
            _ = try await runner.runShortcut(id: UUID())
            XCTFail("Expected launch failure")
        } catch let AppleShortcutsCommandError.launchFailed(code) {
            XCTAssertEqual(code, ENOEXEC)
        } catch {
            XCTFail("Expected typed launch failure, got \(error)")
        }
    }

    private func makeExecutable(_ source: String, in suppliedDirectory: URL? = nil) throws -> URL {
        let directory = suppliedDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        if suppliedDirectory == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent("shortcuts-fixture")
        try Data(source.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        return url
    }
}

private final class AppleShortcutsLaunchGate: @unchecked Sendable {
    private let launchPaused = DispatchSemaphore(value: 0)
    private let launchResume = DispatchSemaphore(value: 0)
    private let stopRecorded = DispatchSemaphore(value: 0)

    func pauseBeforeLaunch() {
        launchPaused.signal()
        launchResume.wait()
    }

    func recordStop() {
        stopRecorded.signal()
    }

    func waitUntilLaunchPaused() -> Bool {
        launchPaused.wait(timeout: .now() + 2) == .success
    }

    func waitUntilStopRecorded() -> Bool {
        stopRecorded.wait(timeout: .now() + 2) == .success
    }

    func resumeLaunch() {
        launchResume.signal()
    }
}
