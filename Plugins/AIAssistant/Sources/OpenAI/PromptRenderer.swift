import Foundation
import MacToolsPluginKit

struct PromptRenderer: Sendable {
    let template: String

    init(template: String) {
        self.template = template
    }

    func render(text: String) throws -> String {
        guard template.contains("{{text}}") else {
            throw PromptRendererError.missingTextPlaceholder
        }

        return template.replacingOccurrences(of: "{{text}}", with: text)
    }
}

enum PromptRendererError: Error, Equatable, Sendable {
    case missingTextPlaceholder
}

extension PromptRendererError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .missingTextPlaceholder:
            return localization.string(
                "prompt.error.missingTextPlaceholder",
                defaultValue: "提示词必须包含 {{text}}。"
            )
        }
    }
}
