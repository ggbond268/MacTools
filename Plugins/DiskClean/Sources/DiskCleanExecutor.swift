import Foundation

// MARK: - Execution interface

/// The executor only accepts `DiskCleanValidatedPlan` (design §6.1, §7).
///
/// The type system carries a safety duty here: `ValidatedPlan.init` is fileprivate; the only cast site is
/// `DiskCleanPlanner.makePlan`. There is no "pass a list of paths and delete them" entry, so no path around validation.
protocol DiskCleanExecuting: Sendable {
    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult
}

// MARK: - Plan-level failure

/// Preflight failure (design §7.1). Any case aborts the **whole run with zero deletions**.
enum DiskCleanExecutionError: LocalizedError, Equatable {
    case planExpired
    case lockedDuringPreflight(path: String, processName: String)
    case safetyRejected(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .planExpired:
            return "扫描结果已过期，请重新扫描"
        case let .lockedDuringPreflight(path, processName):
            return "\(processName) 正在使用 \(path)，已取消本次清理"
        case let .safetyRejected(path, reason):
            return "\(path) 未通过安全校验（\(reason)），已取消本次清理"
        }
    }
}

// MARK: - Execution result

struct DiskCleanExecutionItemResult: Equatable, Sendable {
    /// Terminal status (design §7.5). `changedSinceScan` and `rollbackBlocked` are separate, not folded into skipped/failed:
    /// the former should prompt a rescan; the latter needs a pinned alert in cleanup history—user actions differ entirely.
    enum Outcome: Equatable, Sendable {
        case removed(reclaimedBytes: Int64)
        case trashed(reclaimedBytes: Int64, stagedName: String)
        case skipped(DiskCleanSafetyStatus)
        case changedSinceScan
        case failed(message: String)
        case partiallyDeleted(stagedName: String, message: String)
        case rollbackBlocked(stagedName: String, message: String)
    }

    let candidateID: DiskCleanCandidate.ID
    let path: String
    let outcome: Outcome

    /// Estimated reclaimed bytes. **Not actual free space** (APFS clones / sparse files / hard links outside the tree).
    /// Copy always says "about X"; Trash mode must not say "reclaimed" (design §7.7).
    var reclaimedBytes: Int64 {
        switch outcome {
        case let .removed(reclaimedBytes):
            return max(reclaimedBytes, 0)
        case let .trashed(reclaimedBytes, _):
            return max(reclaimedBytes, 0)
        case .skipped, .changedSinceScan, .failed, .partiallyDeleted, .rollbackBlocked:
            return 0
        }
    }

    /// Honest terminal statuses that need a pinned alert in cleanup history.
    var needsAttention: Bool {
        switch outcome {
        case .partiallyDeleted, .rollbackBlocked:
            return true
        case .removed, .trashed, .skipped, .changedSinceScan, .failed:
            return false
        }
    }
}

struct DiskCleanExecutionResult: Equatable, Sendable {
    let itemResults: [DiskCleanExecutionItemResult]
    let mode: DiskCleanRemovalMode
    let wasCancelled: Bool

    init(
        itemResults: [DiskCleanExecutionItemResult],
        mode: DiskCleanRemovalMode = .trash,
        wasCancelled: Bool = false
    ) {
        self.itemResults = itemResults
        self.mode = mode
        self.wasCancelled = wasCancelled
    }

    /// Disposed item count: permanent delete and move-to-Trash both count as success.
    var removedCount: Int {
        itemResults.filter {
            switch $0.outcome {
            case .removed, .trashed:
                return true
            case .skipped, .changedSinceScan, .failed, .partiallyDeleted, .rollbackBlocked:
                return false
            }
        }.count
    }

    /// Skipped item count: safety-policy rejection and content changed since scan. Neither touches the object.
    var skippedCount: Int {
        itemResults.filter {
            switch $0.outcome {
            case .skipped, .changedSinceScan:
                return true
            case .removed, .trashed, .failed, .partiallyDeleted, .rollbackBlocked:
                return false
            }
        }.count
    }

