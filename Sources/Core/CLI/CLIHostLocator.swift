import AppKit
import CoreServices
import Foundation

struct CLIHostCandidate: Equatable {
    let url: URL
    let bundleIdentifier: String?
    let version: String?
    let build: String?
}

enum CLIHostLocationError: Error, Equatable {
    case notFound(bundleIdentifier: String)
    case versionIncompatible(expected: String, found: [String], candidate: URL?)
    case teamMismatch(candidate: URL?)
    case roleMismatch(candidate: URL?)
    case invalidSignature(candidate: URL?)

    var category: String {
        switch self {
        case .notFound: return "hostNotFound"
        case .versionIncompatible: return "hostVersionIncompatible"
        case .teamMismatch: return "hostTeamMismatch"
        case .roleMismatch: return "hostRoleMismatch"
        case .invalidSignature: return "hostSignatureInvalid"
        }
    }

    var message: String {
        switch self {
        case .notFound:
            return "MacTools is not installed."
        case let .versionIncompatible(expected, found, _):
            let installed = found.isEmpty ? "unknown" : found.joined(separator: ", ")
            return "No installed MacTools app matches CLI version \(expected). Found: \(installed)."
        case .teamMismatch:
            return "The installed MacTools app belongs to a different developer team."
        case .roleMismatch:
            return "The installed application does not have the expected MacTools identity."
        case .invalidSignature:
            return "The installed MacTools application signature is invalid."
        }
    }

    var candidateURL: URL? {
        switch self {
        case .notFound: return nil
        case let .versionIncompatible(_, _, candidate),
             let .teamMismatch(candidate),
             let .roleMismatch(candidate),
             let .invalidSignature(candidate):
            return candidate
        }
    }
}

struct CLIHostLocator {
    typealias CandidateProvider = (String) -> [CLIHostCandidate]
    typealias IdentityEvaluator = (URL) -> CLIHostIdentityAssessment

    private let candidateProvider: CandidateProvider
    private let identityEvaluator: IdentityEvaluator

    init(identityValidator: CLIPeerIdentityValidator = CLIPeerIdentityValidator()) {
        candidateProvider = Self.launchServicesCandidates(bundleIdentifier:)
        identityEvaluator = { applicationURL in
            identityValidator.applicationIdentityAssessment(
                at: applicationURL,
                as: .host
            )
        }
    }

    init(
        candidateProvider: @escaping CandidateProvider,
        identityEvaluator: @escaping IdentityEvaluator
    ) {
        self.candidateProvider = candidateProvider
        self.identityEvaluator = identityEvaluator
    }

    func locate(
        bundleIdentifier: String,
        version: String,
        build: String
    ) throws -> URL {
        let candidates = candidateProvider(bundleIdentifier).sorted {
            $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path
        }
        guard !candidates.isEmpty else {
            throw CLIHostLocationError.notFound(bundleIdentifier: bundleIdentifier)
        }

        let assessed = candidates.map { candidate in
            let assessment = candidate.bundleIdentifier == bundleIdentifier
                ? identityEvaluator(candidate.url)
                : CLIHostIdentityAssessment.wrongRole
            return (candidate: candidate, assessment: assessment)
        }

        let exactRelease = assessed.filter {
            $0.candidate.version == version && $0.candidate.build == build
        }
        if let match = exactRelease.first(where: { $0.assessment == .accepted }) {
            return match.candidate.url.standardizedFileURL
        }
        if let rejectedExactRelease = exactRelease.first {
            throw locationError(
                assessment: rejectedExactRelease.assessment,
                candidate: rejectedExactRelease.candidate.url
            )
        }

        let trusted = assessed.filter { $0.assessment == .accepted }.map(\.candidate)
        if !trusted.isEmpty {
            let found = trusted.map {
                "\($0.version ?? "unknown") (\($0.build ?? "unknown"))"
            }
            throw CLIHostLocationError.versionIncompatible(
                expected: "\(version) (\(build))",
                found: found,
                candidate: trusted.first?.url
            )
        }

        let rejected = assessed[0]
        throw locationError(
            assessment: rejected.assessment,
            candidate: rejected.candidate.url
        )
    }

    private func locationError(
        assessment: CLIHostIdentityAssessment,
        candidate: URL
    ) -> CLIHostLocationError {
        switch assessment {
        case .wrongTeam: return .teamMismatch(candidate: candidate)
        case .wrongRole: return .roleMismatch(candidate: candidate)
        case .invalidSignature: return .invalidSignature(candidate: candidate)
        case .accepted:
            preconditionFailure("Accepted candidates are handled before rejection mapping.")
        }
    }

    private static func launchServicesCandidates(bundleIdentifier: String) -> [CLIHostCandidate] {
        guard let values = LSCopyApplicationURLsForBundleIdentifier(
            bundleIdentifier as CFString,
            nil
        )?.takeRetainedValue() as? [URL] else { return [] }

        var seen = Set<String>()
        return values.compactMap { url in
            let standardizedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(standardizedURL.path).inserted,
                  let bundle = Bundle(url: standardizedURL) else { return nil }
            return CLIHostCandidate(
                url: standardizedURL,
                bundleIdentifier: bundle.bundleIdentifier,
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            )
        }
    }
}
