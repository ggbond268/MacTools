import Darwin
import XCTest
@testable import AppUninstallerPlugin

private struct FixtureMolePlanner: MoleEnginePlanning {
    let value: MoleEnginePlan
    func plan(applicationPath: String) async throws -> MoleEnginePlan { value }
}

private func fixturePlan(
    application: UninstallApplication,
    status: String = "ready",
    source: String = "standalone",
    blockedReason: String? = nil,
    candidates: [MoleEnginePlan.Candidate]? = nil,
    warnings: [String] = []
) -> MoleEnginePlan {
    MoleEnginePlan(
        schemaVersion: 1,
        engine: .init(name: "Mole", revision: "fixture"),
        planID: "fixture-plan",
        status: status,
        source: source,
        blockedReason: blockedReason,
        application: .init(name: application.name, path: application.path, bundleID: application.bundleID,
                           identity: "fixture", infoIdentity: "fixture"),
        requiresSudo: false,
        homebrewCask: nil,
        siblingGuard: "none",
        estimatedKilobytes: 1,
        candidates: candidates ?? [.init(id: "app", path: application.path, kind: "application",
                                         selectedByDefault: true, reviewOnly: false)],
        warnings: warnings
    )
}

@MainActor
final class AppUninstallerMoleEngineTests: XCTestCase {
    func testEmbeddedEngineProducesVersionedReadOnlyApplicationPlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let testFile = URL(fileURLWithPath: #filePath)
        let pluginRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let engineRoot = pluginRoot.appendingPathComponent("MoleEngineResources", isDirectory: true)
        let temporary = fixture.root.appendingPathComponent("EngineTemporary", isDirectory: true)
        let engine = BundledMoleEngine(rootURL: engineRoot, temporaryDirectory: temporary, timeout: 30)

        let plan = try await engine.plan(applicationPath: fixture.app.path)

        XCTAssertEqual(plan.schemaVersion, 1)
        XCTAssertEqual(plan.engine.name, "Mole")
        XCTAssertEqual(plan.application.path, fixture.app.path)
        XCTAssertEqual(plan.application.bundleID, "org.test.fixture")
        XCTAssertEqual(plan.status, "ready")
        XCTAssertEqual(plan.source, "standalone")
        XCTAssertEqual(plan.candidates.first?.path, fixture.app.path)
        XCTAssertTrue(try XCTUnwrap(plan.candidates.first).selectedByDefault)
    }

    func testEmbeddedEngineEnforcesOutputLimitDuringContinuousWrites() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let engine = try fixtureEngine(
            fixture: fixture,
            script: """
            #!/bin/bash
            while true; do
                printf '0123456789abcdef0123456789abcdef'
            done
            """,
            timeout: 5,
            maximumOutputBytes: 32 * 1_024
        )

