import XCTest
@testable import MacTools

final class DiskCleanRuleCatalogTests: XCTestCase {
    func testCatalogExposesExactlyFirstVersionChoices() {
        let catalog = DiskCleanRuleCatalog.moleFirstVersion

        XCTAssertEqual(Set(catalog.rules.map(\.choice)), Set(DiskCleanChoice.allCases))
        XCTAssertEqual(DiskCleanChoice.allCases, [.cache, .developer, .browser])
    }

    func testCacheRulesContainRepresentativeMoleUserAppCloudAndOfficeTargets() {
        let rules = DiskCleanRuleCatalog.moleFirstVersion.rules(for: .cache)
        let haystack = joinedRuleContent(rules)

        XCTAssertTrue(haystack.contains("~/Library/Caches/*"))
        XCTAssertTrue(haystack.contains("~/Library/Logs/*"))
        XCTAssertTrue(haystack.contains("~/Library/Saved Application State/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/com.dropbox.*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/com.microsoft.OneDrive"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/com.microsoft.Word"))
        XCTAssertTrue(haystack.contains("~/Library/Containers/com.apple.AppStore/Data/Library/Caches/*"))
    }

    func testDeveloperRulesContainMoleDeveloperToolTargets() {
        let rules = DiskCleanRuleCatalog.moleFirstVersion.rules(for: .developer)
        let haystack = joinedRuleContent(rules)

        XCTAssertTrue(haystack.contains("xcodeDerivedData"))
        XCTAssertTrue(haystack.contains("~/Library/Developer/CoreSimulator/Caches/*"))
        XCTAssertTrue(haystack.contains("npmCache"))
        XCTAssertTrue(haystack.contains("pnpmStore"))
        XCTAssertTrue(haystack.contains("bunCache"))
        XCTAssertTrue(haystack.contains("pipCache"))
        XCTAssertTrue(haystack.contains("goBuildCache"))
        XCTAssertTrue(haystack.contains("~/.cargo/registry/cache/*"))
        XCTAssertTrue(haystack.contains("~/.docker/buildx/cache/*"))
        XCTAssertTrue(haystack.contains("jetbrainsToolboxOldVersions"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/Cursor/*"))
        XCTAssertTrue(haystack.contains("~/Library/Application Support/Codex/Cache/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/Homebrew/*"))
    }

    func testBrowserRulesContainMoleBrowserTargetsAndDynamicRules() {
        let rules = DiskCleanRuleCatalog.moleFirstVersion.rules(for: .browser)
        let haystack = joinedRuleContent(rules)

        XCTAssertTrue(haystack.contains("~/Library/Caches/com.apple.Safari/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/Google/Chrome/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/company.thebrowser.Browser/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/BraveSoftware/Brave-Browser/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/com.microsoft.edgemac/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/Firefox/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/com.vivaldi.Vivaldi/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/Comet/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/com.kagi.kagimacOS/*"))
        XCTAssertTrue(haystack.contains("~/Library/Caches/zen/*"))
        XCTAssertTrue(haystack.contains("serviceWorkerCache"))
        XCTAssertTrue(haystack.contains("oldBrowserVersions"))
    }

    func testFirstVersionRulesDoNotRequireAdmin() {
        XCTAssertFalse(DiskCleanRuleCatalog.moleFirstVersion.rules.contains { $0.requiresAdmin })
    }

    private func joinedRuleContent(_ rules: [DiskCleanRule]) -> String {
        rules.flatMap { rule -> [String] in
            var values = [rule.id, rule.title]
            values += rule.targets.map { target in
                switch target {
                case let .path(path):
                    return path
                case let .dynamic(dynamicRule):
                    return dynamicRule.rawValue
                }
            }
            return values
        }
        .joined(separator: "\n")
    }
}
