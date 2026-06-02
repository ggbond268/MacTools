import AppKit
import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorCoordinatorTests: XCTestCase {
    private var originalPasteboardSnapshot: PasteboardSnapshot?

    override func setUp() async throws {
        try await super.setUp()
        originalPasteboardSnapshot = PasteboardSnapshot.capture(from: NSPasteboard.general)
        NSPasteboard.general.clearContents()
    }

    override func tearDown() async throws {
        NSPasteboard.general.clearContents()
        if let originalPasteboardSnapshot {
            _ = originalPasteboardSnapshot.restore(to: NSPasteboard.general)
        }
        try await super.tearDown()
    }

    func testMissingSelectionShowsMissingSelectionError() async {
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: .missing,
            providerFactory: { .provider(RecordingTranslationProvider(resultText: "unused")) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.error(.missingSelection))

        XCTAssertEqual(coordinator.snapshot.phase, .error(.missingSelection))
        XCTAssertEqual(coordinator.snapshot.errorMessage, "未找到选中文本")
        XCTAssertNil(coordinator.snapshot.sourceText)
        XCTAssertTrue(panel.updatedSnapshots.contains { $0.phase == .capturing })
        XCTAssertTrue(panel.updatedSnapshots.contains { $0.phase == .error(.missingSelection) })
    }

    func testAccessibilityFailureShowsPermissionRequiredError() async {
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captures: [
                RecordingSelectedTextCapture(
                    strategyID: .accessibility,
                    result: SelectedTextCaptureResult(
                        text: nil,
                        strategyID: .accessibility,
                        isEditable: false,
                        sourceApplicationBundleID: "com.example.secure",
                        failureReason: "需要辅助功能授权"
                    )
                ),
                RecordingSelectedTextCapture(
                    strategyID: .menuCopy,
                    result: SelectedTextCaptureResult(
                        text: nil,
                        strategyID: .menuCopy,
                        isEditable: false,
                        sourceApplicationBundleID: nil,
                        failureReason: "复制失败"
                    )
                ),
            ],
            providerFactory: { .provider(RecordingTranslationProvider(resultText: "unused")) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.error(.permissionRequired))

        XCTAssertEqual(coordinator.snapshot.phase, .error(.permissionRequired))
        XCTAssertEqual(coordinator.snapshot.errorMessage, "需要辅助功能授权")
        XCTAssertNil(coordinator.snapshot.sourceText)
        XCTAssertNil(coordinator.snapshot.languageSelection)
        XCTAssertNil(coordinator.snapshot.translation)
    }

    func testAutomationFailureShowsAutomationPermissionRequiredError() async {
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: SelectedTextCaptureResult(
                text: nil,
                strategyID: .browserAppleScript,
                isEditable: false,
                sourceApplicationBundleID: "com.apple.Safari",
                failureReason: "需要自动化授权"
            ),
            providerFactory: { .provider(RecordingTranslationProvider(resultText: "unused")) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.error(.automationPermissionRequired))

        XCTAssertEqual(coordinator.snapshot.phase, .error(.automationPermissionRequired))
        XCTAssertEqual(coordinator.snapshot.errorMessage, "需要自动化授权")
        XCTAssertNil(coordinator.snapshot.sourceText)
        XCTAssertNil(coordinator.snapshot.languageSelection)
        XCTAssertNil(coordinator.snapshot.translation)
    }

    func testMissingConfigurationPreservesCapturedSourceText() async {
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: selectedText("hello"),
            providerFactory: { .missing(message: "请配置 API Key") },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.error(.missingConfiguration))

        XCTAssertEqual(coordinator.snapshot.phase, .error(.missingConfiguration))
        XCTAssertEqual(coordinator.snapshot.sourceText, "hello")
        XCTAssertEqual(coordinator.snapshot.errorMessage, "请配置 API Key")
        XCTAssertNil(coordinator.snapshot.translation)
    }

    func testSuccessfulTranslationUpdatesSuccessAndTranslationText() async throws {
        let provider = RecordingTranslationProvider(resultText: "你好")
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: selectedText("hello"),
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.success)

        XCTAssertEqual(coordinator.snapshot.phase, .success)
        XCTAssertEqual(coordinator.snapshot.sourceText, "hello")
        XCTAssertEqual(coordinator.snapshot.translation?.text, "你好")
        XCTAssertEqual(provider.requests.map(\.text), ["hello"])
        XCTAssertTrue(panel.updatedSnapshots.contains { $0.phase == .capturing })
        XCTAssertTrue(panel.updatedSnapshots.contains { $0.phase == .translating })
        XCTAssertTrue(panel.updatedSnapshots.contains { $0.phase == .success })
    }

    func testTranslationFailurePreservesSourceAndLanguageSelection() async throws {
        let provider = RecordingTranslationProvider(error: TestTranslationError(message: "网络失败"))
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: selectedText("hello"),
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.error(.requestFailed("网络失败")))

        XCTAssertEqual(coordinator.snapshot.phase, .error(.requestFailed("网络失败")))
        XCTAssertEqual(coordinator.snapshot.sourceText, "hello")
        XCTAssertEqual(coordinator.snapshot.errorMessage, "网络失败")
        XCTAssertEqual(coordinator.snapshot.languageSelection?.source, .english)
        XCTAssertEqual(coordinator.snapshot.languageSelection?.target, .simplifiedChinese)
    }

    func testRetryWithLastSourceRetranslatesWithoutRecapturing() async {
        let capture = RecordingSelectedTextCapture(result: selectedText("hello"))
        let provider = RecordingTranslationProvider(resultText: "你好")
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            capture: capture,
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.success)
        provider.resultText = "您好"

        await coordinator.handle(.retry)
        await panel.waitUntilShown(.success, count: 2)

        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertEqual(provider.requests.map(\.text), ["hello", "hello"])
        XCTAssertEqual(coordinator.snapshot.translation?.text, "您好")
    }

    func testRetryWithoutLastSourceStartsCapture() async {
        let capture = RecordingSelectedTextCapture(result: selectedText("fresh"))
        let provider = RecordingTranslationProvider(resultText: "新文本")
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            capture: capture,
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        await coordinator.handle(.retry)
        await panel.waitUntilShown(.success)

        XCTAssertEqual(capture.captureCount, 1)
        XCTAssertEqual(provider.requests.map(\.text), ["fresh"])
        XCTAssertEqual(coordinator.snapshot.translation?.text, "新文本")
    }

    func testRetryAfterFreshMissingSelectionDoesNotRetranslatePreviousSource() async {
        let capture = RecordingSelectedTextCapture(result: selectedText("first"))
        let provider = RecordingTranslationProvider(resultText: "第一段")
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            capture: capture,
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.success)
        capture.result = .missing
        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.error(.missingSelection))
        await coordinator.handle(.retry)
        await panel.waitUntilShown(.error(.missingSelection), count: 2)

        XCTAssertEqual(capture.captureCount, 3)
        XCTAssertEqual(provider.requests.map(\.text), ["first"])
        XCTAssertEqual(coordinator.snapshot.phase, .error(.missingSelection))
    }

    func testCloseInvalidatesSessionAndClosesPanel() async {
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: selectedText("hello"),
            providerFactory: { .provider(RecordingTranslationProvider(resultText: "你好")) },
            panelController: panel
        )

        await coordinator.handle(.close)

        XCTAssertTrue(panel.didClose)
    }

    func testCloseDuringPendingCapturePreventsProviderInvocation() async {
        let capture = DeferredSelectedTextCapture(result: selectedText("hello"))
        let provider = RecordingTranslationProvider(resultText: "你好")
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captures: [capture],
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.capturing)
        await capture.waitUntilStarted()

        await coordinator.handle(.close)
        capture.resume()
        await capture.waitUntilCompleted()

        XCTAssertTrue(panel.didClose)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(panel.shownSnapshots.contains { $0.phase == .capturing })
    }

    func testCloseDuringPendingTranslationCancelsProviderTask() async {
        let provider = DeferredTranslationProvider()
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: selectedText("hello"),
            providerFactory: { .provider(provider) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await provider.waitUntilStarted()

        await coordinator.handle(.close)
        await provider.waitUntilCancelled()

        XCTAssertTrue(panel.didClose)
    }

    func testCopySourceAndTranslationWriteToGeneralPasteboard() async {
        let panel = RecordingTranslatorPanelController()
        let coordinator = makeCoordinator(
            captureResult: selectedText("hello"),
            providerFactory: { .provider(RecordingTranslationProvider(resultText: "你好")) },
            panelController: panel
        )

        coordinator.startSelectTranslation()
        await panel.waitUntilShown(.success)
        await coordinator.handle(.copySource)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")

        await coordinator.handle(.copyTranslation)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "你好")
    }

    private func makeCoordinator(
        captureResult: SelectedTextCaptureResult,
        providerFactory: @escaping TranslatorProviderFactory,
        panelController: TranslatorPanelControlling? = nil
    ) -> TranslatorCoordinator {
        makeCoordinator(
            capture: RecordingSelectedTextCapture(result: captureResult),
            providerFactory: providerFactory,
            panelController: panelController
        )
    }

    private func makeCoordinator(
        capture: RecordingSelectedTextCapture,
        providerFactory: @escaping TranslatorProviderFactory,
        panelController: TranslatorPanelControlling? = nil
    ) -> TranslatorCoordinator {
        makeCoordinator(
            captures: [capture],
            providerFactory: providerFactory,
            panelController: panelController
        )
    }

    private func makeCoordinator(
        captures: [any SelectedTextCapturing],
        providerFactory: @escaping TranslatorProviderFactory,
        panelController: TranslatorPanelControlling? = nil
    ) -> TranslatorCoordinator {
        let storage = TranslatorInMemoryPluginStorage()
        let languagePreferenceStore = LanguagePreferenceStore(storage: storage)
        languagePreferenceStore.savePair(
            TranslatorLanguagePair(first: .simplifiedChinese, second: .english)
        )

        return TranslatorCoordinator(
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: captures),
            languagePreferenceStore: languagePreferenceStore,
            providerFactory: providerFactory,
            panelController: panelController
        )
    }

    private func selectedText(_ text: String) -> SelectedTextCaptureResult {
        SelectedTextCaptureResult(
            text: text,
            strategyID: .accessibility,
            isEditable: false,
            sourceApplicationBundleID: "com.example.app",
            failureReason: nil
        )
    }
}

