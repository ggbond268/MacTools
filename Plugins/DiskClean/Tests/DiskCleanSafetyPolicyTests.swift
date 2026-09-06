import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

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

    /// Physical expansion rewrites `~/.cache/...` to `/Volumes/...`. Lexical whitelist rules must
    /// still match when the logical alias is also checked.
    func testWhitelistMatchesLogicalAliasWhenPhysicalPathDiverges() {
        let whitelist = DiskCleanWhitelistStore(
            homeDirectory: home,
            includeDefaults: false,
            customRules: ["\(home)/.cache/huggingface/*"]
        )
        let policy = DiskCleanSafetyPolicy(homeDirectory: home, whitelistStore: whitelist)
        let physical = "/Volumes/Data/cache/huggingface/models"
        let logical = "\(home)/.cache/huggingface/models"

        XCTAssertEqual(policy.safetyStatus(for: physical), .allowed, "physical alone must not match")
        guard case let .whitelisted(rule) = policy.safetyStatus(
            for: physical,
            alsoChecking: [logical]
        ) else {
            return XCTFail("expected whitelist hit via logical alias")
        }
        XCTAssertEqual(rule, "\(home)/.cache/huggingface/*")
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

    /// Staged objects may only be touched by reconciliation (design §7.6). Wide globs and ancestor expansion
    /// (`directChildren` returns hidden items too) can discover orphan staged objects; reject them here.
    func testProtectsStagedObjectsFromBeingScannedAsCandidates() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)
        let stagedName = DiskCleanRemovalPrimitive.stagedNamePrefix + "1BE2F1D0"

        assertProtected(policy.safetyStatus(for: "\(home)/Library/Caches/\(stagedName)"))
        assertProtected(policy.safetyStatus(for: "\(home)/Library/Caches/App/\(stagedName)"))
        assertProtected(
            policy.safetyStatus(for: "\(home)/Library/Caches/\(stagedName)/inner/data.bin"),
            "paths inside a staged tree must also be untouchable"
        )

        guard case let .protected(reason) = policy.safetyStatus(for: "\(home)/Library/Caches/\(stagedName)") else {
            return XCTFail("Expected protected status")
        }
        XCTAssertEqual(reason, "staging in progress")
    }

    /// Only objects whose final component matches the prefix are protected; ordinary caches are unaffected.
    func testStagedProtectionDoesNotSpillOverToOrdinaryCaches() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)

        XCTAssertEqual(policy.safetyStatus(for: "\(home)/Library/Caches/mactools-staged-like"), .allowed)
        XCTAssertEqual(policy.safetyStatus(for: "\(home)/Library/Caches/RegularApp"), .allowed)
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
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .protected = status {
            return
        }
        XCTFail("Expected protected status, got \(status). \(message)", file: file, line: line)
    }

    func testExpandedCocoaPodsCarthageAndRotatedLogPathsAreAllowed() {
        let policy = DiskCleanSafetyPolicy(homeDirectory: home)

        XCTAssertEqual(
            policy.safetyStatus(for: "\(home)/Library/Caches/CocoaPods/Pods/Release/AFNetworking"),
            .allowed
        )
        XCTAssertEqual(
            policy.safetyStatus(for: "\(home)/Library/Caches/org.carthage.CarthageKit/dependencies/Alamofire"),
            .allowed
        )
        XCTAssertEqual(
            policy.safetyStatus(for: "\(home)/Library/Logs/MyApp/app.log.2026-09-06"),
            .allowed
        )
        XCTAssertEqual(
            policy.safetyStatus(for: "\(home)/Library/Logs/MyApp/system.old"),
            .allowed
        )
    }

}
