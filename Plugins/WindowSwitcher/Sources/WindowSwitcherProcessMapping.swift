import AppKit
import Foundation

/// Chrome, Electron, and similar apps often render user windows in an accessory
/// helper. Display and app activation use the host PID; AX actions retain their
/// source worker, while capture and WindowServer operations use the owner PID.
enum WindowSwitcherProcessMapping {
    struct Candidate: Equatable, Sendable {
        var processIdentifier: pid_t
        var bundleIdentifier: String?
        var bundlePath: String?
        var isRegular: Bool
        var isTerminated: Bool = false
    }

    struct Snapshot: Equatable, Sendable {
        var hostByOwner: [pid_t: pid_t] = [:]

        func host(for pid: pid_t) -> pid_t { hostByOwner[pid] ?? pid }

        func helpersByHost(owningWindowsIn records: [WindowSwitcherWindowRecord]) -> [pid_t: Set<pid_t>] {
            var helpers: [pid_t: Set<pid_t>] = [:]
            for record in records {
                let owner = record.processIdentifier
                guard let host = hostByOwner[owner], host != owner else { continue }
                helpers[host, default: []].insert(owner)
            }
            return helpers
        }
    }

    static func snapshot(
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Snapshot {
        snapshot(
            candidates: runningApplications.map {
                Candidate(
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    bundlePath: $0.bundleURL?.path,
                    isRegular: $0.activationPolicy == .regular,
                    isTerminated: $0.isTerminated
                )
            },
            ownPID: ownPID
        )
    }

    static func snapshot(candidates: [Candidate], ownPID: pid_t) -> Snapshot {
        let live = candidates.filter { !$0.isTerminated && $0.processIdentifier != ownPID && $0.processIdentifier > 0 }
        let regularPaths = Dictionary(
            uniqueKeysWithValues: live.compactMap { candidate -> (pid_t, String)? in
                guard candidate.isRegular, let path = normalizedPath(candidate.bundlePath) else { return nil }
                return (candidate.processIdentifier, path)
            }
        )
        let regularBundles = Dictionary(
            uniqueKeysWithValues: live.compactMap { candidate -> (pid_t, String)? in
                guard candidate.isRegular, let bundle = candidate.bundleIdentifier, !bundle.isEmpty else { return nil }
                return (candidate.processIdentifier, bundle)
            }
        )
        var hostByOwner: [pid_t: pid_t] = [:]
        for candidate in live {
            let pid = candidate.processIdentifier
            if let path = candidate.bundlePath, let host = embeddedHostPID(helperBundlePath: path, regularBundlePaths: regularPaths), host != pid {
                hostByOwner[pid] = host
                continue
            }
            if !candidate.isRegular, let helperBundle = candidate.bundleIdentifier,
               let host = regularBundles.first(where: { looksLikeHelperBundle(helperBundle, host: $0.value) })?.key,
               host != pid {
                hostByOwner[pid] = host
            }
        }
        return Snapshot(hostByOwner: hostByOwner)
    }

    static func embeddedHostPID(helperBundlePath: String, regularBundlePaths: [pid_t: String]) -> pid_t? {
        guard let helperPath = normalizedPath(helperBundlePath) else { return nil }
        return regularBundlePaths
            .filter { _, hostPath in helperPath.hasPrefix(hostPath + "/") }
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?
            .key
    }

    static func looksLikeHelperBundle(_ helper: String, host: String) -> Bool {
        guard helper.hasPrefix(host + "."), helper != host else { return false }
        let tail = helper.dropFirst(host.count + 1).lowercased()
        return tail.contains("helper") || tail.contains("renderer") || tail == "gpu" || tail.contains("plugin")
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
