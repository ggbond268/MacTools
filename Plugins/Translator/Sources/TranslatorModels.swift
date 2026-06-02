import Foundation

enum TranslatorPanelPhase: Equatable, Sendable {
    case idle
    case capturing
    case translating
    case success
    case error(TranslatorPanelError)
}

enum TranslatorPanelError: Equatable, Sendable {
    case missingSelection
    case missingConfiguration
    case permissionRequired
    case automationPermissionRequired
    case requestFailed(String)

    var message: String {
        switch self {
        case .missingSelection:
            return "未找到选中文本"
        case .missingConfiguration:
            return "请先配置 OpenAI"
        case .permissionRequired:
            return "需要辅助功能授权"
        case .automationPermissionRequired:
            return "需要自动化授权"
        case let .requestFailed(message):
            return message
        }
    }
}

struct TranslatorPanelSnapshot: Equatable, Sendable {
    var phase: TranslatorPanelPhase
    var sourceText: String?
    var languageSelection: TranslatorLanguageSelection?
    var translation: TranslationResult?
    var errorMessage: String?

    static let idle = TranslatorPanelSnapshot(
        phase: .idle,
        sourceText: nil,
        languageSelection: nil,
        translation: nil,
        errorMessage: nil
    )
}

enum TranslatorPanelAction: Equatable, Sendable {
    case retry
    case close
    case copySource
    case copyTranslation
    case speakSource
    case speakTranslation
    case openSettings
}

enum TranslatorProviderBuildResult {
    case provider(any TranslationProviding)
    case missing(message: String)
}
