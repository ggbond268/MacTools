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
    private let clipboardTextProvider: () -> String?
    private weak var panelController: AIAssistantPanelControlling?
    private let localization: PluginLocalization

    private var sessionID = UUID()
    private var activeTask: Task<Void, Never>?
    private var lastSourceText: String?
    private var lastPrompt: AIAssistantPrompt?
    private var lastInputWasClipboard = false
    /// The latest terminal snapshot (success or error), used to restore the
    /// session view when the user stops an in-flight run.
    private var finishedSnapshot: AIAssistantPanelSnapshot?
    /// True after the user hid the panel for the current run. While set, run
    /// completions only refresh the retained snapshot and never reopen the
    /// panel; the user brings the session back via `reopenSession`.
    private var isPanelDismissedByUser = false

    private(set) var snapshot: AIAssistantPanelSnapshot = .idle {
        didSet {
            panelController?.update(snapshot: snapshot)
        }
    }

    init(
        selectedTextCapturePipeline: any SelectedTextCaptureProviding,
        providerFactory: @escaping AIAssistantProviderFactory,
        panelController: AIAssistantPanelControlling?,
        clipboardTextProvider: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.selectedTextCapturePipeline = selectedTextCapturePipeline
        self.providerFactory = providerFactory
        self.clipboardTextProvider = clipboardTextProvider
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
        isPanelDismissedByUser = false
        panelController?.show(snapshot: snapshot)
    }

    // MARK: - Actions

    func startProcessing(prompt: AIAssistantPrompt) {
        lastInputWasClipboard = false
        retainResultForRerun()
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runProcessing(prompt: prompt)
        }
    }

    /// Processes the clipboard only when the user explicitly selected the
    /// clipboard shortcut mode in settings. This path does not simulate copy.
    func startProcessingClipboard(prompt: AIAssistantPrompt) {
        lastInputWasClipboard = true
        retainResultForRerun()
        activeTask?.cancel()
        activeTask = nil
        let currentSessionID = UUID()
        sessionID = currentSessionID
        lastPrompt = prompt
        let sourceText = clipboardTextProvider()?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastSourceText = sourceText

        guard let sourceText, !sourceText.isEmpty else {
            setError(.missingClipboardText, sourceText: nil)
            present(snapshot)
            return
        }

        activeTask = Task { [weak self] in
            await self?.process(sourceText: sourceText, prompt: prompt, sessionID: currentSessionID)
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
    /// Completion updates stay hidden until the user reopens the session.
    func hide() {
        isPanelDismissedByUser = true
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
        isPanelDismissedByUser = false
        panelController?.show(snapshot: snapshot)
    }

    /// Cancels the task and discards the session, closing the panel.
    func discard() {
        sessionID = UUID()
        activeTask?.cancel()
        activeTask = nil
        lastSourceText = nil
        lastPrompt = nil
        lastInputWasClipboard = false
        finishedSnapshot = nil
        isPanelDismissedByUser = false
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
            present(snapshot)
            return
        }

        // 元数据日志：策略与字符长度，杜绝记录用户实际捕获文本
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
            present(AIAssistantPanelSnapshot(
                phase: .error(.missingConfiguration),
                sourceText: sourceText,
                result: nil,
                errorMessage: error.message,
                retainedResult: retained
            ))
            return
        }

        present(AIAssistantPanelSnapshot(
            phase: .processing,
            sourceText: sourceText,
            result: nil,
            errorMessage: nil,
            retainedResult: retained
        ))

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

            finish(AIAssistantPanelSnapshot(
                phase: .success,
                sourceText: sourceText,
                result: result,
                errorMessage: nil,
                retainedResult: nil
            ))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, sessionID == currentSessionID else { return }

            let message = Self.userFacingMessage(for: error, localization: localization)
            finish(AIAssistantPanelSnapshot(
                phase: .error(.requestFailed(message)),
                sourceText: sourceText,
                result: nil,
                errorMessage: message,
                retainedResult: retained
            ))
        }
    }

    /// Presents a brand-new run state (fresh capture, failure, or
    /// configuration problem). This always shows the panel and clears any
    /// stale dismissal marker from a previous run.
    private func present(_ newSnapshot: AIAssistantPanelSnapshot) {
        isPanelDismissedByUser = false
        snapshot = newSnapshot
        panelController?.show(snapshot: snapshot)
    }

    /// Applies a run completion (success or failure). When the user hid the
    /// panel for this run the snapshot is retained but the panel is not
    /// reopened; `reopenSession` shows it on request.
    private func finish(_ newSnapshot: AIAssistantPanelSnapshot) {
        snapshot = newSnapshot
        finishedSnapshot = newSnapshot
        if !isPanelDismissedByUser {
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
            if lastInputWasClipboard {
                startProcessingClipboard(prompt: prompt)
            } else {
                // The previous run failed before any text was captured.
                startProcessing(prompt: prompt)
            }
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
