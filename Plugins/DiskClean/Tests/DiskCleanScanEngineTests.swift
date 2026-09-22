import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanScanEngineTests: XCTestCase {
    private let home = "/Users/diskclean-tester"

    // MARK: - Event stream

    func testEmitsEveryCandidateFoundBeforeAnyCandidateSized() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems(
            [.testDirectory("\(home)/Library/Caches/A"), .testDirectory("\(home)/Library/Caches/B")],
            forPattern: "\(home)/Library/Caches/*"
        )
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let events = try await collect(engine)

        let lastFoundIndex = try XCTUnwrap(events.lastIndex { $0.isCandidateFound })
        let firstSizedIndex = try XCTUnwrap(events.firstIndex { $0.isCandidateSized })
        XCTAssertLessThan(
            lastFoundIndex,
            firstSizedIndex,
            "expansion must stream every entry first so the user sees content within 1-2 seconds"
        )
        XCTAssertEqual(events.filter(\.isCandidateFound).count, 2)
        XCTAssertEqual(events.filter(\.isCandidateSized).count, 2)
    }

    func testFinishedSummaryCountsOnlyCompleteCandidatesAsCleanable() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems(
            [
                .testDirectory("\(home)/Library/Caches/Complete"),
                .testDirectory("\(home)/Library/Caches/Partial")
            ],
            forPattern: "\(home)/Library/Caches/*"
        )
        let executor = FakeDiskCleanSizingExecutor()
        executor.setResult(.testComplete(bytes: 500), forPath: "\(home)/Library/Caches/Complete")
        executor.setResult(
            .testPartial(reasons: [.permissionDenied]),
            forPath: "\(home)/Library/Caches/Partial"
        )
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(summary.candidateCount, 2)
        XCTAssertEqual(summary.cleanableCount, 1)
        XCTAssertEqual(summary.cleanableEstimatedBytes, 500)
        XCTAssertEqual(
            summary.artifact.exclusionPaths,
            ["\(home)/Library/Caches/Partial"],
            "non-complete candidates must enter the exclusion set for M4 Planner ancestor assertions"
        )
    }

    func testLimitsConcurrentSizingToConfiguredMaximum() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        let items = (0..<12).map { DiskCleanFileItem.testDirectory("\(home)/Library/Caches/Item\($0)") }
        fileSystem.setItems(items, forPattern: "\(home)/Library/Caches/*")
        let executor = FakeDiskCleanSizingExecutor(delay: .milliseconds(30))
        var configuration = DiskCleanScanEngineConfiguration()
        configuration.maximumConcurrentSizing = 3
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            configuration: configuration,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        _ = try await finish(engine)

        XCTAssertEqual(executor.requestedPaths.count, 12)
        XCTAssertLessThanOrEqual(executor.peakConcurrency, 3)
        XCTAssertGreaterThan(executor.peakConcurrency, 1, "concurrency window must actually slide, not serialize")
    }

    // MARK: - Cancellation

    func testCancelledTaskFinishesStreamWithCancellationError() async {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/A")], forPattern: "\(home)/Library/Caches/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: FakeDiskCleanSizingExecutor(delay: .milliseconds(200)),
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let task = Task { () -> Error? in
            do {
                for try await _ in engine.scan(choices: [.cache], forceRefresh: false) {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let error = await task.value
        XCTAssertTrue(error is CancellationError)
    }

    // MARK: - Scan scope (panel equivalence)

    // MARK: - limitations

    func testReportsFullDiskAccessRestrictionWithReservedRootsInArtifact() async throws {
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            fullDiskAccess: FakeDiskCleanFullDiskAccess(hasFullDiskAccess: false),
            targets: [
                .test(
                    id: "cache.system",
                    globs: ["/private/var/log/*"],
                    reservedRootPaths: ["/private/var/log"],
                    requiresFullDiskAccess: true
                )
            ]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(summary.limitations, [.fdaRestricted(skippedTargetIDs: ["cache.system"])])
        XCTAssertEqual(
            summary.artifact.reservedRootPaths,
            ["/private/var/log"],
            "reserved roots of skipped targets must enter the artifact: ancestors of unscanned subtrees must never be deleted"
        )
    }

    func testReportsDynamicRuleFailureAndKeepsScanningOtherTargets() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/item")], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [
                .test(
                    id: "cache.dynamic",
                    provider: FakeFailingDynamicRuleProvider(),
                    reservedRootPaths: ["/dynamic/root"]
                ),
                .test(id: "cache.static", globs: ["/cache/*"])
            ]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(
            summary.limitations,
            [.dynamicRuleFailed(targetID: "cache.dynamic", reason: "provider exploded")]
        )
        XCTAssertEqual(summary.artifact.reservedRootPaths, ["/dynamic/root"])
        XCTAssertEqual(summary.artifact.candidates.map(\.path), ["/cache/item"], "one rule failure must not block other rules")
    }

    func testLockedTargetProducesInUseCandidatesThatAreNotCleanable() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/chrome")], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            runningAppLock: FakeDiskCleanRunningAppLock(
                snapshot: DiskCleanRunningAppSnapshot(runningBundleIDs: ["com.google.chrome"])
            ),
            targets: [
                .test(id: "cache.a", globs: ["/cache/*"], lockedByBundleIDs: ["com.google.Chrome"])
            ]
        )

        let summary = try await finish(engine)
        let candidate = try XCTUnwrap(summary.artifact.candidates.first)

        XCTAssertEqual(candidate.safety, .inUse(processName: "com.google.Chrome"))
        XCTAssertFalse(candidate.isCleanable)
    }

    // MARK: - Cache wiring

    func testForceRefreshBypassesSizeCache() async throws {
        let path = "/cache/item"
        let identity = DiskCleanRootIdentity.test()
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(bytes: 4_096, identity: identity), now: Date())
        let sizer = FakeDiskCleanSizer()
        sizer.setResult(.testComplete(bytes: 8_192, identity: identity), forPath: path)
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory(path)], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: DirectDiskCleanSizingExecutor(),
            sizer: sizer,
            sizeCache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [path: identity]),
            targets: [.test(id: "cache.a", globs: ["/cache/*"])]
        )

        let summary = try await finish(engine, forceRefresh: true)

        XCTAssertEqual(sizer.calledPaths, [path])
        XCTAssertEqual(summary.artifact.candidates.first?.sizeResult?.estimatedBytes, 8_192)
    }

    // MARK: - P2 sections join the unified pipeline (design §10)

    /// Core assertion: candidates from dedicated scanners and rule candidates share **the same pipeline** —
    /// same sizing, same completeness, same artifact entry, so both can be minted into plans by `makePlan`.
    /// Any delete path that bypasses this pipeline makes this test meaningless.
    func testDeveloperArtifactCandidatesFlowThroughSizingIntoTheArtifact() async throws {
        let target = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let executor = FakeDiskCleanSizingExecutor()
        executor.setResult(.testComplete(bytes: 4_096), forPath: "/code/app/node_modules")

        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            sizingExecutor: executor,
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/app/node_modules"),
                        specificity: 0,
                        facts: DiskCleanCandidateFacts(
                            risk: .low,
                            notes: [.developerProject(path: "/code/app", marker: "package.json")]
                        )
                    )
                ],
                reservedRootPaths: ["/code"]
            ),
            targets: [target]
        )

        let summary = try await finish(engine, scope: .developerArtifacts(roots: ["/code"]))
        let candidate = try XCTUnwrap(summary.artifact.candidates.first)

        XCTAssertEqual(executor.requestedPaths, ["/code/app/node_modules"], "P2 candidates must go through unified sizing")
        XCTAssertEqual(candidate.path, "/code/app/node_modules")
        XCTAssertEqual(candidate.targetID, DiskCleanPurgeKind.nodeModules.targetID)
        XCTAssertEqual(candidate.category, .developerArtifacts)
        XCTAssertEqual(candidate.estimatedBytes, 4_096)
        XCTAssertTrue(candidate.isCleanable)
        XCTAssertEqual(candidate.notes, [.developerProject(path: "/code/app", marker: "package.json")])
    }

    /// Expansion-source risk overrides the target fallback; when omitted, keep the target (fail-safe to not default-selected).

    /// Reserved scan roots extend Planner ancestor assertions to P2: candidates **inside** a root remain deletable,
    /// while any path that would make the root a descendant (e.g. the root's parent) is refused.
    func testPlannerAcceptsCandidatesInsideReservedRootsButRejectsTheirAncestors() async throws {
        let target = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/app/node_modules"),
                        specificity: 0,
                        facts: DiskCleanCandidateFacts(risk: .low)
                    )
                ],
                reservedRootPaths: ["/code"]
            ),
            targets: [target]
        )

        let artifact = try await finish(engine, scope: .developerArtifacts(roots: ["/code"])).artifact
        let candidate = try XCTUnwrap(artifact.candidates.first)

        let plan = try await MainActor.run {
            try DiskCleanPlanner.makePlan(
                artifact: artifact,
                selectedIDs: [candidate.id],
                mode: .trash,
                now: candidate.observedAt ?? Date(),
                catalog: DiskCleanRuleCatalogV2(targets: [target])
            )
        }
        XCTAssertEqual(plan.items.map(\.path), ["/code/app/node_modules"])
        XCTAssertEqual(plan.reservedPrefixes, ["/code"])

        // Under the same evidence, "delete the scan root parent" must be refused by ancestor assertion.
        XCTAssertThrowsError(
            try DiskCleanPlanner.assertNoAncestorViolation(
                plannedPaths: ["/"],
                exclusionPaths: [],
                reservedPrefixes: plan.reservedPrefixes
            )
        ) { error in
            XCTAssertEqual(
                error as? DiskCleanPlanError,
                .ancestorViolation(plannedPath: "/", protectedPath: "/code")
            )
        }
    }

    func testInstallerScopeUsesInstallerExpansionOnly() async throws {
        let installerTarget = DiskCleanRuleTarget.testExternal(
            id: DiskCleanInstallerKind.diskImage.targetID,
            category: .installers,
            reservedRootPaths: ["/downloads"]
        )
        let purgeTarget = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(target: purgeTarget, item: .testDirectory("/code/x/node_modules"), specificity: 0)
                ]
            ),
            installerExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(target: installerTarget, item: .testFile("/downloads/Tool.dmg"), specificity: 0)
                ],
                reservedRootPaths: ["/downloads"]
            ),
            targets: [installerTarget, purgeTarget]
        )

        let summary = try await finish(engine, scope: .installers)

        XCTAssertEqual(summary.artifact.candidates.map(\.path), ["/downloads/Tool.dmg"])
        XCTAssertEqual(summary.artifact.candidates.first?.category, .installers)
    }

    /// Ordinary three-group scans **never** piggyback P2: developer artifacts walk user project trees and installers trigger
    /// the `~/Downloads` TCC prompt; both must be started explicitly in their own sections.

    /// Unreadable scan roots must be reported honestly: when TCC denies `~/Downloads` it may hold tens of GB;
    /// reporting "nothing to clean" would mislead the user.
    func testExternalExpansionLimitationsReachTheSummary() async throws {
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            installerExpansion: FakeDiskCleanExternalExpansion(
                reservedRootPaths: ["/downloads"],
                limitations: [.scanRootUnreadable(path: "/downloads", reason: .permissionDenied)]
            ),
            targets: [
                .testExternal(
                    id: DiskCleanInstallerKind.diskImage.targetID,
                    category: .installers,
                    reservedRootPaths: ["/downloads"]
                )
            ]
        )

        let summary = try await finish(engine, scope: .installers)

        XCTAssertEqual(
            summary.limitations,
            [.scanRootUnreadable(path: "/downloads", reason: .permissionDenied)]
        )
        XCTAssertTrue(summary.artifact.candidates.isEmpty)
        XCTAssertEqual(summary.artifact.reservedRootPaths, ["/downloads"])
    }

    // MARK: - Fixtures

    private func makeEngine(
        fileSystem: any DiskCleanFileSystemProviding,
        sizingExecutor: any DiskCleanSizingExecuting = FakeDiskCleanSizingExecutor(),
        sizer: any DiskCleanDirectorySizing = FakeDiskCleanSizer(),
        sizeCache: DiskCleanSizeCache = DiskCleanSizeCache(),
        identityProbe: any DiskCleanRootIdentityProbing = FakeDiskCleanRootIdentityProbe(identitiesByPath: [:]),
        runningAppLock: any DiskCleanRunningAppSnapshotting = FakeDiskCleanRunningAppLock(),
        fullDiskAccess: any DiskCleanFullDiskAccessProbing = FakeDiskCleanFullDiskAccess(hasFullDiskAccess: true),
        developerArtifactExpansion: any DiskCleanExternalExpanding = FakeDiskCleanExternalExpansion(),
        installerExpansion: any DiskCleanExternalExpanding = FakeDiskCleanExternalExpansion(),
        configuration: DiskCleanScanEngineConfiguration = DiskCleanScanEngineConfiguration(),
        targets: [DiskCleanRuleTarget],
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> DiskCleanScanEngine {
        DiskCleanScanEngine(
            catalog: DiskCleanRuleCatalogV2(targets: targets),
            fileSystem: fileSystem,
            safetyPolicy: DiskCleanSafetyPolicy(
                homeDirectory: home,
                whitelistStore: DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)
            ),
            sizer: sizer,
            sizingExecutor: sizingExecutor,
            sizeCache: sizeCache,
            identityProbe: identityProbe,
            runningAppLock: runningAppLock,
            fullDiskAccess: fullDiskAccess,
            developerArtifactExpansion: developerArtifactExpansion,
            installerExpansion: installerExpansion,
            configuration: configuration,
            now: now
        )
    }

    private func collect(
        _ engine: DiskCleanScanEngine,
        choices: Set<DiskCleanChoice> = Set(DiskCleanChoice.allCases),
        forceRefresh: Bool = false
    ) async throws -> [DiskCleanScanEvent] {
        try await collect(engine, scope: .rules(choices: choices), forceRefresh: forceRefresh)
    }

    private func collect(
        _ engine: DiskCleanScanEngine,
        scope: DiskCleanScanScope,
        forceRefresh: Bool = false
    ) async throws -> [DiskCleanScanEvent] {
        var events: [DiskCleanScanEvent] = []
        for try await event in engine.scan(scope: scope, forceRefresh: forceRefresh) {
            events.append(event)
        }
        return events
    }

    private func finish(
        _ engine: DiskCleanScanEngine,
        choices: Set<DiskCleanChoice> = Set(DiskCleanChoice.allCases),
        forceRefresh: Bool = false
    ) async throws -> DiskCleanScanSummary {
        try await finish(engine, scope: .rules(choices: choices), forceRefresh: forceRefresh)
    }

    private func finish(
        _ engine: DiskCleanScanEngine,
        scope: DiskCleanScanScope,
        forceRefresh: Bool = false
    ) async throws -> DiskCleanScanSummary {
        let events = try await collect(engine, scope: scope, forceRefresh: forceRefresh)
        return try XCTUnwrap(events.compactMap(\.summary).last)
    }
}

// MARK: - Event projection

extension DiskCleanScanEvent {
    var isCandidateFound: Bool {
        candidateFound != nil
    }

    var candidateFound: DiskCleanCandidate? {
        guard case let .candidateFound(candidate) = self else { return nil }
        return candidate
    }

    var isCandidateSized: Bool {
        guard case .candidateSized = self else { return false }
        return true
    }

    var finishedCategory: DiskCleanCategoryID? {
        guard case let .categoryFinished(category) = self else { return nil }
        return category
    }

    var summary: DiskCleanScanSummary? {
        guard case let .finished(summary) = self else { return nil }
        return summary
    }

    var logMessage: DiskCleanScanLogMessage? {
        guard case let .log(message) = self else { return nil }
        return message
    }
}
