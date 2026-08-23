import XCTest
@testable import MacTools

final class CLIServiceConfigurationTests: XCTestCase {
    func testServiceNameIsDerivedOnlyFromHostBundleIdentifier() {
        XCTAssertEqual(
            CLIServiceConfiguration.serviceName(bundleIdentifier: "example.MacTools.dev"),
            "example.MacTools.dev.cli-broker"
        )
    }

    func testStandaloneCLIIdentifierResolvesHostService() {
        XCTAssertEqual(
            CLIServiceConfiguration.serviceName(
                bundleIdentifier: "example.MacTools.dev.cli"
            ),
            "example.MacTools.dev.cli-broker"
        )
        XCTAssertEqual(
            CLIServiceConfiguration.hostBundleIdentifier(
                for: "example.MacTools.cli"
            ),
            "example.MacTools"
        )
        XCTAssertEqual(
            CLIServiceConfiguration.hostBundleIdentifier(
                for: "example.MacTools.cli-broker"
            ),
            "example.MacTools"
        )
    }

    func testReleaseDownloadURLUsesMatchingVersionedAsset() {
        XCTAssertEqual(
            CLIServiceConfiguration.releaseDownloadURL(version: "1.2.0-beta.1").absoluteString,
            "https://github.com/ggbond268/MacTools/releases/download/v1.2.0-beta.1/mactools-cli-1.2.0-beta.1-macos-universal.zip"
        )
    }

    func testReleaseDownloadURLFallsBackToReleaseListForInvalidVersion() {
        XCTAssertEqual(
            CLIServiceConfiguration.releaseDownloadURL(version: "1/2").absoluteString,
            "https://github.com/ggbond268/MacTools/releases"
        )
        XCTAssertEqual(
            CLIServiceConfiguration.releaseDownloadURL(version: nil).absoluteString,
            "https://github.com/ggbond268/MacTools/releases"
        )
    }

    func testFindsContainingApplicationThroughSymlinkedExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("MacTools.app/Contents/MacOS/mactools")
        let link = root.appendingPathComponent("bin/mactools")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            CLIServiceConfiguration.containingApplicationURL(executableURL: link),
            root.appendingPathComponent("MacTools.app")
        )
    }

    func testResolvesBareExecutableNameThroughPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("MacTools.app/Contents/MacOS/mactools")
        let link = root.appendingPathComponent("bin/mactools")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755]
        ))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = CLIServiceConfiguration.resolvedExecutableURL(
            executablePath: "mactools",
            environment: ["PATH": link.deletingLastPathComponent().path]
        )
        XCTAssertEqual(
            CLIServiceConfiguration.containingApplicationURL(executableURL: resolved),
            root.appendingPathComponent("MacTools.app")
        )
    }
}
