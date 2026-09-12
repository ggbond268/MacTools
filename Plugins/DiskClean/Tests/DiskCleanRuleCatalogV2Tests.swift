import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Rule v1 → v2 mapping snapshot (design §5.4, §11 "rule mapping").
///
/// These assertions guard the migration: the v2 catalog may only change ownership and metadata, never silently add/remove globs or drop v1 rule IDs.
final class DiskCleanRuleCatalogV2Tests: XCTestCase {
    private let catalog = DiskCleanRuleCatalogV2.current

    /// v1 pseudo-dynamic rules only had static fallback globs; v2 lands them as path targets.
    /// This is the full set of globs v2 adds relative to the v1 *catalog*; any other addition should fail this test.
    private let expectedGlobsAbsentFromFirstVersionCatalog: Set<String> = [
        // v1 `.xcodeDerivedData` fallback
        "~/Library/Developer/Xcode/DerivedData/*",
        // two v1 package-manager dynamic rules not covered by other rules
        "~/.cache/go-build/*",
        "~/Library/Caches/mise/*",
        // expanded standard developer caches
        "~/Library/Caches/CocoaPods/*",
        "~/Library/Caches/org.carthage.CarthageKit/*",
        // expanded standard app log rotations
        "~/Library/Logs/*/*.log.*",
        "~/Library/Logs/*/*.old",
        // v1 `.serviceWorkerCache` fallback
        "~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Arc/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Vivaldi/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Code/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Cursor/Service Worker/CacheStorage/*/*"
    ]

    // MARK: - legacyRuleID coverage

    func testLegacyRuleIDsCoverFirstVersionRuleIDsExactly() {
        // Only rule targets: P2 synthetic targets (`purge.*` / `installer.*`) are not v1 migrations;
        // dedicated scanners discover their candidates, and legacyRuleID equals id only so audit logs have a stable name.
        let legacyIDs = Set(catalog.ruleTargets.map(\.legacyRuleID))
        let firstVersionIDs = Set(DiskCleanRuleCatalog.moleFirstVersion.rules.map(\.id))

        XCTAssertEqual(legacyIDs, firstVersionIDs)
        XCTAssertEqual(firstVersionIDs.count, 43)
    }

    func testSplitLegacyRulesKeepEveryTargetUnderTheSameLegacyID() {
        XCTAssertEqual(
            catalog.targets(legacyRuleID: "cache.user-essentials").map(\.id),
            ["cache.user-essentials.caches", "cache.user-essentials.logs"]
        )
        XCTAssertEqual(
            catalog.targets(legacyRuleID: "developer.rust-go-docker").map(\.id),
            ["developer.rust-go", "developer.docker"]
        )
        XCTAssertEqual(
            catalog.targets(legacyRuleID: "browser.chrome").map(\.id),
            ["browser.chrome", "browser.chrome.service-worker"]
        )
    }

    // MARK: - Glob ownership

    func testEveryFirstVersionGlobHasExactlyOneOwningTarget() {
        var ownersByGlob: [String: [String]] = [:]
        for target in catalog.targets {
            for glob in target.pathGlobs {
                ownersByGlob[glob, default: []].append(target.id)
            }
        }

        let duplicated = ownersByGlob.filter { $0.value.count > 1 }
        XCTAssertTrue(duplicated.isEmpty, "glob owned by multiple targets: \(duplicated)")

        let firstVersionGlobs = Self.firstVersionPathGlobs()
        let missing = firstVersionGlobs.subtracting(ownersByGlob.keys)
        XCTAssertTrue(missing.isEmpty, "v1 glob has no v2 owner: \(missing.sorted())")

        let added = Set(ownersByGlob.keys).subtracting(firstVersionGlobs)
        XCTAssertEqual(added, expectedGlobsAbsentFromFirstVersionCatalog)
    }

