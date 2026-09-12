import AppKit
import Foundation
import MacToolsPluginKit

/// Abstraction over text capture so the coordinator can be tested with a fake.
@MainActor
protocol SelectedTextCaptureProviding {
    func capture(context: SelectedTextCaptureContext) async -> SelectedTextCaptureResult
}

/// Resolves a configured provider into a concrete completion handler.
struct ResolvedAIProvider: Sendable {
    var title: String
    var client: any AIProcessing
    var configuration: OpenAICompatibleConfiguration
    var apiKey: String
}

struct AIAssistantProviderError: Error, Equatable, Sendable {
    let message: String
}

typealias AIAssistantProviderFactory = () -> Result<ResolvedAIProvider, AIAssistantProviderError>

@MainActor
final class AIAssistantCoordinator {
    private let selectedTextCapturePipeline: any SelectedTextCaptureProviding
    private let providerFactory: AIAssistantProviderFactory
    private weak var panelController: AIAssistantPanelControlling?
    private let localization: PluginLocalization

    private var sessionID = UUID()
    private var activeTask: Task<Void, Never>?
    private var lastSourceText: String?
    private var lastPrompt: AIAssistantPrompt?

    private(set) var snapshot: AIAssistantPanelSnapshot = .idle {
        didSet {
            panelController?.update(snapshot: snapshot)
        }
    }

    init(
        selectedTextCapturePipeline: any SelectedTextCaptureProviding,
        providerFactory: @escaping AIAssistantProviderFactory,
        panelController: AIAssistantPanelControlling?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.selectedTextCapturePipeline = selectedTextCapturePipeline
        self.providerFactory = providerFactory
        self.panelController = panelController
        self.localization = localization
    }

    func startProcessing(prompt: AIAssistantPrompt) {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runProcessing(prompt: prompt)
        }
    }

    func handle(_ action: AIAssistantPanelAction) {
        switch action {
        case .retry:
            retry()
        case let .reprocess(sourceText):
            reprocess(with: sourceText)
        case .close:
            close()
        case .copyResult:
            copy(snapshot.result?.text)
        case .openSettings:
            break
        }
    }

    func close() {
        sessionID = UUID()
        activeTask?.cancel()
        activeTask = nil
        panelController?.close()
    }

    private func runProcessing(prompt: AIAssistantPrompt) async {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        lastSourceText = nil
        lastPrompt = prompt
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        panelController?.close()

        snapshot = AIAssistantPanelSnapshot(
            phase: .capturing,
            sourceText: nil,
            result: nil,
            errorMessage: nil
        )
        panelController?.show(snapshot: snapshot)

        let result = await selectedTextCapturePipeline.capture(
            context: SelectedTextCaptureContext(frontmostApplication: frontmostApplication)
        )

        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        guard let sourceText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceText.isEmpty
        else {
            if result.failureReason == AIAssistantPanelError.permissionRequired.message(localization: localization) {
                setError(.permissionRequired, sourceText: nil)
            } else {
                setError(.missingSelection, sourceText: nil)
            }
            panelController?.show(snapshot: snapshot)
            return
        }

        lastSourceText = sourceText
        await process(sourceText: sourceText, prompt: prompt, sessionID: currentSessionID)
    }

    private func process(
        sourceText: String,
        prompt: AIAssistantPrompt,
        sessionID currentSessionID: UUID
    ) async {
        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        let providerResult = providerFactory()
        let provider: ResolvedAIProvider
        switch providerResult {
        case let .success(resolved):
            provider = resolved
        case let .failure(error):
            snapshot = AIAssistantPanelSnapshot(
                phase: .error(.missingConfiguration),
                sourceText: sourceText,
                result: nil,
                errorMessage: error.message
            )
            panelController?.show(snapshot: snapshot)
            return
        }

        snapshot = AIAssistantPanelSnapshot(
            phase: .processing,
            sourceText: sourceText,
            result: nil,
            errorMessage: nil
        )
        panelController?.show(snapshot: snapshot)

        do {
            try Task.checkCancellation()
            let renderedPrompt = try PromptRenderer(template: prompt.template).render(text: sourceText)
            var configuration = provider.configuration
            configuration.temperature = prompt.temperature
            var result = try await provider.client.complete(
                prompt: renderedPrompt,
                systemPrompt: prompt.systemPrompt,
                configuration: configuration,
                apiKey: provider.apiKey
            )
            result.providerTitle = provider.title
            result.sourceText = sourceText
            result.promptName = prompt.normalizedName

            guard !Task.isCancelled, sessionID == currentSessionID else { return }

            snapshot = AIAssistantPanelSnapshot(
                phase: .success,
                sourceText: sourceText,
                result: result,
                errorMessage: nil
            )
            panelController?.show(snapshot: snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, sessionID == currentSessionID else { return }

            let message = Self.userFacingMessage(for: error, localization: localization)
            snapshot = AIAssistantPanelSnapshot(
                phase: .error(.requestFailed(message)),
                sourceText: sourceText,
                result: nil,
                errorMessage: message
            )
            panelController?.show(snapshot: snapshot)
        }
    }

    private func retry() {
        guard let sourceText = lastSourceText, let prompt = lastPrompt else {
            return
        }

        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            let currentSessionID = UUID()
            self.sessionID = currentSessionID
            await self.process(sourceText: sourceText, prompt: prompt, sessionID: currentSessionID)
        }
    }

    private func reprocess(with sourceText: String) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let prompt = lastPrompt else { return }

        lastSourceText = trimmed
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            guard let self else { return }
            let currentSessionID = UUID()
            self.sessionID = currentSessionID
            await self.process(sourceText: trimmed, prompt: prompt, sessionID: currentSessionID)
        }
    }

    private func setError(_ error: AIAssistantPanelError, sourceText: String?) {
        snapshot = AIAssistantPanelSnapshot(
            phase: .error(error),
            sourceText: sourceText,
            result: nil,
            errorMessage: error.message(localization: localization)
        )
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    nonisolated private static func userFacingMessage(
        for error: Error,
        localization: PluginLocalization
    ) -> String {
        AIAssistantUserFacingMessage.message(for: error, localization: localization)
    }
}
