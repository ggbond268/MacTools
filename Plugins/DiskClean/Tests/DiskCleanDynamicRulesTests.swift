import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Dynamic rule provider tests (design §5.5, §11 "dynamic rules" row).
/// Always use temporary directories; never touch real user directories.
final class DiskCleanDynamicRulesTests: XCTestCase {
    private var root: URL!

    /// **Fixture roots always use `realpath(3)` physical paths**: `NSTemporaryDirectory()` lives under `/var/folders/...`,
    /// and `/var` is a symlink to `private/var`. `resolvingSymlinksInPath()` does not fix this
    /// (it tends to strip `/private` rather than add it); only realpath yields stable comparable paths.
    /// Reuse `DiskCleanTempDirectory.physicalPath(of:)` so two realpath implementations cannot drift.
    override func setUpWithError() throws {
        try super.setUpWithError()
        let created = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiskCleanDynamicRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: DiskCleanTempDirectory.physicalPath(of: created.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Version parsing

    // MARK: - Version directory provider

    func testVersionProviderKeepsNewestAndReturnsOlderVersions() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["2.1.9", "2.1.10", "2.1.215", "2.2.0"], in: container)

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["2.1.215", "2.1.10", "2.1.9"])
        // Candidate paths must stay under the container physical path: full-path compare is where realpath normalization matters.
        for item in items {
            XCTAssertTrue(item.path.hasPrefix(container.path + "/"), "candidate escaped container: \(item.path)")
        }
    }

    /// The version pointed to by `Current -> <version>` is in use and must not be a candidate even if it is not the newest.
    func testVersionProviderNeverReturnsVersionPinnedBySiblingSymlink() async throws {
        let container = try makeDirectory("GoogleUpdater")
        try makeDirectories(["149.0.7814.0", "150.0.7863.0", "151.0.7910.0"], in: container)
        try FileManager.default.createSymbolicLink(
            atPath: container.appendingPathComponent("Current").path,
            withDestinationPath: "149.0.7814.0"
        )

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["150.0.7863.0"])
    }

    /// Symlinks whose names look like versions are never candidates — deleting the link frees no space and may break callers.
    func testVersionProviderIgnoresSymlinkedVersionDirectories() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["1.0.0", "1.1.0", "1.2.0", "shared"], in: container)
        try FileManager.default.createSymbolicLink(
            atPath: container.appendingPathComponent("0.9.0").path,
            withDestinationPath: "shared"
        )

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["1.1.0", "1.0.0"])
    }

    func testUnavailableSimulatorProviderReturnsOnlyUnavailableExistingDeviceDirectories() async throws {
        let devices = try makeDirectory("Devices")
        let unavailable = "3A6B1C2D-0000-4000-8000-000000000001"
        let available = "3A6B1C2D-0000-4000-8000-000000000002"
        // Third device is unavailable in JSON, and its directory was already deleted by the user; it must not appear as a candidate.
        let missing = "3A6B1C2D-0000-4000-8000-000000000003"
        try makeDirectories([unavailable, available], in: devices)

        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[
          {"udid":"\(unavailable)","isAvailable":false,"name":"iPhone 15"},
          {"udid":"\(available)","isAvailable":true,"name":"iPhone 16"},
          {"udid":"\(missing)","isAvailable":false,"name":"deleted"}
        ]}}
        """

        let items = try await expandSimulators(devicesRoot: devices, outcome: .success(Data(json.utf8)))

        XCTAssertEqual(names(of: items), [unavailable])
    }

    func testUnavailableSimulatorProviderRejectsNonUUIDIdentifiers() async throws {
        let devices = try makeDirectory("Devices")
        try makeDirectories(["passwd"], in: devices)

        let json = """
        {"devices":{"runtime":[{"udid":"../passwd","isAvailable":false}]}}
        """

        let items = try await expandSimulators(devicesRoot: devices, outcome: .success(Data(json.utf8)))

        XCTAssertTrue(items.isEmpty)
    }

    func testUnavailableSimulatorProviderPropagatesTimeout() async throws {
        let devices = try makeDirectory("Devices")

        do {
            _ = try await expandSimulators(
                devicesRoot: devices,
                outcome: .failure(.timedOut(path: "/usr/bin/xcrun"))
            )
            XCTFail("timeout should throw")
        } catch let error as DiskCleanSubprocessError {
            XCTAssertEqual(error, .timedOut(path: "/usr/bin/xcrun"))
        }
    }

    // MARK: - Real subprocess executor

    func testLocalSubprocessRunnerCapturesStandardOutput() async throws {
        let result = try await LocalDiskCleanSubprocessRunner().run(
            executablePath: "/bin/echo",
            arguments: ["diskclean"],
            timeout: .seconds(5)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "diskclean\n")
    }

    func testLocalSubprocessRunnerTimesOutAndTerminatesChild() async throws {
        let started = Date()
        do {
            _ = try await LocalDiskCleanSubprocessRunner().run(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: .milliseconds(300)
            )
            XCTFail("timeout should throw")
        } catch let error as DiskCleanSubprocessError {
            guard case .timedOut = error else {
                return XCTFail("unexpected error type: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLocalSubprocessRunnerKillsTermIgnoringDescendantHoldingOutputPipe() async throws {
        let started = Date()
        do {
            _ = try await LocalDiskCleanSubprocessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", #"(trap '' TERM; sleep 30) & exit 0"#],
                timeout: .milliseconds(300)
            )
            XCTFail("descendant-held pipe should reach the bounded timeout")
        } catch let error as DiskCleanSubprocessError {
            guard case .timedOut = error else {
                return XCTFail("unexpected error type: \(error)")
            }
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            3,
            "SIGKILL escalation must close inherited pipe writers promptly"
        )
    }

    // MARK: - Helpers

    private struct FakeSubprocessRunner: DiskCleanSubprocessRunning {
        enum Outcome: Sendable {
            case success(Data)
            case exit(code: Int32, output: Data)
            case failure(DiskCleanSubprocessError)
        }

        let outcome: Outcome

        func run(
            executablePath: String,
            arguments: [String],
            timeout: Duration
        ) async throws -> DiskCleanSubprocessResult {
            switch outcome {
            case let .success(output):
                return DiskCleanSubprocessResult(exitCode: 0, standardOutput: output)
            case let .exit(code, output):
                return DiskCleanSubprocessResult(exitCode: code, standardOutput: output)
            case let .failure(error):
                throw error
            }
        }
    }

    private func expand(
        containerGlobs: [String],
        keepNewestCount: Int = 1
    ) async throws -> [DiskCleanFileItem] {
        let provider = DiskCleanVersionDirectoryRuleProvider(
            containerGlobs: containerGlobs,
            keepNewestCount: keepNewestCount
        )
        return try await provider.expand()
    }

    private func expandSimulators(
        devicesRoot: URL,
        outcome: FakeSubprocessRunner.Outcome
    ) async throws -> [DiskCleanFileItem] {
        let provider = DiskCleanUnavailableSimulatorRuleProvider(
            devicesRootPath: devicesRoot.path,
            executablePath: "/usr/bin/xcrun",
            timeout: .seconds(2),
            subprocessRunner: FakeSubprocessRunner(outcome: outcome)
        )
        return try await provider.expand()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectories(_ names: [String], in parent: URL) throws {
        for name in names where !name.isEmpty {
            try FileManager.default.createDirectory(
                at: parent.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func names(of items: [DiskCleanFileItem]) -> [String] {
        items.map { ($0.path as NSString).lastPathComponent }
    }
}
