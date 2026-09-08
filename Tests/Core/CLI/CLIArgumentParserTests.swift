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

    func testRejectsMalformedCommands() {
        for arguments in [
            ["actions", "run"],
            ["actions", "run", "test/run", "--timeout", "0"],
            ["actions", "run", "test/run", "--timeout", "301"],
            ["actions", "run", "test/run", "--timeout", "1", "--timeout", "2"],
            ["actions", "run", "test/run", "--parameter", "enabled=true"],
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

    func testRunProducesBoundedTypedRequest() throws {
        for (arguments, expectedTimeout, json) in [
            (["actions", "run", "test/run"], 60, false),
            (["actions", "run", "test/run", "--json", "--timeout", "12"], 12, true),
        ] {
            guard case let .run(payload, actualJSON, timeout) = try CLIArgumentParser().parse(arguments) else {
                return XCTFail("Expected run")
            }
            XCTAssertEqual(actualJSON, json)
            XCTAssertEqual(timeout, expectedTimeout)
            XCTAssertEqual(
                try CLIExecutionValidation.decode(CLIActionRunRequest.self, from: payload),
                CLIActionRunRequest(id: "test/run", timeoutSeconds: expectedTimeout)
            )
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
