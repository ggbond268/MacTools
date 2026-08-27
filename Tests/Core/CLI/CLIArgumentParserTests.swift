import XCTest
@testable import MacTools

final class CLIArgumentParserTests: XCTestCase {
    func testParsesOnlyPhaseZeroCommands() throws {
        XCTAssertEqual(try CLIArgumentParser().parse([]), .help)
        XCTAssertEqual(try CLIArgumentParser().parse(["help"]), .help)
        XCTAssertEqual(try CLIArgumentParser().parse(["version"]), .version(json: false))
        XCTAssertEqual(try CLIArgumentParser().parse(["version", "--json"]), .version(json: true))
        XCTAssertEqual(try CLIArgumentParser().parse(["doctor"]), .doctor(json: false))
        XCTAssertEqual(try CLIArgumentParser().parse(["doctor", "--json"]), .doctor(json: true))
    }

    func testRejectsPostPhaseZeroAndMalformedCommands() {
        for arguments in [
            ["actions", "list"],
            ["plugins", "list"],
            ["workflows", "run", "name"],
            ["doctor", "--unknown"],
            ["doctor", "--json", "--json"],
            ["help", "--json"],
        ] {
            XCTAssertThrowsError(try CLIArgumentParser().parse(arguments), arguments.joined(separator: " "))
        }
    }
}
