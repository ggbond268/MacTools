import Foundation

extension UninstallCandidate {
    var eligible: Bool {
        snapshot != nil && blockedReason == nil && [.verified, .strong].contains(confidence)
            && ![.groupContainer, .launchAgent].contains(dataClass)
    }
    var selectedByDefault: Bool { eligible && dataClass.isDisposable }
}

extension UninstallScan {
    var canPlan: Bool {
        inventoryComplete && sourceChecksComplete && application.restrictions.isEmpty
            && ![.homebrew, .system, .managed, .vendorRequired].contains(application.source)
    }
}

/// Only the planner constructs plans. External actions never accept paths or selections for execution.
struct UninstallPlan: Identifiable, Sendable {
    let id: UUID
    let scanID: UUID
    let application: UninstallApplication
    let createdAt: Date
    let expiresAt: Date
    let items: [UninstallCandidate]
    let retained: [UninstallCandidate]
    let coverage: [UninstallCoverage]
    fileprivate init(scan: UninstallScan, items: [UninstallCandidate], now: Date) {
        id = UUID(); scanID = scan.id; application = scan.application; createdAt = now
        expiresAt = scan.expiresAt; self.items = items
        retained = scan.candidates.filter { candidate in !items.contains { $0.id == candidate.id } }
        coverage = scan.coverage
    }
    var estimatedBytes: Int64 { items.reduce(0) { $0 + ($1.snapshot?.allocatedBytes ?? 0) } }
}

enum UninstallPlanner {
    static func make(scan: UninstallScan, selectedIDs: Set<String>, now: Date = Date()) throws -> UninstallPlan {
        guard now >= scan.observedAt, now < scan.expiresAt else { throw AppUninstallerError.expired }
        guard scan.canPlan else { throw AppUninstallerError.blocked }
        guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(scan.candidates.map(\.id))) else {
            throw AppUninstallerError.unsafePath
        }
        let selected = scan.candidates.filter { selectedIDs.contains($0.id) }
        guard selected.allSatisfy(\.eligible) else { throw AppUninstallerError.blocked }
        let sorted = selected.sorted { $0.path.count < $1.path.count }
        var items: [UninstallCandidate] = []
        for candidate in sorted where !items.contains(where: { UninstallPaths.contains(candidate.path, in: $0.path) }) { items.append(candidate) }
        // Keep the app available for identity and ownership revalidation until associated items finish.
        items.sort { ($0.dataClass == .application ? 1 : 0, $0.path) < ($1.dataClass == .application ? 1 : 0, $1.path) }
        return UninstallPlan(scan: scan, items: items, now: now)
    }
}

enum UninstallDisposition: String, Codable, Sendable {
    case trashed, retained, changed, running, blocked, failed, cancelled, needsAttention
}

struct UninstallItemResult: Identifiable, Codable, Sendable {
    var id: String { originalPath }
    let originalPath: String
    let destinationPath: String?
    let disposition: UninstallDisposition
    let message: String?
}

struct UninstallRun: Identifiable, Codable, Sendable {
    let id: UUID
    let scanID: UUID
    let application: UninstallApplication
    let startedAt: Date
    var finishedAt: Date?
    let estimatedBytes: Int64
    let selectedCount: Int
    var results: [UninstallItemResult]
    var complete: Bool {
        finishedAt != nil && results.filter { $0.disposition == .trashed }.count == selectedCount
            && !results.contains { $0.disposition == .needsAttention }
    }
}
