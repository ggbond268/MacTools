import XCTest
import MacToolsPluginKit
@testable import MacTools

final class CLIProtocolCodecTests: XCTestCase {
    func testNegotiationRequiresThreeWayOverlapWhenHostIsRegistered() {
        XCTAssertEqual(
            CLIProtocolNegotiator.selectedVersion(
                clientMinimum: 1,
                clientMaximum: 3,
                brokerMinimum: 1,
                brokerMaximum: 2,
                hostMinimum: 1,
                hostMaximum: 1
            ),
            1
        )
        XCTAssertNil(CLIProtocolNegotiator.selectedVersion(
            clientMinimum: 2,
            clientMaximum: 3,
            brokerMinimum: 1,
            brokerMaximum: 2,
            hostMinimum: 1,
            hostMaximum: 1
        ))
    }

    func testTimestampsUseFractionalSeconds() {
        XCTAssertEqual(
            CLIProtocolCodec.timestamp(Date(timeIntervalSince1970: 0.123)),
            "1970-01-01T00:00:00.123Z"
        )
    }

    func testRequestRoundTripAndUnknownTopLevelKeyRejection() throws {
        let request = CLIActionListRequest(runnableOnly: true, continuationToken: nil)
        let data = try CLIProtocolCodec.encodeRequest(request)
        XCTAssertEqual(
            try CLIProtocolCodec.decodeRequest(
                CLIActionListRequest.self,
                from: data,
                allowedKeys: ["runnableOnly", "continuationToken"]
            ),
            request
        )

        let unknown = Data(#"{"runnableOnly":true,"future":1}"#.utf8)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIActionListRequest.self,
            from: unknown,
            allowedKeys: ["runnableOnly"]
        ))

        let duplicate = Data(#"{"runnableOnly":true,"runnableOnly":false}"#.utf8)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIActionListRequest.self,
            from: duplicate,
            allowedKeys: ["runnableOnly"]
        )) { error in
            XCTAssertEqual(error as? CLIProtocolCodecError, .duplicateFields(["runnableOnly"]))
        }
    }

    func testRejectsOversizedRequestsAndNonFiniteValues() throws {
        let oversized = Data(repeating: 0x20, count: CLIProtocolVersion.maximumRequestBytes + 1)
        XCTAssertThrowsError(try CLIProtocolCodec.decodeRequest(
            CLIActionListRequest.self,
            from: oversized,
            allowedKeys: ["runnableOnly"]
        ))
        XCTAssertThrowsError(try CLIProtocolCodec.encodeRequest(
            ["value": CLIParameterValue.double(.infinity)]
        ))
    }

    func testExecutionSourceAndExposureSurfaceAreForwardCompatible() throws {
        let source = ActionExecutionSource(rawValue: "future-source")
        let encoded = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(ActionExecutionSource.self, from: encoded), source)
        XCTAssertEqual(ActionExecutionSource.cli.rawValue, "cli")
        XCTAssertEqual(ActionExposureSurface.cli.rawValue, "cli")
    }
}