@MainActor
private final class RecordingTranslatorPanelController: TranslatorPanelControlling {
    var onAction: ((TranslatorPanelAction) -> Void)?
    private(set) var shownSnapshots: [TranslatorPanelSnapshot] = []
    private(set) var updatedSnapshots: [TranslatorPanelSnapshot] = []
    private(set) var didClose = false
    private var shownPhaseWaiters: [(TranslatorPanelPhase, Int, CheckedContinuation<Void, Never>)] = []
    private var updatedPhaseWaiters: [(TranslatorPanelPhase, Int, CheckedContinuation<Void, Never>)] = []

    func show(snapshot: TranslatorPanelSnapshot) {
        shownSnapshots.append(snapshot)
        resumeShownWaiters(matching: snapshot.phase)
    }

    func update(snapshot: TranslatorPanelSnapshot) {
        updatedSnapshots.append(snapshot)
        resumeUpdatedWaiters(matching: snapshot.phase)
    }

    func close() {
        didClose = true
    }

    func waitUntilShown(_ phase: TranslatorPanelPhase, count: Int = 1) async {
        if shownSnapshots.filter({ $0.phase == phase }).count >= count { return }

        await withCheckedContinuation { continuation in
            shownPhaseWaiters.append((phase, count, continuation))
        }
    }

