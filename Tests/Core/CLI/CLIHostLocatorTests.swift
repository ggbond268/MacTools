import XCTest
@testable import MacTools

final class CLIHostLocatorTests: XCTestCase {
    private let hostIdentifier = "app.ggbond.MacTools"

    func testSelectsVersionMatchedCandidateInsteadOfFirstRegisteredApplication() throws {
        let old = candidate(path: "/Applications/A-MacTools.app", version: "1.1.6", build: "60")
        let matching = candidate(
            path: "/Users/test/Applications/Z-MacTools.app",
            version: "1.2.0",
            build: "69"
        )
        let locator = locator(candidates: [old, matching]) { _ in .accepted }

        XCTAssertEqual(
            try locator.locate(
                bundleIdentifier: hostIdentifier,
                version: "1.2.0",
                build: "69"
            ),
            matching.url
        )
    }

    func testSelectionIsDeterministicWhenMultipleCandidatesMatch() throws {
        let first = candidate(path: "/Applications/A-MacTools.app")
        let second = candidate(path: "/Applications/Z-MacTools.app")
        let locator = locator(candidates: [second, first]) { _ in .accepted }

        XCTAssertEqual(
            try locator.locate(
                bundleIdentifier: hostIdentifier,
                version: "1.2.0",
                build: "69"
            ),
            first.url
        )
    }

    func testReportsEveryDiscoveryFailureCategory() {
        assertFailure(
            locator(candidates: []) { _ in .accepted },
            category: "hostNotFound"
        )
        assertFailure(
            locator(candidates: [candidate(version: "1.1.6", build: "60")]) { _ in .accepted },
            category: "hostVersionIncompatible"
        )
        assertFailure(
            locator(candidates: [candidate()]) { _ in .wrongTeam },
            category: "hostTeamMismatch"
        )
        assertFailure(
            locator(candidates: [candidate()]) { _ in .wrongRole },
            category: "hostRoleMismatch"
        )
        assertFailure(
            locator(candidates: [candidate()]) { _ in .invalidSignature },
            category: "hostSignatureInvalid"
        )
    }

    func testRejectsCandidateWhoseBundleIdentifierDoesNotMatch() {
        let candidate = CLIHostCandidate(
            url: URL(fileURLWithPath: "/Applications/Other.app"),
            bundleIdentifier: "example.Other",
            version: "1.2.0",
            build: "69"
        )
        let locator = locator(candidates: [candidate]) { _ in .accepted }

        assertFailure(locator, category: "hostRoleMismatch")
    }

    private func assertFailure(
        _ locator: CLIHostLocator,
        category: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try locator.locate(
                bundleIdentifier: hostIdentifier,
                version: "1.2.0",
                build: "69"
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                (error as? CLIHostLocationError)?.category,
                category,
                file: file,
                line: line
            )
        }
    }

    private func locator(
        candidates: [CLIHostCandidate],
        identityEvaluator: @escaping (URL) -> CLIHostIdentityAssessment
    ) -> CLIHostLocator {
        CLIHostLocator(
            candidateProvider: { _ in candidates },
            identityEvaluator: identityEvaluator
        )
    }

    private func candidate(
        path: String = "/Applications/MacTools.app",
        version: String = "1.2.0",
        build: String = "69"
    ) -> CLIHostCandidate {
        CLIHostCandidate(
            url: URL(fileURLWithPath: path),
            bundleIdentifier: hostIdentifier,
            version: version,
            build: build
        )
    }
}
