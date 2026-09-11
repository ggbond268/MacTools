import Darwin
import XCTest
@testable import ActivityBarPlugin

final class ActivityBarNamespaceTests: XCTestCase {
    func testOnlyNightlyChangesExistingNamesAndFallbackPaths() {
        let nightly = ActivityBarNamespace(releaseChannel: "nightly")
        for channel in [nil, "stable", "development", "unknown"] {
            let stable = ActivityBarNamespace(releaseChannel: channel)
            XCTAssertEqual(stable.socketPath, "/tmp/mactools-activity-bar.sock")
            XCTAssertEqual(stable.hookFileName(tool: "claude"), "mactools-activity-claude-hook.sh")
            XCTAssertEqual(stable.fallbackHooksDirectory, ".mactools/activity-bar/hooks")
            XCTAssertNotEqual(stable.socketPath, nightly.socketPath)
        }
        let home = URL(fileURLWithPath: "/test-home")
        let paths = ActivityBarHookInstallerPaths.defaults(supportDirectory: nil, homeDirectory: home, namespace: nightly)
        XCTAssertEqual(paths.hookScriptsDirectory.path, "/test-home/.mactools-nightly/activity-bar/hooks")
        XCTAssertEqual(paths.claudeSettingsPath.path, "/test-home/.claude/settings.json")
    }

    func testStoppingOneChannelLeavesOtherSocketReachable() throws {
        // Keep test socket paths below sockaddr_un's limit without touching either real endpoint.
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ab-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ["stable", "nightly"].map { channel in
            directory.appendingPathComponent((ActivityBarNamespace(releaseChannel: channel).socketPath as NSString).lastPathComponent).path
        }
        let stable = ActivityBarHookSocketServer(socketPath: paths[0]) { _ in }
        let nightly = ActivityBarHookSocketServer(socketPath: paths[1]) { _ in }
        defer { stable.stop(); nightly.stop() }
        try stable.start()
        try nightly.start()
        XCTAssertTrue(stable.isRunning)
        XCTAssertTrue(nightly.isRunning)
        stable.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths[1]))
        try assertConnects(to: paths[1])
        try stable.start()
        nightly.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths[0]))
        try assertConnects(to: paths[0])
    }

    private func assertConnects(to path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        XCTAssertLessThan(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, "connect failed with errno \(errno)")
    }
}
