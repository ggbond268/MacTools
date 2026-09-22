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
    /// The latest terminal snapshot (success or error), used to restore the
    /// session view when the user stops an in-flight run.
    private var finishedSnapshot: AIAssistantPanelSnapshot?

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

    // MARK: - Session state

    /// Whether a session for this prompt still holds recoverable state (a
    /// running task or a finished snapshot). Used to reopen instead of
    /// recapturing.
    func hasSession(forPromptID promptID: String) -> Bool {
        guard lastPrompt?.id == promptID else { return false }
        return activeTask != nil || finishedSnapshot != nil || snapshot.phase != .idle
    }

    var isPanelVisible: Bool {
        panelController?.isVisible ?? false
    }

    /// Shows the retained session again without recapturing text or issuing a
    /// new provider request.
    func reopenSession() {
        panelController?.show(snapshot: snapshot)
    }

    // MARK: - Actions

    func startProcessing(prompt: AIAssistantPrompt) {
        retainResultForRerun()
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
        case .stop:
            stop()
        case .hide:
            hide()
        case .discard:
            discard()
        case .close:
            close()
        case .copyResult:
            copy(snapshot.result?.text ?? snapshot.retainedResult?.text)
        case .openSettings:
            break
        }
    }

    /// Hides the panel but keeps the session and any running task alive.
    func hide() {
        panelController?.hide()
    }

    /// Cancels the in-flight task and restores the last finished view without
    /// discarding the session.
    func stop() {
        activeTask?.cancel()
        activeTask = nil
        if let finishedSnapshot {
            snapshot = finishedSnapshot
        } else {
            sessionID = UUID()
            snapshot = .idle
        }
        panelController?.show(snapshot: snapshot)
    }

    /// Cancels the task and discards the session, closing the panel.
    func discard() {
        sessionID = UUID()
        activeTask?.cancel()
        activeTask = nil
        lastSourceText = nil
        lastPrompt = nil
        finishedSnapshot = nil
        snapshot = .idle
        panelController?.close()
    }

    /// Fully closes the panel and resets the session. Kept for teardown paths
    /// (deactivation, saving configuration).
    func close() {
        discard()
    }

    // MARK: - Processing

    private func runProcessing(prompt: AIAssistantPrompt) async {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        lastSourceText = nil
        lastPrompt = prompt
        let runningApp = NSWorkspace.shared.frontmostApplication
        let frontmostApplication: NSRunningApplication?
        if runningApp == .current {
            frontmostApplication = NSWorkspace.shared.runningApplications.first(where: {
                $0.isActive && $0 != .current && $0.activationPolicy == .regular
            })
        } else {
            frontmostApplication = runningApp
        }
        panelController?.close()

        // Metadata only: never log the prompt name or captured user text.
        AIAssistantLog.capture.notice("Starting capture, targetApp: \(frontmostApplication?.localizedName ?? "nil", privacy: .public) (pid: \(frontmostApplication?.processIdentifier ?? -1, privacy: .public))")

        // 先在目标应用完整持有焦点状态下取词，避免提前弹窗抢占焦点导致划词与模拟复制失败
        let result = await selectedTextCapturePipeline.capture(
            context: SelectedTextCaptureContext(frontmostApplication: frontmostApplication)
        )

        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        guard let sourceText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceText.isEmpty
        else {
            AIAssistantLog.capture.error("Capture failed, reason: \(result.failureReason ?? "missingSelection", privacy: .public)")
            if result.failureReason == AIAssistantPanelError.permissionRequired.message(localization: localization) {
                setError(.permissionRequired, sourceText: nil)
            } else {
                setError(.missingSelection, sourceText: nil)
            }
            panelController?.show(snapshot: snapshot)
            return
        }

        // Metadata only: strategy and length, never the captured text itself.
        AIAssistantLog.capture.notice("Capture succeeded via \(result.strategyID?.rawValue ?? "unknown", privacy: .public), \(sourceText.count, privacy: .public) chars")

        lastSourceText = sourceText
        await process(sourceText: sourceText, prompt: prompt, sessionID: currentSessionID)
    }

    private func process(
        sourceText: String,
        prompt: AIAssistantPrompt,
        sessionID currentSessionID: UUID
    ) async {
        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        let retained = snapshot.result ?? snapshot.retainedResult

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
                errorMessage: error.message,
                retainedResult: retained
            )
            finishedSnapshot = snapshot
            panelController?.show(snapshot: snapshot)
            return
        }

        snapshot = AIAssistantPanelSnapshot(
            phase: .processing,
            sourceText: sourceText,
            result: nil,
            errorMessage: nil,
            retainedResult: retained
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
                errorMessage: nil,
                retainedResult: nil
            )
            finishedSnapshot = snapshot
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
                errorMessage: message,
                retainedResult: retained
            )
            finishedSnapshot = snapshot
            panelController?.show(snapshot: snapshot)
        }
    }

    private func retry() {
        guard let prompt = lastPrompt else { return }

        if let sourceText = lastSourceText {
            activeTask?.cancel()
            activeTask = Task { [weak self] in
                guard let self else { return }
                let currentSessionID = UUID()
                self.sessionID = currentSessionID
                await self.process(sourceText: sourceText, prompt: prompt, sessionID: currentSessionID)
            }
        } else {
            // The previous run failed before any text was captured; retry
            // attempts capture again for the same prompt.
            startProcessing(prompt: prompt)
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

    /// Keeps the most recent successful result visible across a rerun so
    /// editing the source or a failed request never blanks the output.
    private func retainResultForRerun() {
        if let current = snapshot.result ?? snapshot.retainedResult, snapshot.phase == .success {
            snapshot.retainedResult = current
        }
    }

    private func setError(_ error: AIAssistantPanelError, sourceText: String?) {
        snapshot = AIAssistantPanelSnapshot(
            phase: .error(error),
            sourceText: sourceText,
            result: nil,
            errorMessage: error.message(localization: localization),
            retainedResult: snapshot.retainedResult
        )
        finishedSnapshot = snapshot
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
