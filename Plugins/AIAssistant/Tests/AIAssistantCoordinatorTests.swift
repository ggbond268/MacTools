import Foundation
import XCTest
@testable import AIAssistantPlugin

@MainActor
final class AIAssistantCoordinatorTests: XCTestCase {
    private var panelController: RecordingPanelController!
    private var capturePipeline: StubCapturePipeline!

    override func setUp() async throws {
        panelController = RecordingPanelController()
        capturePipeline = StubCapturePipeline(result: .success("你好世界"))
    }

    func testCapturesTextAndCompletesSuccessfully() async {
        let client = StubProcessingClient(result: .success(
            AIProcessResult(
                providerTitle: "AI 服务",
                text: "处理结果",
                reasoningText: nil,
                sourceText: "",
                promptName: ""
            )
        ))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())

        await waitForPhase(coordinator) { $0 == .success }

        XCTAssertEqual(coordinator.snapshot.phase, .success)
        XCTAssertEqual(coordinator.snapshot.sourceText, "你好世界")
        XCTAssertEqual(coordinator.snapshot.result?.text, "处理结果")
        XCTAssertEqual(coordinator.snapshot.result?.promptName, "翻译")
        XCTAssertEqual(coordinator.snapshot.result?.sourceText, "你好世界")
    }

    func testCapturesTextAndPreservesReasoning() async {
        let client = StubProcessingClient(result: .success(
            AIProcessResult(
                providerTitle: "AI 服务",
                text: "处理结果",
                reasoningText: "这是思考过程",
                sourceText: "",
                promptName: ""
            )
        ))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())

        await waitForPhase(coordinator) { $0 == .success }

        XCTAssertEqual(coordinator.snapshot.result?.reasoningText, "这是思考过程")
    }

    func testMissingSelectionShowsError() async {
        capturePipeline = StubCapturePipeline(result: .missing)
        let coordinator = makeCoordinator(client: StubProcessingClient(result: .success(Self.makeResult())))

        coordinator.startProcessing(prompt: Self.makePrompt())

        await waitForPhase(coordinator) { $0 == .error(.missingSelection) }

        XCTAssertEqual(coordinator.snapshot.phase, .error(.missingSelection))
    }

    func testClientErrorShowsRequestFailed() async {
        let client = StubProcessingClient(result: .failure(OpenAICompatibleClientError.unauthorized))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())

        await waitForPhase(coordinator) { phase in
            if case .error = phase { return true }
            return false
        }

        guard case let .error(error) = coordinator.snapshot.phase else {
            return XCTFail("Expected error phase")
        }
        XCTAssertEqual(error, .requestFailed("API Key 无效或无权限"))
    }

    func testCopyResultWritesToPasteboard() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }

        coordinator.handle(.copyResult)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "处理结果")
    }

    func testReprocessActionUpdatesSourceTextAndRecompletes() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }
        XCTAssertEqual(coordinator.snapshot.sourceText, "你好世界")

        coordinator.handle(.reprocess(sourceText: "修改后的文本"))
        await waitForCondition(coordinator) { $0.phase == .success && $0.sourceText == "修改后的文本" }

        XCTAssertEqual(coordinator.snapshot.sourceText, "修改后的文本")
        XCTAssertEqual(coordinator.snapshot.result?.sourceText, "修改后的文本")
    }

    func testCapturesTextBeforeShowingPanel() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }

        // 验证没有在 capturing 阶段提前弹出面板抢夺焦点
        XCTAssertFalse(panelController.shownSnapshots.contains { $0.phase == .capturing })
        // 验证首次展示的面板已经具备完整的 sourceText
        guard let firstShown = panelController.shownSnapshots.first else {
            return XCTFail("Expected at least one shown snapshot")
        }
        XCTAssertEqual(firstShown.sourceText, "你好世界")
        XCTAssertEqual(firstShown.phase, .processing)
    }

    // MARK: - Non-destructive session controls

    func testHideKeepsSessionAndReopenShowsItWithoutRecapture() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }

        coordinator.handle(.hide)
        XCTAssertFalse(panelController.isVisible)
        XCTAssertTrue(coordinator.hasSession(forPromptID: "translate"))

        coordinator.reopenSession()
        XCTAssertTrue(panelController.isVisible)
        XCTAssertEqual(panelController.shownSnapshots.last?.phase, .success)
        XCTAssertEqual(panelController.shownSnapshots.last?.result?.text, "处理结果")
        // Reopening must not recapture or re-request.
        XCTAssertEqual(capturePipeline.captureCount, 1)
        XCTAssertEqual(client.callCount, 1)
    }

    func testStopDuringProcessingRestoresFinishedResult() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }

        // Start a rerun that hangs until cancelled.
        client.hangsUntilCancelled = true
        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForCondition(coordinator) { $0.phase == .processing }

        coordinator.handle(.stop)

        // Stop restores the previous finished view and keeps the session.
        XCTAssertEqual(coordinator.snapshot.phase, .success)
        XCTAssertEqual(coordinator.snapshot.result?.text, "处理结果")
        XCTAssertEqual(panelController.shownSnapshots.last?.phase, .success)
        XCTAssertTrue(coordinator.hasSession(forPromptID: "translate"))
    }

    func testDiscardAndCloseResetSession() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }
        XCTAssertTrue(coordinator.hasSession(forPromptID: "translate"))

        coordinator.handle(.discard)
        XCTAssertFalse(coordinator.hasSession(forPromptID: "translate"))
        XCTAssertEqual(coordinator.snapshot.phase, .idle)
        XCTAssertTrue(panelController.closedCount > 0)

        // close() shares discard semantics for teardown paths.
        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }
        coordinator.handle(.close)
        XCTAssertFalse(coordinator.hasSession(forPromptID: "translate"))
        XCTAssertEqual(coordinator.snapshot.phase, .idle)
    }

    // MARK: - Retry semantics

    func testRetryAfterCaptureFailureRecapturesText() async {
        capturePipeline = StubCapturePipeline(result: .missing)
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .error(.missingSelection) }
        XCTAssertEqual(capturePipeline.captureCount, 1)

        // The failed run never captured text, so retry must capture again.
        capturePipeline.outcome = .success("你好世界")
        coordinator.handle(.retry)
        await waitForPhase(coordinator) { $0 == .success }

        XCTAssertEqual(capturePipeline.captureCount, 2)
        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(coordinator.snapshot.sourceText, "你好世界")
    }

    func testRetryWithCapturedTextReprocessesWithoutRecapture() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }
        XCTAssertEqual(capturePipeline.captureCount, 1)

        // Make any recapture fail: retry must reuse the captured text instead.
        capturePipeline.outcome = .missing
        coordinator.handle(.retry)
        // The retried run must report success via a second client call, not the stale pre-retry snapshot.
        await waitForCondition(coordinator) {
            $0.phase == .success
                && $0.result?.text == "处理结果"
                && $0.sourceText == "你好世界"
                && client.callCount == 2
        }

        XCTAssertEqual(capturePipeline.captureCount, 1)
        XCTAssertEqual(client.callCount, 2)
    }

    func testRetainedResultSurvivesRerunAndStop() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .success }

        client.hangsUntilCancelled = true
        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForCondition(coordinator) { $0.phase == .processing }

        // The previous successful result stays visible while reprocessing.
        XCTAssertEqual(coordinator.snapshot.retainedResult?.text, "处理结果")

        coordinator.handle(.stop)
        XCTAssertEqual(coordinator.snapshot.phase, .success)
        XCTAssertEqual(coordinator.snapshot.result?.text, "处理结果")
        XCTAssertNil(coordinator.snapshot.retainedResult)
    }

    // MARK: - Confirmation flow for unverified pasteboard captures

    func testUnverifiedClipboardCaptureRequiresConfirmationBeforeRequest() async {
        capturePipeline = StubCapturePipeline(result: .unverified("剪贴板文本"))
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())

        await waitForPhase(coordinator) { $0 == .awaitingConfirmation }

        // The panel shows the pasteboard-derived text and waits; no provider
        // request may be issued before the user confirms.
        XCTAssertEqual(coordinator.snapshot.phase, .awaitingConfirmation)
        XCTAssertEqual(coordinator.snapshot.sourceText, "剪贴板文本")
        XCTAssertEqual(client.callCount, 0)

        coordinator.handle(.confirmSource)
        await waitForPhase(coordinator) { $0 == .success }

        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(coordinator.snapshot.sourceText, "剪贴板文本")
        XCTAssertEqual(coordinator.snapshot.result?.text, "处理结果")
    }

    // MARK: - Hidden panel completions

    func testCompletionWhileHiddenKeepsPanelHiddenUntilReopen() async {
        let client = StubProcessingClient(result: .success(Self.makeResult()))
        // The result lands well after the hide so the completion genuinely
        // happens for a hidden panel.
        client.resultDelay = 0.3
        let coordinator = makeCoordinator(client: client)

        coordinator.startProcessing(prompt: Self.makePrompt())
        await waitForPhase(coordinator) { $0 == .processing }

        coordinator.handle(.hide)
        XCTAssertFalse(panelController.isVisible)

        await waitForPhase(coordinator) { $0 == .success }

        // The snapshot is retained for the session, but the panel must not
        // reopen on its own.
        XCTAssertEqual(coordinator.snapshot.phase, .success)
        XCTAssertEqual(coordinator.snapshot.result?.text, "处理结果")
        XCTAssertFalse(panelController.isVisible)
        XCTAssertFalse(panelController.shownSnapshots.contains { $0.phase == .success })

        coordinator.reopenSession()
        XCTAssertTrue(panelController.isVisible)
        XCTAssertEqual(panelController.shownSnapshots.last?.phase, .success)
        XCTAssertEqual(panelController.shownSnapshots.last?.result?.text, "处理结果")
    }

    // MARK: - Helpers

    private func makeCoordinator(client: any AIProcessing) -> AIAssistantCoordinator {
        AIAssistantCoordinator(
            selectedTextCapturePipeline: capturePipeline,
            providerFactory: {
                .success(
                    ResolvedAIProvider(
                        title: "AI 服务",
                        client: client,
                        configuration: OpenAICompatibleConfiguration(),
                        apiKey: "test-key"
                    )
                )
            },
            panelController: panelController
        )
    }

    private static func makePrompt() -> AIAssistantPrompt {
        AIAssistantPrompt(
            id: "translate",
            name: "翻译",
            template: "请翻译：{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
    }

    private static func makeResult() -> AIProcessResult {
        AIProcessResult(
            providerTitle: "AI 服务",
            text: "处理结果",
            reasoningText: nil,
            sourceText: "你好世界",
            promptName: "翻译"
        )
    }

    private func waitForPhase(
        _ coordinator: AIAssistantCoordinator,
        _ condition: @escaping (AIAssistantPanelPhase) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition(coordinator.snapshot.phase) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForCondition(
        _ coordinator: AIAssistantCoordinator,
        _ condition: @escaping (AIAssistantPanelSnapshot) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition(coordinator.snapshot) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

// MARK: - Stubs

@MainActor
private final class RecordingPanelController: AIAssistantPanelControlling {
    var onAction: ((AIAssistantPanelAction) -> Void)?
    private(set) var shownSnapshots: [AIAssistantPanelSnapshot] = []
    private(set) var closedCount = 0
    private(set) var hiddenCount = 0

    var isVisible = false

    func show(snapshot: AIAssistantPanelSnapshot) {
        shownSnapshots.append(snapshot)
        isVisible = true
    }
    func update(snapshot: AIAssistantPanelSnapshot) {}
    func hide() {
        hiddenCount += 1
        isVisible = false
    }
    func close() {
        closedCount += 1
        isVisible = false
    }
}

@MainActor
private final class StubCapturePipeline: SelectedTextCaptureProviding {
    enum Outcome {
        case success(String)
        case missing
        /// Simulates the simulated-copy fallback: text exists but its
        /// pasteboard origin cannot be attributed, so it needs confirmation.
        case unverified(String)
    }

    var outcome: Outcome
    private(set) var captureCount = 0

    init(result: Outcome) {
        self.outcome = result
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        captureCount += 1
        switch outcome {
        case let .success(text):
            return SelectedTextCaptureResult(
                text: text,
                strategyID: .accessibility,
                isEditable: false,
                sourceApplicationBundleID: nil,
                failureReason: nil
            )
        case let .unverified(text):
            return SelectedTextCaptureResult(
                text: text,
                strategyID: .simulatedCopy,
                isEditable: false,
                sourceApplicationBundleID: nil,
                failureReason: nil,
                requiresUserConfirmation: true
            )
        case .missing:
            return SelectedTextCaptureResult(
                text: nil,
                strategyID: nil,
                isEditable: false,
                sourceApplicationBundleID: nil,
                failureReason: "未找到选中文本"
            )
        }
    }
}

private final class StubProcessingClient: AIProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var hangsUntilCancelled = false
    /// Artificial latency before the configured result is returned, used to
    /// observe panel state while a run is still in flight.
    var resultDelay: TimeInterval = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    let result: Result<AIProcessResult, Error>

    init(result: Result<AIProcessResult, Error>) {
        self.result = result
    }

    func complete(
        prompt: String,
        systemPrompt: String?,
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> AIProcessResult {
        lock.lock()
        _callCount += 1
        lock.unlock()

        if resultDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(resultDelay * 1_000_000_000))
        }
        if hangsUntilCancelled {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CancellationError()
        }
        return try result.get()
    }
}
