import Foundation
import MacToolsPluginKit

// MARK: - Engine interface

protocol DiskCleanScanning: Sendable {
    /// Event stream. Consumer cancellation (`break` out of the loop or task cancel) →
    /// `onTermination` reaches the engine root task → no new sizing tasks are spawned
    /// (design §4.1).
    ///
    /// Rule-section scope is expressed as `DiskCleanChoice`, not the `Set<DiskCleanCategoryID>`
    /// written in design §4.1: categories are not isomorphic to v1 panel groups (see
    /// `DiskCleanChoice` comments), and choosing by category would silently change scan
    /// coverage. Categories remain the unit of display and `categoryFinished`.
    ///
    /// P2 sections use the same method (design §10): **only the expansion source differs**;
    /// sizing, completeness, and artifact minting are all shared, so there is no second path
    /// into the executor.
    func scan(
        scope: DiskCleanScanScope,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error>
}

extension DiskCleanScanning {
    func scan(
        choices: Set<DiskCleanChoice>,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error> {
        scan(scope: .rules(choices: choices), forceRefresh: forceRefresh)
    }
}

/// Execution seam for blocking sizing (wiring point for design §13-7).
///
/// Folds "run on a resident thread + abandon on timeout + circuit-break state" into one
/// protocol: that is exactly what the engine needs, and tests need to inject hangs and
/// fake circuit-break state without starting real threads to verify limitation derivation.
protocol DiskCleanSizingExecuting: Sendable {
    func size(
        ofItemAt path: String,
        using sizer: any DiskCleanDirectorySizing,
        deadline: Date
    ) async -> DiskCleanSizeResult

    var isCircuitBroken: Bool { get }
    var abandonedThreads: Int { get }
}

extension DiskCleanWorkerPool: DiskCleanSizingExecuting {}

struct DiskCleanScanEngineConfiguration: Sendable {
    /// Per-item deadline (design §4.2 item 3). Timeout → `partial([.timedOut])`.
    var itemTimeout: TimeInterval = 20
    /// Global deadline. After it, remaining candidates are marked timed out immediately and sizing is not submitted.
    var globalTimeout: TimeInterval = 300
    /// Concurrency cap for the sizing phase. Matches WorkerPool resident thread count; extra submissions only queue.
    var maximumConcurrentSizing: Int = 3
    /// Cap on `volumeSkipped` reports collected during expansion. Under circuit break almost
    /// every candidate hits it; reporting all would bloat limitations into hundreds of rows;
    /// `walkerCircuitBroken` already expresses the same fact.
    var maximumVolumeSkippedReports: Int = 10

    init() {}
}

// MARK: - Engine

/// Scan orchestration (design §4.2).
///
/// Two phases: **expand** (serial, fast — user sees rows within 1–2s) → **size** (bounded
/// concurrency via WorkerPool, emit events as they complete). The engine itself never does
/// heavy filesystem work; it only owns ordering, concurrency caps, deadlines, and honest aggregation.
struct DiskCleanScanEngine: DiskCleanScanning {
    let catalog: DiskCleanRuleCatalogV2
    let fileSystem: any DiskCleanFileSystemProviding
    let safetyPolicy: DiskCleanSafetyPolicy
    let sizer: any DiskCleanDirectorySizing
    let sizingExecutor: any DiskCleanSizingExecuting
    let sizeCache: DiskCleanSizeCache
    let identityProbe: any DiskCleanRootIdentityProbing
    let runningAppLock: any DiskCleanRunningAppSnapshotting
    let fullDiskAccess: any DiskCleanFullDiskAccessProbing
    /// Expansion sources for P2 sections (design §10).
    let developerArtifactExpansion: any DiskCleanExternalExpanding
    let installerExpansion: any DiskCleanExternalExpanding
    let configuration: DiskCleanScanEngineConfiguration
    let localization: PluginLocalization
    let now: @Sendable () -> Date

