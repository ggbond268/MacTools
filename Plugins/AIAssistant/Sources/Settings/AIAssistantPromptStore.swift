import Foundation
import MacToolsPluginKit

@MainActor
struct AIAssistantPromptStore {
    let storage: PluginStorage
    let localization: PluginLocalization

    init(
        storage: PluginStorage,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.storage = storage
        self.localization = localization
    }

    func loadPrompts() -> [AIAssistantPrompt] {
        if let data = storage.data(forKey: AIAssistantConstants.StorageKey.prompts),
           let prompts = try? JSONDecoder().decode([AIAssistantPrompt].self, from: data),
           !prompts.isEmpty {
            return prompts
        }

        return Self.defaultPrompts(localization: localization)
    }

    func savePrompts(_ prompts: [AIAssistantPrompt]) throws {
        let data = try JSONEncoder().encode(prompts)
        storage.set(data, forKey: AIAssistantConstants.StorageKey.prompts)
    }

    func makeNewPrompt(existing: [AIAssistantPrompt]) -> AIAssistantPrompt {
        let existingNames = Set(existing.map(\.normalizedName))
        var index = existing.count + 1
        var name = localization.string("prompt.newDefaultName", defaultValue: "新模板 \(index)")

        while existingNames.contains(name) {
            index += 1
            name = localization.string("prompt.newDefaultName", defaultValue: "新模板 \(index)")
        }

        return AIAssistantPrompt(
            id: UUID().uuidString,
            name: name,
            template: "{{text}}",
            systemPrompt: nil,
            isEnabled: true
        )
    }

    static func defaultPrompts(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> [AIAssistantPrompt] {
        [
            AIAssistantPrompt(
                id: "translate",
                name: localization.string("prompt.default.translate.name", defaultValue: "翻译"),
                template: localization.string(
                    "prompt.default.translate.template",
                    defaultValue: "请将下面的文本翻译为另一种语言：若原文是中文则译为英文，否则译为简体中文，只返回译文。\n\n{{text}}"
                ),
                systemPrompt: localization.string(
                    "prompt.default.translate.systemPrompt",
                    defaultValue: "你是一名专业的翻译助手。"
                ),
                isEnabled: true
            ),
            AIAssistantPrompt(
                id: "summarize",
                name: localization.string("prompt.default.summarize.name", defaultValue: "总结"),
                template: localization.string(
                    "prompt.default.summarize.template",
                    defaultValue: "请用简洁的语言总结下面的文本要点。\n\n{{text}}"
                ),
                systemPrompt: localization.string(
                    "prompt.default.summarize.systemPrompt",
                    defaultValue: "你是一名擅长提炼要点的助手。"
                ),
                isEnabled: true
            ),
            AIAssistantPrompt(
                id: "polish",
                name: localization.string("prompt.default.polish.name", defaultValue: "润色"),
                template: localization.string(
                    "prompt.default.polish.template",
                    defaultValue: "请润色下面的文本，使其表达更清晰、更自然，保持原意不变。\n\n{{text}}"
                ),
                systemPrompt: localization.string(
                    "prompt.default.polish.systemPrompt",
                    defaultValue: "你是一名专业的文字编辑。"
                ),
                isEnabled: true
            ),
        ]
    }
}
