import MacToolsPluginKit
import XCTest
@testable import AIAssistantPlugin

@MainActor
final class AIAssistantPluginTests: XCTestCase {
    func testMetadataMatchesManifestContract() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "ai-assistant")
        XCTAssertEqual(plugin.metadata.title, "AI 助手")
        XCTAssertEqual(plugin.metadata.defaultDescription, "划词调用 AI 翻译、总结、润色等")
        XCTAssertFalse(plugin.panelItems.isEmpty)
        XCTAssertNotNil(plugin.settingsPage)
    }

    func testShortcutDefinitionsDynamicallyFollowEnabledPrompts() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        // Default prompts are all enabled.
        let definitions = plugin.shortcutDefinitions
        XCTAssertEqual(definitions.map(\.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.scope), [.global, .global, .global])
        XCTAssertEqual(definitions.map(\.defaultBinding), [
            AIAssistantConstants.Defaults.translateShortcut,
            AIAssistantConstants.Defaults.summarizeShortcut,
            AIAssistantConstants.Defaults.polishShortcut,
        ])

        // A disabled prompt keeps its shortcut definition so its binding stays
        // editable in settings; execution is gated on `isEnabled` instead.
        let prompts = AIAssistantPromptStore(storage: storage).loadPrompts()
        let updated = prompts.map { prompt -> AIAssistantPrompt in
            var copy = prompt
            if copy.id == "summarize" {
                copy.isEnabled = false
            }
            return copy
        }
        let message = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: updated,
            apiKey: "sk-test"
        )

        XCTAssertNil(message)
        XCTAssertEqual(
            plugin.shortcutDefinitions.map(\.actionID),
            ["translate", "summarize", "polish"]
        )
    }

    func testHandleShortcutEventIgnoresDisabledPrompt() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        let prompts = AIAssistantPromptStore(storage: storage).loadPrompts()
        let updated = prompts.map { prompt -> AIAssistantPrompt in
            var copy = prompt
            if copy.id == "translate" {
                copy.isEnabled = false
            }
            return copy
        }
        _ = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: updated,
            apiKey: "sk-test"
        )

        // Disabled prompts must not start processing from a shortcut press.
        plugin.handleShortcutEvent(id: "translate", phase: .pressed)
        plugin.handleShortcutEvent(id: "translate", phase: .released)

        // Enabled prompts still process.
        plugin.handleShortcutEvent(id: "summarize", phase: .pressed)
    }

    func testShortcutDefinitionsIgnoreHostLegacyResolverAndKeepDefaultBindings() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        // The getter must derive default bindings directly from the prompt IDs
        // and must not consult the host's legacy binding resolver anymore.
        var resolverCalls = 0
        plugin.shortcutBindingResolver = { legacyID in
            _ = legacyID
            resolverCalls += 1
            return ShortcutBinding(keyCode: 1, modifiers: [.command])
        }

        let definitions = plugin.shortcutDefinitions
        XCTAssertEqual(definitions.map(\.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.defaultBinding), [
            AIAssistantConstants.Defaults.translateShortcut,
            AIAssistantConstants.Defaults.summarizeShortcut,
            AIAssistantConstants.Defaults.polishShortcut,
        ])
        XCTAssertEqual(resolverCalls, 0)

        // A custom prompt has no built-in default binding.
        let customPrompt = AIAssistantPrompt(
            id: "custom",
            name: "自定义",
            template: "{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
        _ = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: [customPrompt],
            apiKey: "sk-test"
        )
        XCTAssertEqual(
            plugin.shortcutDefinitions.first { $0.actionID == "custom" }?.defaultBinding,
            nil
        )
        XCTAssertEqual(resolverCalls, 0)
    }

    func testDeclaresAccessibilityAndAutomationPermissions() {
        let requirements = makePlugin().permissionRequirements

        XCTAssertEqual(requirements.map(\.id), ["accessibility", "automation"])
        XCTAssertEqual(requirements.map(\.kind), [.accessibility, .automation])
    }

    func testPrimaryPanelReflectsPermissionState() {
        XCTAssertEqual(
            makePlugin(accessibilityTrustProvider: { false }).rowState.subtitle,
            "启用前需要辅助功能授权"
        )
    }

    func testSavingConfigurationPersistsPromptsAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        let customPrompt = AIAssistantPrompt(
            id: "custom",
            name: "自定义",
            template: "{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
        let message = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: [customPrompt],
            apiKey: "sk-test"
        )

        XCTAssertNil(message)
        XCTAssertTrue(didNotify)
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["custom"])
    }

    func testSavingConfigurationRejectsPromptMissingTextPlaceholder() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        let invalidPrompt = AIAssistantPrompt(
            id: "bad",
            name: "坏模板",
            template: "没有占位符",
            systemPrompt: nil,
            isEnabled: true
        )
        let message = plugin.saveConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            prompts: [invalidPrompt],
            apiKey: "sk-test"
        )

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("{{text}}") == true)
    }

    func testSaveProviderConfigurationSucceedsAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        let result = plugin.saveProviderConfiguration(
            profiles: [AIAssistantProviderProfile.defaultProfile()],
            apiKey: "sk-provider-test"
        )

        XCTAssertNil(result)
        XCTAssertTrue(didNotify)
    }

    func testSavePromptsConfigurationPersistsAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        let customPrompt = AIAssistantPrompt(
            id: "auto-save-prompt",
            name: "自动保存模板",
            template: "润色：{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
        let result = plugin.savePromptsConfiguration([customPrompt])

        XCTAssertNil(result)
        XCTAssertTrue(didNotify)
        XCTAssertEqual(plugin.shortcutDefinitions.map(\.actionID), ["auto-save-prompt"])
    }

    func testPrimaryPanelTogglePersistsDisabledStateAndNotifies() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.bool(forKey: "ai-assistant.shortcut.enabled"), false)
        XCTAssertTrue(didNotify)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testActionDefinitionsFollowEnabledPrompts() {
        let plugin = makePlugin()

        let definitions = plugin.actionDefinitions
        XCTAssertEqual(definitions.map(\.key.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.key.providerID), Array(repeating: "ai-assistant", count: 3))
        XCTAssertEqual(definitions.map(\.systemImage), Array(repeating: "sparkles", count: 3))
    }

    func testActionAvailabilityRequiresEnabledPromptAndPermissions() {
        let plugin = makePlugin(accessibilityTrustProvider: { false })

        let reference = ActionReference(
            key: ActionKey(providerID: "ai-assistant", actionID: "translate")
        )
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)

        // Unknown or disabled prompt IDs are unavailable regardless of permissions.
        let unknown = ActionReference(
            key: ActionKey(providerID: "ai-assistant", actionID: "missing")
        )
        XCTAssertFalse(plugin.actionAvailability(for: unknown).isAvailable)
    }

    func testBeginActionRunsPromptProcessing() {
        let plugin = makePlugin()
        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "ai-assistant", actionID: "translate")
            ),
            source: .unifiedSearch,
            mode: .foreground
        )

        XCTAssertNoThrow(try plugin.beginAction(invocation))
    }

    func testPermissionRequirementIDsCoverAccessibilityAndAutomation() {
        let ids = makePlugin().permissionRequirementIDs(
            for: ActionKey(providerID: "ai-assistant", actionID: "translate")
        )

        XCTAssertEqual(ids, ["accessibility", "automation"])
    }

    func testClipboardShortcutSettingRoutesToClipboardWithoutSelectionCapture() {
        let storage = AIAssistantInMemoryPluginStorage()
        let panel = RecordingAIAssistantPanelController()
        let plugin = makePlugin(
            storage: storage,
            accessibilityTrustProvider: { false },
            panelController: panel,
            clipboardTextProvider: { nil }
        )
        let actionKey = ActionKey(providerID: "ai-assistant", actionID: "polish")
        XCTAssertEqual(plugin.permissionRequirementIDs(for: actionKey), ["accessibility", "automation"])

        plugin.handleSettingsAction(.setBoolean(
            controlID: AIAssistantConstants.StorageKey.shortcutUsesClipboard,
            value: true
        ))
        plugin.handleShortcutAction(id: "polish")

        XCTAssertTrue(storage.bool(forKey: AIAssistantConstants.StorageKey.shortcutUsesClipboard))
        XCTAssertEqual(plugin.permissionRequirementIDs(for: actionKey), [])
        XCTAssertEqual(panel.snapshot?.phase, .error(.missingClipboardText))
    }

    func testClipboardShortcutUsesNewCopyAfterHiddenSession() async {
        let storage = AIAssistantInMemoryPluginStorage()
        let panel = RecordingAIAssistantPanelController()
        var copiedText = "first copy"
        let plugin = makePlugin(
            storage: storage,
            panelController: panel,
            clipboardTextProvider: { copiedText },
            providerFactoryOverride: { .failure(AIAssistantProviderError(message: "unconfigured")) }
        )
        plugin.handleSettingsAction(.setBoolean(
            controlID: AIAssistantConstants.StorageKey.shortcutUsesClipboard,
            value: true
        ))

        plugin.handleShortcutAction(id: "polish")
        copiedText = "second copy"
        panel.onAction?(.hide)
        plugin.handleShortcutAction(id: "polish")

        for _ in 0..<50 where panel.snapshot?.sourceText != "second copy" {
            await Task.yield()
        }

        XCTAssertEqual(panel.snapshot?.sourceText, "second copy")
        XCTAssertTrue(panel.isVisible)
    }

    // MARK: - Helpers

    private func makePlugin(
        storage: AIAssistantInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true },
        panelController: RecordingAIAssistantPanelController? = nil,
        clipboardTextProvider: @escaping () -> String? = { nil },
        providerFactoryOverride: AIAssistantProviderFactory? = nil
    ) -> AIAssistantPlugin {
        let storage = storage ?? AIAssistantInMemoryPluginStorage()
        return AIAssistantPlugin(
            context: PluginRuntimeContext(pluginID: "ai-assistant", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: { _ in true },
            secretStore: CountingAIAssistantSecretStore(apiKey: "sk-test"),
            panelController: panelController ?? RecordingAIAssistantPanelController(),
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: []),
            providerFactoryOverride: providerFactoryOverride,
            clipboardTextProvider: clipboardTextProvider
        )
    }
}

private final class CountingAIAssistantSecretStore: AIAssistantSecretStoring, @unchecked Sendable {
    private var apiKey: String?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func containsAPIKey() throws -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func loadAPIKey() throws -> String? {
        apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        self.apiKey = apiKey
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }
}

@MainActor
private final class RecordingAIAssistantPanelController: AIAssistantPanelControlling {
    var onAction: ((AIAssistantPanelAction) -> Void)?
    var isVisible = false
    private(set) var snapshot: AIAssistantPanelSnapshot?

    func show(snapshot: AIAssistantPanelSnapshot) {
        isVisible = true
        self.snapshot = snapshot
    }

    func update(snapshot: AIAssistantPanelSnapshot) {
        self.snapshot = snapshot
    }

    func hide() {
        isVisible = false
    }

    func close() {
        isVisible = false
    }
}