    init(
        catalog: DiskCleanRuleCatalogV2 = .current,
        fileSystem: any DiskCleanFileSystemProviding = LocalDiskCleanFileSystem(),
        safetyPolicy: DiskCleanSafetyPolicy = DiskCleanSafetyPolicy(),
        sizer: any DiskCleanDirectorySizing = DiskCleanFastWalker(),
        sizingExecutor: any DiskCleanSizingExecuting = DiskCleanWorkerPool.shared,
        sizeCache: DiskCleanSizeCache = DiskCleanSizeCache(),
        identityProbe: any DiskCleanRootIdentityProbing = DiskCleanRootIdentityProbe(),
        runningAppLock: any DiskCleanRunningAppSnapshotting = DiskCleanRunningAppLock(),
        fullDiskAccess: any DiskCleanFullDiskAccessProbing = DiskCleanFullDiskAccessProbe.shared,
        developerArtifactExpansion: any DiskCleanExternalExpanding = DiskCleanDeveloperArtifactExpansion(),
        installerExpansion: any DiskCleanExternalExpanding = DiskCleanInstallerExpansion(),
        configuration: DiskCleanScanEngineConfiguration = DiskCleanScanEngineConfiguration(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.catalog = catalog
        self.fileSystem = fileSystem
        self.safetyPolicy = safetyPolicy
        self.sizer = sizer
        self.sizingExecutor = sizingExecutor
        self.sizeCache = sizeCache
        self.identityProbe = identityProbe
        self.runningAppLock = runningAppLock
        self.fullDiskAccess = fullDiskAccess
        self.developerArtifactExpansion = developerArtifactExpansion
        self.installerExpansion = installerExpansion
        self.configuration = configuration
        self.localization = localization
        self.now = now
    }

    func scan(
        scope: DiskCleanScanScope,
        forceRefresh: Bool
    ) -> AsyncThrowingStream<DiskCleanScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await run(scope: scope, forceRefresh: forceRefresh, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Main flow

    private func run(
        scope: DiskCleanScanScope,
        forceRefresh: Bool,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async {
        let startedAt = now()
        let globalDeadline = startedAt.addingTimeInterval(configuration.globalTimeout)
        var collector = DiskCleanLimitationCollector(
            maximumVolumeSkippedReports: configuration.maximumVolumeSkippedReports
        )

        let scopedTargets = scopedTargets(for: scope)
        let lockSnapshot = await runningAppLock.makeSnapshot(
            processNames: DiskCleanRunningAppSnapshot.processNames(in: scopedTargets)
        )

        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }

        // Expansion phase: serial; expand and attribute only, no sizing.
        let expansion = await expand(
            scope: scope,
            targets: scopedTargets,
            lockSnapshot: lockSnapshot,
            collector: &collector,
            continuation: continuation
        )
        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }

        var candidates = expansion.candidates
        for candidate in candidates {
            continuation.yield(.candidateFound(candidate))
        }
        for message in Self.foundLogMessages(for: candidates, localization: localization) {
            continuation.yield(.log(message))
        }

        var pendingByCategory = Self.candidateCounts(byCategory: candidates)
        for category in expansion.scopedCategories where (pendingByCategory[category] ?? 0) == 0 {
            continuation.yield(.categoryFinished(category))
        }

        // Sizing phase.
        let categoryByCandidateID = Dictionary(
            candidates.map { ($0.id, $0.category) },
            uniquingKeysWith: { first, _ in first }
        )
        let sizedResults = await sizeAll(
            candidates: candidates,
            forceRefresh: forceRefresh,
            globalDeadline: globalDeadline
        ) { candidateID, result in
            continuation.yield(.candidateSized(id: candidateID, result: result))
            guard let category = categoryByCandidateID[candidateID],
                  let remaining = pendingByCategory[category] else { return }
            pendingByCategory[category] = remaining - 1
            if remaining - 1 <= 0 {
                continuation.yield(.categoryFinished(category))
            }
        }

        guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
        }

        for index in candidates.indices {
            guard let result = sizedResults[candidates[index].id] else { continue }
            candidates[index] = candidates[index].applying(result)
            collector.observe(sizeResult: result, path: candidates[index].path)
        }
        collector.observe(pool: sizingExecutor)

        let artifact = DiskCleanScanArtifact(
            scope: scope,
            candidates: candidates,
            reservedRootPaths: expansion.reservedRootPaths,
            limitations: collector.limitations,
            startedAt: startedAt,
            finishedAt: now()
        )
        let summary = DiskCleanScanSummary(artifact: artifact)
        for message in Self.limitationLogMessages(for: summary.limitations, localization: localization) {
            continuation.yield(.log(message))
        }
        continuation.yield(
            .log(
                DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.completed",
                        defaultValue: "扫描完成：%d 项，%d 项可清理",
                        summary.candidateCount,
                        summary.cleanableCount
                    ),
                    tone: .success
                )
            )
        )
        continuation.yield(.finished(summary))
        continuation.finish()
    }

