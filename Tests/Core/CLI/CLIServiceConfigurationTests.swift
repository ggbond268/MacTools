import XCTest
@testable import MacTools

final class CLIServiceConfigurationTests: XCTestCase {
    func testRoleBundleIdentifiersMapToOneBrokerService() {
        XCTAssertEqual(
            CLIServiceConfiguration.serviceName(
                bundleIdentifier: "app.example.mactools"
            ),
            "app.example.mactools.cli-broker"
        )
        XCTAssertEqual(
            CLIServiceConfiguration.serviceName(
                bundleIdentifier: "app.example.mactools.cli"
            ),
            "app.example.mactools.cli-broker"
        )
        XCTAssertEqual(
            CLIServiceConfiguration.serviceName(
                bundleIdentifier: "app.example.mactools.cli-broker"
            ),
            "app.example.mactools.cli-broker"
        )
    }

    func testContainingApplicationUsesExecutablePathNotWorkingDirectory() {
        let executable = URL(
            fileURLWithPath: "/tmp/Build/MacTools Dev.app/Contents/MacOS/MacToolsCLIBroker"
        )
        XCTAssertEqual(
            CLIServiceConfiguration.containingApplicationURL(executableURL: executable)?.path,
            "/tmp/Build/MacTools Dev.app"
        )
    }

    func testNightlyRolesUseOneServiceDistinctFromStableAndDevelopment() {
        let host = "com.example.mactools.nightly"
        for suffix in ["", ".cli", ".cli-broker"] {
            XCTAssertEqual(CLIServiceConfiguration.serviceName(bundleIdentifier: host + suffix), host + ".cli-broker")
        }
        for other in ["com.example.mactools", "com.example.mactools.dev"] {
            XCTAssertNotEqual(CLIServiceConfiguration.serviceName(bundleIdentifier: other), host + ".cli-broker")
        }
    }

    func testBareExecutableNameResolvesAgainstPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("bin/mactools")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755]
        ))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            CLIServiceConfiguration.resolvedExecutableURL(
                executablePath: "mactools",
                environment: ["PATH": executable.deletingLastPathComponent().path]
            ).path,
            executable.path
        )
    }
}
