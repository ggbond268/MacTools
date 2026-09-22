import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import LaunchControlPlugin

final class LaunchControlScannerTests: XCTestCase {

    func testParsePlistExtractsCommonLaunchdFields() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("local.backup.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>local.backup</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/rsync</string>
                <string>-a</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StartInterval</key>
            <integer>3600</integer>
        </dict>
        </plist>
        """.write(to: plistURL, atomically: true, encoding: .utf8)

        let summary = try LaunchControlScanner.parsePlist(at: plistURL)

        XCTAssertEqual(summary.label, "local.backup")
        XCTAssertEqual(summary.programArguments, ["/usr/bin/rsync", "-a"])
        XCTAssertTrue(summary.runAtLoad)
        XCTAssertEqual(summary.keepAliveDescription, "SuccessfulExit")
        XCTAssertEqual(summary.startInterval, 3600)
        XCTAssertTrue(summary.rawPlist.contains("local.backup"))
    }

    func testParseLaunchctlPrintFindsPIDAndLastExitCode() {
        let parsed = LaunchControlScanner.parseLaunchctlPrint(
            """
            service = {
                pid = 42
                last exit code = 1
            }
            """
        )

        XCTAssertEqual(parsed.pid, 42)
        XCTAssertEqual(parsed.lastExitStatus, 1)
    }

    func testParseDisabledLabelsModernEnabledDisabledFormat() {
        // The format emitted by `launchctl print-disabled` on macOS 14+.
        let labels = LaunchControlScanner.parseDisabledLabels(
            """
            disabled services = {
                "local.enabled" => enabled
                "local.disabled" => disabled
                "com.vendor.helper" => disabled
            }
            """
        )

        XCTAssertEqual(labels, ["local.disabled", "com.vendor.helper"])
    }

    func testParseDisabledLabelsLegacyTrueFalseFormat() {
        // Older macOS used true/false; keep parsing it for backward compatibility.
        let labels = LaunchControlScanner.parseDisabledLabels(
            """
            disabled services = {
                "local.enabled" => false
                "local.disabled" => true
            }
            """
        )

        XCTAssertEqual(labels, ["local.disabled"])
    }
}

@MainActor
final class LaunchControlPluginTests: XCTestCase {
    private let suiteName = "LaunchControlPluginTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

}