    // MARK: - Expansion phase

    private struct ExpansionOutcome {
        var candidates: [DiskCleanCandidate] = []
        var reservedRootPaths: [String] = []
        var scopedCategories: [DiskCleanCategoryID] = []
    }

    /// Targets involved in this scan.
    ///
    /// Rule sections filter by panel group; P2 sections take the matching synthetic targets —
    /// they do not participate in rule expansion (`kind == .external`) but must still appear
    /// here because lock snapshots and category order are both derived from targets.
    private func scopedTargets(for scope: DiskCleanScanScope) -> [DiskCleanRuleTarget] {
        switch scope {
        case let .rules(choices):
            return catalog.targetsInDisplayOrder.filter {
                guard !$0.isExternallyDiscovered else { return false }
                return DiskCleanChoice(legacyRuleID: $0.legacyRuleID).map(choices.contains) ?? false
            }
        case .developerArtifacts:
            return catalog.targets(in: .developerArtifacts)
        case .installers:
            return catalog.targets(in: .installers)
        }
    }

    private func expand(
        scope: DiskCleanScanScope,
        targets: [DiskCleanRuleTarget],
        lockSnapshot: DiskCleanRunningAppSnapshot,
        collector: inout DiskCleanLimitationCollector,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async -> ExpansionOutcome {
        var outcome = ExpansionOutcome()
        outcome.scopedCategories = targets.reduce(into: []) { categories, target in
            guard !categories.contains(target.category) else { return }
            categories.append(target.category)
        }

        let hits: [DiskCleanTargetHit]
        switch scope {
        case .rules:
            hits = await expandRules(
                targets: targets,
                outcome: &outcome,
                collector: &collector,
                continuation: continuation
            )
        case .developerArtifacts:
            hits = await expandExternally(
                using: developerArtifactExpansion,
                scope: scope,
                outcome: &outcome,
                collector: &collector,
                continuation: continuation
            )
        case .installers:
            hits = await expandExternally(
                using: installerExpansion,
                scope: scope,
                outcome: &outcome,
                collector: &collector,
                continuation: continuation
            )
        }

        let assembler = DiskCleanCandidateAssembler(fileSystem: fileSystem)
        outcome.candidates = assembler.assemble(hits: hits).map { owned in
            makeCandidate(from: owned, lockSnapshot: lockSnapshot)
        }
        return outcome
    }

    /// Expansion via a dedicated scanner (design §10). Product shape matches rule expansion so later steps are shared.
    private func expandExternally(
        using expander: any DiskCleanExternalExpanding,
        scope: DiskCleanScanScope,
        outcome: inout ExpansionOutcome,
        collector: inout DiskCleanLimitationCollector,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async -> [DiskCleanTargetHit] {
        let expansion = await expander.expand(
            scope: scope,
            catalog: catalog,
            localization: localization
        )
        outcome.reservedRootPaths += expansion.reservedRootPaths
        for limitation in expansion.limitations {
            collector.add(limitation)
        }
        for message in expansion.logMessages {
            continuation.yield(.log(message))
        }
        return expansion.hits
    }

    private func expandRules(
        targets: [DiskCleanRuleTarget],
        outcome: inout ExpansionOutcome,
        collector: inout DiskCleanLimitationCollector,
        continuation: AsyncThrowingStream<DiskCleanScanEvent, Error>.Continuation
    ) async -> [DiskCleanTargetHit] {
        var hits: [DiskCleanTargetHit] = []
        var skippedByFDA: [String] = []
        let hasFullDiskAccess = fullDiskAccess.hasFullDiskAccess

        for target in targets {
            guard !Task.isCancelled else { return hits }

            // Without authorization, skip wholesale — never trigger a TCC prompt storm per directory (design §9).
            if target.requiresFullDiskAccess && !hasFullDiskAccess {
                skippedByFDA.append(target.id)
                outcome.reservedRootPaths += target.expandedReservedRootPaths()
                continue
            }

            do {
                let expanded = try await expandHits(for: target)
                hits += expanded
                continuation.yield(
                    .log(
                        DiskCleanScanLogMessage(
                            text: localization.format(
                                "scanLog.expandTarget",
                                defaultValue: "展开 %@：匹配 %d 项",
                                target.id,
                                expanded.count
                            ),
                            tone: expanded.isEmpty ? .info : .success
                        )
                    )
                )
            } catch {
                // Failed targets record a limitation + reserved roots: their subtrees are
                // "present but unscanned", so the Planner forbids deleting their ancestors.
                // Never block the whole scan.
                collector.add(Self.failureLimitation(for: target, error: error))
                outcome.reservedRootPaths += target.expandedReservedRootPaths()
                continuation.yield(
                    .log(
                        DiskCleanScanLogMessage(
                            text: localization.format(
                                "scanLog.targetFailed",
                                defaultValue: "展开失败：%@（%@）",
                                target.id,
                                Self.reason(for: error)
                            ),
                            tone: .warning
                        )
                    )
                )
            }
        }

        if !skippedByFDA.isEmpty {
            collector.add(.fdaRestricted(skippedTargetIDs: skippedByFDA))
        }
        return hits
    }

    private func expandHits(for target: DiskCleanRuleTarget) async throws -> [DiskCleanTargetHit] {
        switch target.kind {
        case .external:
            // Synthetic-target candidates are discovered by a dedicated scanner; rule expansion
            // should not reach here (`scopedTargets(for:)` already splits by scope). Return empty;
            // never invent paths.
            return []

        case let .path(globs):
            var hits: [DiskCleanTargetHit] = []
            for glob in globs {
                let specificity = DiskCleanGlobPrefix.fixedPrefix(of: glob).count
                for item in try fileSystem.expandPathPattern(glob) {
                    hits.append(
                        DiskCleanTargetHit(
                            target: target,
                            item: Self.physical(item),
                            logicalPath: item.path,
                            specificity: specificity
                        )
                    )
                }
            }
            return hits

        case let .dynamic(provider):
            let items = try await provider.expand()
            let reservedRoots = target.expandedReservedRootPaths()
            return items.map { item in
                let physical = Self.physical(item)
                // Dynamic targets have no glob to measure specificity; use the hit reserved-root
                // length instead: reserved roots are the author-declared fixed prefix, same semantics
                // as a glob fixed prefix.
                let specificity = reservedRoots
                    .filter { physical.path == $0 || physical.path.hasPrefix($0 + "/") }
                    .map(\.count)
                    .max() ?? 0
                return DiskCleanTargetHit(
                    target: target,
                    item: physical,
                    logicalPath: item.path,
                    specificity: specificity
                )
            }
        }
    }

    /// Always convert paths to physical form (design §13-6): keep the leaf as-is, resolve ancestors.
    private static func physical(_ item: DiskCleanFileItem) -> DiskCleanFileItem {
        let physicalPath = DiskCleanPhysicalPath.resolve(item.path)
        guard physicalPath != item.path else { return item }
        return DiskCleanFileItem(
            path: physicalPath,
            isDirectory: item.isDirectory,
            isSymlink: item.isSymlink,
            resolvedSymlinkTarget: item.resolvedSymlinkTarget
        )
    }

    private func makeCandidate(
        from owned: DiskCleanOwnedPath,
        lockSnapshot: DiskCleanRunningAppSnapshot
    ) -> DiskCleanCandidate {
        let target = owned.target
        let safety: DiskCleanSafetyStatus
        if let processName = lockSnapshot.lockingProcessName(for: target) {
            safety = .inUse(processName: processName)
        } else {
            safety = safetyPolicy.safetyStatus(
                for: owned.item.path,
                alsoChecking: owned.logicalPaths.filter { $0 != owned.item.path },
                isSymlink: owned.item.isSymlink,
                resolvedSymlinkTarget: owned.item.resolvedSymlinkTarget
            )
        }

        return DiskCleanCandidate(
            id: DiskCleanCandidate.makeID(targetID: target.id, path: owned.item.path),
            targetID: target.id,
            legacyRuleID: target.legacyRuleID,
            category: target.category,
            path: owned.item.path,
            logicalPaths: owned.logicalPaths,
            // When the expansion source supplies no override, use target risk (rule candidates always take this path).
            risk: owned.facts.risk ?? target.risk,
            safety: safety,
            notes: owned.facts.notes,
            sizeResult: nil,
            explanation: target.resolvedExplanation
        )
    }

    // MARK: - Sizing phase

    private func sizeAll(
        candidates: [DiskCleanCandidate],
        forceRefresh: Bool,
        globalDeadline: Date,
        onResult: (DiskCleanCandidate.ID, DiskCleanSizeResult) -> Void
    ) async -> [DiskCleanCandidate.ID: DiskCleanSizeResult] {
        guard !candidates.isEmpty else { return [:] }

        let cachingSizer = DiskCleanCachingSizer(
            base: sizer,
            cache: sizeCache,
            identityProbe: identityProbe,
            forceRefresh: forceRefresh
        )
        var results: [DiskCleanCandidate.ID: DiskCleanSizeResult] = [:]
        results.reserveCapacity(candidates.count)

        await withTaskGroup(of: (DiskCleanCandidate.ID, DiskCleanSizeResult).self) { group in
            var iterator = candidates.makeIterator()
            var inFlight = 0

            // After cancel, **spawn no more** tasks: in-flight work is wound down by WorkerPool's cancel flag.
            func submitNext() -> Bool {
                guard !Task.isCancelled, let candidate = iterator.next() else { return false }
                group.addTask {
                    (candidate.id, await size(candidate, using: cachingSizer, globalDeadline: globalDeadline))
                }
                inFlight += 1
                return true
            }

            while inFlight < max(configuration.maximumConcurrentSizing, 1), submitNext() {}

            while let (candidateID, result) = await group.next() {
                inFlight -= 1
                results[candidateID] = result
                onResult(candidateID, result)
                _ = submitNext()
            }
        }

        return results
    }

    private func size(
        _ candidate: DiskCleanCandidate,
        using sizer: any DiskCleanDirectorySizing,
        globalDeadline: Date
    ) async -> DiskCleanSizeResult {
        let startedAt = now()
        // Global deadline already passed: mark timed out honestly. Do not submit work, but
        // still emit events or the UI stays stuck on "calculating".
        guard startedAt < globalDeadline else {
            return .unavailable(reasons: [.timedOut], observedAt: startedAt)
        }

        let itemDeadline = min(
            startedAt.addingTimeInterval(configuration.itemTimeout),
            globalDeadline
        )
        return await sizingExecutor.size(
            ofItemAt: candidate.path,
            using: sizer,
            deadline: itemDeadline
        )
    }

    // MARK: - Log and limitation copy

    private static func candidateCounts(
        byCategory candidates: [DiskCleanCandidate]
    ) -> [DiskCleanCategoryID: Int] {
        candidates.reduce(into: [:]) { counts, candidate in
            counts[candidate.category, default: 0] += 1
        }
    }

    private static func failureLimitation(
        for target: DiskCleanRuleTarget,
        error: Error
    ) -> DiskCleanScanLimitation {
        target.isDynamic
            ? .dynamicRuleFailed(targetID: target.id, reason: reason(for: error))
            : .targetExpansionFailed(targetID: target.id, reason: reason(for: error))
    }

    private static func reason(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    /// Log only **uncleanable** candidates: cleanable ones are obvious in the list;
    /// what needs explaining is "why this one cannot be deleted".
    private static func foundLogMessages(
        for candidates: [DiskCleanCandidate],
        localization: PluginLocalization
    ) -> [DiskCleanScanLogMessage] {
        candidates.compactMap { candidate in
            switch candidate.safety {
            case .allowed:
                return nil
            case let .whitelisted(rule):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.whitelisted",
                        defaultValue: "白名单保护：%@（%@）",
                        candidate.path,
                        rule
                    ),
                    tone: .warning
                )
            case let .protected(reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.protected",
                        defaultValue: "敏感数据保护：%@（%@）",
                        candidate.path,
                        reason
                    ),
                    tone: .warning
                )
            case let .invalid(reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.invalid",
                        defaultValue: "路径安全保护：%@（%@）",
                        candidate.path,
                        reason
                    ),
                    tone: .warning
                )
            case let .requiresAdmin(reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.requiresAdmin",
                        defaultValue: "需要管理员权限：%@（%@）",
                        candidate.path,
                        reason
                    ),
                    tone: .warning
                )
            case let .inUse(processName):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.candidate.inUse",
                        defaultValue: "正在使用(%@)：%@",
                        processName,
                        candidate.path
                    ),
                    tone: .warning
                )
            }
        }
    }

    private static func limitationLogMessages(
        for limitations: [DiskCleanScanLimitation],
        localization: PluginLocalization
    ) -> [DiskCleanScanLogMessage] {
        limitations.map { limitation in
            switch limitation {
            case let .fdaRestricted(skippedTargetIDs):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.fda",
                        defaultValue: "未开启完全磁盘访问，已跳过 %d 项规则",
                        skippedTargetIDs.count
                    ),
                    tone: .warning
                )
            case let .dynamicRuleFailed(targetID, reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.dynamicFailed",
                        defaultValue: "动态规则失败：%@（%@）",
                        targetID,
                        reason
                    ),
                    tone: .warning
                )
            case let .targetExpansionFailed(targetID, reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.expansionFailed",
                        defaultValue: "规则展开失败：%@（%@）",
                        targetID,
                        reason
                    ),
                    tone: .warning
                )
            case let .volumeSkipped(path):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.volumeSkipped",
                        defaultValue: "已跳过不支持的卷：%@",
                        path
                    ),
                    tone: .warning
                )
            case let .scanRootUnreadable(path, reason):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.scanRootUnreadable",
                        defaultValue: "无法读取 %@（%@）",
                        path,
                        DiskCleanFormat.partialReasons([reason], localization: localization)
                    ),
                    tone: .warning
                )
            case .walkerCircuitBroken:
                return DiskCleanScanLogMessage(
                    text: localization.string(
                        "scanLog.limitation.circuitBroken",
                        defaultValue: "扫描引擎已降级，重启应用恢复"
                    ),
                    tone: .error
                )
            case let .threadsAbandoned(count):
                return DiskCleanScanLogMessage(
                    text: localization.format(
                        "scanLog.limitation.threadsAbandoned",
                        defaultValue: "%d 个扫描线程无响应已被放弃",
                        count
                    ),
                    tone: .warning
                )
            }
        }
    }
}

