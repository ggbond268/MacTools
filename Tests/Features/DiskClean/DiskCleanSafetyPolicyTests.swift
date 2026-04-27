import XCTest
@testable import MacTools

final class DiskCleanSafetyPolicyTests: XCTestCase {
    private let home = "/Users/tester"

    func testRejectsInvalidPathShapesButAllowsFirefoxDotDotNames() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)

        assertInvalid(policy.validatePathShape(""))
        assertInvalid(policy.validatePathShape("relative/path"))
        assertInvalid(policy.validatePathShape("/tmp/../etc"))
        assertInvalid(policy.validatePathShape("\(home)/Library/Caches/Foo\nBar"))

        XCTAssertEqual(
            policy.validatePathShape("\(home)/Library/Caches/Firefox/name..files/data"),
            .allowed
        )
    }

    func testRejectsCriticalSystemRootsAndUnsafeSymlinks() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)

        for path in ["/", "/System", "/usr/bin", "/etc", "/private", "/var/db", "/Library/Extensions"] {
            assertInvalid(policy.safetyStatus(for: path))
        }

        assertInvalid(
            policy.safetyStatus(
                for: "\(home)/Library/Caches/SystemLink",
                isSymlink: true,
                resolvedSymlinkTarget: "/System"
            )
        )
    }

    func testAllowsSafeUserCachePathAndReportsWhitelist() {
        let whitelist = DiskCleanWhitelistStore(
            homeDirectory: home,
            includeDefaults: false,
            customRules: ["\(home)/Library/Caches/KeepMe*"]
        )
        let policy = DiskCleanSafetyPolicy(homeDirectory: home, whitelistStore: whitelist)

        XCTAssertEqual(policy.safetyStatus(for: "\(home)/Library/Caches/RegularApp"), .allowed)

        guard case let .whitelisted(rule) = policy.safetyStatus(for: "\(home)/Library/Caches/KeepMe/data") else {
            return XCTFail("Expected whitelisted status")
        }
        XCTAssertEqual(rule, "\(home)/Library/Caches/KeepMe*")
    }

    func testProtectsSensitiveDataPathsPortedFromMole() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)

        assertProtected(policy.safetyStatus(for: "\(home)/Library/Keychains/login.keychain-db"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Application Support/Firefox/Profiles/a.default/places.sqlite"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Application Support/com.apple.TCC/TCC.db"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/file.txt"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Application Support/1Password/Data/vault.sqlite"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Application Support/com.nssurge.surge-mac/profiles.conf"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"))
    }

    private func assertInvalid(
        _ status: DiskCleanSafetyStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .invalid = status {
            return
        }
        XCTFail("Expected invalid status, got \(status)", file: file, line: line)
    }

    private func assertProtected(
        _ status: DiskCleanSafetyStatus,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .protected = status {
            return
        }
        XCTFail("Expected protected status, got \(status)", file: file, line: line)
    }
}
