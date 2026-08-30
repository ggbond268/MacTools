import MacToolsCLIProtocol
import XCTest

final class CLIExecutableTests: XCTestCase {
    func testHelpAndVersionWorkWithoutLaunchingTheHost() throws {
        let help = try runCLI(["help"])
        XCTAssertEqual(help.status, CLIExitCode.success.rawValue)
        XCTAssertTrue(help.output.contains("version [--json]"))
        XCTAssertTrue(help.output.contains("doctor [--json]"))
        XCTAssertTrue(help.output.contains("actions list"))

        let version = try runCLI(["version", "--json"])
        XCTAssertEqual(version.status, CLIExitCode.success.rawValue)
        XCTAssertTrue(version.error.isEmpty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(version.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["command"] as? String, "version")
        XCTAssertEqual(object["outcome"] as? String, "completed")
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        XCTAssertNotEqual(data["cliVersion"] as? String, "unknown")
        XCTAssertNotEqual(data["cliBuild"] as? String, "unknown")
    }

    func testExecutionIsRejectedWithStableJSON() throws {
        let result = try runCLI(["actions", "run", "test/run", "--json"])
        XCTAssertEqual(result.status, CLIExitCode.invalidInput.rawValue)
        XCTAssertTrue(result.error.isEmpty)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["outcome"] as? String, "invalidInput")
        XCTAssertEqual(
            (object["rejection"] as? [String: Any])?["category"] as? String,
            "invalidCommand"
        )
    }

    private func runCLI(
        _ arguments: [String]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("mactools")
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
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
}