// MARK: - Limitation collection

/// Limitation collector with stable order, dedup, and bounded report volume.
struct DiskCleanLimitationCollector {
    private(set) var limitations: [DiskCleanScanLimitation] = []
    private var volumeSkippedPaths: Set<String> = []
    private let maximumVolumeSkippedReports: Int

    init(maximumVolumeSkippedReports: Int) {
        self.maximumVolumeSkippedReports = max(maximumVolumeSkippedReports, 0)
    }

    mutating func add(_ limitation: DiskCleanScanLimitation) {
        guard !limitations.contains(limitation) else { return }
        limitations.append(limitation)
    }

    /// Derive volume-level limitations from sizing results.
    mutating func observe(sizeResult: DiskCleanSizeResult, path: String) {
        guard sizeResult.completeness.partialReasons.contains(.unsupportedVolume) else { return }
        guard volumeSkippedPaths.count < maximumVolumeSkippedReports else { return }
        guard volumeSkippedPaths.insert(path).inserted else { return }
        add(.volumeSkipped(path: path))
    }

    /// Circuit break and thread abandons are derived from WorkerPool's **process-wide** state
    /// (design §4.5, §13-7). Do not depend on "this scan happened to produce certain candidates" —
    /// budget burned by a prior scan must still be visible.
    mutating func observe(pool: any DiskCleanSizingExecuting) {
        if pool.isCircuitBroken {
            add(.walkerCircuitBroken)
        }
        let abandoned = pool.abandonedThreads
        if abandoned > 0 {
            add(.threadsAbandoned(count: abandoned))
        }
    }
}

