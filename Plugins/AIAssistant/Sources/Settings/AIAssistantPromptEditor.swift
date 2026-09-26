import Combine
import MacToolsPluginKit

@MainActor
final class AIAssistantPromptEditor: ObservableObject {
    @Published private(set) var prompts: [AIAssistantPrompt]
    @Published private(set) var promptEditDrafts: [String: AIAssistantPrompt] = [:]
    @Published private(set) var message: String?
    var messageIsError: Bool { message != nil }
    private var pendingIDs: Set<String> = []
    private let localization: PluginLocalization
    private let persist: ([AIAssistantPrompt]) -> String?
    private let makePrompt: ([AIAssistantPrompt]) -> AIAssistantPrompt

    init(
        prompts: [AIAssistantPrompt],
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        persist: @escaping ([AIAssistantPrompt]) -> String?,
        makePrompt: @escaping ([AIAssistantPrompt]) -> AIAssistantPrompt
    ) {
        self.prompts = prompts
        self.localization = localization
        self.persist = persist
        self.makePrompt = makePrompt
    }

    func isEditing(_ id: String) -> Bool { promptEditDrafts[id] != nil }

    func beginEditing(_ id: String) {
        guard !isEditing(id), let prompt = prompts.first(where: { $0.id == id }) else { return }
        promptEditDrafts[id] = prompt
    }

    func updateDraft<Value>(_ id: String, keyPath: WritableKeyPath<AIAssistantPrompt, Value>, value: Value) {
        guard isEditing(id) else { return }
        promptEditDrafts[id]?[keyPath: keyPath] = value
        message = nil
    }

    func addPrompt() {
        let prompt = makePrompt(prompts.map { promptEditDrafts[$0.id] ?? $0 })
        pendingIDs.insert(prompt.id)
        prompts.append(prompt)
        promptEditDrafts[prompt.id] = prompt
        message = nil
    }

    func cancel(_ id: String) {
        if pendingIDs.remove(id) != nil { prompts.removeAll { $0.id == id } }
        promptEditDrafts.removeValue(forKey: id)
        message = nil
    }

    func save(_ id: String) {
        guard let draft = promptEditDrafts[id],
              let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        if draft.normalizedName.isEmpty {
            message = localization.string("settings.prompt.error.emptyName", defaultValue: "模板名称不能为空")
            return
        }
        if prompts.contains(where: { $0.id != id && !pendingIDs.contains($0.id) && $0.normalizedName == draft.normalizedName }) {
            message = localization.string("settings.prompt.error.duplicateName", defaultValue: "模板名称与现有模板重复")
            return
        }
        let snapshot = prompts.compactMap { prompt -> AIAssistantPrompt? in
            if prompt.id == id { return draft }
            return pendingIDs.contains(prompt.id) ? nil : prompt
        }
        message = persist(snapshot)
        guard message == nil else { return }
        prompts[index] = draft
        pendingIDs.remove(id)
        promptEditDrafts.removeValue(forKey: id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        var updated = prompts
        updated[index].isEnabled = enabled
        commit(updated)
    }

    func movePrompt(_ id: String, offset: Int) {
        guard let index = prompts.firstIndex(where: { $0.id == id }),
              prompts.indices.contains(index + offset) else { return }
        var updated = prompts
        updated.swapAt(index, index + offset)
        commit(updated)
    }

    func deletePrompt(_ id: String) {
        guard !pendingIDs.contains(id) else {
            cancel(id)
            return
        }
        guard commit(prompts.filter { $0.id != id }) else { return }
        promptEditDrafts.removeValue(forKey: id)
    }

    @discardableResult
    private func commit(_ updated: [AIAssistantPrompt]) -> Bool {
        message = persist(updated.filter { !pendingIDs.contains($0.id) })
        guard message == nil else { return false }
        prompts = updated
        return true
    }
}
