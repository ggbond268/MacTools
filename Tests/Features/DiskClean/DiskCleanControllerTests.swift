import XCTest
@testable import MacTools

@MainActor
final class DiskCleanControllerTests: XCTestCase {
    func testIdleSubtitleIsChooseCleanScope() {
        let controller = makeController()

        XCTAssertEqual(controller.snapshot.subtitle, "选择清理范围")
        XCTAssertEqual(controller.snapshot.phase, .idle)
    }

    func testScanTransitionsThroughScanningToScanned() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let scanner = FakeDiskCleanControllerScanner(result: result, delayNanoseconds: 20_000_000)
        let controller = makeController(scanner: scanner)

        controller.scan()

        XCTAssertEqual(controller.snapshot.phase, .scanning)
        await waitUntil { controller.snapshot.phase == .scanned }
        XCTAssertEqual(controller.snapshot.scanResult, result)
        XCTAssertFalse(controller.snapshot.isResultStale)
        XCTAssertTrue(controller.snapshot.canClean)
    }

    func testChangingSelectedChoicesAfterScanMarksResultStaleAndDisablesCleaning() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let scanner = FakeDiskCleanControllerScanner(result: result)
        let executor = FakeDiskCleanControllerExecutor()
        let controller = makeController(scanner: scanner, executor: executor)

        controller.scan()
        await waitUntil { controller.snapshot.phase == .scanned }
        controller.setChoice(.browser, isSelected: false)
        controller.cleanSelected(candidateIDs: Set(result.cleanableCandidates.map(\.id)))

        XCTAssertTrue(controller.snapshot.isResultStale)
        XCTAssertFalse(controller.snapshot.canClean)
        XCTAssertEqual(executor.cleanCalls.count, 0)
    }

    func testCleanTransitionsThroughCleaningToCompleted() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let executionResult = DiskCleanExecutionResult(itemResults: [
            DiskCleanExecutionItemResult(
                candidateID: "candidate",
                path: "/Users/tester/Library/Caches/App",
                outcome: .removed(reclaimedBytes: 10)
            )
        ])
        let scanner = FakeDiskCleanControllerScanner(result: result)
        let executor = FakeDiskCleanControllerExecutor(
            result: executionResult,
            delayNanoseconds: 20_000_000
        )
        let controller = makeController(scanner: scanner, executor: executor)

        controller.scan()
        await waitUntil { controller.snapshot.phase == .scanned }
        controller.cleanSelected(candidateIDs: ["candidate"])

        XCTAssertEqual(controller.snapshot.phase, .cleaning)
        await waitUntil { controller.snapshot.phase == .completed }
        XCTAssertEqual(controller.snapshot.executionResult, executionResult)
        XCTAssertEqual(executor.cleanCalls.map(\.selectedCandidateIDs), [["candidate"]])
    }

    func testScannerAndExecutorErrorsBecomeUserFacingMessages() async {
        let scanError = TestDiskCleanControllerError(message: "scan failed")
        let failingScanner = FakeDiskCleanControllerScanner(error: scanError)
        let scanController = makeController(scanner: failingScanner)

        scanController.scan()
        await waitUntil { scanController.snapshot.errorMessage == "scan failed" }
        XCTAssertEqual(scanController.snapshot.phase, .idle)

        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let executeError = TestDiskCleanControllerError(message: "clean failed")
        let scanner = FakeDiskCleanControllerScanner(result: result)
        let executor = FakeDiskCleanControllerExecutor(error: executeError)
        let cleanController = makeController(scanner: scanner, executor: executor)

        cleanController.scan()
        await waitUntil { cleanController.snapshot.phase == .scanned }
        cleanController.cleanSelected(candidateIDs: ["candidate"])
        await waitUntil { cleanController.snapshot.errorMessage == "clean failed" }
        XCTAssertEqual(cleanController.snapshot.phase, .scanned)
    }

    func testCancelingScanOrCleanReturnsToStableState() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let slowScanner = FakeDiskCleanControllerScanner(
            result: result,
            delayNanoseconds: 1_000_000_000
        )
        let scanController = makeController(scanner: slowScanner)

        scanController.scan()
        XCTAssertEqual(scanController.snapshot.phase, .scanning)
        scanController.cancelCurrentOperation()
        XCTAssertEqual(scanController.snapshot.phase, .idle)

        let scanner = FakeDiskCleanControllerScanner(result: result)
        let slowExecutor = FakeDiskCleanControllerExecutor(delayNanoseconds: 1_000_000_000)
        let cleanController = makeController(scanner: scanner, executor: slowExecutor)

        cleanController.scan()
        await waitUntil { cleanController.snapshot.phase == .scanned }
        cleanController.cleanSelected(candidateIDs: ["candidate"])
        XCTAssertEqual(cleanController.snapshot.phase, .cleaning)
        cleanController.cancelCurrentOperation()
        XCTAssertEqual(cleanController.snapshot.phase, .scanned)
        XCTAssertNil(cleanController.snapshot.executionResult)
    }

    func testCleanIsEnabledAfterScanAndInvokesExecutor() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let scanner = FakeDiskCleanControllerScanner(result: result)
        let executor = FakeDiskCleanControllerExecutor()
        let controller = makeController(scanner: scanner, executor: executor)

        controller.scan()
        await waitUntil { controller.snapshot.phase == .scanned }
        controller.cleanSelected(candidateIDs: ["candidate"])

        await waitUntil { controller.snapshot.phase == .completed }
        XCTAssertEqual(controller.snapshot.scanResult, result)
        XCTAssertEqual(executor.cleanCalls.map(\.selectedCandidateIDs), [["candidate"]])
    }

    func testScanProgressLogUpdatesSnapshotWhileScanIsRunning() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let scanner = FakeDiskCleanControllerScanner(
            result: result,
            progressMessages: [
                DiskCleanScanLogMessage(text: "展开规则：Cache", tone: .info),
                DiskCleanScanLogMessage(text: "可清理：/Users/tester/Library/Caches/App", tone: .success)
            ],
            delayNanoseconds: 250_000_000
        )
        let controller = makeController(scanner: scanner)

        controller.scan()

        await waitUntil {
            controller.snapshot.scanLogEntries.contains {
                $0.text == "可清理：/Users/tester/Library/Caches/App"
            }
        }
        XCTAssertEqual(controller.snapshot.phase, .scanning)
        XCTAssertEqual(
            controller.snapshot.scanLogEntries.map(\.text),
            [
                "开始扫描：缓存清理、开发者缓存清理、浏览器缓存清理",
                "展开规则：Cache",
                "可清理：/Users/tester/Library/Caches/App"
            ]
        )

        await waitUntil { controller.snapshot.phase == .scanned }
        XCTAssertEqual(controller.snapshot.scanLogEntries.last?.text, "可清理：/Users/tester/Library/Caches/App")
    }

    func testScanProgressLogBatchesSnapshotUpdatesForLargeScans() async {
        let result = scanResult(choices: Set(DiskCleanChoice.allCases))
        let progressMessages = (0..<200).map {
            DiskCleanScanLogMessage(
                text: "可清理：/Users/tester/Library/Caches/App/\($0)",
                tone: .success
            )
        }
        let scanner = FakeDiskCleanControllerScanner(
            result: result,
            progressMessages: progressMessages
        )
        let controller = makeController(scanner: scanner)
        var stateChangeCount = 0
        controller.onStateChange = {
            stateChangeCount += 1
        }

        controller.scan()
        await waitUntil { controller.snapshot.phase == .scanned }

        XCTAssertLessThanOrEqual(stateChangeCount, 12)
        XCTAssertEqual(controller.snapshot.scanLogEntries.last?.text, "可清理：/Users/tester/Library/Caches/App/199")
    }

    private func makeController(
        scanner: DiskCleanScanning = FakeDiskCleanControllerScanner(),
        executor: DiskCleanExecuting = FakeDiskCleanControllerExecutor()
    ) -> DiskCleanController {
        DiskCleanController(scanner: scanner, executor: executor)
    }

    private func scanResult(choices: Set<DiskCleanChoice>) -> DiskCleanScanResult {
        DiskCleanScanResult(
            choices: choices,
            candidates: [
                DiskCleanCandidate(
                    id: "candidate",
                    ruleID: "rule",
                    choice: .cache,
                    title: "Cache",
                    path: "/Users/tester/Library/Caches/App",
                    sizeBytes: 10,
                    safety: .allowed,
                    risk: .low
                )
            ],
            scannedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private struct TestDiskCleanControllerError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class FakeDiskCleanControllerScanner: DiskCleanScanning, @unchecked Sendable {
    var result: DiskCleanScanResult
    var error: Error?
    var progressMessages: [DiskCleanScanLogMessage]
    var delayNanoseconds: UInt64
    private(set) var scanCalls: [Set<DiskCleanChoice>] = []

    init(
        result: DiskCleanScanResult = DiskCleanScanResult(
            choices: Set(DiskCleanChoice.allCases),
            candidates: [],
            scannedAt: Date(timeIntervalSince1970: 0)
        ),
        error: Error? = nil,
        progressMessages: [DiskCleanScanLogMessage] = [],
        delayNanoseconds: UInt64 = 0
    ) {
        self.result = result
        self.error = error
        self.progressMessages = progressMessages
        self.delayNanoseconds = delayNanoseconds
    }

    func scan(
        choices: Set<DiskCleanChoice>,
        progress: DiskCleanScanProgressHandler
    ) async throws -> DiskCleanScanResult {
        scanCalls.append(choices)
        for message in progressMessages {
            await progress(message)
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }
        return result
    }
}

private final class FakeDiskCleanControllerExecutor: DiskCleanExecuting, @unchecked Sendable {
    struct CleanCall: Equatable {
        let candidates: [DiskCleanCandidate]
        let selectedCandidateIDs: Set<DiskCleanCandidate.ID>
    }

    var result: DiskCleanExecutionResult
    var error: Error?
    var delayNanoseconds: UInt64
    private(set) var cleanCalls: [CleanCall] = []

    init(
        result: DiskCleanExecutionResult = DiskCleanExecutionResult(itemResults: []),
        error: Error? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.result = result
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func clean(
        candidates: [DiskCleanCandidate],
        selectedCandidateIDs: Set<DiskCleanCandidate.ID>
    ) async throws -> DiskCleanExecutionResult {
        cleanCalls.append(CleanCall(candidates: candidates, selectedCandidateIDs: selectedCandidateIDs))
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error {
            throw error
        }
        return result
    }
}
