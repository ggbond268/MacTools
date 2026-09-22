import XCTest
@testable import AppUninstallerPlugin

private struct FixtureMolePlanner: MoleEnginePlanning {
    let value: MoleEnginePlan
    func plan(applicationPath: String) async throws -> MoleEnginePlan { value }
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

    func testUnrelatedIncompleteProcessCoverageDoesNotBlockAppOnlyMolePlan() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let native = try fixture.scanner.application(fixture.app.path)
        let plan = MoleEnginePlan(
            schemaVersion: 1,
            engine: .init(name: "Mole", revision: "fixture"),
            planID: "fixture-plan",
            status: "ready",
            source: "standalone",
            blockedReason: nil,
            application: .init(name: native.name, path: native.path, bundleID: native.bundleID,
                               identity: "fixture", infoIdentity: "fixture"),
            requiresSudo: false,
            homebrewCask: nil,
            siblingGuard: "none",
            estimatedKilobytes: 1,
            candidates: [.init(id: "app", path: native.path, kind: "application",
                               selectedByDefault: true, reviewOnly: false)],
            warnings: []
        )
        var environment = fixture.environment
        environment.snapshot = .init(
            runningPaths: [],
            isManaged: false,
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
}
