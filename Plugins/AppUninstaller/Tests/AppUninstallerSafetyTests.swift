import Darwin
import XCTest
@testable import AppUninstallerPlugin

@MainActor
final class AppUninstallerSafetyTests: XCTestCase {
    func testUnreadableProcessFromAnotherLoginUserKeepsSnapshotIncomplete() throws {
        let snapshot = try UninstallSystemEnvironment.processSnapshot(
            processIDs: { [42] },
            inspect: { _ in .unreadable(userID: 502, realUserID: 502) }
        )

        XCTAssertTrue(snapshot.paths.isEmpty)
        XCTAssertFalse(snapshot.complete)
    }

    func testUnreadablePrivilegedServiceDoesNotBlockUserDomainSnapshot() throws {
        let snapshot = try UninstallSystemEnvironment.processSnapshot(
            processIDs: { [42] },
            inspect: { _ in .unreadable(userID: 0, realUserID: 0) }
        )

        XCTAssertTrue(snapshot.complete)
    }

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
        XCTAssertFalse(try XCTUnwrap(scan.candidates.first { $0.dataClass == .preference }).selectedByDefault)
        let support = try XCTUnwrap(scan.candidates.first { $0.dataClass == .support })
        XCTAssertTrue(support.eligible)
        XCTAssertFalse(support.selectedByDefault)
    }

    func testBatchRequiresEachAppAndKeepsIndependentPlans() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let second = fixture.root.appendingPathComponent("Applications/Second.app")
        try UninstallFixture.makeApp(second, identifier: "org.test.second")
        let firstScan = try fixture.scan()
        let secondScan = try fixture.scanner.scan(path: second.path, environment: fixture.environment.snapshot)
        let batch = try UninstallBatchPlanner.make(
            scans: [firstScan, secondScan],
            selections: [fixture.app.path: [fixture.app.path], second.path: [second.path]]
        )
        XCTAssertEqual(batch.applicationCount, 2)
        XCTAssertEqual(batch.itemCount, 2)
        XCTAssertEqual(Set(batch.plans.map(\.application.path)), [fixture.app.path, second.path])
        XCTAssertThrowsError(try UninstallBatchPlanner.make(
            scans: [firstScan, secondScan], selections: [fixture.app.path: [fixture.app.path], second.path: []]
        ))
        XCTAssertThrowsError(try UninstallBatchPlanner.make(
            scans: [firstScan, firstScan], selections: [fixture.app.path: [fixture.app.path]]
        ))
    }

    func testEmbeddedHelperIsGroupedUnderItsParentApp() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let helper = fixture.app.appendingPathComponent("Contents/Helpers/Helper.app")
        try UninstallFixture.makeApp(helper, identifier: "org.test.helper")
        let browse = try fixture.scanner.inventory(runningPaths: [])
        XCTAssertEqual(browse.apps.map(\.path), [fixture.app.path])
        let inventory = try fixture.scanner.inventory(runningPaths: [], includeComponents: true)
        XCTAssertEqual(inventory.topLevelApps.map(\.path), [fixture.app.path])
        XCTAssertEqual(inventory.components(of: try XCTUnwrap(inventory.topLevelApps.first)).map(\.path), [helper.path])
        XCTAssertEqual(inventory.parent(of: try XCTUnwrap(inventory.apps.first { $0.path == helper.path }))?.path, fixture.app.path)
    }

    func testNestedApplicationHelpersDoNotUseInstallationFolderDepth() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let nested = fixture.root.appendingPathComponent("Applications/Unity/Hub/Editor/6000.3.14f1/Unity.app")
        let helper = nested.appendingPathComponent("Contents/Helpers/Nested/UnityHelper.app")
        try UninstallFixture.makeApp(nested, identifier: "org.test.unity")
        try UninstallFixture.makeApp(helper, identifier: "org.test.unity-helper")

        let browse = try fixture.scanner.inventory(runningPaths: [])
        XCTAssertTrue(browse.complete)
        XCTAssertFalse(browse.apps.contains { $0.path == helper.path })

        let review = try fixture.scanner.inventory(runningPaths: [], includeComponents: true)
        XCTAssertTrue(review.complete)
        XCTAssertTrue(review.apps.contains { $0.path == helper.path })
        XCTAssertFalse(review.coverage.contains { $0.issue?.contains("深度上限") == true })
    }

    func testRunningSystemAppsOutsideInstallationRootsDoNotBlockInventory() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let inventory = try fixture.scanner.inventory(runningPaths: [
            "/System/Library/CoreServices/Finder.app",
            fixture.app.appendingPathComponent("Contents/Frameworks/Unknown.app").path
        ])
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.apps.map(\.path), [fixture.app.path])
    }

    func testInventoryFindsTopLevelAppsBeforeDeepDirectoryBudgetIsExhausted() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let applications = fixture.root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications.appendingPathComponent("A/Deep"), withIntermediateDirectories: true)
        let other = applications.appendingPathComponent("Other.app")
        try UninstallFixture.makeApp(other, identifier: "org.test.other")
        var scanner = fixture.scanner
        scanner.inventoryMaximumDirectories = 5

        let inventory = try scanner.inventory(runningPaths: [])
        XCTAssertEqual(Set(inventory.topLevelApps.map(\.path)), [fixture.app.path, other.path])
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.coverage.filter { $0.issue?.contains("上限") == true }.count, 1)
    }

    func testIncompleteInventoryAllowsOnlyTheVerifiedAppBundle() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let cache = try fixture.makeData("Caches")
        var scanner = fixture.scanner
        scanner.inventoryMaximumDirectories = 2
        let scan = try scanner.scan(path: fixture.app.path, environment: fixture.environment.snapshot)

        XCTAssertFalse(scan.inventoryComplete)
        XCTAssertTrue(scan.canPlan)
        XCTAssertTrue(try XCTUnwrap(scan.candidates.first { $0.path == fixture.app.path }).eligible)
        XCTAssertFalse(try XCTUnwrap(scan.candidates.first { $0.path == cache.path }).eligible)
        XCTAssertNoThrow(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path, cache.path]))
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

    func testCaseVariantIdentifiersProtectSharedData() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        try UninstallFixture.makeApp(fixture.root.appendingPathComponent("Applications/Other.app"), identifier: "ORG.test.fixture")
        _ = try fixture.makeData("Preferences", name: "org.test.fixture.plist", directory: false)
        let candidate = try XCTUnwrap(fixture.scan().candidates.first { $0.dataClass == .preference })
        XCTAssertFalse(candidate.eligible)
        XCTAssertEqual(candidate.confidence, .protected)
        let apple = fixture.root.appendingPathComponent("Applications/Apple.app")
        try UninstallFixture.makeApp(apple, identifier: "COM.APPLE.fixture")
        XCTAssertNotEqual(try fixture.scanner.application(apple.path).source, .system)
    }

    func testUserOwnedOptionalAppleAppCanMoveWithoutItsAssociatedData() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let apple = fixture.root.appendingPathComponent("Applications/Xcode-beta.app")
        let stable = fixture.root.appendingPathComponent("Applications/Xcode.app")
        try UninstallFixture.makeApp(apple, identifier: "com.apple.dt.Xcode")
        try UninstallFixture.makeApp(stable, identifier: "com.apple.dt.Xcode")
        let cache = try fixture.makeData("Caches", name: "com.apple.dt.Xcode")
        let scan = try fixture.scanner.scan(path: apple.path, environment: fixture.environment.snapshot)

        XCTAssertNotEqual(scan.application.source, .system)
        XCTAssertTrue(scan.canPlan)
        XCTAssertTrue(scan.inventory.contains { $0.path == stable.path })
        XCTAssertTrue(try XCTUnwrap(scan.candidates.first { $0.path == apple.path }).eligible)
        let associated = try XCTUnwrap(scan.candidates.first { $0.path == cache.path })
        XCTAssertFalse(associated.eligible)
        XCTAssertEqual(associated.confidence, .protected)
        XCTAssertTrue(associated.evidence.contains(.competingApplication(stable.path)))
        XCTAssertNil(associated.snapshot)
        XCTAssertNoThrow(try UninstallPlanner.make(scan: scan, selectedIDs: [apple.path]))
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [apple.path, cache.path]))
    }

    func testRestrictedAndImmutableFilesystemFlagsRemainProtected() {
        XCTAssertTrue(UninstallFileSystem.protectedForRemoval(flags: UInt32(SF_RESTRICTED)))
        XCTAssertTrue(UninstallFileSystem.protectedForRemoval(flags: UInt32(UF_IMMUTABLE)))
        XCTAssertTrue(UninstallFileSystem.protectedForRemoval(flags: UInt32(SF_IMMUTABLE)))
        XCTAssertFalse(UninstallFileSystem.protectedForRemoval(flags: 0))
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

    func testApplicationTreeHasItsOwnBoundedSnapshotBudget() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        var fs = UninstallFileSystem()
        fs.maximumEntries = 1
        fs.maximumSeconds = 0
        XCTAssertThrowsError(try fs.tree(fixture.app.path))
        XCTAssertGreaterThan(try fs.tree(fixture.app.path, isApplication: true).entryCount, 1)
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
        environment = .init(runningPaths: [], managementState: .managed,
                            homebrewApps: [], restrictions: ["Managed"], coverage: [])
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

    func testDeclaredPrivilegedHelperRemainsProtectedWithoutRemovalFlow() throws {
        let fixture = try UninstallFixture(); defer { fixture.remove() }
        let infoURL = fixture.app.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["SMPrivilegedExecutables"] = ["org.test.fixture.helper": "identifier org.test.fixture.helper"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)

        let scan = try fixture.scan()
        XCTAssertEqual(scan.application.source, .vendorRequired)
        XCTAssertFalse(scan.canPlan)
        XCTAssertThrowsError(try UninstallPlanner.make(scan: scan, selectedIDs: [fixture.app.path]))
    }
}