        do {
            _ = try await engine.plan(applicationPath: fixture.app.path)
            XCTFail("Expected the continuous output to reach the configured limit")
        } catch MoleEngineError.outputTooLarge {
            // Expected.
        }
    }

    func testEmbeddedEngineTerminatesDescendantsAfterTimeout() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let temporary = fixture.root.appendingPathComponent("EngineTemporary", isDirectory: true)
        let engine = try fixtureEngine(
            fixture: fixture,
            temporary: temporary,
            script: """
            #!/bin/bash
            /usr/bin/perl -MPOSIX=setpgid -e 'setpgid(0, 0); exec "/bin/sleep", "30"' &
            printf '%s' "$!" > "$TMPDIR/child.pid"
            while true; do sleep 1; done
            """,
            timeout: 0.2,
            maximumOutputBytes: 1_024
        )

        do {
            _ = try await engine.plan(applicationPath: fixture.app.path)
            XCTFail("Expected the engine deadline to expire")
        } catch MoleEngineError.timedOut {
            // Expected.
        }

        let pidURL = temporary.appendingPathComponent("MoleEngine/child.pid")
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidURL, encoding: .utf8)))
        for _ in 0..<50 where kill(pid, 0) == 0 { usleep(20_000) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSpawnDescriptorsNormalizeStandardStreams() throws {
        let descriptors = try BundledMoleEngine.duplicatedSpawnDescriptors([
            STDIN_FILENO,
            STDOUT_FILENO,
            STDERR_FILENO,
        ])
        defer { descriptors.forEach { _ = Darwin.close($0) } }

        XCTAssertEqual(descriptors.count, 3)
        XCTAssertEqual(Set(descriptors).count, 3)
        XCTAssertTrue(descriptors.allSatisfy { $0 >= 3 })
    }

    func testProcessListingRetriesWhenSnapshotIsSaturated() throws {
        var bufferCalls = 0
        let currentPID = getpid()
        let processIDs = BundledMoleEngine.listedProcessIDs { buffer, byteCount in
            guard let buffer else { return 1 }
            bufferCalls += 1
            let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
            let values = buffer.bindMemory(to: pid_t.self, capacity: capacity)
            if bufferCalls == 1 {
                for index in 0..<capacity { values[index] = pid_t(index + 1) }
                return Int32(capacity)
            }
            values[0] = currentPID
            return 1
        }

        XCTAssertEqual(processIDs, [currentPID])
        XCTAssertEqual(bufferCalls, 2)
    }

    func testUnrelatedIncompleteProcessCoverageDoesNotBlockAppOnlyMolePlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        let plan = fixturePlan(application: native)
        var environment = fixture.environment
        environment.snapshot = .init(
            runningPaths: [],
            managementState: .unmanaged,
            homebrewApps: [],
            restrictions: [],
            coverage: [.init(path: "运行进程", issue: "不相关进程的路径不可读。")]
        )
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: environment,
            engine: FixtureMolePlanner(value: plan)
        )

        let scan = try await service.review(fixture.app.path)

        XCTAssertTrue(scan.canPlan)
        XCTAssertTrue(scan.coverage.contains { $0.path == "运行进程" && $0.issue != nil })
        XCTAssertEqual(scan.candidates.map(\.path), [fixture.app.path])
        XCTAssertNoThrow(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
    }

    func testIncompleteHomebrewSourceCheckBlocksMolePlan() async throws {
        try await assertIncompleteSourceCheckBlocksPlan(
            coverage: .init(path: "/opt/homebrew/Caskroom", issue: "Homebrew 安装记录检查未完成。")
        )
    }

    func testIncompleteLaunchServiceCheckBlocksMolePlan() async throws {
        try await assertIncompleteSourceCheckBlocksPlan(
            coverage: .init(path: "/Library/LaunchDaemons", issue: "后台服务检查未完成。")
        )
    }

    func testIndeterminateManagementStateBlocksMolePlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        var environment = fixture.environment
        environment.snapshot = .init(
            runningPaths: [],
            managementState: .indeterminate,
            homebrewApps: [],
            restrictions: ["无法确认设备管理状态，仅可检查文件。"],
            coverage: [.init(path: "设备管理", issue: "管理状态检查未完成。")]
        )
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: environment,
            engine: FixtureMolePlanner(value: fixturePlan(application: native))
        )

        let scan = try await service.review(fixture.app.path)

        XCTAssertEqual(scan.application.source, .managed)
        XCTAssertTrue(scan.application.restrictions.contains("无法确认设备管理状态，仅可检查文件。"))
        XCTAssertFalse(scan.sourceChecksComplete)
        XCTAssertFalse(scan.canPlan)
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
    }

    func testNativeHomebrewClaimOverridesStandaloneMolePlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        var environment = fixture.environment
        environment.snapshot = .init(
            runningPaths: [],
            managementState: .unmanaged,
            homebrewApps: [fixture.app.path],
            restrictions: [],
            coverage: []
        )
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: environment,
            engine: FixtureMolePlanner(value: fixturePlan(application: native))
        )

        let scan = try await service.review(fixture.app.path)

        XCTAssertEqual(scan.application.source, .homebrew)
        XCTAssertFalse(scan.canPlan)
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
    }

    func testVendorReasonIsGuidanceAndNotARevealPath() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        let plan = fixturePlan(application: native, status: "blocked", source: "vendor",
                               blockedReason: "An official vendor uninstaller is required.")
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: fixture.environment,
            engine: FixtureMolePlanner(value: plan)
        )

        let scan = try await service.review(fixture.app.path)

        XCTAssertEqual(scan.application.source, .vendorRequired)
        XCTAssertTrue(scan.application.restrictions.contains("请使用开发者提供的卸载工具。"))
        XCTAssertTrue(scan.application.vendorUninstallers.isEmpty)
        XCTAssertFalse(scan.canPlan)
    }

    func testInBundleVendorUninstallerBlocksMolePlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let uninstaller = fixture.app.appendingPathComponent("Contents/Resources/Uninstall Fixture.app")
        try FileManager.default.createDirectory(at: uninstaller, withIntermediateDirectories: true)
        let native = try fixture.scanner.application(fixture.app.path)
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: fixture.environment,
            engine: FixtureMolePlanner(value: fixturePlan(application: native))
        )

        let scan = try await service.review(fixture.app.path)

        XCTAssertEqual(scan.application.source, .vendorRequired)
        XCTAssertEqual(scan.application.vendorUninstallers, [uninstaller.path])
        XCTAssertTrue(scan.application.restrictions.contains("发现可能的厂商卸载工具，请先检查其说明。"))
        XCTAssertFalse(scan.canPlan)
    }

    func testSameTeamSiblingVendorUninstallerIsSharedWithMoleReview() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let siblingURL = fixture.app.deletingLastPathComponent().appendingPathComponent("Uninstall Fixture.app")
        try UninstallFixture.makeApp(siblingURL, identifier: "org.test.uninstaller", name: "Uninstall Fixture")
        let selected = withTeamID(try fixture.scanner.application(fixture.app.path), "TESTTEAM")
        let sibling = withTeamID(try fixture.scanner.application(siblingURL.path), "TESTTEAM")
        let inventory = UninstallInventory(apps: [selected, sibling], coverage: [])

        let evidence = try fixture.scanner.vendorUninstallerEvidence(for: selected, inventory: inventory)

        XCTAssertEqual(evidence.paths, [siblingURL.path])
        XCTAssertTrue(evidence.restrictions.isEmpty)
    }

    func testMoleWarningsAreConvertedToLocalizedReviewMessages() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        let plan = fixturePlan(
            application: native,
            warnings: [
                "Another installed copy may share data; Mole narrowed the plan.",
                "System-level remnants are review-only and are not removable by this plan.",
                "A future Mole warning",
            ]
        )
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: fixture.environment,
            engine: FixtureMolePlanner(value: plan)
        )

        let scan = try await service.review(fixture.app.path)
        let issues = Set(scan.coverage.compactMap(\.issue))

        XCTAssertTrue(issues.contains("另一个已安装副本可能共享数据；Mole 已缩小清单范围。"))
        XCTAssertTrue(issues.contains("系统级残留仅供检查，无法通过此清单移除。"))
        XCTAssertTrue(issues.contains("Mole 报告一项未识别的检查警告；仅显示已验证项目。"))
        XCTAssertFalse(issues.contains("A future Mole warning"))
    }

    func testAppleAssociatedDataRemainsProtectedInMolePlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        try UninstallFixture.makeApp(fixture.app, identifier: "com.apple.dt.Xcode")
        let cache = try fixture.makeData("Caches", name: "com.apple.dt.Xcode")
        let native = try fixture.scanner.application(fixture.app.path)
        let candidates: [MoleEnginePlan.Candidate] = [
            .init(id: "app", path: fixture.app.path, kind: "application", selectedByDefault: true, reviewOnly: false),
            .init(id: "cache", path: cache.path, kind: "cache", selectedByDefault: true, reviewOnly: false),
        ]
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: fixture.environment,
            engine: FixtureMolePlanner(value: fixturePlan(application: native, candidates: candidates))
        )

        let scan = try await service.review(fixture.app.path)
        let cacheCandidate = try XCTUnwrap(scan.candidates.first { $0.path == cache.path })

        XCTAssertEqual(cacheCandidate.confidence, .protected)
        XCTAssertNil(cacheCandidate.snapshot)
        XCTAssertEqual(cacheCandidate.blockedReason, "Apple 应用的关联数据将保留。")
        XCTAssertFalse(cacheCandidate.eligible)
        XCTAssertEqual(scan.candidates.filter { $0.selectedByDefault }.map(\.path), [fixture.app.path])
    }

    func testMoleCandidatesRequireExpectedTypeAndContainerMetadata() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let preference = try fixture.makeData("Preferences", name: "org.test.fixture.plist")
        let container = try fixture.makeData("Containers")
        let metadata = ["MCMMetadataIdentifier": "org.test.other"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let native = try fixture.scanner.application(fixture.app.path)
        let candidates: [MoleEnginePlan.Candidate] = [
            .init(id: "app", path: fixture.app.path, kind: "application", selectedByDefault: true, reviewOnly: false),
            .init(id: "preference", path: preference.path, kind: "preference", selectedByDefault: true, reviewOnly: false),
            .init(id: "container", path: container.path, kind: "container", selectedByDefault: false, reviewOnly: false),
        ]
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: fixture.environment,
            engine: FixtureMolePlanner(value: fixturePlan(application: native, candidates: candidates))
        )

        let scan = try await service.review(fixture.app.path)
        let preferenceCandidate = try XCTUnwrap(scan.candidates.first { $0.path == preference.path })
        let containerCandidate = try XCTUnwrap(scan.candidates.first { $0.path == container.path })

        XCTAssertEqual(preferenceCandidate.confidence, .protected)
        XCTAssertEqual(preferenceCandidate.blockedReason, "项目类型与此关联规则不一致。")
        XCTAssertFalse(preferenceCandidate.eligible)
        XCTAssertEqual(containerCandidate.confidence, .protected)
        XCTAssertTrue(containerCandidate.evidence.contains(.conflictingMetadata))
        XCTAssertEqual(containerCandidate.blockedReason, "容器元数据与所选应用不一致。")
        XCTAssertFalse(containerCandidate.eligible)
    }

    private func assertIncompleteSourceCheckBlocksPlan(coverage: UninstallCoverage) async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        var environment = fixture.environment
        environment.snapshot = .init(
            runningPaths: [],
            managementState: .unmanaged,
            homebrewApps: [],
            restrictions: [],
            coverage: [coverage],
            sourceChecksComplete: false
        )
        let service = MoleBackedUninstallReviewService(
            scanner: fixture.scanner,
            environment: environment,
            engine: FixtureMolePlanner(value: fixturePlan(application: native))
        )

        let scan = try await service.review(fixture.app.path)

        XCTAssertFalse(scan.sourceChecksComplete)
        XCTAssertFalse(scan.canPlan)
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
    }

    private func fixtureEngine(
        fixture: UninstallFixture,
        temporary: URL? = nil,
        script: String,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> BundledMoleEngine {
        let root = fixture.root.appendingPathComponent("FixtureEngine", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture-revision\n".utf8).write(to: root.appendingPathComponent("REVISION"))
        try Data(script.utf8).write(to: root.appendingPathComponent("mactools-engine.sh"))
        return BundledMoleEngine(
            rootURL: root,
            temporaryDirectory: temporary ?? fixture.root.appendingPathComponent("EngineTemporary", isDirectory: true),
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func withTeamID(_ application: UninstallApplication, _ teamID: String) -> UninstallApplication {
        .init(
            path: application.path,
            bundleID: application.bundleID,
            name: application.name,
            version: application.version,
            build: application.build,
            executable: application.executable,
            teamID: teamID,
            groups: application.groups,
            signingMetadataAvailable: true,
            identity: application.identity,
            metadataDigest: application.metadataDigest,
            source: application.source,
            restrictions: application.restrictions,
            vendorUninstallers: application.vendorUninstallers
        )
    }
}
