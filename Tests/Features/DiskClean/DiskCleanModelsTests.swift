import XCTest
@testable import MacTools

final class DiskCleanModelsTests: XCTestCase {
    func testCleanupChoiceTitlesMatchFirstVersionScope() {
        XCTAssertEqual(DiskCleanChoice.cache.title, "缓存清理")
        XCTAssertEqual(DiskCleanChoice.developer.title, "开发者缓存清理")
        XCTAssertEqual(DiskCleanChoice.browser.title, "浏览器缓存清理")
        XCTAssertEqual(DiskCleanChoice.allCases, [.cache, .developer, .browser])
    }

    func testScanResultTotalsOnlyAllowedCandidates() {
        let result = DiskCleanScanResult(
            choices: [.cache],
            candidates: [
                DiskCleanCandidate(
                    id: "a",
                    ruleID: "r1",
                    choice: .cache,
                    title: "A",
                    path: "/tmp/a",
                    sizeBytes: 10,
                    safety: .allowed,
                    risk: .low
                ),
                DiskCleanCandidate(
                    id: "b",
                    ruleID: "r2",
                    choice: .cache,
                    title: "B",
                    path: "/tmp/b",
                    sizeBytes: 20,
                    safety: .protected(reason: "protected"),
                    risk: .high
                )
            ],
            scannedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.cleanableSizeBytes, 10)
        XCTAssertEqual(result.cleanableCandidates.map(\.id), ["a"])
        XCTAssertEqual(result.protectedCount, 1)
    }
}
