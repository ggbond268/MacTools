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
        XCTAssertThrowsError(try CLIParameterInput().json(
            path: file.path,
            definitions: [parameter("name", kind: "string")]
        )) { error in
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
        let parsed = try CLIParameterInput().json(
            path: secure.path,
            definitions: [
                parameter("token", kind: "string", privacy: "sensitive"),
                parameter("count", kind: "integer"),
            ]
        )
        XCTAssertEqual(parsed.source, .protectedFile)
        XCTAssertEqual(parsed.values["token"], .string("secret"))
        XCTAssertEqual(parsed.values["count"], .integer(2))

        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secure)
        XCTAssertThrowsError(try CLIParameterInput().json(path: link.path, definitions: []))

        let open = root.appendingPathComponent("open.json")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: open.path,
            contents: Data("{}".utf8),
            attributes: [.posixPermissions: 0o644]
        ))
        XCTAssertThrowsError(try CLIParameterInput().json(path: open.path, definitions: []))
    }

    func testJSONIntegerConversionPreservesInt64BoundsAndRejectsAdjacentValues() throws {
        XCTAssertEqual(
            try parseJSON(#"{"value":9223372036854775807}"#, kind: "integer"),
            .integer(Int64.max)
        )
        XCTAssertEqual(
            try parseJSON(#"{"value":-9223372036854775808}"#, kind: "integer"),
            .integer(Int64.min)
        )
        XCTAssertThrowsError(try parseJSON(#"{"value":9223372036854775808}"#, kind: "integer")) { error in
            XCTAssertEqual(error as? CLIParameterInputError, .invalidValue("value"))
        }
        XCTAssertThrowsError(try parseJSON(#"{"value":-9223372036854775809}"#, kind: "integer")) { error in
            XCTAssertEqual(error as? CLIParameterInputError, .invalidValue("value"))
        }
    }

    func testJSONPreservesBooleanIntegerAndFloatingScalarTypes() throws {
        let values = try parseJSONObject(
            #"{"zero":0,"one":1,"trueValue":true,"falseValue":false,"oneDouble":1.0,"twoDouble":2.0,"exponent":1e3}"#,
            definitions: [
                parameter("zero", kind: "integer"),
                parameter("one", kind: "integer"),
                parameter("trueValue", kind: "boolean"),
                parameter("falseValue", kind: "boolean"),
                parameter("oneDouble", kind: "double"),
                parameter("twoDouble", kind: "double"),
                parameter("exponent", kind: "double"),
            ]
        )

        XCTAssertEqual(values["zero"], .integer(0))
        XCTAssertEqual(values["one"], .integer(1))
        XCTAssertEqual(values["trueValue"], .boolean(true))
        XCTAssertEqual(values["falseValue"], .boolean(false))
        XCTAssertEqual(values["oneDouble"], .double(1))
        XCTAssertEqual(values["twoDouble"], .double(2))
        XCTAssertEqual(values["exponent"], .double(1_000))
    }

    func testJSONRejectsCrossTypeNumericAndBooleanValues() {
        XCTAssertThrowsError(try parseJSON(#"{"value":1}"#, kind: "boolean"))
        XCTAssertThrowsError(try parseJSON(#"{"value":true}"#, kind: "integer"))
        XCTAssertThrowsError(try parseJSON(#"{"value":1.5}"#, kind: "integer"))
    }

    private func parseJSON(
        _ json: String,
        kind: String
    ) throws -> CLIParameterValue? {
        try parseJSONObject(
            json,
            definitions: [parameter("value", kind: kind)]
        )["value"]
    }

    private func parseJSONObject(
        _ json: String,
        definitions: [CLIActionParameter]
    ) throws -> [String: CLIParameterValue] {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path,
            contents: Data(json.utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        defer { try? FileManager.default.removeItem(at: file) }
        return try CLIParameterInput().json(
            path: file.path,
            definitions: definitions
        ).values
    }

    private func parameter(
        _ id: String,
        kind: String,
        privacy: String = "public"
    ) -> CLIActionParameter {
        CLIActionParameter(
            id: id,
            title: id,
            kind: kind,
            isRequired: true,
            privacy: privacy,
            portability: "portable"
        )
    }
}
