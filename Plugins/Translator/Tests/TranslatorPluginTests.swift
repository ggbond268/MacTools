import Carbon
import MacToolsPluginKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class TranslatorPluginTests: XCTestCase {
    func testMetadataMatchesManifestContract() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "translator")
        XCTAssertEqual(plugin.metadata.title, "翻译")
        XCTAssertEqual(plugin.metadata.defaultDescription, "划词与截图快捷键翻译")
        XCTAssertTrue(plugin.panelItems.contains { $0.kind == .row })
        XCTAssertNotNil(plugin.settingsPage)
    }

    func testShortcutDefinitionsIncludeSelectAndScreenshotTranslation() {
        let definitions = makePlugin().shortcutDefinitions

        XCTAssertEqual(definitions.map(\.id), [
            "translator.select-translation",
            "translator.screenshot-translation",
        ])
        XCTAssertEqual(definitions.map(\.actionID), [
            "select-translation",
            "screenshot-translation",
        ])
        XCTAssertEqual(definitions.map(\.scope), [.global, .global])
        XCTAssertEqual(definitions.first?.defaultBinding?.keyCode, UInt16(kVK_ANSI_D))
        XCTAssertEqual(definitions.last?.defaultBinding?.keyCode, UInt16(kVK_ANSI_S))
    }

    func testDeclaresAccessibilityAutomationAndScreenRecordingPermissions() {
        let requirements = makePlugin().permissionRequirements

        XCTAssertEqual(requirements.map(\.id), ["accessibility", "automation", "screen-recording"])
        XCTAssertEqual(requirements.map(\.kind), [.accessibility, .automation, .screenRecording])
    }

    func testPrimaryPanelReflectsPermissionAndSetupState() {
        XCTAssertEqual(
            makePlugin(accessibilityTrustProvider: { false }).rowState.subtitle,
            "启用前需要辅助功能授权"
        )

        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage, secretStore: CountingTranslatorSecretStore(apiKey: nil))
        let message = plugin.saveConfiguration(
            OpenAICompatibleConfiguration(
                baseURL: "https://gateway.example.com",
                model: "gpt-test",
                promptTemplate: "{{text}}"
            ),
            apiKey: "",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertEqual(message, "API Key 不能为空。")
        XCTAssertEqual(plugin.rowState.subtitle, "需要配置翻译服务")
    }

    func testSavingBlankAPIKeyPreservesExistingKey() {
        let secretStore = CountingTranslatorSecretStore(apiKey: "sk-existing")
        let plugin = makePlugin(secretStore: secretStore)

        let message = plugin.saveConfiguration(
            OpenAICompatibleConfiguration(
                baseURL: "https://gateway.example.com",
                model: "gpt-test",
                promptTemplate: "{{text}}"
            ),
            apiKey: "",
            languagePair: TranslatorLanguagePair(first: .english, second: .simplifiedChinese)
        )

        XCTAssertNil(message)
        XCTAssertEqual(secretStore.saveCount, 0)
        XCTAssertEqual(plugin.rowState.subtitle, "按 ⌥D 划词，⌥S 截图")
    }

    func testPrimaryPanelTogglePersistsDisabledStateAndNotifies() {
        let storage = TranslatorInMemoryPluginStorage()
        let plugin = makePlugin(storage: storage)
        var didNotify = false
        plugin.onStateChange = { didNotify = true }

        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.bool(forKey: "translator.shortcut.enabled"), false)
        XCTAssertTrue(didNotify)
        XCTAssertFalse(plugin.rowState.isOn)
    }

    func testActionsReuseTranslationStartersAndMigrateLegacyBindings() async throws {
        var selectStartCount = 0
        let plugin = makePlugin(selectTranslationStarter: { selectStartCount += 1 })
        plugin.shortcutBindingResolver = { shortcutID in
            shortcutID == "translator.select-translation"
                ? ShortcutBinding(keyCode: UInt16(kVK_ANSI_D), modifiers: [.option])
                : nil
        }
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .foreground)
        ).result()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), [
            "select-translation",
            "screenshot-translation",
        ])
        XCTAssertEqual(plugin.legacyActionShortcutAssignments.count, 1)
        XCTAssertEqual(
            plugin.legacyActionShortcutAssignments.first?.legacyShortcutDefinitionID,
            "translator.select-translation"
        )
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(selectStartCount, 1)
    }

    private func makePlugin(
        storage: TranslatorInMemoryPluginStorage? = nil,
        accessibilityTrustProvider: @escaping () -> Bool = { true },
        secretStore: (any TranslatorSecretStoring)? = nil,
        selectTranslationStarter: (() -> Void)? = nil
    ) -> TranslatorPlugin {
        let storage = storage ?? TranslatorInMemoryPluginStorage()
        return TranslatorPlugin(
            context: PluginRuntimeContext(pluginID: "translator", storage: storage),
            accessibilityTrustProvider: accessibilityTrustProvider,
            accessibilityTrustRequester: { _ in true },
            screenRecordingPermissionProvider: { true },
            selectTranslationStarter: selectTranslationStarter,
            secretStore: secretStore ?? CountingTranslatorSecretStore(apiKey: "sk-test"),
            panelController: RecordingTranslatorPanelController(),
            selectedTextCapturePipeline: SelectedTextCapturePipeline(strategies: [])
        )
    }
}

private final class CountingTranslatorSecretStore: TranslatorSecretStoring, @unchecked Sendable {
    private var apiKey: String?
    private(set) var saveCount = 0

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func containsAPIKey() throws -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func containsAPIKey(forProfileID _: String) throws -> Bool {
        try containsAPIKey()
    }

    func loadAPIKey() throws -> String? {
        apiKey
    }

    func loadAPIKey(forProfileID _: String) throws -> String? {
        apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        saveCount += 1
        self.apiKey = apiKey
    }

    func saveAPIKey(_ apiKey: String, forProfileID _: String) throws {
        try saveAPIKey(apiKey)
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }

    func deleteAPIKey(forProfileID _: String) throws {
        try deleteAPIKey()
    }
}

@MainActor
private final class RecordingTranslatorPanelController: TranslatorPanelControlling {
    var onAction: ((TranslatorPanelAction) -> Void)?

    func show(snapshot _: TranslatorPanelSnapshot) {}
    func update(snapshot _: TranslatorPanelSnapshot) {}
    func close() {}
}
