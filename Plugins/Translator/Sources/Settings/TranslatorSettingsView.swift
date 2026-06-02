import SwiftUI
import MacToolsPluginKit

@MainActor
struct TranslatorSettingsView: View {
    @State private var firstLanguage: TranslatorLanguage
    @State private var secondLanguage: TranslatorLanguage
    @State private var baseURL: String
    @State private var model: String
    @State private var promptTemplate: String
    @State private var apiKey: String
    @State private var message: String?

    private let onSave: (OpenAICompatibleConfiguration, String, TranslatorLanguagePair) -> String?
    private let onRestoreDefaults: () -> (configuration: OpenAICompatibleConfiguration, languagePair: TranslatorLanguagePair)

    init(
        configuration: OpenAICompatibleConfiguration,
        apiKey: String,
        languagePair: TranslatorLanguagePair,
        onSave: @escaping (OpenAICompatibleConfiguration, String, TranslatorLanguagePair) -> String?,
        onRestoreDefaults: @escaping () -> (configuration: OpenAICompatibleConfiguration, languagePair: TranslatorLanguagePair)
    ) {
        _firstLanguage = State(initialValue: languagePair.first)
        _secondLanguage = State(initialValue: languagePair.second)
        _baseURL = State(initialValue: configuration.baseURL)
        _model = State(initialValue: configuration.model)
        _promptTemplate = State(initialValue: configuration.promptTemplate)
        _apiKey = State(initialValue: apiKey)
        self.onSave = onSave
        self.onRestoreDefaults = onRestoreDefaults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            languageSection
            providerSection
            promptSection
            actions
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader("偏好语言", icon: "character.book.closed")

            VStack(spacing: 0) {
                languageRow(title: "第一语言", description: "自动识别为其他语言时翻译到这里。") {
                    languagePicker(selection: $firstLanguage)
                }

                PluginSettingsListDivider()

                languageRow(title: "第二语言", description: "识别为第一语言时翻译到这里。") {
                    languagePicker(selection: $secondLanguage)
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader("OpenAI 兼容服务", icon: "network")

            VStack(spacing: 0) {
                fieldRow(title: "Base URL", description: "OpenAI 或兼容网关地址。") {
                    TextField("https://api.openai.com", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                }

                PluginSettingsListDivider()

                fieldRow(title: "API Key", description: "保存在系统钥匙串。") {
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                }

                PluginSettingsListDivider()

                fieldRow(title: "模型", description: "用于翻译的模型名称。") {
                    TextField("gpt-5.4-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                }
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            sectionHeader("提示词", icon: "text.alignleft")

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text("模板")
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text("必须包含 {{text}}。可使用 {{source_language}} 和 {{target_language}}。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptTemplate)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150, idealHeight: 180, maxHeight: 240)
                    .background(PluginSettingsTheme.Palette.nativeFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous))
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.host)
        }
    }

    private var actions: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button("恢复默认") {
                let defaults = onRestoreDefaults()
                baseURL = defaults.configuration.baseURL
                model = defaults.configuration.model
                promptTemplate = defaults.configuration.promptTemplate
                firstLanguage = defaults.languagePair.first
                secondLanguage = defaults.languagePair.second
                message = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if let message {
                Text(message)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(message == "已保存" ? Color.secondary : Color.red)
            }

            Button("保存") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }

    private func fieldRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            content()
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func languageRow<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        fieldRow(title: title, description: description, content: content)
    }

    private func languagePicker(selection: Binding<TranslatorLanguage>) -> some View {
        Picker("", selection: selection) {
            ForEach(TranslatorLanguage.allCases) { language in
                Text("\(language.flag) \(language.displayName)")
                    .tag(language)
            }
        }
        .labelsHidden()
        .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
    }

    private func save() {
        let languagePair = TranslatorLanguagePair(first: firstLanguage, second: secondLanguage)

        guard languagePair.first != languagePair.second else {
            message = "两种偏好语言不能相同。"
            return
        }

        let configuration = OpenAICompatibleConfiguration(
            baseURL: baseURL,
            model: model,
            promptTemplate: promptTemplate
        )

        message = onSave(configuration, apiKey, languagePair) ?? "已保存"
    }
}
