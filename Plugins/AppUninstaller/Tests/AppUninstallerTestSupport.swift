import Foundation
@testable import AppUninstallerPlugin

struct UninstallFixture: Sendable {
    let root: URL
    let home: URL
    let app: URL
    let configuration: UninstallConfiguration

    init() throws {
        root = URL(fileURLWithPath: UninstallFileSystem.physicalHome(NSTemporaryDirectory()))
            .appendingPathComponent("AppUninstallerTests-" + UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        app = root.appendingPathComponent("Applications/Fixture.app", isDirectory: true)
        configuration = .init(home: home.path, applicationRoots: [root.appendingPathComponent("Applications").path, home.appendingPathComponent("Applications").path],
                              selfPath: root.appendingPathComponent("MacTools.app").path, selfBundleID: "org.test.mactools", caskRoots: [])
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try Self.makeApp(app)
    }
    static func makeApp(_ url: URL, identifier: String = "org.test.fixture") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL", "CFBundleExecutable": "fixture", "CFBundleName": "Fixture", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture executable".utf8).write(to: url.appendingPathComponent("Contents/MacOS/fixture"))
    }
    func makeData(_ folder: String, name: String = "org.test.fixture", directory: Bool = true) throws -> URL {
        let parent = home.appendingPathComponent("Library/" + folder, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent(name)
        if directory {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("synthetic data".utf8).write(to: path.appendingPathComponent("data"))
        } else { try Data("synthetic data".utf8).write(to: path) }
        return path
    }
    var scanner: UninstallScanner { .init(configuration: configuration) }
    var environment: FixtureEnvironment { .init() }
    func scan() throws -> UninstallScan { try scanner.scan(path: app.path, environment: environment.snapshot) }
    func history() -> UninstallHistory { .init(directory: root.appendingPathComponent("History")) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct FixtureEnvironment: UninstallEnvironmentChecking {
    var snapshot = UninstallEnvironmentSnapshot(runningPaths: [], isManaged: false, homebrewApps: [], restrictions: [], coverage: [])
    var onInspect: (@Sendable () throws -> Void)?
    var onValidate: (@Sendable (String?) throws -> Void)?
    func inspect(applicationPath: String) async throws -> UninstallEnvironmentSnapshot { try onInspect?(); return snapshot }
    func validateRunning(applicationPath: String, additionalPath: String?) throws {
        try onValidate?(additionalPath)
        if (snapshot.runningPaths + snapshot.activeExecutables).contains(where: { UninstallPaths.contains($0, in: applicationPath) }) {
            throw AppUninstallerError.running
        }
    }
}

struct FixtureTrash: UninstallTrashing {
    let directory: URL
    var fail = false
    func trash(_ url: URL) throws -> URL? {
        if fail { throw AppUninstallerError.io(13) }
        let parent = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class UninstallTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}
