import Foundation
import MacToolsPluginKit

// MARK: - Risk ordering

/// Comparable risk levels for category display order (low → high) and assertions such as "dynamic rules are at least medium".
extension DiskCleanRisk: Comparable {
    static func < (lhs: DiskCleanRisk, rhs: DiskCleanRisk) -> Bool {
        lhs.severity < rhs.severity
    }

    private var severity: Int {
        switch self {
        case .low:
            return 0
        case .medium:
            return 1
        case .high:
            return 2
        }
    }
}

// MARK: - Categories

/// The ten cleanup categories in rules v2 (design §5.1).
///
/// Each category carries `risk` (display order and copy tone only), an honest `consequence`
/// string, and an SF Symbol. Whether a candidate is selected by default is decided by
/// **target-level** `risk`, not category risk — a category may mix risks (e.g. under
/// `developer`, `developer.docker` is medium while most others are low).
enum DiskCleanCategoryID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case userEssentials
    case appCaches
    case systemCaches
    case logs
    case developer
    case browsers
    case cloudOffice
    case communication
    case aiTools
    case virtualization
    /// P2 developer-artifact cleanup (design §10.1). Candidates come from user-configured scan roots, not rule-glob expansion.
    case developerArtifacts
    /// P2 leftover installers (design §10.2).
    case installers

    var id: String { rawValue }

    /// Detail-page and panel display order: low risk → high (design §5.1).
    /// `DiskCleanRisk` has only three levels while there are a dozen-plus categories, so this
    /// table owns the order; `risk` only guarantees the table is non-decreasing.
    ///
    /// The two P2 categories sit at the end but do not share a frame with rule categories —
    /// each renders in its own detail-page section, and order only matters inside a section.
    /// They still live in this table because grouping always filters by it; absence would
    /// silently drop the group.
    static let displayOrder: [DiskCleanCategoryID] = [
        .userEssentials,
        .appCaches,
        .logs,
        .browsers,
        .cloudOffice,
        .communication,
        .aiTools,
        .developer,
        .systemCaches,
        .virtualization,
        .installers,
        .developerArtifacts
    ]

    var risk: DiskCleanRisk {
        switch self {
        case .userEssentials, .appCaches, .logs, .browsers, .cloudOffice, .communication, .aiTools:
            return .low
        // Installers are the user's own files, not caches: a mistaken delete has no
        // "auto-rebuild" path, only re-download — shown at the same level as developer artifacts.
        case .developer, .systemCaches, .virtualization, .developerArtifacts, .installers:
            return .medium
        }
    }

    var symbolName: String {
        switch self {
        case .userEssentials:
            return "person.crop.circle"
        case .appCaches:
            return "square.grid.2x2"
        case .systemCaches:
            return "gearshape"
        case .logs:
            return "doc.text"
        case .developer:
            return "hammer"
        case .browsers:
            return "safari"
        case .cloudOffice:
            return "cloud"
        case .communication:
            return "bubble.left.and.bubble.right"
        case .aiTools:
            return "sparkles"
        case .virtualization:
            return "cube"
        case .developerArtifacts:
            return "shippingbox"
        case .installers:
            return "arrow.down.circle"
        }
    }

    var titleKey: String { "category.\(rawValue).title" }

    var consequenceKey: String { "category.\(rawValue).consequence" }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        localization.string(titleKey, defaultValue: defaultTitle)
    }

    /// One honest consequence string. Does not promise "no impact" or overstate risk.
    func consequence(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        localization.string(consequenceKey, defaultValue: defaultConsequence)
    }

    private var defaultTitle: String {
        switch self {
        case .userEssentials:
            return "用户缓存"
        case .appCaches:
            return "应用缓存"
        case .systemCaches:
            return "系统状态缓存"
        case .logs:
            return "日志与诊断报告"
        case .developer:
            return "开发者缓存"
        case .browsers:
            return "浏览器缓存"
        case .cloudOffice:
            return "云盘与办公"
        case .communication:
            return "通讯应用"
        case .aiTools:
            return "AI 工具"
        case .virtualization:
            return "虚拟化"
        case .developerArtifacts:
            return "开发产物"
        case .installers:
            return "残留安装包"
        }
    }

    private var defaultConsequence: String {
        switch self {
        case .userEssentials:
            return "应用首次启动会稍慢，登录状态与文档不受影响。"
        case .appCaches:
            return "相关应用首次打开会稍慢，缩略图与预览需要重新生成。"
        case .systemCaches:
            return "下次打开应用可能不恢复上次的窗口，预览缩略图需要重建。"
        case .logs:
            return "历史日志与诊断报告会丢失，反馈问题时可能缺少记录。"
        case .developer:
            return "首次构建会变慢，依赖与索引需要重新下载或生成。"
        case .browsers:
            return "首次访问网站会稍慢，书签与登录状态不受影响。"
        case .cloudOffice:
            return "云盘与办公应用需要重建本地缓存，同步会短暂变慢。"
        case .communication:
            return "聊天记录不受影响，图片与文件需要重新下载。"
        case .aiTools:
            return "对话记录不受影响，模型与界面资源需要重新缓存。"
        case .virtualization:
            return "虚拟机磁盘不受影响，快照缓存与临时文件需要重建。"
        case .developerArtifacts:
            return "源码与提交不受影响，依赖需要重新安装、产物需要重新构建。"
        case .installers:
            return "已安装的应用不受影响，安装包需要时可重新下载。"
        }
    }
}

