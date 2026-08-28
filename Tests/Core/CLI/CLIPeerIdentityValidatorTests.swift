import XCTest
@testable import MacTools

final class CLIPeerIdentityValidatorTests: XCTestCase {
    func testLocalIdentityCacheReusesSuccessfulValidation() {
        var cache = CLILocalPeerIdentityCache()
        var loadCount = 0
        let identity = CLIPeerIdentity(
            processIdentifier: 1,
            effectiveUserIdentifier: 501,
            signingIdentifier: "app.example.mactools",
            teamIdentifier: "TEAM123"
        )

        let first = cache.resolve {
            loadCount += 1
            return identity
        }
        let second = cache.resolve {
            loadCount += 1
            return nil
        }

        XCTAssertEqual(first, identity)
        XCTAssertEqual(second, identity)
        XCTAssertEqual(loadCount, 1)
    }

    func testLocalIdentityCacheRetriesAfterValidationFailure() {
        var cache = CLILocalPeerIdentityCache()
        var loadCount = 0

        XCTAssertNil(cache.resolve {
            loadCount += 1
            return nil
        })
        XCTAssertNil(cache.resolve {
            loadCount += 1
            return nil
        })
        XCTAssertEqual(loadCount, 2)
    }

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
            validator.expectedSigningIdentifier(
                for: .commandLineTool,
                brokerIdentifier: releaseBroker
            ),
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

    func testPeerMatchingRejectsOtherReleaseChannelsInBothDirections() {
        let validator = CLIPeerIdentityValidator()
        let hosts = ["com.example.mactools", "com.example.mactools.dev", "com.example.mactools.nightly"]
        for brokerHost in hosts {
            let broker = CLIPeerIdentity(
                processIdentifier: 1, effectiveUserIdentifier: 501,
                signingIdentifier: brokerHost + ".cli-broker", teamIdentifier: "TEAM123"
            )
            for peerHost in hosts {
                for (role, suffix) in [(CLIPeerRole.host, ""), (.commandLineTool, ".cli"), (.broker, ".cli-broker")] {
                    let peer = CLIPeerIdentity(
                        processIdentifier: 2, effectiveUserIdentifier: 501,
                        signingIdentifier: peerHost + suffix, teamIdentifier: "TEAM123"
                    )
                    XCTAssertEqual(validator.matches(peer, as: role, relativeTo: broker), peerHost == brokerHost)
                }
            }
        }
    }

    func testCompleteRequirementIncludesAppleAnchorExactRoleAndTeam() {
        XCTAssertEqual(
            CLIPeerIdentityValidator().requirementString(
                signingIdentifier: "app.example.mactools.cli",
                teamIdentifier: "TEAM123"
            ),
            "anchor apple generic and identifier \"app.example.mactools.cli\" "
                + "and certificate leaf[subject.OU] = \"TEAM123\""
        )
    }

    func testAdHocSignedApplicationIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("mactools-host")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executable
        )
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = [
            "--force", "--sign", "-", "--timestamp=none",
            "--identifier", "app.example.mactools", executable.path,
        ]
        try signer.run()
        signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)

        let broker = CLIPeerIdentity(
            processIdentifier: 1,
            effectiveUserIdentifier: geteuid(),
            signingIdentifier: "app.example.mactools.cli-broker",
            teamIdentifier: "TEAM123"
        )
        XCTAssertEqual(
            CLIPeerIdentityValidator().applicationIdentityAssessment(
                at: executable,
                as: .host,
                relativeTo: broker
            ),
            .invalidSignature
        )
    }
}
