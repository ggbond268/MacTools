import Darwin
import XCTest
@testable import AppUninstallerPlugin

@MainActor
final class AppUninstallerSafetyTests: XCTestCase {
    func testBundleIdentifierRejectsPathEscapes() {
        for id in ["../Documents", "org.test/../../Data", "org..test", "org.test\0extra", "org.test\n", ".", "..", "org.test_unsafe"] {
            XCTAssertFalse(UninstallPaths.validIdentifier(id), id)
        }
        XCTAssertTrue(UninstallPaths.validIdentifier("org.example.App-1"))
    }

    func testUnsignedApplicationCanBeReviewedWithoutInventingGroupEvidence() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        _ = try fixture.makeData("Group Containers", name: "org.shared")
        let scan = try fixture.scan()
        XCTAssertFalse(scan.application.signingMetadataAvailable)
        XCTAssertTrue(scan.coverage.contains { $0.path.hasSuffix("Group Containers") && $0.issue != nil })
        XCTAssertEqual(scan.application.source, .unknown)
    }

    func testExactDisposableMatchesDefaultToSelectedAndSupportDoesNot() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        _ = try fixture.makeData("Caches")
        _ = try fixture.makeData("Preferences", name: "org.test.fixture.plist", directory: false)
        _ = try fixture.makeData("Application Support")
        let scan = try fixture.scan()
        XCTAssertTrue(scan.inventoryComplete)
        XCTAssertTrue(try XCTUnwrap(scan.candidates.first { $0.dataClass == .cache }).selectedByDefault)
        XCTAssertTrue(try XCTUnwrap(scan.candidates.first { $0.dataClass == .preference }).selectedByDefault)
        let support = try XCTUnwrap(scan.candidates.first { $0.dataClass == .support })
        XCTAssertTrue(support.eligible)
        XCTAssertFalse(support.selectedByDefault)
    }

    func testDirectoryMasqueradingAsPreferenceIsProtected() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        _ = try fixture.makeData("Preferences", name: "org.test.fixture.plist")
        let candidate = try XCTUnwrap(fixture.scan().candidates.first { $0.dataClass == .preference })
        XCTAssertEqual(candidate.confidence, .protected)
        XCTAssertFalse(candidate.eligible)
        XCTAssertFalse(candidate.selectedByDefault)
    }

    func testHiddenCompetingApplicationProtectsAssociatedData() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let hidden = fixture.root.appendingPathComponent("Applications/.Hidden.app")
        try UninstallFixture.makeApp(hidden)
        _ = try fixture.makeData("Caches")
        let scan = try fixture.scan()
        XCTAssertTrue(scan.inventory.contains { $0.path == hidden.path })
        XCTAssertTrue(scan.inventoryComplete)
        let candidate = try XCTUnwrap(scan.candidates.first { $0.dataClass == .cache })
        XCTAssertEqual(candidate.confidence, .protected)
        XCTAssertFalse(candidate.eligible)
    }

    func testConflictingContainerMetadataBlocksSelection() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let container = try fixture.makeData("Containers")
        let metadata = ["MCMMetadataIdentifier": "org.other.app"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let candidate = try XCTUnwrap(fixture.scan().candidates.first { $0.dataClass == .container })
        XCTAssertEqual(candidate.confidence, .protected)
        XCTAssertTrue(candidate.evidence.contains(.conflictingMetadata))
    }

    func testCaseVariantIdentifiersProtectSharedDataAndAppleApplications() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        try UninstallFixture.makeApp(fixture.root.appendingPathComponent("Applications/Other.app"), identifier: "ORG.test.fixture")
        _ = try fixture.makeData("Preferences", name: "org.test.fixture.plist", directory: false)
        let candidate = try XCTUnwrap(fixture.scan().candidates.first { $0.dataClass == .preference })
        XCTAssertFalse(candidate.eligible)
        XCTAssertEqual(candidate.confidence, .protected)
        let apple = fixture.root.appendingPathComponent("Applications/Apple.app")
        try UninstallFixture.makeApp(apple, identifier: "COM.APPLE.fixture")
        XCTAssertEqual(try fixture.scanner.application(apple.path).source, .system)
    }

    func testUppercaseParentBundleProtectsEmbeddedApplication() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let embedded = fixture.root.appendingPathComponent("Applications/Host.APP/Contents/Child.app")
        try UninstallFixture.makeApp(embedded)
        let app = try fixture.scanner.application(embedded.path)
        XCTAssertFalse(app.restrictions.isEmpty)
        XCTAssertFalse(fixture.configuration.permitted(app.path, kind: .application, app: app))
    }

    func testSymlinkAncestorsAndApplicationLeafAreRejected() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.app)
        XCTAssertThrowsError(try fixture.scanner.application(link.path))
        let parentLink = fixture.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: fixture.app.deletingLastPathComponent())
        XCTAssertThrowsError(try fixture.scanner.application(parentLink.appendingPathComponent("Fixture.app").path))
    }

    func testMissingDescendantIsNotAnAbsentRoot() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        XCTAssertFalse(fixture.scanner.fileSystem.isMissingCandidate(fixture.app.path, error: AppUninstallerError.io(ENOENT)))
        XCTAssertTrue(fixture.scanner.fileSystem.isMissingCandidate(fixture.root.appendingPathComponent("Absent").path, error: AppUninstallerError.io(ENOENT)))
    }

    func testTreeDigestIsStableAndDetectsDescendantChange() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let first = try fixture.scanner.fileSystem.tree(fixture.app.path)
        XCTAssertEqual(first, try fixture.scanner.fileSystem.tree(fixture.app.path))
        try Data("new unreviewed content".utf8).write(to: fixture.app.appendingPathComponent("Contents/extra"))
        XCTAssertNotEqual(first.digest, try fixture.scanner.fileSystem.tree(fixture.app.path).digest)
    }

    func testTreeEntryAndTimeBudgetsIncludeSymlinks() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let folder = try fixture.makeData("Caches")
        for i in 0..<40 { try FileManager.default.createSymbolicLink(atPath: folder.path + "/link\(i)", withDestinationPath: "/not-followed") }
        var fs = UninstallFileSystem(); fs.maximumEntries = 10
        XCTAssertThrowsError(try fs.tree(folder.path))
        fs.maximumEntries = 1_000; fs.maximumSeconds = 0
        XCTAssertThrowsError(try fs.tree(folder.path))
    }

    func testFIFOIsNotReadAsMetadata() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let path = fixture.root.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        XCTAssertThrowsError(try fixture.scanner.fileSystem.read(path))
    }

    func testCancelledInventoryThrowsInsteadOfReturningPartialSuccess() async throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.scanner.inventory(runningPaths: [])
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPlanRejectsStaleUnknownAndProtectedSelections() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let scan = try fixture.scan()
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: ["/arbitrary/path"]))
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path], now: scan.expiresAt))
        var environment = fixture.environment.snapshot
        environment = .init(runningPaths: [], isManaged: true, homebrewApps: [], restrictions: ["Managed"], coverage: [])
        let managed = try fixture.scanner.scan(path: fixture.app.path, environment: environment)
        XCTAssertThrowsError(try UninstallPlanner.make(scan: managed, selectedIDs: [fixture.app.path]))
    }

    func testLaunchServiceAttributesScriptsAndDeclaredBundlePaths() {
        let app = "/Applications/Fixture App.app"
        let declarations: [[String: Any]] = [
            ["Program": app + "/Contents/MacOS/helper"],
            ["ProgramArguments": ["/bin/sh", app + "/Contents/Resources/service.sh"]],
            ["Program": "/bin/sh", "ProgramArguments": ["sh", app + "/Contents/Resources/service.sh"]],
            ["BundleProgram": app + "/Contents/MacOS/helper"],
            ["WorkingDirectory": app + "/Contents", "ProgramArguments": ["./MacOS/helper"]],
            ["Program": "/applications/fixture app.app/Contents/Resources/../MacOS/helper"]
        ]
        for declaration in declarations {
            XCTAssertTrue(UninstallSystemEnvironment.launchServiceReferencesApplication(declaration, applicationPath: app))
        }
        XCTAssertFalse(UninstallSystemEnvironment.launchServiceReferencesApplication(
            ["ProgramArguments": ["/bin/sh", app + ".backup/Contents/service.sh"]], applicationPath: app))
        XCTAssertFalse(UninstallSystemEnvironment.launchServiceReferencesApplication(
            ["Program": "/unrelated" + app + "/Contents/MacOS/helper"], applicationPath: app))
        XCTAssertFalse(UninstallSystemEnvironment.launchServiceReferencesApplication(
            ["ProgramArguments": ["/bin/echo", "Example: " + app]], applicationPath: app))
    }

    func testBundledLaunchAgentRequiresVendorGuidance() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let agents = fixture.app.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = ["Label": "org.test.fixture.agent", "BundleProgram": "Contents/MacOS/helper"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("org.test.fixture.agent.plist"))
        let scan = try fixture.scan()
        XCTAssertEqual(scan.application.source, .vendorRequired)
        XCTAssertFalse(scan.canPlan)
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
    }
}