    /// Items that did not finish cleanly. `partiallyDeleted` / `rollbackBlocked` count here—
    /// they are not success; burying them under "cleaned" would be dishonest.
    var failedCount: Int {
        itemResults.filter {
            switch $0.outcome {
            case .failed, .partiallyDeleted, .rollbackBlocked:
                return true
            case .removed, .trashed, .skipped, .changedSinceScan:
                return false
            }
        }.count
    }

    var changedSinceScanCount: Int {
        itemResults.filter { $0.outcome == .changedSinceScan }.count
    }

    var attentionResults: [DiskCleanExecutionItemResult] {
        itemResults.filter(\.needsAttention)
    }

    var reclaimedBytes: Int64 {
        itemResults.reduce(0) { $0 + $1.reclaimedBytes }
    }
}

// MARK: - Executor

/// Plan executor (design §7.1, §7.2).
///
/// Responsibility: this type owns **ordering and revalidation**; only `DiskCleanPlanItemRemoving` actually mutates files.
/// Three independent defenses: Planner validates at cast time; preflight and per-item revalidation run here;
/// the primitive authenticates identity on the fd. They do not share decision points, so a defect in one layer cannot collapse the whole chain.
struct DiskCleanExecutor: DiskCleanExecuting {
    private let primitive: any DiskCleanPlanItemRemoving
    private let safetyPolicy: DiskCleanSafetyPolicy
    private let runningAppLock: any DiskCleanRunningAppSnapshotting
    private let auditLog: DiskCleanAuditLog
    private let now: @Sendable () -> Date

    init(
        storageDirectory: URL = DiskCleanStorageLocation.fallbackDirectory,
        journal: DiskCleanStagingJournal? = nil,
        auditLog: DiskCleanAuditLog? = nil,
        safetyPolicy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy(),
        runningAppLock: any DiskCleanRunningAppSnapshotting = DiskCleanRunningAppLock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let sharedJournal = journal ?? DiskCleanStagingJournal(directory: storageDirectory)
        self.init(
            primitive: DiskCleanRemovalPrimitive(journal: sharedJournal, now: now),
            safetyPolicy: safetyPolicy,
            runningAppLock: runningAppLock,
            auditLog: auditLog ?? DiskCleanAuditLog(directory: storageDirectory),
            now: now
        )
    }

    init(
        primitive: any DiskCleanPlanItemRemoving,
        safetyPolicy: DiskCleanSafetyPolicy,
        runningAppLock: any DiskCleanRunningAppSnapshotting,
        auditLog: DiskCleanAuditLog,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.primitive = primitive
        self.safetyPolicy = safetyPolicy
        self.runningAppLock = runningAppLock
        self.auditLog = auditLog
        self.now = now
    }