// MARK: - Target-level rules

/// Cleanup targets in rules v2 (design §5.2).
///
/// v1 carried risk at "rule" granularity; v2 pushes it down to targets so one v1 rule can
/// split into several targets (e.g. `cache.user-essentials` becomes user-cache and user-log
/// categories), each with its own category and risk. `legacyRuleID` keeps the v1 rule id for
/// audit logs, whitelist migration, and mapping-snapshot tests.
struct DiskCleanRuleTarget: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Static glob group. Globs in one target share category, risk, and lock conditions.
        case path(globs: [String])
        /// Dynamic expansion (simctl, version-directory comparison, etc.; see `DiskCleanDynamicRules`).
        case dynamic(provider: any DiskCleanDynamicRuleProviding)
        /// Candidates are discovered by a dedicated scanner; the engine does not expand this
        /// target (design §10 P2 synthetic targets).
        ///
        /// The only reason this exists: **deletes must go through a plan minted by the Planner**,
        /// and the Planner looks up lock declarations by `targetID` in the catalog. P2 candidates
        /// must therefore hang on a real target; otherwise they would need a second minting path —
        /// exactly what this design forbids.
        case external
    }

    /// Stable target ID. Single-target rules reuse the v1 rule id; split targets append a suffix.
    let id: String
    /// v1 rule id. Multiple targets may share one legacyRuleID.
    let legacyRuleID: String
    let category: DiskCleanCategoryID
    /// Target-level risk. Default-selection policy looks only here (only `.low` is selected by default).
    let risk: DiskCleanRisk
    let kind: Kind
    /// Normalized absolute reserved roots (may use a `~` prefix; expand via `expandedReservedRootPaths` before use).
    ///
    /// **Required, regardless of whether the target ran successfully** (design §5.2, §6.1): when a
    /// target is skipped for FDA or a dynamic provider fails, content under these paths is treated
    /// as "present but unscanned", and the Planner refuses to delete their ancestors so an unreviewed
    /// subtree is never deleted as a side effect. Path targets derive these as literals from fixed
    /// directory prefixes of their globs.
    let reservedRootPaths: [String]
    /// Whether to skip the whole target without Full Disk Access (design §9). Set true only when
    /// every glob is under TCC protection; otherwise prefer degrading individual paths as
    /// `permissionDenied` over sacrificing other cleanable paths in the same target.
    let requiresFullDiskAccess: Bool
    /// App bundle IDs that lock the target while running (`NSWorkspace.runningApplications` snapshot).
    let lockedByBundleIDs: [String]
    /// Process names that lock the target while running (batched pgrep snapshot; covers non-app processes).
    let skipWhenProcessIsRunning: [String]
    /// Structured rule explanation for auditability, user review, and consequence disclosure.
    let explanation: DiskCleanRuleExplanation?

    init(
        id: String,
        legacyRuleID: String,
        category: DiskCleanCategoryID,
        risk: DiskCleanRisk,
        kind: Kind,
        reservedRootPaths: [String],
        requiresFullDiskAccess: Bool = false,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = [],
        explanation: DiskCleanRuleExplanation? = nil
    ) {
        self.id = id
        self.legacyRuleID = legacyRuleID
        self.category = category
        self.risk = risk
        self.kind = kind
        self.reservedRootPaths = reservedRootPaths
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.lockedByBundleIDs = lockedByBundleIDs
        self.skipWhenProcessIsRunning = skipWhenProcessIsRunning
        self.explanation = explanation
    }

    var pathGlobs: [String] {
        guard case let .path(globs) = kind else { return [] }
        return globs
    }

    var dynamicProvider: (any DiskCleanDynamicRuleProviding)? {
        guard case let .dynamic(provider) = kind else { return nil }
        return provider
    }

    var isDynamic: Bool { dynamicProvider != nil }

    /// Whether the engine skips this target during rule expansion.
    var isExternallyDiscovered: Bool {
        if case .external = kind { return true }
        return false
    }

    /// Reserved roots with `~` expanded. Ancestor assertions and reserved sets always use the expanded form so `~` is never compared against absolute paths.
    func expandedReservedRootPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        reservedRootPaths.map { Self.expandHome(in: $0, homeDirectory: homeDirectory) }
    }

    static func expandHome(in path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory + String(path.dropFirst())
    }

    /// Structured explanation for this target, deriving safe fallbacks when not explicitly declared.
    var resolvedExplanation: DiskCleanRuleExplanation {
        if let explanation {
            return explanation
        }
        return DiskCleanRuleExplanation(
            whyMatched: "Matches cleanup target pattern for \(id)",
            consequence: category.consequence(),
            safetyTier: DiskCleanSafetyTier(risk: risk),
            requiresFullDiskAccess: requiresFullDiskAccess,
            confidence: .high,
            title: id,
            dataClass: category == .logs ? .log : .cache,
            discoveryMethod: isDynamic ? .systemQuery : .knownPathPattern,
            defaultSelectionReason: risk == .low ? "低风险缓存，可自动清理" : "需要用户确认",
            provenance: .builtInMacToolsRule
        )
    }

    var whyMatched: String { resolvedExplanation.whyMatched }
    var consequence: String { resolvedExplanation.consequence }
    var safetyTier: DiskCleanSafetyTier { resolvedExplanation.safetyTier }
    var confidence: DiskCleanConfidence { resolvedExplanation.confidence }
}

