import XCTest
@testable import MacTools

final class CLIParameterInputTests: XCTestCase {
    func testJSONRejectsDuplicateParameterNames() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path,
            contents: Data(#"{"name":"first","name":"second"}"#.utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try CLIParameterInput().json(path: file.path)) { error in
            XCTAssertEqual(error as? CLIParameterInputError, .invalidJSON)
        }
    }

    func testConvertsPublicArgumentTypesAndRejectsSensitiveValues() throws {
        let definitions = [
            CLIActionParameter(id: "name", title: "Name", kind: "string", isRequired: true, privacy: "public", portability: "portable"),
            CLIActionParameter(id: "count", title: "Count", kind: "integer", isRequired: true, privacy: "public", portability: "portable"),
            CLIActionParameter(id: "ratio", title: "Ratio", kind: "double", isRequired: true, privacy: "public", portability: "portable"),
            CLIActionParameter(id: "enabled", title: "Enabled", kind: "boolean", isRequired: true, privacy: "public", portability: "portable"),
            CLIActionParameter(id: "token", title: "Token", kind: "string", isRequired: false, privacy: "sensitive", portability: "localOnly"),
        ]
        XCTAssertEqual(try CLIParameterInput().arguments([
            "name": "demo", "count": "4", "ratio": "1.5", "enabled": "yes",
        ], definitions: definitions), [
            "name": .string("demo"), "count": .integer(4), "ratio": .double(1.5), "enabled": .boolean(true),
        ])
        XCTAssertThrowsError(try CLIParameterInput().arguments(
            ["token": "visible"], definitions: definitions
        )) { error in
            XCTAssertEqual(error as? CLIParameterInputError, .sensitiveArgument("token"))
        }
    }

    func testProtectedJSONRequiresOwnedUserOnlyRegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secure = root.appendingPathComponent("secure.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: secure.path,
            contents: Data(#"{"token":"secret","count":2}"#.utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        let parsed = try CLIParameterInput().json(path: secure.path)
        XCTAssertEqual(parsed.source, .protectedFile)
        XCTAssertEqual(parsed.values["token"], .string("secret"))
        XCTAssertEqual(parsed.values["count"], .integer(2))

        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secure)
        XCTAssertThrowsError(try CLIParameterInput().json(path: link.path))

        let open = root.appendingPathComponent("open.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: open.path,
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o644]
        ))
        XCTAssertThrowsError(try CLIParameterInput().json(path: open.path))
    }
}