// MARK: - Ownership attribution and ancestor decomposition

/// One raw hit from the expansion phase.
enum DiskCleanPathAlias {
    static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths where seen.insert(path).inserted {
            result.append(path)
        }
        return result
    }
}

struct DiskCleanTargetHit: Sendable {
    let target: DiskCleanRuleTarget
    let item: DiskCleanFileItem
    /// Paths before physical conversion. Multiple aliases can resolve to the same physical item.
    let logicalPaths: [String]
    /// Fixed-prefix length of the hitting glob (reserved root for dynamic targets); longer is more specific.
    /// P2 synthetic targets have no measurable glob and are always 0 — the same path is never hit by two synthetic targets.
    let specificity: Int
    /// Candidate attributes known only at expansion time (P2 git state, installer age, etc.). Rule hits are always `.inherited`.
    let facts: DiskCleanCandidateFacts

    /// Primary logical path for display / legacy call sites.
    var logicalPath: String { logicalPaths.first ?? item.path }

    init(
        target: DiskCleanRuleTarget,
        item: DiskCleanFileItem,
        logicalPath: String? = nil,
        logicalPaths: [String]? = nil,
        specificity: Int,
        facts: DiskCleanCandidateFacts = .inherited
    ) {
        self.target = target
        self.item = item
        if let logicalPaths {
            self.logicalPaths = DiskCleanPathAlias.unique(logicalPaths.isEmpty ? [item.path] : logicalPaths)
        } else if let logicalPath {
            self.logicalPaths = DiskCleanPathAlias.unique([logicalPath])
        } else {
            self.logicalPaths = [item.path]
        }
        self.specificity = specificity
        self.facts = facts
    }

