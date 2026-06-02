import AppKit
import AVFoundation
import Foundation

@MainActor
protocol TranslatorPanelControlling: AnyObject {
    var onAction: ((TranslatorPanelAction) -> Void)? { get set }

    func show(snapshot: TranslatorPanelSnapshot)
    func update(snapshot: TranslatorPanelSnapshot)
    func close()
}

protocol TranslationProviding: Sendable {
    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult
}

typealias TranslatorProviderFactory = @MainActor () -> TranslatorProviderBuildResult

struct OpenAITranslationProviderAdapter: TranslationProviding {
    let client: OpenAICompatibleClient
    let configuration: OpenAICompatibleConfiguration
    let apiKey: String

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult {
        try await client.translate(
            text: text,
            languageSelection: languageSelection,
            configuration: configuration,
            apiKey: apiKey
        )
    }
}

@MainActor
final class TranslatorCoordinator {
    private let selectedTextCapturePipeline: SelectedTextCapturePipeline
    private let languagePreferenceStore: LanguagePreferenceStore
    private let providerFactory: TranslatorProviderFactory
    private weak var panelController: TranslatorPanelControlling?
    private let speechSynthesizer = AVSpeechSynthesizer()

    private var sessionID = UUID()
    private var activeTask: Task<Void, Never>?
    private var lastSourceText: String?

    private(set) var snapshot: TranslatorPanelSnapshot = .idle {
        didSet {
            panelController?.update(snapshot: snapshot)
        }
    }

    init(
        selectedTextCapturePipeline: SelectedTextCapturePipeline,
        languagePreferenceStore: LanguagePreferenceStore,
        providerFactory: @escaping TranslatorProviderFactory,
        panelController: TranslatorPanelControlling?
    ) {
        self.selectedTextCapturePipeline = selectedTextCapturePipeline
        self.languagePreferenceStore = languagePreferenceStore
        self.providerFactory = providerFactory
        self.panelController = panelController
    }

    func startSelectTranslation() {
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runSelectTranslation()
        }
    }

    private func runSelectTranslation() async {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        lastSourceText = nil
        snapshot = TranslatorPanelSnapshot(
            phase: .capturing,
            sourceText: nil,
            languageSelection: nil,
            translation: nil,
            errorMessage: nil
        )
        panelController?.show(snapshot: snapshot)

        let result = await selectedTextCapturePipeline.capture(
            context: SelectedTextCaptureContext(
                frontmostApplication: NSWorkspace.shared.frontmostApplication
            )
        )

        guard !Task.isCancelled, sessionID == currentSessionID else { return }

        guard let sourceText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceText.isEmpty
        else {
            if result.failureReason == TranslatorPanelError.permissionRequired.message {
                setError(.permissionRequired, sourceText: nil, languageSelection: nil)
                panelController?.show(snapshot: snapshot)
                return
            }

            if result.failureReason == TranslatorPanelError.automationPermissionRequired.message {
                setError(.automationPermissionRequired, sourceText: nil, languageSelection: nil)
                panelController?.show(snapshot: snapshot)
                return
            }

            setError(.missingSelection, sourceText: nil, languageSelection: nil)
            panelController?.show(snapshot: snapshot)
            return
        }

        lastSourceText = sourceText

        switch providerFactory() {
        case let .provider(provider):
            await translate(sourceText: sourceText, provider: provider, sessionID: currentSessionID)
        case let .missing(message):
            snapshot = TranslatorPanelSnapshot(
                phase: .error(.missingConfiguration),
                sourceText: sourceText,
                languageSelection: nil,
                translation: nil,
                errorMessage: message
            )
            panelController?.show(snapshot: snapshot)
        }
    }

    func handle(_ action: TranslatorPanelAction) async {
        switch action {
        case .retry:
            retry()
        case .close:
            close()
        case .copySource:
            copy(snapshot.sourceText)
        case .copyTranslation:
            copy(snapshot.translation?.text)
        case .speakSource:
            speak(snapshot.sourceText)
        case .speakTranslation:
            speak(snapshot.translation?.text)
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

    private func retry() {
        guard let sourceText = lastSourceText else {
            startSelectTranslation()
            return
        }

        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.runRetry(sourceText: sourceText)
        }
    }

    private func runRetry(sourceText: String) async {
        let currentSessionID = UUID()
        sessionID = currentSessionID

        switch providerFactory() {
        case let .provider(provider):
            await translate(sourceText: sourceText, provider: provider, sessionID: currentSessionID)
        case let .missing(message):
            snapshot = TranslatorPanelSnapshot(
                phase: .error(.missingConfiguration),
                sourceText: sourceText,
                languageSelection: snapshot.languageSelection,
                translation: nil,
                errorMessage: message
            )
        }
    }

    private func translate(
        sourceText: String,
        provider: any TranslationProviding,
        sessionID currentSessionID: UUID
    ) async {
        let languageSelection = AutomaticLanguageSelector(
            preferredPair: languagePreferenceStore.loadPair()
        ).select(text: sourceText)

        snapshot = TranslatorPanelSnapshot(
            phase: .translating,
            sourceText: sourceText,
            languageSelection: languageSelection,
            translation: nil,
            errorMessage: nil
        )
        panelController?.show(snapshot: snapshot)

        do {
            try Task.checkCancellation()
            let translation = try await provider.translate(
                text: sourceText,
                languageSelection: languageSelection
            )

            guard !Task.isCancelled, sessionID == currentSessionID else { return }

            snapshot = TranslatorPanelSnapshot(
                phase: .success,
                sourceText: sourceText,
                languageSelection: languageSelection,
                translation: translation,
                errorMessage: nil
            )
        } catch {
            guard !Task.isCancelled, sessionID == currentSessionID else { return }

            setError(
                .requestFailed(error.localizedDescription),
                sourceText: sourceText,
                languageSelection: languageSelection
            )
        }
    }

    private func setError(
        _ error: TranslatorPanelError,
        sourceText: String?,
        languageSelection: TranslatorLanguageSelection?
    ) {
        snapshot = TranslatorPanelSnapshot(
            phase: .error(error),
            sourceText: sourceText,
            languageSelection: languageSelection,
            translation: nil,
            errorMessage: error.message
        )
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func speak(_ text: String?) {
        guard let text, !text.isEmpty else { return }

        speechSynthesizer.speak(AVSpeechUtterance(string: text))
    }
}
