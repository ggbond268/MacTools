import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanPurgeRootsStoreTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var persistence: InMemoryDiskCleanPurgeRootsPersistence!
    private var store: DiskCleanPurgeRootsStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanPurgeRootsStoreTests")
        persistence = InMemoryDiskCleanPurgeRootsPersistence()
        store = DiskCleanPurgeRootsStore(persistence: persistence)
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        persistence = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Normalization

    /// Users may pick a symlinked folder; store the physical path or `O_NOFOLLOW_ANY` rejects the whole tree.
    func testStoresPhysicalPathForSymlinkedRoot() throws {
        let real = try temporaryDirectory.makeDirectory("Projects")
        let link = try temporaryDirectory.makeSymlink("ProjectsLink", destination: "Projects")

        let update = store.add(link.path)

        XCTAssertEqual(update.roots, [real.path])
        XCTAssertEqual(persistence.storedRoots, [real.path])
    }

    /// Two spellings of the same directory keep only one root.
    func testRejectsDuplicateAfterNormalization() throws {
        let real = try temporaryDirectory.makeDirectory("Code")
        try temporaryDirectory.makeSymlink("CodeLink", destination: "Code")

        store.add(real.path)
        let update = store.add(temporaryDirectory.resolve("CodeLink").path)

        XCTAssertEqual(update.roots, [real.path])
        XCTAssertEqual(update.rejections.count, 1)
        guard case .duplicate = update.rejections[0] else {
            return XCTFail("duplicate root should report .duplicate, got \(update.rejections[0])")
        }
    }

    /// A trailing slash must not create a second root.
    func testDropsDescendantWhenAncestorIsAdded() throws {
        let ancestor = try temporaryDirectory.makeDirectory("Repos")
        let descendant = try temporaryDirectory.makeDirectory("Repos/app")

        let update = store.replaceAll(with: [ancestor.path, descendant.path])

        XCTAssertEqual(update.roots, [ancestor.path])
        XCTAssertEqual(update.rejections, [.coveredByAncestor(path: descendant.path, ancestor: ancestor.path)])
    }

    /// Adjudication is order-independent: descendant then ancestor still keeps the ancestor. Shrinking the user's explicit scope is the worse failure.

    func testRejectsMissingPath() {
        let missing = temporaryDirectory.resolve("NotThere").path

        let update = store.add(missing)

        XCTAssertTrue(update.roots.isEmpty)
        XCTAssertEqual(update.rejections, [.unresolvable(path: missing)])
    }

    /// Relative paths would be resolved by `realpath` against cwd into a directory the user never chose; reject them outright.
    func testRejectsRelativePath() {
        let update = store.add("Documents/Code")

        XCTAssertTrue(update.roots.isEmpty)
        XCTAssertEqual(update.rejections, [.unresolvable(path: "Documents/Code")])
    }

    // MARK: - Too-broad denylist

    func testRejectsHomeDirectoryAsRoot() {
        let home = NSHomeDirectory()
        let update = DiskCleanPurgeRootNormalizer.normalize([home]) { $0 }

        XCTAssertTrue(update.roots.isEmpty)
        XCTAssertEqual(update.rejections, [.tooBroad(path: home)])
    }

    func testRejectsSystemAndApplicationsRoots() {
        for path in ["/", "/Applications", "/System", "/Users", "/Library", "/Volumes"] {
            let update = DiskCleanPurgeRootNormalizer.normalize([path]) { $0 }
            XCTAssertEqual(update.rejections, [.tooBroad(path: path)], path)
            XCTAssertTrue(update.roots.isEmpty, path)
        }
    }

    func testRejectsTopLevelHomeFoldersButAllowsProjectSubfolders() {
        let home = NSHomeDirectory()
        let documents = home + "/Documents"
        let project = documents + "/MyApp"

        let rejected = DiskCleanPurgeRootNormalizer.normalize([documents]) { $0 }
        XCTAssertEqual(rejected.rejections, [.tooBroad(path: documents)])

        let allowed = DiskCleanPurgeRootNormalizer.normalize([project]) { $0 }
        XCTAssertEqual(allowed.roots, [project])
        XCTAssertTrue(allowed.rejections.isEmpty)
    }

    /// Denylist covers any account's home, not just the current user's: `/Users/<name>/Documents`
    /// is exactly as broad as the current user's own Documents folder.

    func testSanitizeDropsPersistedTooBroadRoots() throws {
        let home = NSHomeDirectory()
        let project = try temporaryDirectory.makeDirectory("Code").path
        persistence.storedRoots = [home, "/Applications", project, "/"]

        XCTAssertEqual(store.roots(), [project])
        XCTAssertEqual(persistence.storedRoots, [project])
    }

    // MARK: - Add/remove

    func testUserDefaultsPersistenceRoundTrip() throws {
        let suiteName = "DiskCleanPurgeRootsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UserDefaultsDiskCleanPurgeRootsPersistence(defaults: defaults)

        XCTAssertTrue(persistence.loadRoots().isEmpty)
        persistence.saveRoots(["/tmp/a", "/tmp/b"])

        XCTAssertEqual(persistence.loadRoots(), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsDiskCleanPurgeRootsPersistence.defaultsKey),
            ["/tmp/a", "/tmp/b"]
        )
    }
}

/// In-memory persistence: purge-root tests never touch `UserDefaults.standard`.
final class InMemoryDiskCleanPurgeRootsPersistence: DiskCleanPurgeRootsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []

    var storedRoots: [String] {
        get { lock.withLock { roots } }
        set { lock.withLock { roots = newValue } }
    }

    func loadRoots() -> [String] {
        storedRoots
    }

    func saveRoots(_ roots: [String]) {
        storedRoots = roots
    }
}