    func mergingLogicalPaths(from other: DiskCleanTargetHit) -> DiskCleanTargetHit {
        DiskCleanTargetHit(
            target: target,
            item: item,
            logicalPaths: logicalPaths + other.logicalPaths,
            specificity: specificity,
            facts: facts
        )
    }
}

struct DiskCleanOwnedPath: Sendable {
    let target: DiskCleanRuleTarget
    let item: DiskCleanFileItem
    /// All pre-physical aliases that resolve to this physical path.
    let logicalPaths: [String]
    /// Children produced by ancestor decomposition inherit the source hit's facts — they are fragments of the same hit, so risk and notes should match.
    let facts: DiskCleanCandidateFacts

    var logicalPath: String { logicalPaths.first ?? item.path }

    init(
        target: DiskCleanRuleTarget,
        item: DiskCleanFileItem,
        logicalPath: String? = nil,
        logicalPaths: [String]? = nil,
        facts: DiskCleanCandidateFacts = .inherited
    ) {
        self.target = target
        self.item = item
        if let logicalPaths {
            self.logicalPaths = DiskCleanPathAlias.unique(logicalPaths.isEmpty ? [item.path] : logicalPaths)
        } else if let logicalPath {
            self.logicalPaths = DiskCleanPathAlias.unique([logicalPath])
        } else {
            self.logicalPaths = [item.path]
        }
        self.facts = facts
    }
}

