import Foundation
import Security
import XCTest
@testable import MacTools

final class CLIArtifactVerifierTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/unused-test-cli")

    private func verify(_ checks: CLIArtifactVerifier.SignatureChecks, notarized: Bool = true) throws {
        try CLIArtifactVerifier.verifySignature(at: executable, identifier: "test.mactools.nightly.cli",
            team: "TESTTEAM00", notarized: notarized, checks: checks)
    }

    func testColdCacheRecoveryRequiresFreshFullVerificationDespiteNonAppVerdict() throws {
        var events: [String] = []
        var hasTicket = false
        try verify(.init(check: { url, identifier, team, notarized in
            XCTAssertEqual(url, self.executable)
            XCTAssertEqual(identifier, "test.mactools.nightly.cli")
            XCTAssertEqual(team, "TESTTEAM00")
            events.append(notarized ? "full" : "identity")
            return !notarized || hasTicket ? errSecSuccess : errSecCSReqFailed
        }, assess: { url in
            XCTAssertEqual(url, self.executable)
            events.append("assessment")
            hasTicket = true
            return 3 // Gatekeeper fetched the ticket but the target is not an app.
        }))
        XCTAssertEqual(events, ["identity", "full", "assessment", "full"])
    }

    func testWarmCacheAndHostAuthenticationDoNotAssess() throws {
        for notarized in [true, false] {
            var checks: [Bool] = []
            try verify(.init(check: { _, _, _, full in
                checks.append(full)
                return errSecSuccess
            }, assess: { _ in
                XCTFail("No assessment needed")
                return 0
            }), notarized: notarized)
            XCTAssertEqual(checks, notarized ? [false, true] : [false])
        }
    }

    func testWrongPublisherOrInvalidSignatureNeverTriggersRecovery() {
        for failure in [errSecCSReqFailed, errSecCSSignatureFailed, errSecCSUnsigned] {
            XCTAssertThrowsError(try verify(.init(check: { _, _, _, full in
                XCTAssertFalse(full)
                return failure
            }, assess: { _ in
                XCTFail("Invalid identity must not reach Gatekeeper recovery")
                return 0
            }))) { XCTAssertEqual($0 as? CLIInstallError, .signature) }
        }
    }

    func testNonRequirementFailureDoesNotTriggerRecovery() {
        XCTAssertThrowsError(try verify(.init(check: { _, _, _, full in
            full ? errSecCSSignatureFailed : errSecSuccess
        }, assess: { _ in
            XCTFail("Only a failed notarization requirement is recoverable")
            return 0
        }))) { XCTAssertEqual($0 as? CLIInstallError, .signature) }
    }

    func testAssessmentSuccessCannotOverrideFailedFinalSignatureCheck() {
        for finalStatus in [errSecCSReqFailed, errSecCSSignatureFailed] {
            var fullChecks = 0
            var assessments = 0
            XCTAssertThrowsError(try verify(.init(check: { _, _, _, full in
                guard full else { return errSecSuccess }
                fullChecks += 1
                return fullChecks == 1 ? errSecCSReqFailed : finalStatus
            }, assess: { _ in
                assessments += 1
                return 0
            }))) { XCTAssertEqual($0 as? CLIInstallError, .notarization) }
            XCTAssertEqual(fullChecks, 2)
            XCTAssertEqual(assessments, 1)
        }
    }

    func testAssessmentTimeoutStopsRecovery() {
        var fullChecks = 0
        XCTAssertThrowsError(try verify(.init(check: { _, _, _, full in
            if full { fullChecks += 1 }
            return full ? errSecCSReqFailed : errSecSuccess
        }, assess: { _ in
            try CLIProcess.runResult(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05).status
        }))) { XCTAssertEqual($0 as? CLIInstallError, .notarization) }
        XCTAssertEqual(fullChecks, 1)
    }

    func testCancellationAfterAssessmentPreventsFinalVerification() async {
        let task = Task.detached {
            let checks = CLIArtifactVerifier.SignatureChecks(check: { _, _, _, full in
                full ? errSecCSReqFailed : errSecSuccess
            }, assess: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return 0
            })
            try CLIArtifactVerifier.verifySignature(at: URL(fileURLWithPath: "/unused-test-cli"),
                identifier: "test", team: "TESTTEAM00", notarized: true, checks: checks)
        }
        do {
            try await task.value
            XCTFail("Cancellation must stop verification")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProcessAssessmentVerdictIsSeparateFromStrictCommandSuccess() throws {
        let command = URL(fileURLWithPath: "/usr/bin/false")
        XCTAssertNotEqual(try CLIProcess.runResult(command, []).status, 0)
        XCTAssertThrowsError(try CLIProcess.run(command, []))
    }
}
