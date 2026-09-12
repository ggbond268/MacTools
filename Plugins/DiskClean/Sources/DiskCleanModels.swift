import Foundation
import MacToolsPluginKit

// MARK: - Panel groups

/// The three scan-scope groups for the menu bar and detail page.
///
/// Rules v2 already split into ten `DiskCleanCategoryID`s, but the panel still keeps v1's three
/// groups: category cannot own "scan scope"—`aiTools` holds both `cache.ai-assistants` and
/// `developer.ai-agent-old-versions`, and the `developer` category still has a target whose
/// legacy id is `browser.service-worker`. Scope is always decided by `legacyRuleID` prefix so
/// scan coverage stays entry-for-entry equivalent to v1 (M5 will introduce category selection).
enum DiskCleanChoice: String, CaseIterable, Identifiable, Equatable, Sendable {
    case cache
    case developer
    case browser

    var id: String { rawValue }

    /// v1 rule-id prefix → panel group. Sole decision point for v1/v2 scan-scope equivalence.
    init?(legacyRuleID: String) {
        switch legacyRuleID.prefix(while: { $0 != "." }) {
        case "cache":
            self = .cache
        case "developer":
            self = .developer
        case "browser":
            self = .browser
        default:
            return nil
        }
    }

    var title: String {
        title()
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .cache:
            return localization.string("choice.cache.title", defaultValue: "缓存清理")
        case .developer:
            return localization.string("choice.developer.title", defaultValue: "开发者缓存清理")
        case .browser:
            return localization.string("choice.browser.title", defaultValue: "浏览器缓存清理")
        }
    }
}

// MARK: - Scan scope

/// Scope of one scan (design §10).
///
/// The three values map to the detail page's three independent sections. They share **one
/// pipeline**—same engine, sizing, Planner, and executor—differing only in where candidates come
/// from: rule-catalog expansion vs a dedicated scanner. Collapsing that difference into one enum
/// means the Controller does not need a second state machine for P2.
enum DiskCleanScanScope: Equatable, Sendable {
    /// Rule-catalog expansion (v1's three panel groups).
    case rules(choices: Set<DiskCleanChoice>)
    /// Developer-artifact purge (design §10.1). `roots` are user-configured scan roots, already
    /// normalized to physical paths.
    case developerArtifacts(roots: [String])
    /// Leftover installers (design §10.2). Scope is fixed to top-level `~/Downloads`; no parameters.
    case installers

    /// Section identity (parameters excluded). Used where only "which section" matters—selection UI,
    /// log prefixes, etc.
    var section: DiskCleanScanSection {
        switch self {
        case .rules:
            return .rules
        case .developerArtifacts:
            return .developerArtifacts
        case .installers:
            return .installers
        }
    }

    /// Empty scope = nothing to scan; the scan entry point should be disabled.
    /// Rules section: no group checked. Developer-artifacts section: no folders added yet.
    /// Both need guidance rather than a no-op spin.
    var isEmpty: Bool {
        switch self {
        case let .rules(choices):
            return choices.isEmpty
        case let .developerArtifacts(roots):
            return roots.isEmpty
        case .installers:
            return false
        }
    }

    /// Group set for the rules section. Other sections have no groups; returns empty.
    var choices: Set<DiskCleanChoice> {
        guard case let .rules(choices) = self else { return [] }
        return choices
    }

    var developerArtifactRoots: [String] {
        guard case let .developerArtifacts(roots) = self else { return [] }
        return roots
    }
}

enum DiskCleanScanSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case rules
    case developerArtifacts
    case installers

    var id: String { rawValue }
}

enum DiskCleanRisk: Equatable, Sendable {
    case low
    case medium
    case high
}

enum DiskCleanSafetyStatus: Equatable, Sendable {
    case allowed
    case whitelisted(rule: String)
    case protected(reason: String)
    case invalid(reason: String)
    case requiresAdmin(reason: String)
    case inUse(processName: String)

    var isCleanable: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }
}

// MARK: - Scan log

enum DiskCleanScanLogTone: Equatable, Sendable {
    case info
    case success
    case warning
    case error
}

struct DiskCleanScanLogMessage: Equatable, Sendable {
    let text: String
    let tone: DiskCleanScanLogTone
}

struct DiskCleanScanLogEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let tone: DiskCleanScanLogTone
}

// MARK: - Scan-level limitations