/// Ownership attribution and ancestor decomposition (design §5.3). Purely functional: hit set in, final attribution table out.
struct DiskCleanCandidateAssembler: Sendable {
    /// Decomposition recursion depth cap. Recursion only descends branches that still have
    /// descendant candidates, so depth is naturally bounded; the cap is only a backstop for
    /// pathological input (extremely deep paths).
    static let maximumDecompositionDepth = 64

    let fileSystem: any DiskCleanFileSystemProviding

    func assemble(hits: [DiskCleanTargetHit]) -> [DiskCleanOwnedPath] {
        let owners = Self.resolveOwnership(hits: hits)
        let paths = owners.keys.sorted()
        var results: [DiskCleanOwnedPath] = []
        let pathSet = Set(paths)

        for path in paths {
            guard let hit = owners[path] else { continue }
            // No descendant candidates → keep an independent identity and accept as-is.
            guard Self.hasStrictDescendant(of: path, in: paths) else {
                results.append(
                    DiskCleanOwnedPath(
                        target: hit.target,
                        item: hit.item,
                        logicalPaths: hit.logicalPaths,
                        facts: hit.facts
                    )
                )
                continue
            }
            results += decompose(
                path: path,
                target: hit.target,
                logicalRoots: hit.logicalPaths,
                physicalRoot: hit.item.path,
                facts: hit.facts,
                allPaths: pathSet,
                sortedPaths: paths,
                depth: 0
            )
        }

        return results.sorted { $0.item.path < $1.item.path }
    }

