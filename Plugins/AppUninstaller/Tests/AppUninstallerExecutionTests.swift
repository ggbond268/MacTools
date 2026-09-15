import XCTest
@testable import AppUninstallerPlugin

@MainActor
final class AppUninstallerExecutionTests: XCTestCase {
    private func executor(_ fixture: UninstallFixture, environment: FixtureEnvironment? = nil, failTrash: Bool = false) -> UninstallExecutor {
        .init(scanner: fixture.scanner, environment: environment ?? fixture.environment, history: fixture.history(),
              trash: FixtureTrash(directory: fixture.root.appendingPathComponent("FakeTrash"), fail: failTrash))
    }

    func testReviewedAppAndCacheMoveToFakeTrashAndSupportRemains() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let cache = try fixture.makeData("Caches")
        let support = try fixture.makeData("Application Support")
        let scan = try fixture.scan()
        let plan = try UninstallPlanner.make(scan: scan, selectedIDs: Set(scan.candidates.filter(\.selectedByDefault).map(\.id)))
        let run = try await executor(fixture).execute(plan)
        XCTAssertTrue(run.complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path))
        XCTAssertEqual(run.results.filter { $0.disposition == .trashed }.count, 2)
        for result in run.results where result.disposition == .trashed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.destinationPath)))
        }
        let saved = try await fixture.history().load()
        XCTAssertEqual(saved.first?.id, run.id)
        XCTAssertTrue(saved.first?.complete == true)
    }

    func testFailedTrashRestoresOriginalAndNeverDeletesIt() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [fixture.app.path])
        let run = try await executor(fixture, failTrash: true).execute(plan)
        XCTAssertFalse(run.complete)
        XCTAssertEqual(run.results.first?.disposition, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("FakeTrash").path))
    }

    func testReplacementAfterReviewIsRetained() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [fixture.app.path])
        try FileManager.default.moveItem(at: fixture.app, to: fixture.root.appendingPathComponent("Original.app"))
        try UninstallFixture.makeApp(fixture.app)
        let run = try await executor(fixture).execute(plan)
        XCTAssertEqual(run.results.first?.disposition, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testNewHiddenOwnerAfterReviewProtectsCache() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let cache = try fixture.makeData("Caches")
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [cache.path])
        try UninstallFixture.makeApp(fixture.root.appendingPathComponent("Applications/.NewOwner.app"))
        let run = try await executor(fixture).execute(plan)
        XCTAssertEqual(run.results.first { $0.originalPath == cache.path }?.disposition, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
    }

    func testRunningHelperExecutableBlocksRemoval() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [fixture.app.path])
        var environment = fixture.environment
        environment.snapshot.activeExecutables = [fixture.app.appendingPathComponent("Contents/MacOS/helper").path]
        let run = try await executor(fixture, environment: environment).execute(plan)
        XCTAssertEqual(run.results.first?.disposition, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testExpiryDuringRevalidationPreventsMutation() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let scan = try fixture.scan()
        let clock = UninstallTestClock(scan.expiresAt.addingTimeInterval(-1))
        let plan = try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path], now: clock.now())
        var environment = fixture.environment
        environment.onInspect = { clock.advance(30) }
        let run = try await executor(fixture, environment: environment).execute(plan, now: { clock.now() })
        XCTAssertEqual(run.results.first?.disposition, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testNewContentInStagingIsNotTrashed() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [fixture.app.path])
        var environment = fixture.environment
        environment.onValidate = { stage in
            guard let stage else { return }
            try Data("unreviewed".utf8).write(to: URL(fileURLWithPath: stage).appendingPathComponent("Contents/unreviewed"))
        }
        let run = try await executor(fixture, environment: environment).execute(plan)
        XCTAssertEqual(run.results.first?.disposition, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("FakeTrash").path))
    }

    func testCancellationReturnsAndPersistsPartialResult() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [fixture.app.path])
        var environment = fixture.environment
        environment.onInspect = { withUnsafeCurrentTask { $0?.cancel() } }
        let executor = executor(fixture, environment: environment)
        let task = Task.detached { try await executor.execute(plan) }
        let run = try await task.value
        XCTAssertFalse(run.complete)
        XCTAssertEqual(run.results.first?.disposition, .cancelled)
        let saved = try await fixture.history().load()
        XCTAssertEqual(saved.first?.results.first?.disposition, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testHistoryFailureBeforeStagePreservesApplication() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let blocker = fixture.root.appendingPathComponent("NotADirectory")
        try Data().write(to: blocker)
        let executor = UninstallExecutor(scanner: fixture.scanner, environment: fixture.environment,
            history: UninstallHistory(directory: blocker), trash: FixtureTrash(directory: fixture.root.appendingPathComponent("FakeTrash")))
        let plan = try UninstallPlanner.make(scan: fixture.scan(), selectedIDs: [fixture.app.path])
        do { _ = try await executor.execute(plan); XCTFail("Expected journal failure") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testClearHistoryPreservesInterruptedRunsAndDiagnosticsRedactHome() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let app = try fixture.scan().application
        let run = UninstallRun(id: UUID(), scanID: UUID(), application: app, startedAt: Date(),
            estimatedBytes: 10, selectedCount: 1, results: [.init(originalPath: fixture.home.appendingPathComponent("Library/Caches/org.test.fixture").path,
                destinationPath: fixture.home.appendingPathComponent("Stage").path, disposition: .needsAttention, message: nil)])
        let history = fixture.history()
        try await history.save(run)
        try await history.prune(clear: true)
        let saved = try await history.load()
        XCTAssertEqual(saved.count, 1)
        let text = UninstallDiagnostics.redacted(run, home: fixture.home.path)
        XCTAssertFalse(text.contains(fixture.home.path))
        XCTAssertTrue(text.contains("~/Library/Caches"))
    }
}
