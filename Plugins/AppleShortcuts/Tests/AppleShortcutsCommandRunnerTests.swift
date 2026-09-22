import Darwin
import Foundation
import XCTest
@testable import AppleShortcutsPlugin

final class AppleShortcutsCommandRunnerTests: XCTestCase {

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

    func testDiscoveryAndExecutionUseExactArgumentsAndParseResults() async throws {
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

        let shortcuts = try await runner.listShortcuts()
        let folders = try await runner.listFolders()
        let folderShortcuts = try await runner.listShortcuts(inFolder: folderID)
        let execution = try await runner.runShortcut(id: itemID)
        try await runner.viewShortcut(name: "--help")

        XCTAssertEqual(shortcuts.map(\.id), [itemID])
        XCTAssertEqual(folders.map(\.id), [itemID])
        XCTAssertEqual(folderShortcuts.map(\.id), [itemID])
        XCTAssertEqual(execution.standardOutput, "Fixture (\(itemID.uuidString))\n")
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