    func waitUntilUpdated(_ phase: TranslatorPanelPhase, count: Int = 1) async {
        if updatedSnapshots.filter({ $0.phase == phase }).count >= count { return }

        await withCheckedContinuation { continuation in
            updatedPhaseWaiters.append((phase, count, continuation))
        }
    }

    private func resumeShownWaiters(matching phase: TranslatorPanelPhase) {
        let currentCount = shownSnapshots.filter { $0.phase == phase }.count
        let matching = shownPhaseWaiters.filter { $0.0 == phase && currentCount >= $0.1 }
        shownPhaseWaiters.removeAll { $0.0 == phase && currentCount >= $0.1 }
        matching.forEach { $0.2.resume() }
    }

    private func resumeUpdatedWaiters(matching phase: TranslatorPanelPhase) {
        let currentCount = updatedSnapshots.filter { $0.phase == phase }.count
        let matching = updatedPhaseWaiters.filter { $0.0 == phase && currentCount >= $0.1 }
        updatedPhaseWaiters.removeAll { $0.0 == phase && currentCount >= $0.1 }
        matching.forEach { $0.2.resume() }
    }
}

@MainActor
private final class RecordingSelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID
    var result: SelectedTextCaptureResult
    private(set) var captureCount = 0

    init(
        strategyID: SelectedTextCaptureStrategyID = .accessibility,
        result: SelectedTextCaptureResult
    ) {
        self.strategyID = strategyID
        self.result = result
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        captureCount += 1
        return result
    }
}

