import XCTest
@testable import MacTools

final class DiskCleanScannerTests: XCTestCase {
    private let home = "/Users/tester"

    func testScanReturnsOnlySelectedChoicesAndNeverDeletesDuringDryRun() async throws {
        let cachePath = "\(home)/Library/Caches/App"
        let developerPath = "\(home)/Library/Caches/DeveloperTool"
        let fileSystem = FakeDiskCleanFileSystem(
            expansions: [
                "\(home)/Library/Caches/*": [item(cachePath), item(developerPath)],
                "\(home)/Library/Developer/*": [item(developerPath)]
            ],
            sizes: [
                cachePath: 10,
                developerPath: 20
            ]
        )
        let catalog = DiskCleanRuleCatalog(rules: [
            DiskCleanRule(
                id: "cache-rule",
                choice: .cache,
                title: "Cache",
                risk: .low,
                targets: [.path("\(home)/Library/Caches/*")]
            ),
            DiskCleanRule(
                id: "developer-rule",
                choice: .developer,
                title: "Developer",
                risk: .medium,
                targets: [.path("\(home)/Library/Developer/*")]
            )
        ])
        let scanner = makeScanner(catalog: catalog, fileSystem: fileSystem)

        let result = try await scanner.scan(choices: [.cache])

        XCTAssertEqual(result.choices, [.cache])
        XCTAssertEqual(result.candidates.map(\.choice), [.cache, .cache])
        XCTAssertEqual(Set(result.candidates.map(\.path)), [cachePath, developerPath])
        XCTAssertTrue(fileSystem.removedPaths.isEmpty)
    }

    func testScanPreservesWhitelistedProtectedAndInUseCandidatesAsNonCleanable() async throws {
        let allowedPath = "\(home)/Library/Caches/Regular"
        let whitelistedPath = "\(home)/Library/Caches/KeepMe/data"
        let protectedPath = "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"
        let runningPath = "\(home)/Library/Caches/Running"
        let fileSystem = FakeDiskCleanFileSystem(
            expansions: [
                "\(home)/Library/Caches/Regular": [item(allowedPath)],
                "\(home)/Library/Caches/KeepMe/data": [item(whitelistedPath)],
                "\(home)/Library/Application Support/Google/Chrome/Default/Cookies": [item(protectedPath)],
                "\(home)/Library/Caches/Running": [item(runningPath)]
            ],
            sizes: [
                allowedPath: 10,
                whitelistedPath: 20,
                protectedPath: 30,
                runningPath: 40
            ]
        )
        let whitelist = DiskCleanWhitelistStore(
            homeDirectory: home,
            includeDefaults: false,
            customRules: ["\(home)/Library/Caches/KeepMe*"]
        )
        let catalog = DiskCleanRuleCatalog(rules: [
            DiskCleanRule(
                id: "allowed",
                choice: .cache,
                title: "Allowed",
                risk: .low,
                targets: [.path("\(home)/Library/Caches/Regular")]
            ),
            DiskCleanRule(
                id: "whitelisted",
                choice: .cache,
                title: "Whitelisted",
                risk: .low,
                targets: [.path("\(home)/Library/Caches/KeepMe/data")]
            ),
            DiskCleanRule(
                id: "protected",
                choice: .cache,
                title: "Protected",
                risk: .high,
                targets: [.path("\(home)/Library/Application Support/Google/Chrome/Default/Cookies")]
            ),
            DiskCleanRule(
                id: "running",
                choice: .cache,
                title: "Running",
                risk: .medium,
                targets: [.path("\(home)/Library/Caches/Running")],
                skipWhenProcessIsRunning: ["Google Chrome"]
            )
        ])
        let scanner = makeScanner(
            catalog: catalog,
            fileSystem: fileSystem,
            whitelistStore: whitelist,
            processInspector: FakeDiskCleanProcessInspector(runningProcessNames: ["Google Chrome"])
        )

        let result = try await scanner.scan(choices: [.cache])

        XCTAssertEqual(result.cleanableCandidates.map(\.path), [allowedPath])
        XCTAssertEqual(result.cleanableSizeBytes, 10)
        XCTAssertEqual(result.protectedCount, 2)
        XCTAssertEqual(status(for: whitelistedPath, in: result), .whitelisted(rule: "\(home)/Library/Caches/KeepMe*"))
        XCTAssertEqual(status(for: protectedPath, in: result), .protected(reason: "browser profile data is protected"))
        XCTAssertEqual(status(for: runningPath, in: result), .inUse(processName: "Google Chrome"))
    }