/// Completeness gaps for one scan (design §4.5).
///
/// Menu-bar "(limited)" and detail banners always derive from this, **not** from "a
/// permissionDenied candidate happens to exist": wholly skipped targets produce no candidates, so
/// only an explicit limitation can surface that fact.
enum DiskCleanScanLimitation: Equatable, Sendable {
    /// Full Disk Access not granted; targets skipped as a whole.
    case fdaRestricted(skippedTargetIDs: [String])
    /// Dynamic provider failed (subprocess timeout, malformed output).
    case dynamicRuleFailed(targetID: String, reason: String)
    /// Glob expansion failed. Not listed in design §4.5: fixed prefixes of path-type targets can
    /// also fail with EIO/EACCES; throwing the whole scan is worse than degrading, and reusing
    /// `dynamicRuleFailed` would misreport the cause.
    case targetExpansionFailed(targetID: String, reason: String)
    /// Non-local volume / candidates left unsized after circuit break.
    case volumeSkipped(path: String)
    /// An entire P2 scan root could not be opened (design §10): deleted directory, TCC denial, or
    /// not a directory.
    ///
    /// **Must stay distinct from "scanned but no candidates"**: when TCC denies `~/Downloads` it
    /// may still hold tens of GB of installers, and showing "nothing to clean" would lie.
    /// `reason` chooses guidance copy (authorize vs "folder no longer valid").
    case scanRootUnreadable(path: String, reason: DiskCleanScanCompleteness.PartialReason)
    /// WorkerPool abandon budget exhausted; this process will not run further sizing.
    case walkerCircuitBroken
    /// Cumulative count of abandoned threads.
    case threadsAbandoned(count: Int)
}

// MARK: - Candidate notes

/// Hints derived from candidate facts (design §10).
///
/// Split from `safety`: "can it be deleted" belongs to `safety`; "what to know before deleting"
/// belongs here. A note **does not affect cleanability**; it only drives badges and default
/// selection—default selection follows `risk`, set by the expansion source from the same facts
/// (see `DiskCleanCandidateFacts`). Keeping them separate is intentional: letting badges decide
/// deletability would open a second decision point beyond `isCleanable`.
enum DiskCleanCandidateNote: Equatable, Sendable {
    /// Owning git repo has uncommitted changes / unpushed commits / check failure (design §10.1;
    /// failures treated as dirty). Carries structured reason, not finished copy: this type enters
    /// the artifact; copy belongs in the view layer.
    case repositoryHasChanges(repositoryPath: String, reason: DiskCleanPurgeGitState.DirtyReason)
    /// Project root and matching project marker. `marker == nil` means unconditional hit (`__pycache__`).
    case developerProject(path: String, marker: String?)
    /// A `.zip` is not necessarily an installer (design §10.2).
    case mayNotBeInstaller
    /// Downloaded less than 7 days ago; may not be installed yet.
    case recentlyDownloaded(modifiedAt: Date)
}

/// Candidate attributes known only at expansion time.
///
/// Rule-target risk is fixed in the catalog, but P2 synthetic targets cannot do that: under the
/// same `purge.artifacts`, a clean-repo `node_modules` should default-select while one with
/// uncommitted changes should not, and dirtiness is only known after git runs. Risk may therefore
/// be overridden by the expansion source—**this is the only source of `candidate.risk !=
/// target.risk`**, and it only affects default selection (Planner and executor ignore risk).
struct DiskCleanCandidateFacts: Equatable, Sendable {
    /// nil = inherit target risk.
    var risk: DiskCleanRisk?
    var notes: [DiskCleanCandidateNote] = []

    static let inherited = DiskCleanCandidateFacts()
}

// MARK: - Candidate

