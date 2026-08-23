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
}
