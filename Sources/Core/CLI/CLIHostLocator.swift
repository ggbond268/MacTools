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

        var accepted: [CLIHostCandidate] = []
        var failures: [(CLIHostIdentityAssessment, URL)] = []
        for candidate in candidates {
            guard candidate.bundleIdentifier == bundleIdentifier else {
                failures.append((.wrongRole, candidate.url))
                continue
            }
            let assessment = identityEvaluator(candidate.url)
            if assessment == .accepted {
                accepted.append(candidate)
            } else {
                failures.append((assessment, candidate.url))
            }
        }

        if let match = accepted.first(where: { $0.version == version && $0.build == build }) {
            return match.url.standardizedFileURL
        }
        if !accepted.isEmpty {
            let found = accepted.map {
                "\($0.version ?? "unknown") (\($0.build ?? "unknown"))"
            }
            throw CLIHostLocationError.versionIncompatible(
                expected: "(version) ((build))",
                found: found,
                candidate: accepted.first?.url
            )
        }
        if let candidate = failures.first(where: { $0.0 == .wrongTeam })?.1 {
            throw CLIHostLocationError.teamMismatch(candidate: candidate)
        }
        if let candidate = failures.first(where: { $0.0 == .wrongRole })?.1 {
            throw CLIHostLocationError.roleMismatch(candidate: candidate)
        }
        throw CLIHostLocationError.invalidSignature(candidate: failures.first?.1)
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