/// One cleanup candidate.
///
/// `sizeResult == nil` means "discovered, size unknown"—expansion streams entries first so the
/// user sees content in 1–2s, with sizing filled in asynchronously (design §4.2). Unsized and
/// non-complete candidates are never cleanable (§3.1 invariant).
struct DiskCleanCandidate: Identifiable, Equatable, Sendable {
    /// `targetID::physicalPath`. A path belongs to at most one target (§5.3 ownership).
    let id: String
    let targetID: String
    /// v1 rule id. Audit, whitelist migration, and panel grouping all depend on it.
    let legacyRuleID: String
    let category: DiskCleanCategoryID
    /// **Physical path** (no symlink ancestors; design §13-6). Deletion and sizing use this.
    let path: String
    /// All pre-physical path aliases that resolved to `path` (e.g. both `~/.cache/pip` and
    /// `~/Library/Caches/pip` when they are the same object). Whitelist / sensitive checks
    /// consult every alias so a redirected home cache cannot slip past a lexical allowlist.
    let logicalPaths: [String]
    /// Default-selection policy looks only here. Rule candidates take target risk; P2 candidates
    /// may be overridden by the expansion source (see `DiskCleanCandidateFacts`).
    let risk: DiskCleanRisk
    let safety: DiskCleanSafetyStatus
    /// Display notes. Not part of cleanability.
    let notes: [DiskCleanCandidateNote]
    /// Size result. nil = not sized yet.
    let sizeResult: DiskCleanSizeResult?
    /// Structured rule explanation for why found, consequences, and safety disclosures.
    let explanation: DiskCleanRuleExplanation?

    /// Primary logical path (first alias, or the physical path when none differ).
    var logicalPath: String { logicalPaths.first ?? path }

    init(
        id: String,
        targetID: String,
        legacyRuleID: String,
        category: DiskCleanCategoryID,
        path: String,
        logicalPath: String? = nil,
        logicalPaths: [String]? = nil,
        risk: DiskCleanRisk,
        safety: DiskCleanSafetyStatus,
        notes: [DiskCleanCandidateNote] = [],
        sizeResult: DiskCleanSizeResult? = nil,
        explanation: DiskCleanRuleExplanation? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.legacyRuleID = legacyRuleID
        self.category = category
        self.path = path
        if let logicalPaths {
            self.logicalPaths = Self.uniquePaths(logicalPaths.isEmpty ? [path] : logicalPaths)
        } else if let logicalPath {
            self.logicalPaths = Self.uniquePaths([logicalPath])
        } else {
            self.logicalPaths = [path]
        }
        self.risk = risk
        self.safety = safety
        self.notes = notes
        self.sizeResult = sizeResult
        self.explanation = explanation
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }

    static func makeID(targetID: String, path: String) -> String {
        "\(targetID)::\(path)"
    }

    /// Panel group. Unrecognized legacyRuleID falls back to cache—never silently drop a candidate.
    var choice: DiskCleanChoice {
        DiskCleanChoice(legacyRuleID: legacyRuleID) ?? .cache
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    /// Estimated logical size. 0 when unsized; UI should show "calculating" from
    /// `sizeResult == nil`, not "0 bytes".
    var estimatedBytes: Int64 {
        max(sizeResult?.estimatedBytes ?? 0, 0)
    }

    /// Whether the candidate is cleanable.
    ///
    /// Design §3.1's core invariant lives here: safety allows **and** size is known **and**
    /// completeness is complete. `crossedMountPoint` needs no separate check—it always appears in
    /// the `partial` reason set and is already blocked by `isComplete`.
    var isCleanable: Bool {
        guard safety.isCleanable, let sizeResult else { return false }
        return sizeResult.completeness.isComplete && sizeResult.rootIdentity != nil
    }

    /// Observation time. The expiry gate (§4.4) takes the minimum across selected items.
    var observedAt: Date? {
        sizeResult?.observedAt
    }

    func applying(_ sizeResult: DiskCleanSizeResult) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            targetID: targetID,
            legacyRuleID: legacyRuleID,
            category: category,
            path: path,
            logicalPaths: logicalPaths,
            risk: risk,
            safety: safety,
            notes: notes,
            sizeResult: sizeResult,
            explanation: explanation
        )
    }

    /// Paths that must all be checked against lexical safety rules (every alias except the physical path itself).
    var safetyCheckPaths: [String] {
        logicalPaths.filter { $0 != path }
    }
}

// MARK: - Result freshness

/// Result expiry gate (design §4.4).
///
/// **Positioning: misuse protection** (against "scan, leave for hours, then clean"), **not TOCTOU
/// protection**—execution's real defenses are identity verification and the freeze primitive (§7).
/// No doc, comment, or user copy may claim this gate "prevents deleting unreviewed content".
enum DiskCleanScanFreshness {
    /// Expiry window. Cache TTL must be strictly smaller (see `DiskCleanSizeCache.timeToLive`).
    static let window: TimeInterval = 300