@MainActor
private final class DeferredSelectedTextCapture: SelectedTextCapturing {
    let strategyID: SelectedTextCaptureStrategyID
    let result: SelectedTextCaptureResult
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var completedContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<SelectedTextCaptureResult, Never>?
    private var didStart = false
    private var didComplete = false

    init(
        strategyID: SelectedTextCaptureStrategyID = .accessibility,
        result: SelectedTextCaptureResult
    ) {
        self.strategyID = strategyID
        self.result = result
    }

    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil

        let result = await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
        didComplete = true
        completedContinuation?.resume()
        completedContinuation = nil
        return result
    }

    func waitUntilStarted() async {
        if didStart { return }

        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func resume() {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }

    func waitUntilCompleted() async {
        if didComplete { return }

        await withCheckedContinuation { continuation in
            completedContinuation = continuation
        }
    }
}

private struct TranslationRequest: Equatable {
    var text: String
    var languageSelection: TranslatorLanguageSelection
}

private final class RecordingTranslationProvider: TranslationProviding, @unchecked Sendable {
    var resultText: String
    var error: Error?
    private(set) var requests: [TranslationRequest] = []

    init(resultText: String = "", error: Error? = nil) {
        self.resultText = resultText
        self.error = error
    }

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult {
        requests.append(TranslationRequest(text: text, languageSelection: languageSelection))

        if let error {
            throw error
        }

        return TranslationResult(
            providerTitle: "测试翻译",
            text: resultText,
            sourceText: text,
            languageSelection: languageSelection
        )
    }
}

@MainActor
private final class DeferredTranslationProvider: TranslationProviding, @unchecked Sendable {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var cancelledContinuation: CheckedContinuation<Void, Never>?
    private var translationContinuation: CheckedContinuation<TranslationResult, Error>?
    private var didStart = false
    private var didCancel = false

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult {
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                translationContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                didCancel = true
                translationContinuation?.resume(throwing: CancellationError())
                translationContinuation = nil
                cancelledContinuation?.resume()
                cancelledContinuation = nil
            }
        }
    }

    func waitUntilStarted() async {
        if didStart { return }

        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func waitUntilCancelled() async {
        if didCancel { return }

        await withCheckedContinuation { continuation in
            cancelledContinuation = continuation
        }
    }
}

private struct TestTranslationError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