// MARK: - Rule explainability

enum DiskCleanConfidence: String, Codable, Equatable, Sendable, CaseIterable {
    case high
    case medium
    case low
}

enum DiskCleanSafetyTier: String, Codable, Equatable, Sendable, CaseIterable {
    case safe
    case moderate
    case sensitive

    init(risk: DiskCleanRisk) {
        switch risk {
        case .low:
            self = .safe
        case .medium:
            self = .moderate
        case .high:
            self = .sensitive
        }
    }

    var titleKey: String {
        "safetyTier.\(rawValue).title"
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .safe:
            return localization.string("safetyTier.safe.title", defaultValue: "安全")
        case .moderate:
            return localization.string("safetyTier.moderate.title", defaultValue: "中等")
        case .sensitive:
            return localization.string("safetyTier.sensitive.title", defaultValue: "敏感")
        }
    }
}

enum DiskCleanDataClass: String, Codable, Equatable, Sendable, CaseIterable {
    case cache
    case log
    case diagnostic
    case downloadedResource
    case generatedDependency
    case buildArtifact
    case installer
    case temporaryState
}

enum DiskCleanDiscoveryMethod: String, Codable, Equatable, Sendable, CaseIterable {
    case knownPath
    case knownPathPattern
    case systemQuery
    case applicationVersionComparison
    case userConfiguredRoot
    case projectMarker
}

enum DiskCleanRuleProvenance: String, Codable, Equatable, Sendable, CaseIterable {
    case builtInMacToolsRule
    case macOSDocumentedLocation
    case applicationDocumentedLocation
    case independentlyVerifiedBehavior
}

struct DiskCleanRuleExplanation: Codable, Equatable, Sendable {
    let whyMatched: String
    let consequence: String
    let safetyTier: DiskCleanSafetyTier
    let requiresFullDiskAccess: Bool
    let confidence: DiskCleanConfidence

    let title: String?
    let summary: String?
    let dataClass: DiskCleanDataClass?
    let owner: String?
    let discoveryMethod: DiskCleanDiscoveryMethod?
    let defaultSelectionReason: String?
    let regeneration: String?
    let provenance: DiskCleanRuleProvenance?

    var whyFound: String { whyMatched }

    init(
        whyMatched: String,
        consequence: String,
        safetyTier: DiskCleanSafetyTier = .safe,
        requiresFullDiskAccess: Bool = false,
        confidence: DiskCleanConfidence = .high,
        title: String? = nil,
        summary: String? = nil,
        dataClass: DiskCleanDataClass? = nil,
        owner: String? = nil,
        discoveryMethod: DiskCleanDiscoveryMethod? = nil,
        defaultSelectionReason: String? = nil,
        regeneration: String? = nil,
        provenance: DiskCleanRuleProvenance? = nil
    ) {
        self.whyMatched = whyMatched
        self.consequence = consequence
        self.safetyTier = safetyTier
        self.requiresFullDiskAccess = requiresFullDiskAccess
        self.confidence = confidence
        self.title = title
        self.summary = summary
        self.dataClass = dataClass
        self.owner = owner
        self.discoveryMethod = discoveryMethod
        self.defaultSelectionReason = defaultSelectionReason
        self.regeneration = regeneration
        self.provenance = provenance
    }
}