    static func deadline(minObservedAt: Date) -> Date {
        minObservedAt.addingTimeInterval(window)
    }
}

// MARK: - Scan events and artifact

enum DiskCleanScanEvent: Sendable {
    case log(DiskCleanScanLogMessage)
    /// Size unknown; not selectable.
    case candidateFound(DiskCleanCandidate)
    case candidateSized(id: DiskCleanCandidate.ID, result: DiskCleanSizeResult)
    case categoryFinished(DiskCleanCategoryID)
    case finished(DiskCleanScanSummary)
}

/// Immutable artifact of one scan; the **only** input to M4 `DiskCleanPlanner.makePlan` (design §6.1).
///
/// Planner derives exclusion set and reserved prefixes from this; the Controller can only pass
/// `selectedIDs` as subtraction, so it cannot forge evidence or omit reserved prefixes.
struct DiskCleanScanArtifact: Equatable, Sendable {
    let scope: DiskCleanScanScope
    /// All candidates (including non-cleanable), with final sizeResult.
    let candidates: [DiskCleanCandidate]
    /// Reserved roots of skipped / failed targets (`~` already expanded).
    ///
    /// These subtrees "exist but were not scanned"; Planner must forbid deleting their ancestors
    /// (§6.1 item 3).
    let reservedRootPaths: [String]
    let limitations: [DiskCleanScanLimitation]
    let startedAt: Date
    let finishedAt: Date

    var cleanableCandidates: [DiskCleanCandidate] {
        candidates.filter(\.isCleanable)
    }

    /// Paths of non-cleanable candidates.
    ///
    /// **Not** the Planner exclusion set: that is "all candidates not in the plan", which varies
    /// with selection and is derived inside `makePlan` (§6.1 item 2 explicitly rejects caller-supplied
    /// exclusions). This property is the selection-independent slice—locked / whitelisted /
    /// protected / partial / unsized—used by scan-engine tests to assert incomplete candidates
    /// really entered the exclusion set.
    var exclusionPaths: [String] {
        candidates.filter { !$0.isCleanable }.map(\.path)
    }
}

/// Scan summary (design §4.5). Stats always derive from the artifact so two number sources cannot disagree.
struct DiskCleanScanSummary: Equatable, Sendable {
    let artifact: DiskCleanScanArtifact

    var limitations: [DiskCleanScanLimitation] { artifact.limitations }
    var candidateCount: Int { artifact.candidates.count }
    var cleanableCount: Int { artifact.cleanableCandidates.count }
    var cleanableEstimatedBytes: Int64 {
        artifact.cleanableCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }
}

// MARK: - Controller-held scan result projection

/// UI projection of scan results. Exists while scanning (`artifact == nil`); completed scans carry the artifact.
struct DiskCleanScanResult: Equatable, Sendable {
    /// Scope that produced this result. Differing from the current scope means "result is stale"
    /// (`isResultStale`)—rules section: groups changed; developer-artifacts section: roots added/removed;
    /// same semantics either way.
    let scope: DiskCleanScanScope
    let candidates: [DiskCleanCandidate]
    let scannedAt: Date
    let limitations: [DiskCleanScanLimitation]
    /// Present only after scan completion. Cleanup entry accepts only non-nil artifacts.
    let artifact: DiskCleanScanArtifact?

    init(
        scope: DiskCleanScanScope,
        candidates: [DiskCleanCandidate],
        scannedAt: Date,
        limitations: [DiskCleanScanLimitation] = [],
        artifact: DiskCleanScanArtifact? = nil
    ) {
        self.scope = scope
        self.candidates = candidates
        self.scannedAt = scannedAt
        self.limitations = limitations
        self.artifact = artifact
    }

    var cleanableCandidates: [DiskCleanCandidate] {
        candidates.filter(\.isCleanable)
    }

    var cleanableSizeBytes: Int64 {
        cleanableCandidates.reduce(0) { $0 + $1.estimatedBytes }
    }

    var isLimited: Bool {
        !limitations.isEmpty
    }

    /// Expiry deadline: earliest observation among cleanable candidates + 300s. No cleanable
    /// candidates means no expiry needed.
    var expiryDeadline: Date? {
        cleanableCandidates
            .compactMap(\.observedAt)
            .min()
            .map(DiskCleanScanFreshness.deadline(minObservedAt:))
    }
}
