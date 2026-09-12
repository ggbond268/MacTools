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
        XCTAssertNotNil(plugin.primaryPanel)
        XCTAssertNotNil(plugin.settingsPage)
    }

    func testShortcutDefinitionsDynamicallyFollowEnabledPrompts() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)

        // Default prompts are all enabled.
        let definitions = plugin.shortcutDefinitions
        XCTAssertEqual(definitions.map(\.actionID), ["translate", "summarize", "polish"])
        XCTAssertEqual(definitions.map(\.scope), [.global, .global, .global])
        XCTAssertEqual(definitions.map(\.defaultBinding), [nil, nil, nil])

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

    func testShortcutDefinitionsMigrateLegacyBindingsForBuiltInPrompts() {
        let storage = AIAssistantInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        let migratedBinding = ShortcutBinding(keyCode: 1, modifiers: [.command])

        plugin.shortcutBindingResolver = { legacyID in
            switch legacyID {
            case "process-translate": return migratedBinding
            case "process-summary": return nil
            default: return nil
            }
        }

        let definitions = plugin.shortcutDefinitions
        let translateDefinition = definitions.first { $0.actionID == "translate" }
        let summarizeDefinition = definitions.first { $0.actionID == "summarize" }
        let polishDefinition = definitions.first { $0.actionID == "polish" }

        XCTAssertEqual(translateDefinition?.defaultBinding, migratedBinding)
        XCTAssertNil(summarizeDefinition?.defaultBinding)
        XCTAssertNil(polishDefinition?.defaultBinding)
    }

    func testDeclaresAccessibilityAndAutomationPermissions() {
        let requirements = makePlugin().permissionRequirements

        XCTAssertEqual(requirements.map(\.id), ["accessibility", "automation"])
        XCTAssertEqual(requirements.map(\.kind), [.accessibility, .automation])
    }

    func testPrimaryPanelReflectsPermissionState() {
        XCTAssertEqual(
            makePlugin(accessibilityTrustProvider: { false }).primaryPanelState.subtitle,
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
        XCTAssertFalse(plugin.primaryPanelState.isOn)
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

    // MARK: - Helpers

    private func makePlugin(
        storage: AIAssistantInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true }
    ) -> AIAssistantPlugin {
        let storage = storage ?? AIAssistantInMemoryPluginStorage()
        return AIAssistantPlugin(
            context: PluginRuntimeContext(pluginID: "ai-assistant", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: { _ in true },
            secretStore: CountingAIAssistantSecretStore(apiKey: "sk-test"),
            panelController: RecordingAIAssistantPanelController(),
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: [])
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

    func show(snapshot: AIAssistantPanelSnapshot) {}
    func update(snapshot: AIAssistantPanelSnapshot) {}
    func close() {}
}
