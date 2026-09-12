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

    func show(snapshot: AIAssistantPanelSnapshot) {}
    func update(snapshot: AIAssistantPanelSnapshot) {}
    func close() {}
}

@MainActor
private final class StubCapturePipeline: SelectedTextCaptureProviding {
    enum Outcome {
        case success(String)
        case missing
    }

    private let outcome: Outcome

    init(result: Outcome) {
        self.outcome = result
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        switch outcome {
        case let .success(text):
            return SelectedTextCaptureResult(
                text: text,
                strategyID: .accessibility,
                isEditable: false,
                sourceApplicationBundleID: nil,
                failureReason: nil
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

private struct StubProcessingClient: AIProcessing {
    let result: Result<AIProcessResult, Error>

    func complete(
        prompt: String,
        systemPrompt: String?,
        configuration: OpenAICompatibleConfiguration,
        apiKey: String
    ) async throws -> AIProcessResult {
        try result.get()
    }
}
