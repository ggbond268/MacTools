import XCTest
@testable import MacTools

final class CLIPeerIdentityValidatorTests: XCTestCase {
    func testExactPeerMatchingRejectsWrongUserTeamIdentifierAndRole() {
        let validator = CLIPeerIdentityValidator()
        let broker = CLIPeerIdentity(
            processIdentifier: 1,
            effectiveUserIdentifier: 501,
            signingIdentifier: "app.example.mactools.cli-broker",
            teamIdentifier: "TEAM123"
        )
        let validCLI = CLIPeerIdentity(
            processIdentifier: 2,
            effectiveUserIdentifier: 501,
            signingIdentifier: "app.example.mactools.cli",
            teamIdentifier: "TEAM123"
        )
        XCTAssertTrue(validator.matches(validCLI, as: .commandLineTool, relativeTo: broker))
        XCTAssertFalse(validator.matches(
            CLIPeerIdentity(
                processIdentifier: 2,
                effectiveUserIdentifier: 502,
                signingIdentifier: validCLI.signingIdentifier,
                teamIdentifier: validCLI.teamIdentifier
            ),
            as: .commandLineTool,
            relativeTo: broker
        ))
        XCTAssertFalse(validator.matches(
            CLIPeerIdentity(
                processIdentifier: 2,
                effectiveUserIdentifier: 501,
                signingIdentifier: validCLI.signingIdentifier,
                teamIdentifier: "WRONG"
            ),
            as: .commandLineTool,
            relativeTo: broker
        ))
        XCTAssertFalse(validator.matches(validCLI, as: .host, relativeTo: broker))
    }

    func testDerivesExactRoleSpecificSigningIdentifiers() {
        let validator = CLIPeerIdentityValidator()
        let releaseBroker = "app.ggbond.MacTools.mactools.cli-broker"
        XCTAssertEqual(
            validator.expectedSigningIdentifier(for: .host, brokerIdentifier: releaseBroker),
            "app.ggbond.MacTools.mactools"
        )
        XCTAssertEqual(
            validator.expectedSigningIdentifier(for: .commandLineTool, brokerIdentifier: releaseBroker),
            "app.ggbond.MacTools.mactools.cli"
        )
        XCTAssertEqual(
            validator.expectedSigningIdentifier(for: .broker, brokerIdentifier: releaseBroker),
            releaseBroker
        )
    }

    func testCLIIdentityCanDeriveItsBrokerIdentity() {
        XCTAssertEqual(
            CLIPeerIdentityValidator().expectedSigningIdentifier(
                for: .broker,
                brokerIdentifier: "app.ggbond.MacTools.mactools.dev.cli"
            ),
            "app.ggbond.MacTools.mactools.dev.cli-broker"
        )
    }
}