    func execute(plan: DiskCleanValidatedPlan) async throws -> DiskCleanExecutionResult {
        var snapshot = try await preflight(plan: plan)
        let runID = UUID().uuidString

        var itemResults: [DiskCleanExecutionItemResult] = []
        itemResults.reserveCapacity(plan.items.count)

        for item in plan.items {
            if Task.isCancelled {
                recordRunSummary(runID: runID, plan: plan, itemResults: itemResults, wasCancelled: true)
                return DiskCleanExecutionResult(
                    itemResults: itemResults,
                    mode: plan.mode,
                    wasCancelled: true
                )
            }

            // Per-item lock recheck: refresh bundle IDs; keep process names from the preflight snapshot (trade-off noted on the protocol).
            snapshot = await runningAppLock.refreshingBundleIDs(in: snapshot)
            if Task.isCancelled {
                recordRunSummary(runID: runID, plan: plan, itemResults: itemResults, wasCancelled: true)
                return DiskCleanExecutionResult(
                    itemResults: itemResults,
                    mode: plan.mode,
                    wasCancelled: true
                )
            }
            if let processName = snapshot.lockingProcessName(
                bundleIDs: item.lockedByBundleIDs,
                processNames: item.skipWhenProcessIsRunning
            ) {
                itemResults.append(
                    record(item: item, outcome: .skipped(.inUse(processName: processName)), mode: plan.mode, runID: runID)
                )
                continue
            }

            // Second SafetyPolicy check: the whitelist may grow after the scan; staged-name protection also applies here.
            // Check physical + logical so a redirected home cache still matches lexical whitelist rules.
            let safety = safetyPolicy.safetyStatus(
                for: item.path,
                alsoChecking: item.safetyCheckPaths
            )
            guard safety.isCleanable else {
                itemResults.append(record(item: item, outcome: .skipped(safety), mode: plan.mode, runID: runID))
                continue
            }

            let disposition = primitive.remove(item, mode: plan.mode)
            itemResults.append(
                record(item: item, outcome: Self.outcome(for: disposition, item: item), mode: plan.mode, runID: runID)
            )
        }

        recordRunSummary(runID: runID, plan: plan, itemResults: itemResults, wasCancelled: false)
        return DiskCleanExecutionResult(itemResults: itemResults, mode: plan.mode)
    }

    private func recordRunSummary(
        runID: String,
        plan: DiskCleanValidatedPlan,
        itemResults: [DiskCleanExecutionItemResult],
        wasCancelled: Bool
    ) {
        let categories = Array(Set(plan.items.map { $0.category.rawValue })).sorted()
        let removedCount = itemResults.filter {
            switch $0.outcome {
            case .removed, .trashed:
                return true
            case .skipped, .changedSinceScan, .failed, .partiallyDeleted, .rollbackBlocked:
                return false
            }
        }.count
        let reclaimedBytes = itemResults.reduce(0) { $0 + $1.reclaimedBytes }
        let errors = itemResults.compactMap { item -> String? in
            switch item.outcome {
            case let .failed(msg):
                return msg
            case let .partiallyDeleted(_, msg):
                return msg
            case let .rollbackBlocked(_, msg):
                return msg
            case .removed, .trashed, .skipped, .changedSinceScan:
                return nil
            }
        }

        let status: String
        if wasCancelled {
            status = "cancelled"
        } else if !errors.isEmpty {
            status = "completedWithErrors"
        } else {
            status = "ok"
        }

        auditLog.append(
            DiskCleanAuditLog.Record(
                timestamp: now(),
                action: .runSummary,
                runID: runID,
                status: status,
                categoriesCleaned: categories,
                itemsRemoved: removedCount,
                bytesRemoved: reclaimedBytes,
                errorsEncountered: errors,
                isTrash: plan.mode == .trash
            )
        )
    }

    // MARK: - preflight（§7.1）

    private func preflight(plan: DiskCleanValidatedPlan) async throws -> DiskCleanRunningAppSnapshot {
        // 1. Expiry recheck. The confirm window must not cross expiry, but the clock is still evaluated at execution time.
        guard now() < plan.expiryDeadline else {
            throw DiskCleanExecutionError.planExpired
        }

        // 2. Fresh snapshot + lock/safety precheck of every plan item. Any failure aborts the whole run.
        let processNames = Array(Set(plan.items.flatMap(\.skipWhenProcessIsRunning)))
        let snapshot = await runningAppLock.makeSnapshot(processNames: processNames)
        for item in plan.items {
            if let processName = snapshot.lockingProcessName(
                bundleIDs: item.lockedByBundleIDs,
                processNames: item.skipWhenProcessIsRunning
            ) {
                throw DiskCleanExecutionError.lockedDuringPreflight(path: item.path, processName: processName)
            }
            let safety = safetyPolicy.safetyStatus(
                for: item.path,
                alsoChecking: item.safetyCheckPaths
            )
            guard safety.isCleanable else {
                throw DiskCleanExecutionError.safetyRejected(
                    path: item.path,
                    reason: Self.describe(safety)
                )
            }
        }

        // 3. Re-run ancestor assertions with the plan's own evidence. Evidence is in-plan and independently recheckable—this layer guards against
        //    defects in the Planner itself; pure in-memory compare, negligible cost.
        try DiskCleanPlanner.assertNoAncestorViolation(
            plannedPaths: plan.items.map(\.path),
            exclusionPaths: plan.exclusionPaths,
            reservedPrefixes: plan.reservedPrefixes
        )

        return snapshot
    }