    /// Same physical path hit by multiple targets/aliases → keep the most specific ownership,
    /// but **merge every logical alias**. Otherwise a more-specific `~/Library/Caches/pip/*`
    /// hit would discard `~/.cache/pip/*` and its whitelist rule would never be checked.
    static func resolveOwnership(hits: [DiskCleanTargetHit]) -> [String: DiskCleanTargetHit] {
        var owners: [String: DiskCleanTargetHit] = [:]
        for hit in hits {
            guard let incumbent = owners[hit.item.path] else {
                owners[hit.item.path] = hit
                continue
            }
            if isMoreSpecific(hit, than: incumbent) {
                owners[hit.item.path] = hit.mergingLogicalPaths(from: incumbent)
            } else {
                owners[hit.item.path] = incumbent.mergingLogicalPaths(from: hit)
            }
        }
        return owners
    }

    private static func isMoreSpecific(
        _ candidate: DiskCleanTargetHit,
        than incumbent: DiskCleanTargetHit
    ) -> Bool {
        if candidate.specificity != incumbent.specificity {
            return candidate.specificity > incumbent.specificity
        }
        if candidate.target.risk != incumbent.target.risk {
            return candidate.target.risk > incumbent.target.risk
        }
        return candidate.target.id < incumbent.target.id
    }

    /// Ancestor decomposition: if A is an ancestor of B → replace A with its direct children
    /// (inheriting A's target and risk), recurse until no other candidates remain under it;
    /// B keeps an independent identity (its own risk, lock, default selection).
    ///
    /// If the directory cannot be listed, **drop A wholesale**: keeping A would delete B's
    /// subtree as a side effect, erasing B's independent risk and selection. Prefer cleaning
    /// less over overreaching.
    private func decompose(
        path: String,
        target: DiskCleanRuleTarget,
        logicalRoots: [String],
        physicalRoot: String,
        facts: DiskCleanCandidateFacts,
        allPaths: Set<String>,
        sortedPaths: [String],
        depth: Int
    ) -> [DiskCleanOwnedPath] {
        guard depth < Self.maximumDecompositionDepth else { return [] }
        guard let children = try? fileSystem.directChildren(of: path) else { return [] }

        var results: [DiskCleanOwnedPath] = []
        for child in children {
            // The child is itself a candidate → it has its own identity; do not absorb it.
            if allPaths.contains(child.path) {
                continue
            }
            if Self.hasStrictDescendant(of: child.path, in: sortedPaths) {
                results += decompose(
                    path: child.path,
                    target: target,
                    logicalRoots: logicalRoots,
                    physicalRoot: physicalRoot,
                    facts: facts,
                    allPaths: allPaths,
                    sortedPaths: sortedPaths,
                    depth: depth + 1
                )
                continue
            }
            results.append(
                DiskCleanOwnedPath(
                    target: target,
                    item: child,
                    logicalPaths: Self.logicalChildPaths(
                        physicalChild: child.path,
                        physicalRoot: physicalRoot,
                        logicalRoots: logicalRoots
                    ),
                    facts: facts
                )
            )
        }
        return results
    }

    /// Map a decomposed physical child under every logical root when possible.
    private static func logicalChildPaths(
        physicalChild: String,
        physicalRoot: String,
        logicalRoots: [String]
    ) -> [String] {
        guard physicalChild == physicalRoot || physicalChild.hasPrefix(physicalRoot + "/") else {
            return [physicalChild]
        }
        let suffix = String(physicalChild.dropFirst(physicalRoot.count))
        return DiskCleanPathAlias.unique(logicalRoots.map { $0 + suffix })
    }

    /// `sortedPaths` is sorted, so strict descendants necessarily appear contiguously afterward.
    static func hasStrictDescendant(of path: String, in sortedPaths: [String]) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        guard let index = sortedPaths.firstIndex(where: { $0 > path }) else { return false }
        return sortedPaths[index].hasPrefix(prefix)
    }
}
