import AppKit
import Carbon
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class TranslatorPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        TranslatorPluginProvider(context: context)
    }
}

@MainActor
private struct TranslatorPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [TranslatorPlugin(context: context)]
    }
}

@MainActor
final class TranslatorPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginConfigurationPresenting {
    let metadata = PluginMetadata(
        id: TranslatorConstants.pluginID,
        title: "翻译",
        iconName: "text.bubble",
        iconTint: Color(nsColor: .systemBlue),
        order: 57,
        defaultDescription: "划词快捷键翻译"
    )

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var requestPluginConfigurationPresentation: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let storage: PluginStorage
    private let accessibilityTrustProvider: () -> Bool
    private let accessibilityTrustRequester: (Bool) -> Bool
    private let selectTranslationStarter: (() -> Void)?
    private let secretStore: OpenAICompatibleSecretStore
    private let languagePreferenceStore: LanguagePreferenceStore
    private let panelController: any TranslatorPanelControlling
    private let selectedTextCapturePipeline: SelectedTextCapturePipeline
    private let translationProviderFactoryOverride: TranslatorProviderFactory?
    private var providerConfiguration: OpenAICompatibleConfiguration
    private var languagePair: TranslatorLanguagePair
    private var hasAPIKey: Bool
    private var coordinator: TranslatorCoordinator?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: TranslatorConstants.pluginID),
        accessibilityTrustProvider: @escaping () -> Bool = AccessibilityCheck.isTrusted,
        accessibilityTrustRequester: @escaping (Bool) -> Bool = AccessibilityCheck.requestTrust,
        selectTranslationStarter: (() -> Void)? = nil,
        secretStore: OpenAICompatibleSecretStore = OpenAICompatibleSecretStore(),
        panelController: any TranslatorPanelControlling = TranslatorPanelController(),
        selectedTextCapturePipeline: SelectedTextCapturePipeline = .live(),
        translationProviderFactoryOverride: TranslatorProviderFactory? = nil
    ) {
        self.storage = context.storage
        self.accessibilityTrustProvider = accessibilityTrustProvider
        self.accessibilityTrustRequester = accessibilityTrustRequester
        self.selectTranslationStarter = selectTranslationStarter
        self.secretStore = secretStore
        self.panelController = panelController
        self.selectedTextCapturePipeline = selectedTextCapturePipeline
        self.translationProviderFactoryOverride = translationProviderFactoryOverride
        let languagePreferenceStore = LanguagePreferenceStore(storage: context.storage)
        self.languagePreferenceStore = languagePreferenceStore
        self.providerConfiguration = OpenAICompatibleConfiguration(storage: context.storage)
        self.languagePair = languagePreferenceStore.loadPair()
        self.hasAPIKey = Self.hasNonEmptyAPIKey(try? secretStore.loadAPIKey())
        panelController.onAction = { [weak self] action in
            self?.handlePanelAction(action)
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: isShortcutEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: TranslatorConstants.PermissionID.accessibility,
                kind: .accessibility,
                title: "辅助功能授权",
                description: "划词翻译需要读取当前选中文本。"
            ),
            PluginPermissionRequirement(
                id: TranslatorConstants.PermissionID.automation,
                kind: .automation,
                title: "自动化授权",
                description: "浏览器划词可能需要允许 MacTools 控制当前浏览器。"
            ),
        ]
    }

    var settingsSections: [PluginSettingsSection] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: TranslatorConstants.ShortcutID.selectTranslation,
                title: "划词翻译",
                description: "翻译当前选中的文本。",
                actionID: TranslatorConstants.ActionID.selectTranslation,
                scope: .global,
                defaultBinding: ShortcutBinding(
                    keyCode: UInt16(kVK_ANSI_D),
                    modifiers: [.option]
                ),
                isRequired: false
            )
        ]
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription, prefersFullHeight: false) { [weak self] _ in
            if let self {
                TranslatorSettingsView(
                    configuration: self.providerConfiguration,
                    apiKey: (try? self.secretStore.loadAPIKey()) ?? "",
                    languagePair: self.languagePair,
                    onSave: { [weak self] configuration, apiKey, languagePair in
                        self?.saveConfiguration(configuration, apiKey: apiKey, languagePair: languagePair)
                    },
                    onRestoreDefaults: {
                        (
                            configuration: OpenAICompatibleConfiguration(),
                            languagePair: LanguagePreferenceStore.defaultPair(fromPreferredLanguages: Locale.preferredLanguages)
                        )
                    }
                )
            } else {
                EmptyView()
            }
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }

        storage.set(isEnabled, forKey: TranslatorConstants.StorageKey.shortcutEnabled)
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case TranslatorConstants.PermissionID.accessibility:
            let isGranted = accessibilityTrustProvider()
            return PluginPermissionState(
                isGranted: isGranted,
                footnote: isGranted ? nil : "前往系统设置 → 隐私与安全性 → 辅助功能，授权 MacTools。"
            )
        case TranslatorConstants.PermissionID.automation:
            return PluginPermissionState(
                isGranted: true,
                footnote: "macOS 会在首次控制浏览器时请求自动化授权。",
                statusText: "按需确认",
                statusSystemImage: "sparkles",
                statusTone: .neutral
            )
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case TranslatorConstants.PermissionID.accessibility:
            _ = accessibilityTrustRequester(true)
            onStateChange?()
        case TranslatorConstants.PermissionID.automation:
            requestPermissionGuidance?(TranslatorConstants.PermissionID.automation)
            onStateChange?()
        default:
            return
        }
    }

    func handleSettingsAction(id: String) {}

    func handleShortcutAction(id: String) {
        guard id == TranslatorConstants.ActionID.selectTranslation,
              isShortcutEnabled
        else {
            return
        }

        if let selectTranslationStarter {
            selectTranslationStarter()
            return
        }

        let coordinator = coordinator ?? makeCoordinator()
        self.coordinator = coordinator
        coordinator.startSelectTranslation()
    }

    private var isShortcutEnabled: Bool {
        guard storage.object(forKey: TranslatorConstants.StorageKey.shortcutEnabled) != nil else {
            return TranslatorConstants.Defaults.shortcutEnabled
        }

        return storage.bool(forKey: TranslatorConstants.StorageKey.shortcutEnabled)
    }

    private var panelSubtitle: String {
        if !isShortcutEnabled { return "快捷键已暂停" }
        if !accessibilityTrustProvider() { return "启用前需要辅助功能授权" }
        if providerConfiguration.validationError != nil || !hasAPIKey { return "需要配置 OpenAI" }
        guard let binding = shortcutBindingResolver?(TranslatorConstants.ShortcutID.selectTranslation) else {
            return "按快捷键翻译选中文本"
        }

        return "按 \(ShortcutFormatter.displayString(for: binding)) 翻译选中文本"
    }

    func saveConfiguration(
        _ configuration: OpenAICompatibleConfiguration,
        apiKey: String,
        languagePair: TranslatorLanguagePair
    ) -> String? {
        guard languagePair.first != languagePair.second else {
            return "两种偏好语言不能相同。"
        }

        if let validationError = configuration.validationError {
            return validationError.localizedDescription
        }

        do {
            try secretStore.saveAPIKey(apiKey)
            configuration.save(to: storage)
            languagePreferenceStore.savePair(languagePair)
            providerConfiguration = configuration
            self.languagePair = languagePair
            hasAPIKey = Self.hasNonEmptyAPIKey(try secretStore.loadAPIKey())
            if let coordinator {
                coordinator.close()
            } else {
                panelController.close()
            }
            coordinator = nil
            onStateChange?()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func handlePanelAction(_ action: TranslatorPanelAction) {
        if action == .openSettings {
            requestPluginConfigurationPresentation?(metadata.id)
            return
        }

        if action == .close {
            if let coordinator {
                coordinator.close()
            } else {
                panelController.close()
            }
            return
        }

        guard let coordinator else { return }

        Task { await coordinator.handle(action) }
    }

    private func makeCoordinator() -> TranslatorCoordinator {
        TranslatorCoordinator(
            selectedTextCapturePipeline: selectedTextCapturePipeline,
            languagePreferenceStore: LanguagePreferenceStore(storage: storage),
            providerFactory: translationProviderFactoryOverride ?? { [weak self] in
                guard let self else {
                    return .missing(message: "请先配置 OpenAI")
                }

                guard self.providerConfiguration.validationError == nil,
                      let key = try? self.secretStore.loadAPIKey()
                else {
                    return .missing(message: "请先配置 OpenAI")
                }

                let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedKey.isEmpty else {
                    return .missing(message: "请先配置 OpenAI")
                }

                return .provider(
                    OpenAITranslationProviderAdapter(
                        client: OpenAICompatibleClient(),
                        configuration: self.providerConfiguration,
                        apiKey: trimmedKey
                    )
                )
            },
            panelController: panelController
        )
    }

    private static func hasNonEmptyAPIKey(_ apiKey: String?) -> Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