    // MARK: - Terminal-status mapping and audit

    private static func outcome(
        for disposition: DiskCleanRemovalDisposition,
        item: DiskCleanValidatedPlan.PlanItem
    ) -> DiskCleanExecutionItemResult.Outcome {
        switch disposition {
        case .removed:
            return .removed(reclaimedBytes: item.estimatedBytes)
        case let .trashed(stagedName):
            return .trashed(reclaimedBytes: item.estimatedBytes, stagedName: stagedName)
        case .changedSinceScan:
            return .changedSinceScan
        case let .failed(reason):
            return .failed(message: reason)
        case let .partiallyDeleted(stagedName, reason):
            return .partiallyDeleted(stagedName: stagedName, message: reason)
        case let .rollbackBlocked(stagedName, reason):
            return .rollbackBlocked(stagedName: stagedName, message: reason)
        }
    }

    private func record(
        item: DiskCleanValidatedPlan.PlanItem,
        outcome: DiskCleanExecutionItemResult.Outcome,
        mode: DiskCleanRemovalMode,
        runID: String? = nil
    ) -> DiskCleanExecutionItemResult {
        auditLog.append(
            DiskCleanAuditLog.Record(
                timestamp: now(),
                action: mode == .trash ? .trash : .delete,
                runID: runID,
                targetID: item.targetID,
                legacyRuleID: item.legacyRuleID,
                category: item.category.rawValue,
                path: item.path,
                stagedName: Self.stagedName(of: outcome),
                estimatedBytes: item.estimatedBytes,
                status: Self.status(of: outcome),
                skipReason: Self.skipReason(of: outcome),
                error: Self.errorMessage(of: outcome)
            )
        )
        return DiskCleanExecutionItemResult(
            candidateID: item.candidateID,
            path: item.path,
            outcome: outcome
        )
    }

    private static func stagedName(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        switch outcome {
        case let .trashed(_, stagedName),
             let .partiallyDeleted(stagedName, _),
             let .rollbackBlocked(stagedName, _):
            return stagedName
        case .removed, .skipped, .changedSinceScan, .failed:
            return nil
        }
    }

    private static func status(of outcome: DiskCleanExecutionItemResult.Outcome) -> String {
        switch outcome {
        case .removed, .trashed:
            return "ok"
        case .skipped:
            return "skipped"
        case .changedSinceScan:
            return "changedSinceScan"
        case .failed:
            return "failed"
        case .partiallyDeleted:
            return "partiallyDeleted"
        case .rollbackBlocked:
            return "rollbackBlocked"
        }
    }

    private static func skipReason(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        guard case let .skipped(safety) = outcome else { return nil }
        return describe(safety)
    }

    private static func errorMessage(of outcome: DiskCleanExecutionItemResult.Outcome) -> String? {
        switch outcome {
        case let .failed(message),
             let .partiallyDeleted(_, message),
             let .rollbackBlocked(_, message):
            return message
        case .removed, .trashed, .skipped, .changedSinceScan:
            return nil
        }
    }

    private static func describe(_ safety: DiskCleanSafetyStatus) -> String {
        switch safety {
        case .allowed:
            return "allowed"
        case let .whitelisted(rule):
            return "whitelisted(\(rule))"
        case let .protected(reason):
            return "protected(\(reason))"
        case let .invalid(reason):
            return "invalid(\(reason))"
        case let .requiresAdmin(reason):
            return "requiresAdmin(\(reason))"
        case let .inUse(processName):
            return "inUse(\(processName))"
        }
    }
}
