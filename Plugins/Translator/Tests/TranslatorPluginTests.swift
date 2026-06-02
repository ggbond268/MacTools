import Carbon
import Foundation
import MacToolsPluginKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorPluginTests: XCTestCase {
    func testMetadataMatchesManifestContract() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "translator")
        XCTAssertEqual(plugin.metadata.title, "翻译")
        XCTAssertEqual(plugin.metadata.defaultDescription, "划词快捷键翻译")
        XCTAssertNotNil(plugin.primaryPanel)
        XCTAssertNotNil(plugin.configuration)
    }

    func testShortcutDefinitionUsesOptionD() throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.shortcutDefinitions.first)

        XCTAssertEqual(definition.id, "translator.select-translation")
        XCTAssertEqual(definition.title, "划词翻译")
        XCTAssertEqual(definition.description, "翻译当前选中的文本。")
        XCTAssertEqual(definition.actionID, "select-translation")
        XCTAssertEqual(definition.scope, .global)
        XCTAssertEqual(definition.defaultBinding?.keyCode, UInt16(kVK_ANSI_D))
        XCTAssertEqual(definition.defaultBinding?.modifiers, [.option])
        XCTAssertFalse(definition.isRequired)
    }

    func testDeclaresAccessibilityAndAutomationPermissions() {
        let plugin = makePlugin()
        let requirements = plugin.permissionRequirements

        XCTAssertEqual(requirements.map(\.id), ["accessibility", "automation"])
        XCTAssertEqual(requirements.map(\.kind), [.accessibility, .automation])
        XCTAssertEqual(requirements.map(\.title), ["辅助功能授权", "自动化授权"])
        XCTAssertEqual(
            requirements.map(\.description),
            [
                "划词翻译需要读取当前选中文本。",
                "浏览器划词可能需要允许 MacTools 控制当前浏览器。",
            ]
        )
    }

    func testAutomationPermissionStateUsesOnDemandGuidance() {
        let plugin = makePlugin()
        let state = plugin.permissionState(for: "automation")

        XCTAssertTrue(state.isGranted)
        XCTAssertEqual(state.footnote, "macOS 会在首次控制浏览器时请求自动化授权。")
        XCTAssertEqual(state.statusText, "按需确认")
        XCTAssertEqual(state.statusSystemImage, "sparkles")
        XCTAssertEqual(state.statusTone, .neutral)
    }

    func testAccessibilityPermissionStateUsesDeniedGuidance() {
        let plugin = makePlugin(accessibilityTrustProvider: { false })
        let state = plugin.permissionState(for: "accessibility")

        XCTAssertFalse(state.isGranted)
        XCTAssertEqual(state.footnote, "前往系统设置 → 隐私与安全性 → 辅助功能，授权 MacTools。")
    }

    func testAccessibilityPermissionActionRequestsTrustAndNotifies() {
        var requestedPrompt: Bool?
        let plugin = makePlugin(accessibilityTrustRequester: { prompt in
            requestedPrompt = prompt
            return true
        })
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handlePermissionAction(id: "accessibility")

        XCTAssertEqual(requestedPrompt, true)
        XCTAssertTrue(didNotify)
    }

    func testPrimaryPanelStartsEnabledWithSetupSubtitleWhenOpenAIIsMissing() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, accessibilityTrustProvider: { true })
        let state = plugin.primaryPanelState

        XCTAssertTrue(state.isVisible)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.subtitle, "需要配置 OpenAI")
    }

    func testPrimaryPanelSubtitleUsesResolvedShortcutBinding() throws {
        let secretStore = OpenAICompatibleSecretStore(service: uniqueTestKeychainService())
        try secretStore.saveAPIKey("sk-test")
        let plugin = makePlugin(secretStore: secretStore)
        plugin.shortcutBindingResolver = { shortcutID in
            guard shortcutID == "translator.select-translation" else { return nil }
            return ShortcutBinding(
                keyCode: UInt16(kVK_ANSI_T),
                modifiers: [.control, .option]
            )
        }

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "按 ⌃ + ⌥ + T 翻译选中文本")

        try secretStore.deleteAPIKey()
    }

    func testPrimaryPanelShowsAccessibilitySubtitleBeforeOpenAISetupWhenPermissionIsMissing() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, accessibilityTrustProvider: { false })

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "启用前需要辅助功能授权")
    }

    func testWhitespaceOnlyAPIKeyKeepsSetupSubtitle() throws {
        let secretStore = OpenAICompatibleSecretStore(service: uniqueTestKeychainService())
        try secretStore.saveAPIKey("   \n\t  ")

        let plugin = makePlugin(secretStore: secretStore)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "需要配置 OpenAI")

        try secretStore.deleteAPIKey()
    }

    func testPrimaryPanelTogglePersistsDisabledStateAndNotifies() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertTrue(didNotify)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "快捷键已暂停")
        XCTAssertEqual(storage.bool(forKey: "translator.shortcut.enabled"), false)

        let reloadedPlugin = makePlugin(storage: storage)
        XCTAssertFalse(reloadedPlugin.primaryPanelState.isOn)
        XCTAssertEqual(reloadedPlugin.primaryPanelState.subtitle, "快捷键已暂停")
    }

    func testShortcutActionStartsSelectTranslationWhenEnabled() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, selectTranslationStarter: {
            storage.set(true, forKey: "handler.invoked")
        })

        plugin.handleShortcutAction(id: "select-translation")

        XCTAssertTrue(storage.bool(forKey: "handler.invoked"))
    }

    func testShortcutActionDoesNotStartSelectTranslationWhenDisabled() {
        let storage = TranslatorInMemoryPluginStorage()
        storage.set(false, forKey: "translator.shortcut.enabled")
        let plugin = makePlugin(storage: storage, selectTranslationStarter: {
            storage.set(true, forKey: "handler.invoked")
        })

        plugin.handleShortcutAction(id: "select-translation")

        XCTAssertFalse(storage.bool(forKey: "handler.invoked"))
    }

    func testShortcutActionDoesNotStartSelectTranslationForWrongActionID() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, selectTranslationStarter: {
            storage.set(true, forKey: "handler.invoked")
        })

        plugin.handleShortcutAction(id: "unexpected")

        XCTAssertFalse(storage.bool(forKey: "handler.invoked"))
    }

    func testShortcutActionStillStartsCapturePipelineWhenAccessibilityIsDenied() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(
            storage: storage,
            accessibilityTrustProvider: { false },
            selectTranslationStarter: {
                storage.set(true, forKey: "handler.invoked")
            }
        )

        plugin.handleShortcutAction(id: "select-translation")

        XCTAssertTrue(storage.bool(forKey: "handler.invoked"))
    }

    func testAutomationPermissionActionRequestsGuidanceAndNotifies() {
        let plugin = makePlugin()
        var requestedPermissionID: String?
        plugin.requestPermissionGuidance = { requestedPermissionID = $0 }
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handlePermissionAction(id: "automation")

        XCTAssertEqual(requestedPermissionID, "automation")
        XCTAssertTrue(didNotify)
    }

    func testSavingConfigurationClosesExistingPanelBeforeDroppingCoordinator() {
        let panelController = RecordingTranslatorPanelController()
        let plugin = makePlugin(panelController: panelController)
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://gateway.example.com",
            model: "gpt-test",
            promptTemplate: "{{text}}"
        )

        let message = plugin.saveConfiguration(
            configuration,
            apiKey: "sk-test",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertNil(message)
        XCTAssertTrue(panelController.didClose)
    }

    func testSavingConfigurationDuringPendingCapturePreventsProviderInvocation() async {
        let capture = DeferredSelectedTextCapture(
            result: SelectedTextCaptureResult(
                text: "hello",
                strategyID: .accessibility,
                isEditable: false,
                sourceApplicationBundleID: "com.example.app",
                failureReason: nil
            )
        )
        let provider = RecordingTranslationProvider(resultText: "你好")
        let panelController = RecordingTranslatorPanelController()
        let plugin = makePlugin(
            panelController: panelController,
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: [capture]),
            translationProviderFactoryOverride: { .provider(provider) }
        )
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://gateway.example.com",
            model: "gpt-test",
            promptTemplate: "{{text}}"
        )

        plugin.handleShortcutAction(id: "select-translation")
        await capture.waitUntilStarted()

        let message = plugin.saveConfiguration(
            configuration,
            apiKey: "sk-test",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )
        capture.resume()
        await capture.waitUntilCompleted()

        XCTAssertNil(message)
        XCTAssertTrue(panelController.didClose)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testPanelCloseActionClosesPanelEvenWithoutCoordinator() {
        let panelController = RecordingTranslatorPanelController()
        let plugin = makePlugin(panelController: panelController)

        panelController.onAction?(.close)

        XCTAssertTrue(panelController.didClose)
        _ = plugin
    }

    func testPanelOpenSettingsActionRequestsPluginConfiguration() {
        let panelController = RecordingTranslatorPanelController()
        let plugin = makePlugin(panelController: panelController)
        var requestedSettingsPluginID: String?
        plugin.requestPluginConfigurationPresentation = { requestedSettingsPluginID = $0 }

        panelController.onAction?(.openSettings)

        XCTAssertEqual(requestedSettingsPluginID, "translator")
    }

    func testPanelCloseActionDuringPendingCapturePreventsProviderInvocation() async {
        let capture = DeferredSelectedTextCapture(
            result: SelectedTextCaptureResult(
                text: "hello",
                strategyID: .accessibility,
                isEditable: false,
                sourceApplicationBundleID: "com.example.app",
                failureReason: nil
            )
        )
        let provider = RecordingTranslationProvider(resultText: "你好")
        let panelController = RecordingTranslatorPanelController()
        let plugin = makePlugin(
            panelController: panelController,
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: [capture]),
            translationProviderFactoryOverride: { .provider(provider) }
        )

        plugin.handleShortcutAction(id: "select-translation")
        await capture.waitUntilStarted()

        panelController.onAction?(.close)
        capture.resume()
        await capture.waitUntilCompleted()

        XCTAssertTrue(panelController.didClose)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testSavingIdenticalLanguagePairDoesNotPersistProviderOrLanguageData() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://gateway.example.com",
            model: "gpt-test",
            promptTemplate: "{{text}}"
        )

        let message = plugin.saveConfiguration(
            configuration,
            apiKey: "sk-test",
            languagePair: TranslatorLanguagePair(first: .english, second: .english)
        )

        XCTAssertEqual(message, "两种偏好语言不能相同。")
        XCTAssertNil(storage.string(forKey: "translator.openai.base-url"))
        XCTAssertNil(storage.string(forKey: "translator.openai.model"))
        XCTAssertNil(storage.string(forKey: "translator.openai.prompt-template"))
        XCTAssertNil(storage.string(forKey: "translator.language.first"))
        XCTAssertNil(storage.string(forKey: "translator.language.second"))
    }

    private func makePlugin(
        storage: TranslatorInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true },
        accessibilityTrustRequester: @escaping (Bool) -> Bool = { _ in true },
        selectTranslationStarter: (() -> Void)? = nil,
        secretStore: OpenAICompatibleSecretStore? = nil,
        panelController: (any TranslatorPanelControlling)? = nil,
        selectedTextCapturePipeline: SelectedTextCapturePipeline? = nil,
        translationProviderFactoryOverride: TranslatorProviderFactory? = nil
    ) -> TranslatorPlugin {
        let storage = storage ?? TranslatorInMemoryPluginStorage()

        return TranslatorPlugin(
            context: PluginRuntimeContext(pluginID: "translator", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: accessibilityTrustRequester,
            selectTranslationStarter: selectTranslationStarter,
            secretStore: secretStore ?? OpenAICompatibleSecretStore(service: uniqueTestKeychainService()),
            panelController: panelController ?? TranslatorPanelController(),
            selectedTextCapturePipeline: selectedTextCapturePipeline ?? .live(),
            translationProviderFactoryOverride: translationProviderFactoryOverride
        )
    }

    private func uniqueTestKeychainService() -> String {
        "cc.ggbond.mactools.translator.tests.plugin.\(UUID().uuidString)"
    }
}

@MainActor
private final class RecordingTranslatorPanelController: TranslatorPanelControlling {
    var onAction: ((TranslatorPanelAction) -> Void)?
    private(set) var shownSnapshots: [TranslatorPanelSnapshot] = []
    private(set) var updatedSnapshots: [TranslatorPanelSnapshot] = []
    private(set) var didClose = false

    func show(snapshot: TranslatorPanelSnapshot) {
        shownSnapshots.append(snapshot)
    }

    func update(snapshot: TranslatorPanelSnapshot) {
        updatedSnapshots.append(snapshot)
    }

    func close() {
        didClose = true
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

private final class RecordingTranslationProvider: TranslationProviding, @unchecked Sendable {
    var resultText: String
    private(set) var requests: [String] = []

    init(resultText: String) {
        self.resultText = resultText
    }

    func translate(
        text: String,
        languageSelection: TranslatorLanguageSelection
    ) async throws -> TranslationResult {
        requests.append(text)
        return TranslationResult(
            providerTitle: "测试翻译",
            text: resultText,
            sourceText: text,
            languageSelection: languageSelection
        )
    }
}