    func testFirstVersionDuplicatedGlobsAreOwnedByTheMoreSpecificCategory() {
        // In v1, five Codex globs and Figma appeared in two rules; v2 normalizes to the more specific category.
        XCTAssertEqual(
            Self.owner(of: "~/Library/Application Support/Codex/Cache/*", in: catalog)?.id,
            "cache.ai-assistants"
        )
        XCTAssertEqual(
            Self.owner(of: "~/Library/Caches/com.figma.Desktop/*", in: catalog)?.id,
            "cache.creative-tools"
        )
    }

    func testPathTargetsDeclareAtLeastOneGlob() {
        for target in catalog.ruleTargets where !target.isDynamic {
            XCTAssertFalse(target.pathGlobs.isEmpty, "path target has no globs: \(target.id)")
        }
    }

    func testTargetIDsAreUniqueAndNonEmpty() {
        let ids = catalog.targets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains { $0.isEmpty })
        for target in catalog.targets {
            XCTAssertEqual(catalog.target(id: target.id)?.id, target.id)
        }
    }

    // MARK: - Reserved roots

    func testReservedRootPathsAreNonEmptyNormalizedAbsolutePaths() {
        let home = "/Users/diskclean-tests"
        for target in catalog.targets {
            if target.id.hasPrefix("purge.") {
                // Only allowed empty class: scan roots are user-configured; the catalog has no fixed prefix.
                // Reserved roots come from the expansion source at runtime; see
                // `DiskCleanScanEngineTests.testDeveloperArtifactScanReservesConfiguredRoots`.
                XCTAssertTrue(target.reservedRootPaths.isEmpty, "developer-artifact target must not hardcode reserved roots: \(target.id)")
            } else {
                XCTAssertFalse(target.reservedRootPaths.isEmpty, "target missing reserved roots: \(target.id)")
            }
            for path in target.expandedReservedRootPaths(homeDirectory: home) {
                XCTAssertTrue(path.hasPrefix("/"), "reserved root is not absolute: \(target.id) \(path)")
                XCTAssertFalse(path.contains { "*?[".contains($0) }, "reserved root contains glob: \(target.id) \(path)")
                XCTAssertFalse(path.contains("//"), "reserved root not normalized: \(target.id) \(path)")
                XCTAssertFalse(path.hasSuffix("/"), "reserved root has trailing slash: \(target.id) \(path)")
                XCTAssertEqual(
                    path,
                    (path as NSString).standardizingPath,
                    "reserved root not normalized: \(target.id) \(path)"
                )
            }
        }
    }

    /// The real criterion is **no path component may be a symlink** — the sizing root opener uses `O_NOFOLLOW_ANY`
    /// (see `DiskCleanRootOpener` docs); intermediate symlinks also fail with ELOOP.
    /// A final-component symlink is a legitimate candidate (measured as the link, not followed).
    ///
    /// Only runtime `realpath(3)` can decide that, and catalog globs often point at paths that may not exist on this machine,
    /// so here we statically block the three well-known macOS symlink prefixes (`/var -> private/var`,
    /// `/tmp -> private/tmp`, `/etc -> private/etc`). Future system directories must use `/private/...` physical paths.
    /// Note `resolvingSymlinksInPath()` does not help: it tends to strip `/private` rather than add it.
    func testNoTargetPathStartsWithSymlinkedSystemPrefix() {
        let symlinkedRoots = ["/var", "/tmp", "/etc"]
        for target in catalog.targets {
            for path in target.pathGlobs + target.reservedRootPaths {
                for root in symlinkedRoots {
                    XCTAssertNotEqual(path, root, "path must use /private physical path: \(target.id) \(path)")
                    XCTAssertFalse(
                        path.hasPrefix(root + "/"),
                        "path traverses a symlinked directory; rewrite to /private physical path: \(target.id) \(path)"
                    )
                }
            }
        }
    }

    /// Reserved roots must equal the deduped set of glob fixed-directory prefixes — recompute independently so hand-edited globs cannot drift.
    func testPathTargetReservedRootsEqualGlobFixedPrefixes() {
        for target in catalog.ruleTargets where !target.isDynamic {
            var expected: [String] = []
            for glob in target.pathGlobs {
                let prefix = Self.fixedDirectoryPrefix(of: glob)
                if !expected.contains(prefix) {
                    expected.append(prefix)
                }
            }
            XCTAssertEqual(target.reservedRootPaths, expected, "reserved roots disagree with glob fixed prefixes: \(target.id)")
        }
    }

    func testDynamicTargetReservedRootsCoverProviderScopes() {
        XCTAssertEqual(
            catalog.target(id: "developer.simulator-unavailable")?.reservedRootPaths,
            ["~/Library/Developer/CoreSimulator/Devices"]
        )
        XCTAssertEqual(
            catalog.target(id: "developer.jetbrains-toolbox-old-versions")?.reservedRootPaths,
            ["~/Library/Application Support/JetBrains/Toolbox/apps"]
        )
        XCTAssertEqual(
            catalog.target(id: "browser.old-versions")?.reservedRootPaths.first,
            "~/Library/Application Support/Google/GoogleUpdater"
        )
    }

    // MARK: - Risk and category

    func testDynamicTargetsAreAtLeastMediumRisk() {
        let dynamicTargets = catalog.targets.filter(\.isDynamic)
        XCTAssertEqual(dynamicTargets.count, 4)
        XCTAssertEqual(
            Set(dynamicTargets.map(\.id)),
            [
                "developer.simulator-unavailable",
                "developer.jetbrains-toolbox-old-versions",
                "developer.ai-agent-old-versions",
                "browser.old-versions"
            ]
        )
        for target in dynamicTargets {
            XCTAssertGreaterThanOrEqual(target.risk, .medium, "dynamic target risk too low: \(target.id)")
        }
    }

    func testMappingTableRiskAndCategoryForSplitAndElevatedTargets() {
        assertTarget("cache.user-essentials.caches", category: .userEssentials, risk: .low)
        assertTarget("cache.user-essentials.logs", category: .logs, risk: .low)
        assertTarget("cache.macos-app-state", category: .systemCaches, risk: .medium)
        assertTarget("cache.virtualization", category: .virtualization, risk: .medium)
        assertTarget("developer.rust-go", category: .developer, risk: .low)
        assertTarget("developer.docker", category: .developer, risk: .medium)
        assertTarget("developer.ai-agent-old-versions", category: .aiTools, risk: .medium)
        assertTarget("browser.safari", category: .browsers, risk: .low)
        assertTarget("browser.chrome.service-worker", category: .browsers, risk: .medium)
        assertTarget("browser.service-worker", category: .browsers, risk: .medium)
    }

    func testServiceWorkerTargetsAreAllMediumRisk() {
        let serviceWorkerTargets = catalog.targets.filter { $0.id.contains("service-worker") }
        XCTAssertEqual(serviceWorkerTargets.count, 6)
        for target in serviceWorkerTargets {
            XCTAssertEqual(target.risk, .medium, "Service Worker target should be medium: \(target.id)")
        }
    }

    func testCategoryDisplayOrderCoversAllCasesWithNonDecreasingRisk() {
        XCTAssertEqual(Set(DiskCleanCategoryID.displayOrder), Set(DiskCleanCategoryID.allCases))
        XCTAssertEqual(DiskCleanCategoryID.displayOrder.count, DiskCleanCategoryID.allCases.count)

        let risks = DiskCleanCategoryID.displayOrder.map(\.risk)
        XCTAssertEqual(risks, risks.sorted())
    }

    func testEveryCategoryOwnsAtLeastOneTarget() {
        for category in DiskCleanCategoryID.allCases {
            XCTAssertFalse(catalog.targets(in: category).isEmpty, "category has no targets: \(category.rawValue)")
        }
    }

    func testTargetsInDisplayOrderAreCategoryThenRiskOrdered() {
        let ordered = catalog.targetsInDisplayOrder
        XCTAssertEqual(ordered.count, catalog.targets.count)

        let categoryRank = Dictionary(
            uniqueKeysWithValues: DiskCleanCategoryID.displayOrder.enumerated().map { ($0.element, $0.offset) }
        )
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let previousRank = categoryRank[previous.category] ?? 0
            let nextRank = categoryRank[next.category] ?? 0
            XCTAssertLessThanOrEqual(previousRank, nextRank)
            if previous.category == next.category {
                XCTAssertLessThanOrEqual(previous.risk, next.risk)
            }
        }
    }

    // MARK: - Locking and FDA

    func testProcessLockedTargetsAlsoDeclareBundleIDs() {
        for target in catalog.targets where !target.skipWhenProcessIsRunning.isEmpty {
            XCTAssertFalse(
                target.lockedByBundleIDs.isEmpty,
                "declares process names but no bundle IDs: \(target.id)"
            )
        }
    }

    func testFirstVersionProcessLocksArePreserved() {
        XCTAssertEqual(
            catalog.target(id: "developer.xcode-derived-data")?.skipWhenProcessIsRunning,
            ["Xcode"]
        )
        XCTAssertEqual(
            catalog.target(id: "developer.simulator-unavailable")?.skipWhenProcessIsRunning,
            ["Simulator"]
        )
        XCTAssertEqual(
            catalog.target(id: "browser.chrome.service-worker")?.lockedByBundleIDs,
            ["com.google.Chrome"]
        )
    }

    /// TCC-protected prefix table (design §9).
    ///
    /// Declared **independently in the test**; marks are reverse-derived from it: a catalog that sets
    /// `requiresFullDiskAccess` wrongly, or omits it when required, fails either way. New targets whose
    /// full glob set lands in protected ranges without the mark are also caught here.
    ///
    /// Rationale is in `DiskCleanRuleCatalogV2` docs; briefly: containers use macOS 14+
    /// `kTCCServiceSystemPolicyAppData` (prompts), Safari caches and Suggestions/Calendars/AddressBook
    /// are FDA / Calendar / Contacts protected (silent EPERM).
    private static let tccProtectedPrefixes = [
        "~/Library/Containers/",
        "~/Library/Group Containers/",
        "~/Library/Caches/com.apple.Safari",
        "~/Library/Safari",
        "~/Library/Suggestions",
        "~/Library/Calendars",
        "~/Library/Application Support/AddressBook"
    ]

    func testFullDiskAccessMarksAreDerivableFromTCCProtectedPrefixes() {
        for target in catalog.ruleTargets where !target.pathGlobs.isEmpty {
            let allProtected = target.pathGlobs.allSatisfy { glob in
                Self.tccProtectedPrefixes.contains { glob.hasPrefix($0) }
            }
            XCTAssertEqual(
                target.requiresFullDiskAccess,
                allProtected,
                allProtected
                    ? "all globs are TCC-protected but not marked: \(target.id)"
                    : "contains non-protected globs yet marked FDA, which would skip cleanable paths too: \(target.id)"
            )
        }
    }

    /// Mark-set snapshot. Prevents silent coverage changes for unauthorized users when a target is split without carrying the mark.
    func testFullDiskAccessTargetSnapshot() {
        XCTAssertEqual(
            catalog.targets.filter(\.requiresFullDiskAccess).map(\.id).sorted(),
            [
                "browser.safari",
                "cache.apple-sandboxed-apps.containers",
                "cache.macos-app-state.protected",
                "cache.office-apps.containers",
                "cache.productivity-media.containers"
            ]
        )
    }

    /// Dynamic and synthetic targets are never marked: the former degrades via their provider, the latter never goes through rule expansion;
    /// a mark would only make `fdaRestricted` report a target id the user cannot map to content.
    func testDynamicAndExternalTargetsNeverRequireFullDiskAccess() {
        for target in catalog.targets where target.isDynamic || target.isExternallyDiscovered {
            XCTAssertFalse(target.requiresFullDiskAccess, "must not mark FDA: \(target.id)")
        }
    }

    /// Split-out FDA targets must keep the parent category and risk — the only reason to split is TCC,
    /// not to change what the user sees.
    func testFullDiskAccessSplitsKeepParentCategoryAndRisk() {
        for target in catalog.targets where target.requiresFullDiskAccess {
            let siblings = catalog.targets(legacyRuleID: target.legacyRuleID)
            for sibling in siblings where sibling.id != target.id {
                XCTAssertEqual(sibling.category, target.category, "split changed category: \(target.id)")
                XCTAssertEqual(sibling.risk, target.risk, "split changed risk: \(target.id)")
            }
        }
    }

    // MARK: - P2 synthetic targets

    func testExternalTargetsCoverEveryPurgeAndInstallerKind() {
        XCTAssertEqual(
            catalog.targets(in: .developerArtifacts).map(\.id),
            DiskCleanPurgeKind.allCases.map(\.targetID)
        )
        XCTAssertEqual(
            catalog.targets(in: .installers).map(\.id),
            DiskCleanInstallerKind.allCases.map(\.targetID)
        )
        for target in catalog.targets(in: .developerArtifacts) + catalog.targets(in: .installers) {
            XCTAssertTrue(target.isExternallyDiscovered, "P2 target should be external: \(target.id)")
            XCTAssertTrue(target.pathGlobs.isEmpty, "P2 target must not have globs: \(target.id)")
            // Fallback risk must be >= medium: if the expansion source omits an override, default to not selected.
            XCTAssertGreaterThanOrEqual(target.risk, .medium, "P2 fallback risk too low: \(target.id)")
        }
    }

    /// Synthetic targets must actually exist in the catalog — `DiskCleanPlanner.makePlan` looks up by targetID,
    /// throws `unknownTarget` if missing, and P2 candidates become permanently uncleansable dead items.
    func testEveryExternalTargetIDResolvesInCatalog() {
        for kind in DiskCleanPurgeKind.allCases {
            XCTAssertNotNil(catalog.target(id: kind.targetID), "missing target: \(kind.targetID)")
        }
        for kind in DiskCleanInstallerKind.allCases {
            XCTAssertNotNil(catalog.target(id: kind.targetID), "missing target: \(kind.targetID)")
        }
    }

    func testRuleTargetsExcludeExternalTargets() {
        XCTAssertFalse(catalog.ruleTargets.contains { $0.isExternallyDiscovered })
        XCTAssertEqual(
            catalog.ruleTargets.count + DiskCleanPurgeKind.allCases.count + DiskCleanInstallerKind.allCases.count,
            catalog.targets.count
        )
    }

    // MARK: - Helpers

    private func assertTarget(
        _ id: String,
        category: DiskCleanCategoryID,
        risk: DiskCleanRisk,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let target = catalog.target(id: id) else {
            return XCTFail("missing target: \(id)", file: file, line: line)
        }
        XCTAssertEqual(target.category, category, "category mismatch: \(id)", file: file, line: line)
        XCTAssertEqual(target.risk, risk, "risk mismatch: \(id)", file: file, line: line)
    }

    private static func owner(of glob: String, in catalog: DiskCleanRuleCatalogV2) -> DiskCleanRuleTarget? {
        catalog.targets.first { $0.pathGlobs.contains(glob) }
    }

    private static func firstVersionPathGlobs() -> Set<String> {
        var globs: Set<String> = []
        for rule in DiskCleanRuleCatalog.moleFirstVersion.rules {
            for target in rule.targets {
                if case let .path(glob) = target {
                    globs.insert(glob)
                }
            }
        }
        return globs
    }

    /// Last complete path component before the first glob metacharacter. Without metacharacters, the path itself.
    private static func fixedDirectoryPrefix(of glob: String) -> String {
        guard let metaIndex = glob.firstIndex(where: { "*?[".contains($0) }) else {
            return glob
        }
        let head = glob[glob.startIndex..<metaIndex]
        guard let slashIndex = head.lastIndex(of: "/") else {
            return String(head)
        }
        return String(head[head.startIndex..<slashIndex])
    }
}
