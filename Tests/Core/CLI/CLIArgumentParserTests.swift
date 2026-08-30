import XCTest
import MacToolsCLIProtocol
@testable import MacTools

final class CLIArgumentParserTests: XCTestCase {
    func testPreservesPhaseZeroCommands() throws {
        XCTAssertEqual(try CLIArgumentParser().parse([]), .help)
        XCTAssertEqual(try CLIArgumentParser().parse(["help"]), .help)
        XCTAssertEqual(try CLIArgumentParser().parse(["version"]), .version(json: false))
        XCTAssertEqual(try CLIArgumentParser().parse(["version", "--json"]), .version(json: true))
        XCTAssertEqual(try CLIArgumentParser().parse(["doctor"]), .doctor(json: false))
        XCTAssertEqual(try CLIArgumentParser().parse(["doctor", "--json"]), .doctor(json: true))
    }

    func testRejectsExecutionAndMalformedCommands() {
        for arguments in [
            ["actions", "run", "test/run"],
            ["actions", "list", "--parameter", "enabled=true"],
            ["actions", "list", "--page-size", "0"],
            ["actions", "list", "--page-size", "101"],
            ["actions", "list", "--page-size", "1", "--page-size", "2"],
            ["actions", "list", "--cursor", "invalid"],
            ["actions", "describe", "test/run", "--json", "--json"],
            ["actions", "describe", "test/run", "extra"],
            ["plugins", "list"],
            ["workflows", "run", "name"],
            ["doctor", "--unknown"],
            ["doctor", "--json", "--json"],
            ["help", "--json"],
        ] {
            XCTAssertThrowsError(try CLIArgumentParser().parse(arguments), arguments.joined(separator: " "))
        }
    }

    func testDiscoveryArgumentsProduceTypedPayloads() throws {
        guard case let .discovery(operation, payload, json) = try CLIArgumentParser().parse(
            ["actions", "list", "--json", "--page-size", "2"]
        ) else { return XCTFail("Expected discovery") }
        XCTAssertEqual(operation, .actionsList)
        XCTAssertTrue(json)
        XCTAssertEqual(try CLIDiscoveryValidation.decode(CLIActionListRequest.self, from: payload),
                       CLIActionListRequest(pageSize: 2))
        for verb in ["describe", "availability"] {
            guard case let .discovery(operation, payload, _) = try CLIArgumentParser().parse(
                ["actions", verb, "test/run"]
            ) else { return XCTFail("Expected discovery") }
            XCTAssertEqual(operation.rawValue, "actions.\(verb)")
            XCTAssertEqual(try CLIDiscoveryValidation.decode(CLIActionTargetRequest.self, from: payload).id, "test/run")
        }
    }
}