    func testScanDeduplicatesParentChildCandidatesBeforeSizingTotals() async throws {
        let parent = "\(home)/Library/Caches/App"
        let child = "\(home)/Library/Caches/App/Nested"
        let sibling = "\(home)/Library/Caches/Other"
        let fileSystem = FakeDiskCleanFileSystem(
            expansions: [
                "\(home)/Library/Caches/App": [item(parent)],
                "\(home)/Library/Caches/App/Nested": [item(child)],
                "\(home)/Library/Caches/Other": [item(sibling)]
            ],
            sizes: [
                parent: 100,
                child: 75,
                sibling: 25
            ]
        )
        let catalog = DiskCleanRuleCatalog(rules: [
            DiskCleanRule(
                id: "dedupe",
                choice: .cache,
                title: "Dedupe",
                risk: .low,
                targets: [
                    .path("\(home)/Library/Caches/App"),
                    .path("\(home)/Library/Caches/App/Nested"),
                    .path("\(home)/Library/Caches/Other")
                ]
            )
        ])
        let scanner = makeScanner(catalog: catalog, fileSystem: fileSystem)

        let result = try await scanner.scan(choices: [.cache])

        XCTAssertEqual(result.candidates.map(\.path), [parent, sibling])
        XCTAssertEqual(result.cleanableSizeBytes, 125)
    }

    func testScanEmitsProgressMessagesForRulesCandidatesAndCompletion() async throws {
        let cachePath = "\(home)/Library/Caches/App"
        let fileSystem = FakeDiskCleanFileSystem(
            expansions: ["\(home)/Library/Caches/App": [item(cachePath)]],
            sizes: [cachePath: 10]
        )
        let catalog = DiskCleanRuleCatalog(rules: [
            DiskCleanRule(
                id: "cache",
                choice: .cache,
                title: "Cache",
                risk: .low,
                targets: [.path("\(home)/Library/Caches/App")]
            )
        ])
        let scanner = makeScanner(catalog: catalog, fileSystem: fileSystem)
        let recorder = DiskCleanProgressRecorder()

        _ = try await scanner.scan(choices: [.cache]) { message in
            await recorder.record(message)
        }

        let messages = await recorder.messages()
        let texts = messages.map(\.text)

        XCTAssertTrue(texts.contains("扫描范围：缓存清理"))
        XCTAssertTrue(texts.contains("展开规则：Cache"))
        XCTAssertTrue(texts.contains("匹配 1 项：Cache"))
        XCTAssertTrue(texts.contains("可清理：\(cachePath)"))
        XCTAssertEqual(texts.last, "扫描完成：1 项，1 项可清理")
    }

    private func makeScanner(
        catalog: DiskCleanRuleCatalog,
        fileSystem: FakeDiskCleanFileSystem,
        whitelistStore: DiskCleanWhitelistStore? = nil,
        processInspector: DiskCleanProcessInspecting = FakeDiskCleanProcessInspector()
    ) -> DiskCleanScanner {
        DiskCleanScanner(
            ruleCatalog: catalog,
            fileSystem: fileSystem,
            safetyPolicy: DiskCleanSafetyPolicy(
                homeDirectory: home,
                whitelistStore: whitelistStore ?? DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)
            ),
            processInspector: processInspector,
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    private func status(for path: String, in result: DiskCleanScanResult) -> DiskCleanSafetyStatus? {
        result.candidates.first { $0.path == path }?.safety
    }

    private func item(_ path: String, isDirectory: Bool = true) -> DiskCleanFileItem {
        DiskCleanFileItem(
            path: path,
            isDirectory: isDirectory,
            isSymlink: false,
            resolvedSymlinkTarget: nil
        )
    }
}

private final class FakeDiskCleanFileSystem: DiskCleanFileSystemProviding, @unchecked Sendable {
    let expansions: [String: [DiskCleanFileItem]]
    let sizes: [String: Int64]

    private(set) var removedPaths: [String] = []

    init(
        expansions: [String: [DiskCleanFileItem]],
        sizes: [String: Int64]
    ) {
        self.expansions = expansions
        self.sizes = sizes
    }

    func expandPathPattern(_ pattern: String) throws -> [DiskCleanFileItem] {
        expansions[pattern] ?? []
    }

    func itemInfo(at path: String) throws -> DiskCleanFileItem? {
        expansions.values
            .flatMap { $0 }
            .first { $0.path == path }
    }

    func sizeOfItem(at path: String) throws -> Int64 {
        sizes[path] ?? 0
    }

    func removeItem(at path: String) throws {
        removedPaths.append(path)
    }

    func deduplicatedParentChildPaths(_ paths: [String]) -> [String] {
        let uniqueSortedPaths = Array(Set(paths)).sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count < rhs.count
        }

        var kept: [String] = []
        for path in uniqueSortedPaths {
            if kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                continue
            }
            kept.append(path)
        }

        return kept.sorted()
    }
}

private struct FakeDiskCleanProcessInspector: DiskCleanProcessInspecting {
    var runningProcessNames: Set<String> = []

    func runningProcessName(from names: [String]) -> String? {
        names.first { runningProcessNames.contains($0) }
    }
}

private actor DiskCleanProgressRecorder {
    private var recordedMessages: [DiskCleanScanLogMessage] = []

    func record(_ message: DiskCleanScanLogMessage) {
        recordedMessages.append(message)
    }

    func messages() -> [DiskCleanScanLogMessage] {
        recordedMessages
    }
}
