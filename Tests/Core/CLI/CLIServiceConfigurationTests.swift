import XCTest
@testable import MacTools

final class CLIServiceConfigurationTests: XCTestCase {
    func testServiceNameIsDerivedOnlyFromHostBundleIdentifier() {
        XCTAssertEqual(
            CLIServiceConfiguration.serviceName(bundleIdentifier: "example.MacTools.dev"),
            "example.MacTools.dev.cli-broker"
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
}
