import XCTest
@testable import MacTools

final class DiskCleanExecutorTests: XCTestCase {
    private let home = "/Users/tester"

    func testCleanRemovesOnlySelectedAllowedCandidatesAndCountsReclaimedBytes() async throws {
        let removable = candidate(id: "remove", path: "\(home)/Library/Caches/Remove", size: 10)
        let unselected = candidate(id: "unselected", path: "\(home)/Library/Caches/Unselected", size: 20)
        let protected = candidate(
            id: "protected",
            path: "\(home)/Library/Caches/Protected",
            size: 30,
            safety: .protected(reason: "protected")
        )
        let failed = candidate(id: "failed", path: "\(home)/Library/Caches/Failed", size: 40)
        let fileSystem = FakeDiskCleanExecutorFileSystem(
            items: [
                removable.path: item(removable.path),
                unselected.path: item(unselected.path),
                protected.path: item(protected.path),
                failed.path: item(failed.path)
            ],
            removeErrors: [failed.path: TestRemoveError()]
        )
        let executor = makeExecutor(fileSystem: fileSystem)

        let result = try await executor.clean(
            candidates: [removable, unselected, protected, failed],
            selectedCandidateIDs: [removable.id, protected.id, failed.id]
        )

        XCTAssertEqual(fileSystem.removedPaths, [removable.path, failed.path])
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.reclaimedBytes, 10)
        XCTAssertEqual(result.itemResults.map(\.candidateID), [removable.id, protected.id, failed.id])
    }

    func testCleanRevalidatesEachPathImmediatelyBeforeDeletion() async throws {
        let safe = candidate(id: "safe", path: "\(home)/Library/Caches/Safe", size: 10)
        let changed = candidate(id: "changed", path: "\(home)/Library/Caches/Changed", size: 20)
        let missing = candidate(id: "missing", path: "\(home)/Library/Caches/Missing", size: 30)
        let fileSystem = FakeDiskCleanExecutorFileSystem(
            items: [
                safe.path: item(safe.path),
                changed.path: item(changed.path, isSymlink: true, resolvedSymlinkTarget: "/System")
            ]
        )
        let executor = makeExecutor(fileSystem: fileSystem)

        let result = try await executor.clean(
            candidates: [safe, changed, missing],
            selectedCandidateIDs: [safe.id, changed.id, missing.id]
        )

        XCTAssertEqual(fileSystem.removedPaths, [safe.path])
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(outcome(for: changed.id, in: result), .skipped(.invalid(reason: "symlink points to protected system path")))
        XCTAssertEqual(outcome(for: missing.id, in: result), .skipped(.invalid(reason: "path no longer exists")))
    }

    func testCleanSkipsEveryNonCleanableSafetyStatus() async throws {
        let candidates = [
            candidate(id: "whitelisted", path: "\(home)/Library/Caches/White", safety: .whitelisted(rule: "rule")),
            candidate(id: "protected", path: "\(home)/Library/Caches/Protected", safety: .protected(reason: "protected")),
            candidate(id: "invalid", path: "\(home)/Library/Caches/Invalid", safety: .invalid(reason: "invalid")),
            candidate(id: "admin", path: "\(home)/Library/Caches/Admin", safety: .requiresAdmin(reason: "admin")),
            candidate(id: "in-use", path: "\(home)/Library/Caches/InUse", safety: .inUse(processName: "App"))
        ]
        let fileSystem = FakeDiskCleanExecutorFileSystem(
            items: Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, item($0.path)) })
        )
        let executor = makeExecutor(fileSystem: fileSystem)

        let result = try await executor.clean(
            candidates: candidates,
            selectedCandidateIDs: Set(candidates.map(\.id))
        )

        XCTAssertTrue(fileSystem.removedPaths.isEmpty)
        XCTAssertEqual(result.removedCount, 0)
        XCTAssertEqual(result.skippedCount, candidates.count)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.reclaimedBytes, 0)
    }

    private func makeExecutor(fileSystem: FakeDiskCleanExecutorFileSystem) -> DiskCleanExecutor {
        DiskCleanExecutor(
            fileSystem: fileSystem,
            safetyPolicy: DiskCleanSafetyPolicy(
                homeDirectory: home,
                whitelistStore: DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)
            )
        )
    }

    private func candidate(
        id: String,
        path: String,
        size: Int64 = 1,
        safety: DiskCleanSafetyStatus = .allowed
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            ruleID: "rule",
            choice: .cache,
            title: id,
            path: path,
            sizeBytes: size,
            safety: safety,
            risk: .low
        )
    }

    private func item(
        _ path: String,
        isSymlink: Bool = false,
        resolvedSymlinkTarget: String? = nil
    ) -> DiskCleanFileItem {
        DiskCleanFileItem(
            path: path,
            isDirectory: true,
            isSymlink: isSymlink,
            resolvedSymlinkTarget: resolvedSymlinkTarget
        )
    }

    private func outcome(
        for candidateID: String,
        in result: DiskCleanExecutionResult
    ) -> DiskCleanExecutionItemResult.Outcome? {
        result.itemResults.first { $0.candidateID == candidateID }?.outcome
    }
}

private struct TestRemoveError: Error {}

private final class FakeDiskCleanExecutorFileSystem: DiskCleanFileSystemProviding, @unchecked Sendable {
    var items: [String: DiskCleanFileItem]
    var removeErrors: [String: Error]

    private(set) var removedPaths: [String] = []

    init(
        items: [String: DiskCleanFileItem],
        removeErrors: [String: Error] = [:]
    ) {
        self.items = items
        self.removeErrors = removeErrors
    }

    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem] {
        []
    }

    func itemInfo(at path: String) throws -> DiskCleanFileItem? {
        items[path]
    }

    func sizeOfItem(at path: String) throws -> Int64 {
        0
    }

    func removeItem(at path: String) throws {
        removedPaths.append(path)
        if let error = removeErrors[path] {
            throw error
        }
        items[path] = nil
    }

    func deduplicatedParentChildPaths(_ paths: [String]) -> [String] {
        paths
    }
}
