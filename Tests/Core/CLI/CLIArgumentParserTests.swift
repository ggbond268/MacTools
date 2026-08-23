import XCTest
@testable import MacTools

final class CLIArgumentParserTests: XCTestCase {
    func testParsesActionRunWithTypedInputOptions() throws {
        let command = try CLIArgumentParser().parse([
            "actions", "run", "display/brightness",
            "--parameter", "level=50", "--no-wait", "--json",
        ])
        guard case let .actionRun(arguments) = command else {
            return XCTFail("Expected action run")
        }
        XCTAssertEqual(arguments.target, "display/brightness")
        XCTAssertEqual(arguments.rawParameters, ["level": "50"])
        XCTAssertTrue(arguments.noWait)
        XCTAssertTrue(arguments.json)
    }

    func testRejectsDuplicateOrConflictingInputSources() throws {
        XCTAssertThrowsError(try CLIArgumentParser().parse([
            "actions", "run", "provider/action",
            "--input-json", "one.json", "--input-json", "two.json",
        ]))
        XCTAssertThrowsError(try CLIArgumentParser().parse([
            "actions", "run", "provider/action",
            "--parameter", "name=value", "--input-json", "input.json",
        ]))
        XCTAssertThrowsError(try CLIArgumentParser().parse([
            "workflows", "run", "Daily", "--parameter", "name=value",
        ]))
    }

    func testRejectsInvalidActionIdentity() {
        XCTAssertThrowsError(try CLIArgumentParser().parse([
            "actions", "describe", "not-an-action",
        ]))
    }
}
